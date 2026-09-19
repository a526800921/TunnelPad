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
            if events.contains("stop") && events.contains("start") {
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
        XCTAssertEqual(checker.asyncSyncCalls, 1, "恢复链应执行一次写入型同步前置检查")
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

    func testLaunchdFailureAfterRestartUsesBackoffInsteadOfLoop() async throws {
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
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            healthMonitorIntervalNanoseconds: 3_600_000_000_000,
            launchdFailureMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                if nanoseconds == HealthRecoveryPolicy.backoffNanoseconds(for: 2) {
                    // 保留足够长的观察窗口，验证第二次恢复确实进入退避。
                    try await Task.sleep(nanoseconds: 200_000_000)
                } else {
                    try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
                }
            }
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let deadline = Date().addingTimeInterval(1)
        while owner.events.filter({ $0 == "start" }).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(owner.events.filter({ $0 == "start" }).count, 1, "首次重启应立即执行")

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(
            owner.events.filter({ $0 == "start" }).count,
            1,
            "重启后连接再次退出时，后续恢复必须退避，不能形成快速循环"
        )
        XCTAssertEqual(checker.asyncSyncCalls, 1, "退避期间不应重复执行 ECS 同步")
        await manager.shutdownAsync()
    }

}

private final class IPDriftChecker: LaunchPreflightChecking, ECSIPDriftChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let driftOnFirstCheck: Bool
    private var readOnlyChecksStorage = 0
    private var asyncSyncCallsStorage = 0

    init(driftOnFirstCheck: Bool = true) {
        self.driftOnFirstCheck = driftOnFirstCheck
    }

    var requiresAutomaticRecoveryQuiescence: Bool { true }
    var readOnlyChecks: Int { lock.withLock { readOnlyChecksStorage } }
    var asyncSyncCalls: Int { lock.withLock { asyncSyncCallsStorage } }

    func check(tunnel: TunnelConfig) throws {}

    func launchResource() async throws -> String { "0123456789abcdef" }

    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        LaunchPreflightResult(
            version: 1,
            stage: "complete",
            category: .success,
            retryHint: 0,
            sanitizedCode: "synchronized",
            exitCode: 0
        )
    }

    func checkAsync(tunnel: TunnelConfig) async throws {
        lock.withLock { asyncSyncCallsStorage += 1 }
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
                retryHint: 300,
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
    private let configuration: AppConfig
    private var currentStatus: TunnelStatus = .running(pid: 77)
    private var eventsStorage: [String] = []
    private var churnEnabled = false
    private var immediateFailure = false
    private var failAfterNextStart = false
    private var nextPID: Int32 = 77

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

    func loadConfig() throws -> AppConfig { configuration }
    func saveConfig(_ config: AppConfig) throws {}
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
            } else if failAfterNextStart {
                failAfterNextStart = false
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
            return currentStatus
        }
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        try start(id: id, generation: generation)
    }

    func remove(id: String, generation: UInt64?) throws {}
    func shutdown() throws -> Int {
        lock.withLock {
            eventsStorage.append("shutdown")
            return 0
        }
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
