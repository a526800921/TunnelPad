import XCTest
@testable import TunnelPadCore

@MainActor
final class IPDriftRecoveryTests: XCTestCase {
    func testDetectedIPDriftUsesBootoutSyncAndStartRecoveryChain() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-ip-drift-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "drift-ssh",
            name: "漂移隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        let checker = IPDriftChecker()
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        await manager.restoreAutoStartTunnels()

        var recovered = false
        for _ in 0..<2_000 {
            let events = owner.events
            if events.contains("stop") && events.contains("start")
                && checker.readOnlyChecks >= 1 && checker.asyncSyncCalls >= 2 {
                recovered = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(recovered, "IP 漂移恢复未在测试窗口内完成，events=\(owner.events)")
        guard recovered else {
            await manager.shutdownAsync()
            return
        }

        let events = owner.events
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "stop")),
            try XCTUnwrap(events.firstIndex(of: "start")),
            "发现 IP 漂移后必须先 bootout，再同步并启动"
        )
        XCTAssertEqual(
            checker.asyncSyncCalls,
            2,
            "启动交接和确认漂移后的运行期恢复应各执行一次结构化同步前置"
        )
        XCTAssertTrue(checker.readOnlyChecks >= 1)

        let appLogURL = TunnelPaths(homeDirectory: home).appEventLogURL
        let appLog = try String(contentsOf: appLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("`/32` 漂移"))
        await manager.shutdownAsync()
    }

    func testLaunchdPIDChangeUsesImmediateRecoveryAndSameCleanupChain() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-launchd-churn-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "churn-ssh",
            name: "抖动隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        owner.enablePIDChurn()
        let checker = IPDriftChecker(driftOnFirstCheck: false)
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                if nanoseconds >= 300_000_000_000 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
                }
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        var recovered = false
        for _ in 0..<2_000 {
            let events = owner.events
            if events.contains("stop") && events.contains("start") {
                recovered = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let diagnosticLog = (try? String(
            contentsOf: TunnelPaths(homeDirectory: home).appEventLogURL,
            encoding: .utf8
        )) ?? "<no app log>"
        XCTAssertTrue(recovered, "launchd 抖动恢复未在测试窗口内完成，events=\(owner.events)，log=\(diagnosticLog)")
        guard recovered else {
            await manager.shutdownAsync()
            return
        }

        XCTAssertEqual(checker.asyncSyncCalls, 1, "抖动恢复仍应经过一次同步前置")
        let appLog = try String(contentsOf: TunnelPaths(homeDirectory: home).appEventLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("SSH 连接异常（launchd 状态或 PID 发生变化）"))
        await manager.shutdownAsync()
    }

    func testLaunchdNotRunningImmediatelyRunsECSBeforeRestart() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-launchd-not-running-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "not-running-ssh",
            name: "断开隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        owner.enableImmediateFailure()
        let checker = IPDriftChecker(driftOnFirstCheck: false)
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        var recovered = false
        for _ in 0..<2_000 {
            let events = owner.events
            if events.contains("stop") && events.contains("start") {
                recovered = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(recovered, "launchd 未运行时未立即进入恢复，events=\(owner.events)")
        guard recovered else {
            await manager.shutdownAsync()
            return
        }

        let events = owner.events
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "stop")),
            try XCTUnwrap(events.firstIndex(of: "start")),
            "断开恢复必须先清理旧实例，再同步并启动"
        )
        XCTAssertEqual(checker.asyncSyncCalls, 1, "断开后的首次重连必须经过一次 ECS 前置同步")
        let appLog = try String(contentsOf: TunnelPaths(homeDirectory: home).appEventLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("SSH 连接异常（launchd 状态或 PID 发生变化）"))
        await manager.shutdownAsync()
    }

    func testLaunchdFailureAfterTransientRestartUsesEscalatingBackoff() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-launchd-restart-loop-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "restart-loop-ssh",
            name: "重启循环隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        owner.enableImmediateFailure()
        owner.failNextStart()
        let checker = IPDriftChecker(driftOnFirstCheck: false)
        let delays = IPDriftDelayRecorder()
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: delays.sleep
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let deadline = Date().addingTimeInterval(1)
        while owner.events.filter({ $0 == "start" }).count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            owner.events.filter({ $0 == "start" }).count,
            2,
            "重启后再次断开必须继续进入下一轮恢复"
        )
        XCTAssertGreaterThanOrEqual(checker.asyncSyncCalls, 2, "每轮断开重连都必须先执行 ECS 同步")
        XCTAssertEqual(delays.values.filter { $0 == 0 }.count, 1, "只有第一轮恢复为零延迟")
        XCTAssertTrue(delays.values.contains(5_000_000_000), "短暂 running 后再次退出必须进入 5 秒退避")
        XCTAssertTrue(manager.lastMessage?.contains("未配置连接探针") == true)
        await manager.shutdownAsync()
    }

    func testAutomaticRecoveryKeepsRetryingPastHistoricalAttemptLimit() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-persistent-retry-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "persistent-ssh",
            name: "持续恢复隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        owner.enableImmediateFailure()
        let failures = HealthRecoveryPolicy.maximumRecoveryAttempts + 2
        let checker = IPDriftChecker(driftOnFirstCheck: false, asyncFailures: failures)
        let delays = IPDriftDelayRecorder()
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: delays.sleep
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let deadline = Date().addingTimeInterval(3)
        while owner.events.filter({ $0 == "start" }).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(checker.asyncSyncCalls, failures + 1)
        XCTAssertEqual(owner.events.filter({ $0 == "start" }).count, 1)
        XCTAssertTrue(delays.values.contains(5_000_000_000))
        XCTAssertTrue(delays.values.contains(10_000_000_000))
        XCTAssertTrue(delays.values.contains(30_000_000_000))
        XCTAssertTrue(delays.values.contains(60_000_000_000))
        XCTAssertFalse(delays.values.contains(300_000_000_000))
        let appLog = try String(contentsOf: TunnelPaths(homeDirectory: home).appEventLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("60 秒后继续尝试"), "退避应在 60 秒封顶但恢复意图必须保留")
        XCTAssertTrue(
            appLog.contains("ecs_transient_fixture_failure"),
            "运行期恢复日志必须保留结构化、脱敏的 ECS 失败分类"
        )
        await manager.shutdownAsync()
    }

    func testConcurrentRuntimeRecoverySharesSingleECSPreflightByResource() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-shared-runtime-preflight-\(UUID().uuidString)", isDirectory: true)
        let tunnels = ["shared-a", "shared-b"].enumerated().map { index, id in
            TunnelConfig(
                id: id,
                name: id,
                command: ["/usr/bin/ssh", "-N", "-R", "127.0.0.1:\(18_080 + index):127.0.0.1:8080", "root@fixture"],
                keepAlive: true,
                autoStart: true,
                forceRemotePortCleanup: true
            )
        }
        let owner = SharedRuntimeRecoveryOwner(config: AppConfig(tunnels: tunnels))
        let checker = SharedRuntimeRecoveryChecker()
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let stoppedDeadline = Date().addingTimeInterval(2)
        while (checker.calls < 1 || owner.stoppedIDs.count < 2), Date() < stoppedDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(checker.calls, 1, "同一 ECS 资源只能执行一个同步前置")
        XCTAssertEqual(owner.stoppedIDs, Set(["shared-a", "shared-b"]))

        checker.release()
        let startedDeadline = Date().addingTimeInterval(2)
        while owner.startedIDs.count < 2, Date() < startedDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(owner.startedIDs, Set(["shared-a", "shared-b"]))
        XCTAssertEqual(checker.calls, 1, "等待者必须复用首次同步结果，而不是收到 lock_busy 后重试")
        XCTAssertEqual(Set(checker.cleanupIDs), Set(["shared-a", "shared-b"]), "共享同步后仍须逐隧道清理")
        XCTAssertEqual(checker.cleanupIDs.count, 2, "远端清理成功不能跨隧道复用")
        XCTAssertEqual(checker.maxConcurrentCalls, 1)
        await manager.shutdownAsync()
    }

    func testDisplayEditDoesNotReviveManuallyStoppedTunnel() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manual-stop-edit-\(UUID().uuidString)", isDirectory: true)
        var tunnel = TunnelConfig(
            id: "manual-stop-ssh",
            name: "手动停止隧道",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: IPDriftChecker(driftOnFirstCheck: false),
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        _ = await manager.stopAsync(tunnel.id)
        tunnel.remark = "只修改显示说明"
        let saved = await manager.updateTunnelAsync(tunnel)
        XCTAssertTrue(saved)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(owner.events.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(owner.events.filter { $0 == "start" }.isEmpty)
        await manager.shutdownAsync()
    }

    func testRuntimeEditDoesNotReviveManuallyStoppedTunnel() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manual-stop-runtime-edit-\(UUID().uuidString)", isDirectory: true)
        var tunnel = TunnelConfig(
            id: "manual-stop-runtime-ssh",
            name: "手动停止后改参数",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: IPDriftChecker(driftOnFirstCheck: false),
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        _ = await manager.stopAsync(tunnel.id)
        tunnel.command.append(contentsOf: ["-o", "ServerAliveInterval=17"])
        let saved = await manager.updateTunnelAsync(tunnel)
        XCTAssertTrue(saved)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(owner.events.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(owner.events.filter { $0 == "start" }.isEmpty)
        await manager.shutdownAsync()
    }

    func testRuntimeAddedAutoStartTunnelWaitsUntilNextAppLaunch() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-runtime-add-\(UUID().uuidString)", isDirectory: true)
        let owner = IPDriftOwner(config: AppConfig())
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: IPDriftChecker(driftOnFirstCheck: false),
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let added = TunnelConfig(
            id: "late-auto-start",
            name: "本次运行新增",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )

        XCTAssertTrue(manager.addTunnel(added))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(owner.events.filter { $0 == "start" || $0 == "stop" }.isEmpty)
        await manager.shutdownAsync()
    }

    func testFailedShutdownKeepsAppAliveAndResumesUnattendedMonitoring() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-shutdown-retry-\(UUID().uuidString)", isDirectory: true)
        let tunnel = TunnelConfig(
            id: "shutdown-retry-ssh",
            name: "退出失败恢复监测",
            command: ["/usr/bin/ssh", "-N", "fixture"],
            keepAlive: true,
            autoStart: true
        )
        let owner = IPDriftOwner(config: AppConfig(tunnels: [tunnel]))
        owner.failNextShutdown()
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: IPDriftChecker(driftOnFirstCheck: false),
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let firstShutdown = await manager.shutdownAsync()
        XCTAssertFalse(firstShutdown)
        XCTAssertTrue(manager.lastError?.contains("退出清理失败") == true)

        owner.enableImmediateFailure()
        let deadline = Date().addingTimeInterval(2)
        while owner.events.filter({ $0 == "start" }).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(
            owner.events.contains("start"),
            "退出清理失败后必须恢复无人值守监测，而不是留在静默停止态"
        )

        let secondShutdown = await manager.shutdownAsync()
        XCTAssertTrue(secondShutdown)
    }

}

