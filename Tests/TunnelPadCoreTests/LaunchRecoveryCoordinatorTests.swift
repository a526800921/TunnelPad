import XCTest
@testable import TunnelPadCore

final class LaunchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    var pending: Int { lock.withLock { waits.count } }
    var clock: LaunchRecoveryClock { .init(now: { self.now }, sleep: { try await self.sleep($0) }) }
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if delay <= 0 { continuation.resume() }
                    else { waits[id] = (instant + delay, continuation) }
                }
            }
        }, onCancel: { self.lock.withLock { self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } })
    }
    func advance(_ interval: TimeInterval) {
        lock.withLock {
            instant += interval
            for (id, wait) in waits.filter({ $0.value.0 <= instant }) { waits.removeValue(forKey: id); wait.1.resume() }
        }
    }
}

@MainActor
final class LaunchRecoveryCoordinatorTests: XCTestCase {
    private func tunnel(_ id: String) -> TunnelConfig { .init(id: id, name: id, command: ["/bin/true"], autoStart: true) }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("异步状态未收敛"); throw CancellationError()
    }
    func testProductionCoordinatorBackoffDayWakeAndNoSuccessTimer() async throws {
        let clock = LaunchTestClock(); var calls = 0; let availability = LaunchTestAvailability(); var handed = 0; var reports = 0
        let coordinator = LaunchRecoveryCoordinator(clock: clock.clock, attempt: { _ in
            calls += 1; return availability.online ? .running(.running(pid: 123)) : .retry(.transient)
        }, handoff: { _, _ in handed += 1 }, report: { _, _, _ in reports += 1 })
        coordinator.start([.init(tunnel: tunnel("a"), resource: nil)])
        try await eventually { calls == 1 && clock.pending == 1 }
        for (count, delay) in [5.0, 15, 30, 60, 300].enumerated() {
            clock.advance(delay - 1); await Task.yield(); XCTAssertEqual(calls, count + 1)
            clock.advance(1); try await eventually { calls == count + 2 && clock.pending == 1 }
        }
        XCTAssertEqual(reports, 1, "相同故障快速重试不能刷日志")
        availability.online = true; clock.advance(86_400)
        try await eventually { handed == 1 && coordinator.ownedIDs.isEmpty && clock.pending == 0 }
        XCTAssertEqual(calls, 7, "唤醒不补发错过的重试")
        clock.advance(86_400); await Task.yield(); XCTAssertEqual(calls, 7)
        await coordinator.shutdown()
    }
    func testSameResourceDoesNotConsumeOtherGlobalSlotAndCancellationWaitsForCleanup() async throws {
        let clock = LaunchTestClock(); var started: [String] = []; var completions: [String: CheckedContinuation<LaunchRecoveryOutcome, Never>] = [:]
        let coordinator = LaunchRecoveryCoordinator(clock: clock.clock, attempt: { tunnel in
            started.append(tunnel.id)
            return await withCheckedContinuation { completions[tunnel.id] = $0 }
        }, handoff: { _, _ in }, report: { _, _, _ in })
        coordinator.start([.init(tunnel: tunnel("a"), resource: "ecs"), .init(tunnel: tunnel("b"), resource: "ecs"), .init(tunnel: tunnel("c"), resource: "other")])
        try await eventually { started.count == 2 }
        XCTAssertEqual(Set(started), ["a", "c"]); XCTAssertEqual(coordinator.activeCount, 2)
        coordinator.cancel("a"); await Task.yield()
        XCTAssertEqual(coordinator.activeCount, 2); XCTAssertFalse(started.contains("b"))
        completions.removeValue(forKey: "a")?.resume(returning: .running(.running(pid: 1)))
        try await eventually { started.contains("b") }
        XCTAssertFalse(coordinator.ownedIDs.contains("a"))
        completions.removeValue(forKey: "b")?.resume(returning: .running(.running(pid: 2)))
        completions.removeValue(forKey: "c")?.resume(returning: .running(.running(pid: 3)))
        try await eventually { coordinator.ownedIDs.isEmpty }
        await coordinator.shutdown()
    }
    func testResourceAuthenticationCooldownAndPermanentPrerequisitePolling() async throws {
        let clock = LaunchTestClock(); var calls: [String] = []
        let coordinator = LaunchRecoveryCoordinator(clock: clock.clock, attempt: { tunnel in
            calls.append(tunnel.id); return .retry(tunnel.id == "a" ? .auth : .local)
        }, handoff: { _, _ in }, report: { _, _, _ in })
        coordinator.start([.init(tunnel: tunnel("a"), resource: "ecs"), .init(tunnel: tunnel("b"), resource: "ecs"), .init(tunnel: tunnel("c"), resource: nil)])
        try await eventually { calls.count == 2 && clock.pending == 1 }
        XCTAssertEqual(Set(calls), ["a", "c"])
        clock.advance(300); try await eventually { calls.count == 3 && clock.pending == 1 }
        XCTAssertFalse(calls.contains("b"))
        clock.advance(1500); try await eventually { calls.contains("b") }
        await coordinator.shutdown(); let count = calls.count
        clock.advance(86_400); await Task.yield(); XCTAssertEqual(calls.count, count)
    }
    func testRunningWithoutPIDDoesNotHandoff() async throws {
        let clock = LaunchTestClock(); var calls = 0; var handed = false
        let coordinator = LaunchRecoveryCoordinator(clock: clock.clock, attempt: { _ in calls += 1; return .running(.running(pid: nil)) }, handoff: { _, _ in handed = true }, report: { _, _, _ in })
        coordinator.start([.init(tunnel: tunnel("a"), resource: nil)])
        try await eventually { calls == 1 && clock.pending == 1 }
        XCTAssertFalse(handed); XCTAssertEqual(coordinator.ownedIDs, ["a"])
        await coordinator.shutdown()
    }
}

@MainActor
private final class LaunchTestAvailability { var online = false }
