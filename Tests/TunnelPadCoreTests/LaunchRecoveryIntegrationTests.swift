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
    private var heldStarts: [String: DispatchSemaphore] = [:]
    init(_ tunnels: [TunnelConfig]) { config = AppConfig(tunnels: tunnels) }
    var events: [String] { lock.withLock { eventsStorage } }
    func setLoadFailure(_ value: Bool) { lock.withLock { failure = value } }
    func setUnknown(_ value: Bool) { lock.withLock { unknown = value } }
    func setBusy(_ value: Bool) { lock.withLock { busy = value } }
    func setCapabilities(_ value: Bool) { lock.withLock { capabilities = value } }
    func holdStart(_ id: String) { lock.withLock { heldStarts[id] = DispatchSemaphore(value: 0) } }
    func releaseStart(_ id: String) { lock.withLock { heldStarts.removeValue(forKey: id) }?.signal() }
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
    func launchRecoveryStart(tunnel: TunnelConfig, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        lock.withLock { heldStarts[tunnel.id] }?.wait()
        return try lock.withLock {
        guard generations[tunnel.id] == generation, config.tunnels.contains(where: { $0.matchesLaunchRuntime(tunnel) }), timeout > 0 else { throw CancellationError() }
        eventsStorage.append("strictStart:\(tunnel.id)"); states[tunnel.id] = .running(pid: 123); return states[tunnel.id]
        }
    }
    func launchRecoveryStop(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? { lock.withLock { eventsStorage.append("strictStop:\(id)"); states[id] = .notLoaded; return .notLoaded } }
    func start(id: String, generation: UInt64?) throws -> TunnelStatus { lock.withLock { eventsStorage.append("manualStart:\(id)"); states[id] = .running(pid: 321); return states[id]! } }
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus { lock.withLock { eventsStorage.append("manualStop:\(id)"); states[id] = .notLoaded; return .notLoaded } }
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus { try start(id: id, generation: generation) }
    func remove(id: String, generation: UInt64?) throws { lock.withLock { config.tunnels.removeAll { $0.id == id }; eventsStorage.append("remove:\(id)") } }
    func shutdown() throws -> Int { lock.withLock { eventsStorage.append("shutdown"); return 0 } }
}

final class LaunchTestPreflight: LaunchPreflightChecking, ECSIPDriftChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var category: LaunchRecoveryCategory = .transient
    private var count = 0
    private var resourceCount = 0
    private var cleanupIDsStorage: [String] = []
    private var driftIDsStorage: [String] = []
    private var cleanupCategory: LaunchRecoveryCategory = .success
    private var held = false
    private var wait: CheckedContinuation<LaunchPreflightResult, Never>?
    var calls: Int { lock.withLock { count } }
    var resourceCalls: Int { lock.withLock { resourceCount } }
    var cleanupIDs: [String] { lock.withLock { cleanupIDsStorage } }
    var driftIDs: [String] { lock.withLock { driftIDsStorage } }
    var waiting: Bool { lock.withLock { wait != nil } }
    func set(_ category: LaunchRecoveryCategory) { lock.withLock { self.category = category } }
    func setCleanup(_ category: LaunchRecoveryCategory) { lock.withLock { cleanupCategory = category } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false; wait?.resume(returning: result(.success)); wait = nil } }
    func check(tunnel: TunnelConfig) throws {}
    func checkAsync(tunnel: TunnelConfig) async throws {}
    func launchResource() async throws -> String { lock.withLock { resourceCount += 1 }; return "resource" }
    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        await withCheckedContinuation { continuation in
            lock.withLock { count += 1; if held { wait = continuation } else { continuation.resume(returning: result(category)) } }
        }
    }
    func remotePortCleanupResource(tunnel: TunnelConfig) -> String? {
        tunnel.forceRemotePortCleanup ? "cleanup:\(tunnel.id)" : nil
    }
    func cleanupRemotePort(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        let category = lock.withLock { cleanupIDsStorage.append(tunnel.id); return cleanupCategory }
        return .init(version: 1, stage: "remoteCleanup", category: category, retryHint: 5,
                     sanitizedCode: "fixture", exitCode: category == .success ? 0 : 3)
    }
    func checkCurrentState(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        lock.withLock { driftIDsStorage.append(tunnel.id) }
        return result(.success)
    }
    private func result(_ category: LaunchRecoveryCategory) -> LaunchPreflightResult {
        .init(version: 1, stage: "fixture", category: category, retryHint: 5, sanitizedCode: "fixture", exitCode: category == .success ? 0 : 3)
    }
}