private final class IPDriftDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] { lock.withLock { storage } }

    func sleep(_ nanoseconds: UInt64) async throws {
        lock.withLock { storage.append(nanoseconds) }
        try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
    }
}

private final class SharedRuntimeRecoveryChecker: LaunchPreflightChecking, ECSIPDriftChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var callsStorage = 0
    private var activeCalls = 0
    private var maxConcurrentCallsStorage = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var cleanupIDsStorage: [String] = []

    var requiresAutomaticRecoveryQuiescence: Bool { true }
    var calls: Int { lock.withLock { callsStorage } }
    var maxConcurrentCalls: Int { lock.withLock { maxConcurrentCallsStorage } }
    var cleanupIDs: [String] { lock.withLock { cleanupIDsStorage } }

    func check(tunnel: TunnelConfig) throws {}

    func checkAsync(tunnel: TunnelConfig) async throws {}

    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                callsStorage += 1
                activeCalls += 1
                maxConcurrentCallsStorage = max(maxConcurrentCallsStorage, activeCalls)
                self.continuation = continuation
            }
        }
        return lock.withLock {
            activeCalls -= 1
            return LaunchPreflightResult(
                version: 1,
                stage: "complete",
                category: .success,
                retryHint: 0,
                sanitizedCode: "synchronized",
                exitCode: 0
            )
        }
    }

    func release() {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume()
    }

    func launchResource() async throws -> String { "shared-resource" }

    func remotePortCleanupResource(tunnel: TunnelConfig) -> String? { "cleanup:\(tunnel.id)" }

    func cleanupRemotePort(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        lock.withLock { cleanupIDsStorage.append(tunnel.id) }
        return .init(
            version: 1,
            stage: "remoteCleanup",
            category: .success,
            retryHint: 0,
            sanitizedCode: "listener_absent",
            exitCode: 0
        )
    }

    func checkCurrentState(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        .init(
            version: 1,
            stage: "complete",
            category: .success,
            retryHint: 0,
            sanitizedCode: "synchronized",
            exitCode: 0
        )
    }
}

