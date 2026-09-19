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
        for (count, delay) in [5.0, 10, 30, 60, 60].enumerated() {
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
        clock.advance(60); try await eventually { calls.contains("b") && clock.pending == 1 }
        await coordinator.shutdown(); let count = calls.count
        clock.advance(86_400); await Task.yield(); XCTAssertEqual(calls.count, count)
    }
    func testRuntimePreflightCoordinatorCapsDifferentResources() async throws {
        let coordinator = SharedRecoveryPreflightCoordinator(maximumConcurrentResources: 2)
        let probe = SharedPreflightCapacityProbe()

        async let first = coordinator.run(resource: "a") { await probe.run("a") }
        async let second = coordinator.run(resource: "b") { await probe.run("b") }
        async let third = coordinator.run(resource: "c") { await probe.run("c") }

        var snapshot = await probe.snapshot()
        for _ in 0..<2_000 where snapshot.calls.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
            snapshot = await probe.snapshot()
        }
        XCTAssertEqual(snapshot.calls.count, 2)
        XCTAssertEqual(snapshot.maximumActive, 2)

        await probe.releaseAndStopBlocking()
        _ = try await (first, second, third)
        snapshot = await probe.snapshot()
        XCTAssertEqual(Set(snapshot.calls), ["a", "b", "c"])
        XCTAssertEqual(snapshot.maximumActive, 2)
    }
    func testRuntimePreflightCoordinatorCachesAuthenticationFailureByResource() async throws {
        let clock = LaunchTestClock()
        let coordinator = SharedRecoveryPreflightCoordinator(clock: clock.clock)
        let probe = SharedPreflightAuthenticationProbe()

        let first = try await coordinator.run(resource: "ecs") { await probe.run() }
        let second = try await coordinator.run(resource: "ecs") { await probe.run() }
        XCTAssertEqual(first.category, .auth)
        XCTAssertEqual(second.sanitizedCode, "authentication_failed")
        var calls = await probe.calls
        XCTAssertEqual(calls, 1, "认证冷却期间必须复用脱敏结构化结果")

        clock.advance(59)
        _ = try await coordinator.run(resource: "ecs") { await probe.run() }
        calls = await probe.calls
        XCTAssertEqual(calls, 1)

        clock.advance(1)
        _ = try await coordinator.run(resource: "ecs") { await probe.run() }
        calls = await probe.calls
        XCTAssertEqual(calls, 2, "冷却到期后才允许新的安全复核")
    }
    func testRemotePortCleanupSerializesSamePortWithoutSharingResult() async throws {
        let coordinator = RemotePortCleanupCoordinator()
        let probe = RemotePortCleanupProbe()

        async let first = coordinator.run(resource: "root@example:22/tcp/18080") {
            await probe.run("first")
        }
        async let second = coordinator.run(resource: "root@example:22/tcp/18080") {
            await probe.run("second")
        }

        var snapshot = await probe.snapshot()
        for _ in 0..<2_000 where snapshot.calls.count < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
            snapshot = await probe.snapshot()
        }
        XCTAssertEqual(snapshot.calls.count, 1)
        XCTAssertEqual(snapshot.maximumActive, 1)

        await probe.releaseOne()
        for _ in 0..<2_000 where snapshot.calls.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
            snapshot = await probe.snapshot()
        }
        XCTAssertEqual(Set(snapshot.calls), ["first", "second"], "每条隧道都必须重新执行端口确认")
        XCTAssertEqual(snapshot.maximumActive, 1, "同一远端端口不能并发强杀")

        await probe.releaseOne()
        _ = try await (first, second)
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

private actor SharedPreflightCapacityProbe {
    struct Snapshot: Sendable {
        let calls: [String]
        let maximumActive: Int
    }

    private var calls: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var blocking = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(_ resource: String) async -> LaunchPreflightResult {
        calls.append(resource)
        active += 1
        maximumActive = max(maximumActive, active)
        if blocking {
            await withCheckedContinuation { continuations.append($0) }
        }
        active -= 1
        return LaunchPreflightResult(
            version: 1,
            stage: "complete",
            category: .success,
            retryHint: 0,
            sanitizedCode: "synchronized",
            exitCode: 0
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(calls: calls, maximumActive: maximumActive)
    }

    func releaseAndStopBlocking() {
        blocking = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SharedPreflightAuthenticationProbe {
    private(set) var calls = 0

    func run() -> LaunchPreflightResult {
        calls += 1
        return LaunchPreflightResult(
            version: 1,
            stage: "authenticate",
            category: .auth,
            retryHint: 60,
            sanitizedCode: "authentication_failed",
            exitCode: 3
        )
    }
}

private actor RemotePortCleanupProbe {
    struct Snapshot: Sendable {
        let calls: [String]
        let maximumActive: Int
    }

    private var calls: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(_ label: String) async -> LaunchPreflightResult {
        calls.append(label)
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { continuations.append($0) }
        active -= 1
        return LaunchPreflightResult(
            version: 1,
            stage: "remote_port_cleanup",
            category: .success,
            retryHint: 0,
            sanitizedCode: "listener_absent",
            exitCode: 0
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(calls: calls, maximumActive: maximumActive)
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