@MainActor
final class LaunchRecoveryIntegrationTests: XCTestCase {
    private func tunnel(_ id: String = "a", auto: Bool = true, keepAlive: Bool = true) -> TunnelConfig {
        .init(id: id, name: id, command: ["/usr/bin/ssh", "-N", "fixture"], keepAlive: keepAlive, autoStart: auto, ecsSyncPolicy: .required)
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
        checker.release(); _ = await shutdown.value
        XCTAssertTrue(owner.events.contains("shutdown")); XCTAssertFalse(owner.events.contains("strictStart:a"))
        await manager.restoreAutoStartTunnels(); XCTAssertEqual(checker.calls, 1)
        try? FileManager.default.removeItem(at: manager.paths.homeDirectory)
    }
    func testLoadedNotRunningAlwaysStopsBeforePreflightAndStart() async throws {
        let owner = LaunchTestOwner([tunnel(), tunnel("b", keepAlive: false)]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.set(.success)
        owner.setStatus(.notRunning, id: "a"); owner.setStatus(.notRunning, id: "b")
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
        try await eventually { owner.events.contains("strictStart:a") && owner.events.contains("strictStart:b") && manager.busyIDs.isEmpty }
        XCTAssertTrue(owner.events.contains("strictStop:a")); XCTAssertEqual(checker.calls, 2)
        XCTAssertLessThan(try XCTUnwrap(owner.events.firstIndex(of: "strictStop:a")), try XCTUnwrap(owner.events.firstIndex(of: "strictStart:a")))
        XCTAssertLessThan(try XCTUnwrap(owner.events.firstIndex(of: "strictStop:b")), try XCTUnwrap(owner.events.firstIndex(of: "strictStart:b")))
        XCTAssertTrue(manager.launchRecoveryIDs.isEmpty)
        await cleanup(manager)
    }
    func testDisabledSSHStartsWhileRequiredECSPreflightIsHeld() async throws {
        var lan = tunnel("lan")
        lan.ecsSyncPolicy = .disabled
        let owner = LaunchTestOwner([tunnel("ecs"), lan])
        let checker = LaunchTestPreflight()
        checker.hold()
        let manager = manager(owner, checker, LaunchTestClock())
        await manager.restoreAutoStartTunnels()
        try await eventually { checker.waiting && owner.events.contains("strictStart:lan") }
        XCTAssertFalse(owner.events.contains("strictStart:ecs"))
        XCTAssertEqual(checker.calls, 1)
        checker.release()
        try await eventually { owner.events.contains("strictStart:ecs") }
        try await eventually { checker.driftIDs.contains("ecs") }
        XCTAssertEqual(checker.driftIDs, ["ecs"])
        await cleanup(manager)
    }
    func testDisabledSSHRemoteCleanupRunsWithoutECSAndFailureBlocksStart() async throws {
        for category in [LaunchRecoveryCategory.success, .local] {
            var lan = tunnel("lan")
            lan.forceRemotePortCleanup = true
            lan.ecsSyncPolicy = .disabled
            let owner = LaunchTestOwner([lan])
            let checker = LaunchTestPreflight()
            checker.setCleanup(category)
            let clock = LaunchTestClock()
            let manager = manager(owner, checker, clock)
            await manager.restoreAutoStartTunnels()
            try await eventually { checker.cleanupIDs == ["lan"] && manager.busyIDs.isEmpty }
            XCTAssertEqual(checker.calls, 0)
            XCTAssertEqual(checker.resourceCalls, 0)
            XCTAssertTrue(checker.driftIDs.isEmpty)
            XCTAssertEqual(owner.events.contains("strictStart:lan"), category == .success)
            await cleanup(manager)
        }
    }
    func testDisabledHandoffDoesNotRepeatRequiredIPCheck() async throws {
        var lan = tunnel("lan")
        lan.ecsSyncPolicy = .disabled
        let owner = LaunchTestOwner([tunnel("ecs"), lan])
        owner.holdStart("lan")
        defer { owner.releaseStart("lan") }
        let checker = LaunchTestPreflight()
        checker.set(.success)
        let manager = manager(owner, checker, LaunchTestClock())
        await manager.restoreAutoStartTunnels()
        try await eventually { checker.driftIDs == ["ecs"] }
        XCTAssertFalse(owner.events.contains("strictStart:lan"))
        owner.releaseStart("lan")
        try await eventually { owner.events.contains("strictStart:lan") && manager.launchRecoveryIDs.isEmpty }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(checker.driftIDs, ["ecs"])
        await cleanup(manager)
    }
    func testRunningUnattendedSSHIsQuiescedToInstallSingleRecoveryOwner() async throws {
        let owner = LaunchTestOwner([tunnel()]), checker = LaunchTestPreflight(), clock = LaunchTestClock(); checker.set(.success)
        owner.setStatus(.running(pid: 456), id: "a")
        let manager = manager(owner, checker, clock); await manager.restoreAutoStartTunnels()
        try await eventually { owner.events.contains("strictStart:a") && manager.launchRecoveryIDs.isEmpty }
        XCTAssertLessThan(try XCTUnwrap(owner.events.firstIndex(of: "strictStop:a")), try XCTUnwrap(owner.events.firstIndex(of: "strictStart:a")))
        XCTAssertEqual(checker.calls, 1)
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
        try await eventually { clock.pending == 1 }; owner.setLoadFailure(false); owner.setBusy(true); clock.advance(60)
        await setup.value; try await eventually { clock.pending == 1 && manager.busyIDs.isEmpty }; XCTAssertEqual(checker.calls, 0)
        owner.setBusy(false); clock.advance(5)
        try await eventually { owner.events.contains("strictStart:a") && manager.launchRecoveryIDs.isEmpty }
        await cleanup(manager)
    }
}