private final class SharedRuntimeRecoveryOwner: RustLaunchRecoveryOwner, RustHealthStatusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: AppConfig
    private var statuses: [String: TunnelStatus]
    private var generations: [String: UInt64] = [:]
    private var stopped: Set<String> = []
    private var started: Set<String> = []

    init(config: AppConfig) {
        configuration = config
        statuses = Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, .notRunning) })
    }

    var stoppedIDs: Set<String> { lock.withLock { stopped } }
    var startedIDs: Set<String> { lock.withLock { started } }

    func loadConfig() throws -> AppConfig { lock.withLock { configuration } }
    func saveConfig(_ config: AppConfig) throws { lock.withLock { configuration = config } }
    func beginOperation(id: String) throws -> UInt64 {
        lock.withLock {
            generations[id, default: 0] += 1
            return generations[id]!
        }
    }
    func cancelOperation(id: String, generation: UInt64) throws {}
    func snapshot() throws -> RustCoreClient.Snapshot {
        lock.withLock { .init(config: configuration, statuses: statuses) }
    }
    func status(id: String) throws -> TunnelStatus { lock.withLock { statuses[id] ?? .notLoaded } }
    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.withLock {
            started.insert(id)
            statuses[id] = .running(pid: Int32(100 + started.count))
            return statuses[id]!
        }
    }
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.withLock {
            stopped.insert(id)
            statuses[id] = .notLoaded
            return .notLoaded
        }
    }
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        try start(id: id, generation: generation)
    }
    func remove(id: String, generation: UInt64?) throws {}
    func shutdown() throws -> Int { 0 }
    func supportsLaunchRecovery() throws -> Bool { true }
    func beginLaunchRecovery(id: String) throws -> UInt64? { try beginOperation(id: id) }
    func launchRecoveryStatus(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        try status(id: id)
    }
    func launchRecoveryStart(tunnel: TunnelConfig, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        try start(id: tunnel.id, generation: generation)
    }
    func launchRecoveryStop(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        try stop(id: id, generation: generation)
    }
}

