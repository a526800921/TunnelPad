import XCTest
@testable import TunnelPadCore

final class LaunchTestOwner: RustLaunchRecoveryOwner, RustHealthStatusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var config: AppConfig
    private var states: [String: TunnelStatus] = [:]
    private var generations: [String: UInt64] = [:]
    private var eventsStorage: [String] = []
    private var failure = false
    private var unknown = false
    private var busy = false
    private var capabilities = true
    init(_ tunnels: [TunnelConfig]) { config = AppConfig(tunnels: tunnels) }
    var events: [String] { lock.withLock { eventsStorage } }
    func setLoadFailure(_ value: Bool) { lock.withLock { failure = value } }
    func setUnknown(_ value: Bool) { lock.withLock { unknown = value } }
    func setBusy(_ value: Bool) { lock.withLock { busy = value } }
    func setCapabilities(_ value: Bool) { lock.withLock { capabilities = value } }
    func setStatus(_ value: TunnelStatus, id: String) { lock.withLock { states[id] = value } }
    func loadConfig() throws -> AppConfig { try lock.withLock { if failure { throw RustCoreClient.ClientError.transport("fixture") }; return config } }
    func saveConfig(_ value: AppConfig) throws { lock.withLock { config = value } }
    func supportsLaunchRecovery() throws -> Bool { lock.withLock { capabilities } }
    func beginOperation(id: String) throws -> UInt64 { lock.withLock { generations[id, default: 0] += 1; return generations[id]! } }
    func beginLaunchRecovery(id: String) throws -> UInt64? { if lock.withLock({ busy }) { return nil }; return try beginOperation(id: id) }
    func cancelOperation(id: String, generation: UInt64) throws { lock.withLock { if generations[id] == generation { generations[id, default: 0] += 1 }; eventsStorage.append("cancel:\(id)") } }
    func snapshot() throws -> RustCoreClient.Snapshot { lock.withLock { eventsStorage.append("snapshot"); return .init(config: config, statuses: Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, states[$0.id] ?? .notLoaded) })) } }
    func status(id: String) throws -> TunnelStatus { lock.withLock { states[id] ?? .notLoaded } }
    func launchRecoveryStatus(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? { try lock.withLock {
        eventsStorage.append("checked:\(id)"); if unknown { throw RustCoreClient.ClientError.transport("unknown") }; return states[id] ?? .notLoaded
    } }
    func launchRecoveryStart(tunnel: TunnelConfig, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? { try lock.withLock {
        guard generations[tunnel.id] == generation, config.tunnels.contains(where: { $0.matchesLaunchRuntime(tunnel) }), timeout > 0 else { throw CancellationError() }
        eventsStorage.append("strictStart:\(tunnel.id)"); states[tunnel.id] = .running(pid: 123); return states[tunnel.id]
    } }
    func launchRecoveryStop(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? { lock.withLock { eventsStorage.append("strictStop:\(id)"); states[id] = .notLoaded; return .notLoaded } }
    func start(id: String, generation: UInt64?) throws -> TunnelStatus { lock.withLock { eventsStorage.append("manualStart:\(id)"); states[id] = .running(pid: 321); return states[id]! } }
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus { lock.withLock { eventsStorage.append("manualStop:\(id)"); states[id] = .notLoaded; return .notLoaded } }
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus { try start(id: id, generation: generation) }
    func remove(id: String, generation: UInt64?) throws { lock.withLock { config.tunnels.removeAll { $0.id == id }; eventsStorage.append("remove:\(id)") } }
    func shutdown() throws -> Int { lock.withLock { eventsStorage.append("shutdown"); return 0 } }
}

final class LaunchTestPreflight: LaunchPreflightChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var category: LaunchRecoveryCategory = .transient
    private var count = 0
    private var held = false
    private var wait: CheckedContinuation<LaunchPreflightResult, Never>?
    var calls: Int { lock.withLock { count } }
    var waiting: Bool { lock.withLock { wait != nil } }
    func set(_ category: LaunchRecoveryCategory) { lock.withLock { self.category = category } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false; wait?.resume(returning: result(.success)); wait = nil } }
    func check(tunnel: TunnelConfig) throws {}
    func checkAsync(tunnel: TunnelConfig) async throws {}
    func launchResource() async throws -> String { "resource" }
    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        await withCheckedContinuation { continuation in
            lock.withLock { count += 1; if held { wait = continuation } else { continuation.resume(returning: result(category)) } }
        }
    }
    private func result(_ category: LaunchRecoveryCategory) -> LaunchPreflightResult {
        .init(version: 1, stage: "fixture", category: category, retryHint: 5, sanitizedCode: "fixture", exitCode: category == .success ? 0 : 3)
    }
}