private final class IPDriftChecker: LaunchPreflightChecking, ECSIPDriftChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let driftOnFirstCheck: Bool
    private var readOnlyChecksStorage = 0
    private var asyncSyncCallsStorage = 0
    private var asyncFailuresRemaining: Int

    init(driftOnFirstCheck: Bool = true, asyncFailures: Int = 0) {
        self.driftOnFirstCheck = driftOnFirstCheck
        self.asyncFailuresRemaining = asyncFailures
    }

    var requiresAutomaticRecoveryQuiescence: Bool { true }
    var readOnlyChecks: Int { lock.withLock { readOnlyChecksStorage } }
    var asyncSyncCalls: Int { lock.withLock { asyncSyncCallsStorage } }

    func check(tunnel: TunnelConfig) throws {}

    func launchResource() async throws -> String { "0123456789abcdef" }

    func checkAsync(tunnel: TunnelConfig) async throws {
        let result = nextLaunchResult()
        if result.exitCode != 0 {
            throw ECSPreStartError.commandFailed(exitCode: 4)
        }
    }

    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        nextLaunchResult()
    }

    private func nextLaunchResult() -> LaunchPreflightResult {
        lock.withLock {
            asyncSyncCallsStorage += 1
            if asyncFailuresRemaining > 0 {
                asyncFailuresRemaining -= 1
                return LaunchPreflightResult(
                    version: 1,
                    stage: "fixture",
                    category: .transient,
                    retryHint: 0,
                    sanitizedCode: "fixture_failure",
                    exitCode: 3
                )
            }
            return LaunchPreflightResult(
                version: 1,
                stage: "complete",
                category: .success,
                retryHint: 0,
                sanitizedCode: "synchronized",
                exitCode: 0
            )
        }
    }

    func checkCurrentState(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        let count = lock.withLock {
            readOnlyChecksStorage += 1
            return readOnlyChecksStorage
        }
        if count == 1, driftOnFirstCheck {
            return LaunchPreflightResult(
                version: 1,
                stage: "read",
                category: .unknown,
                retryHint: 60,
                sanitizedCode: "ip_drift",
                exitCode: 4
            )
        }
        return LaunchPreflightResult(
            version: 1,
            stage: "complete",
            category: .success,
            retryHint: 0,
            sanitizedCode: "synchronized",
            exitCode: 0
        )
    }
}

private final class IPDriftOwner: RustLaunchRecoveryOwner, RustHealthStatusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: AppConfig
    private var currentStatus: TunnelStatus = .running(pid: 77)
    private var eventsStorage: [String] = []
    private var churnEnabled = false
    private var immediateFailure = false
    private var failAfterNextStart = false
    private var failOnNextStatus = false
    private var nextPID: Int32 = 77
    private var shutdownFailuresRemaining = 0

    init(config: AppConfig) {
        configuration = config
    }

    var events: [String] { lock.withLock { eventsStorage } }

    func enablePIDChurn() {
        lock.withLock { churnEnabled = true }
    }

    func enableImmediateFailure() {
        lock.withLock { immediateFailure = true }
    }

    func failNextStart() {
        lock.withLock { failAfterNextStart = true }
    }

    func failNextShutdown() {
        lock.withLock { shutdownFailuresRemaining += 1 }
    }

    func loadConfig() throws -> AppConfig { lock.withLock { configuration } }
    func saveConfig(_ config: AppConfig) throws { lock.withLock { configuration = config } }
    func beginOperation(id: String) throws -> UInt64 { 1 }
    func cancelOperation(id: String, generation: UInt64) throws {}

    func snapshot() throws -> RustCoreClient.Snapshot {
        lock.withLock {
            eventsStorage.append("snapshot")
            return RustCoreClient.Snapshot(
                config: configuration,
                statuses: Dictionary(uniqueKeysWithValues: configuration.tunnels.map {
                    ($0.id, currentStatus)
                })
            )
        }
    }

    func status(id: String) throws -> TunnelStatus {
        lock.withLock {
            if immediateFailure {
                immediateFailure = false
                currentStatus = .notRunning
            } else if failOnNextStatus {
                failOnNextStatus = false
                currentStatus = .notRunning
            } else if churnEnabled, case .running = currentStatus {
                nextPID += 1
                currentStatus = .running(pid: nextPID)
            }
            if case .running(let pid) = currentStatus {
                eventsStorage.append("status-\(pid ?? -1)")
            } else {
                eventsStorage.append("status-not-running")
            }
            return currentStatus
        }
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.withLock {
            eventsStorage.append("stop")
            currentStatus = .notLoaded
            return currentStatus
        }
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.withLock {
            eventsStorage.append("start")
            currentStatus = .running(pid: 99)
            if failAfterNextStart {
                failAfterNextStart = false
                failOnNextStatus = true
            }
            return currentStatus
        }
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        try start(id: id, generation: generation)
    }

    func remove(id: String, generation: UInt64?) throws {}
    func shutdown() throws -> Int {
        let shouldFail = lock.withLock {
            eventsStorage.append("shutdown")
            if shutdownFailuresRemaining > 0 {
                shutdownFailuresRemaining -= 1
                return true
            }
            return false
        }
        if shouldFail { throw IPDriftOwnerError.shutdownFailure }
        return 0
    }

    func supportsLaunchRecovery() throws -> Bool { true }
    func beginLaunchRecovery(id: String) throws -> UInt64? { 1 }
    func launchRecoveryStatus(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        lock.withLock { currentStatus }
    }
    func launchRecoveryStart(tunnel: TunnelConfig, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        try start(id: tunnel.id, generation: generation)
    }
    func launchRecoveryStop(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus? {
        try stop(id: id, generation: generation)
    }
}

private enum IPDriftOwnerError: Error {
    case shutdownFailure
}