@MainActor
final class LaunchRecoveryIntegrationTests: XCTestCase {
    private func tunnel(_ id: String = "a", auto: Bool = true, keepAlive: Bool = true) -> TunnelConfig {
        .init(id: id, name: id, command: ["/usr/bin/ssh", "-N", "fixture"], keepAlive: keepAlive, autoStart: auto)
    }
    private func manager(_ owner: LaunchTestOwner, _ checker: LaunchTestPreflight, _ clock: LaunchTestClock) -> TunnelManager {
        TunnelManager(paths: TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("launch-integration-\(UUID().uuidString)")), rustCore: owner, preStartChecker: checker,
            healthSleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }, launchClock: clock.clock)
    }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("生产管理器未收敛"); throw CancellationError()
    }
    private func cleanup(_ manager: TunnelManager) async {
        await manager.shutdownAsync(); try? FileManager.default.removeItem(at: manager.paths.homeDirectory)
    }
    func testOfflineThenVirtualDayAutomaticallyStartsOnlyFrozenCandidates() async throws {
        let owner = LaunchTestOwner([tunnel(), tunnel("off", auto: false)]), checker = LaunchTestPreflight(), clock = LaunchTestClock()
        let manager = manager(owner, checker, clock)
        await manager.restoreAutoStartTunnels()
        try await eventually { checker.calls == 1 && manager.busyIDs.isEmpty && clock.pending == 1 }
        var config = try owner.loadConfig(); config.tunnels.append(tunnel("late")); try owner.saveConfig(config)
        checker.set(.success); clock.advance(86_400)
        try await eventually { owner.events.contains("strictStart:a") && manager.launchRecoveryIDs.isEmpty }
        XCTAssertEqual(checker.calls, 2); XCTAssertEqual(manager.statuses["a"], .running(pid: 123))
        XCTAssertFalse(owner.events.contains("strictStart:off")); XCTAssertFalse(owner.events.contains("strictStart:late"))
        XCTAssertFalse(owner.events.contains("manualStart:a")); XCTAssertLessThanOrEqual(owner.events.filter { $0 == "snapshot" }.count, 1)
        await manager.restoreAutoStartTunnels(); clock.advance(86_400); await Task.yield(); XCTAssertEqual(checker.calls, 2)
        await cleanup(manager)
    }
    func testDisplayEditKeepsPendingCandidateAndUsesOriginalRuntime() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock()
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
        try await eventually { checker.calls == 1 && manager.busyIDs.isEmpty && clock.pending == 1 }
        var renamed = tunnel(); renamed.name = "新名称"; renamed.remark = "仅备注"
        let saved = await manager.updateTunnelAsync(renamed); XCTAssertTrue(saved)
        XCTAssertEqual(manager.launchRecoveryIDs, ["a"])
        checker.set(.success); clock.advance(5)
        try await eventually { owner.events.contains("strictStart:a") && manager.launchRecoveryIDs.isEmpty }
        await cleanup(manager)
    }

    func testManualStopWaitsForCancelledPreflightAndPreventsLateBootstrap() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.hold()
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
        try await eventually { checker.waiting }
        let stop = Task { await manager.stopAsync("a") }
        try await eventually { owner.events.contains("cancel:a") }
        XCTAssertFalse(owner.events.contains("manualStop:a")); XCTAssertTrue(manager.busyIDs.contains("a"))
        checker.release(); _ = await stop.value
        XCTAssertTrue(owner.events.contains("manualStop:a")); XCTAssertFalse(owner.events.contains("strictStart:a"))
        XCTAssertTrue(manager.launchRecoveryIDs.isEmpty); clock.advance(86_400); await Task.yield(); XCTAssertEqual(checker.calls, 1)
        await cleanup(manager)
    }
    func testRuntimeConfigEditCancelsAndWaitsBeforeSave() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.hold()
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels(); try await eventually { checker.waiting }
        var changed = tunnel(); changed.command.append("changed")
        let edit = Task { await manager.updateTunnelAsync(changed) }
        try await eventually { owner.events.contains("cancel:a") }
        XCTAssertEqual(try owner.loadConfig().tunnels.first?.command, tunnel().command)
        checker.release(); let saved = await edit.value; XCTAssertTrue(saved)
        XCTAssertFalse(owner.events.contains("strictStart:a")); XCTAssertTrue(manager.launchRecoveryIDs.isEmpty)
        await cleanup(manager)
    }
    func testShutdownWaitsForCleanupAndDoesNotStartAfterCancellation() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.hold()
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels(); try await eventually { checker.waiting }
        let shutdown = Task { await manager.shutdownAsync() }
        try await eventually { owner.events.contains("cancel:a") }; XCTAssertFalse(owner.events.contains("shutdown"))
        checker.release(); await shutdown.value
        XCTAssertTrue(owner.events.contains("shutdown")); XCTAssertFalse(owner.events.contains("strictStart:a"))
        await manager.restoreAutoStartTunnels(); XCTAssertEqual(checker.calls, 1)
        try? FileManager.default.removeItem(at: manager.paths.homeDirectory)
    }
    func testLoadedKeepAliveObservesAndNonKeepAliveStopsBeforePreflight() async throws {
        let owner = LaunchTestOwner([tunnel(), tunnel("b", keepAlive: false)]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.set(.success)
        owner.setStatus(.notRunning, id: "a"); owner.setStatus(.notRunning, id: "b")
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
        try await eventually { owner.events.contains("strictStart:b") && manager.busyIDs.isEmpty }
        XCTAssertFalse(owner.events.contains("strictStop:a")); XCTAssertFalse(owner.events.contains("strictStart:a")); XCTAssertEqual(checker.calls, 1)
        XCTAssertLessThan(try XCTUnwrap(owner.events.firstIndex(of: "strictStop:b")), try XCTUnwrap(owner.events.firstIndex(of: "strictStart:b")))
        owner.setStatus(.running(pid: 456), id: "a"); try await eventually { clock.pending > 0 }; clock.advance(5)
        try await eventually { manager.launchRecoveryIDs.isEmpty }; XCTAssertEqual(checker.calls, 1)
        await cleanup(manager)
    }
    func testUnknownStatusAndOldCoreNeverRunPreflight() async throws {
        for old in [false, true] {
            let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock()
            owner.setUnknown(true); owner.setCapabilities(!old)
            let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
            if !old { try await eventually { owner.events.contains("checked:a") && manager.busyIDs.isEmpty } }
            XCTAssertEqual(checker.calls, 0); XCTAssertFalse(owner.events.contains("strictStart:a"))
            await cleanup(manager)
        }
    }
    func testInvalidInitialConfigRetriesAndBusyBeginDoesNotBootstrap() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); owner.setLoadFailure(true); checker.set(.success)
        let manager = manager(owner, checker, clock)
        let setup = Task { await manager.restoreAutoStartTunnels() }
        try await eventually { clock.pending == 1 }; owner.setLoadFailure(false); owner.setBusy(true); clock.advance(300)
        await setup.value; try await eventually { clock.pending == 1 && manager.busyIDs.isEmpty }; XCTAssertEqual(checker.calls, 0)
        owner.setBusy(false); clock.advance(5)
        try await eventually { owner.events.contains("strictStart:a") && manager.launchRecoveryIDs.isEmpty }
        await cleanup(manager)
    }
}
