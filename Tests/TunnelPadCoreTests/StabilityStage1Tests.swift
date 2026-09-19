import Foundation
import XCTest
@testable import TunnelPadCore

final class StabilityStage1Tests: XCTestCase {

    @MainActor
    func testBackgroundMonitoringTriggersRecoveryAfterThreeFailures() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-recovery",
            name: "Stage 1 Recovery",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure
        )

        let deadline = Date().addingTimeInterval(2)
        while owner.restartCount < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThanOrEqual(owner.probeCount, 3)
        XCTAssertEqual(owner.restartCount, 1, "连续三次失败应触发一次自动恢复")
        XCTAssertEqual(owner.stopCount, 0)
        await manager.shutdownAsync()
    }

    @MainActor
    func testKeepAliveFalseDoesNotTriggerRecovery() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-no-keepalive",
            name: "No KeepAlive",
            command: ["/usr/bin/ssh", "-N"],
            keepAlive: false,
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThanOrEqual(owner.probeCount, 3)
        XCTAssertEqual(owner.restartCount, 0, "keepAlive=false 不应进入自动恢复")
        await manager.shutdownAsync()
    }

    @MainActor
    func testManualStopCancelsPendingRecovery() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-manual-stop",
            name: "Manual Stop",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure,
            sleep: { nanoseconds in
                if nanoseconds == HealthRecoveryPolicy.backoffNanoseconds(for: 1) {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        )

        let deadline = Date().addingTimeInterval(1)
        while owner.probeCount < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        manager.stop(tunnel.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThanOrEqual(owner.probeCount, 3)
        XCTAssertEqual(owner.stopCount, 1)
        XCTAssertEqual(owner.restartCount, 0, "手动停止后待执行恢复任务必须取消")
        await manager.shutdownAsync()
    }

    @MainActor
    func testInFlightRecoveryDoesNotConsumeAdditionalAttempts() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-in-flight",
            name: "In Flight Recovery",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        owner.shouldFailRestart = true
        owner.blockRestart = true
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure,
            sleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        let deadline = Date().addingTimeInterval(1)
        while owner.restartCount < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(owner.restartCount, 1)

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(owner.stopCount, 0, "恢复进行中不应因后续探针失败提前耗尽次数并熔断")

        owner.releaseRestart()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(owner.stopCount, 0, "第一次恢复失败后应从下一次尝试重新计数")
        await manager.shutdownAsync()
    }

    @MainActor
    func testFailedRecoveryKeepsRetryingPastHistoricalLimitWithoutStopping() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-circuit-breaker",
            name: "Circuit Breaker",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        owner.shouldFailRestart = true
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure,
            sleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        let deadline = Date().addingTimeInterval(3)
        while owner.restartCount < HealthRecoveryPolicy.maximumRecoveryAttempts + 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let observed = owner.restartCount
        XCTAssertGreaterThan(observed, HealthRecoveryPolicy.maximumRecoveryAttempts)
        XCTAssertEqual(owner.stopCount, 0, "历史尝试上限后不得永久停止恢复")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThan(owner.restartCount, observed, "无人值守恢复意图必须持续存在")
        await manager.shutdownAsync()
    }

    @MainActor
    func testManualStartRemainsAvailableDuringPersistentRecovery() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-manual-restart",
            name: "Manual Restart",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        owner.shouldFailRestart = true
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure,
            sleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        let cooldownDeadline = Date().addingTimeInterval(3)
        while owner.restartCount < HealthRecoveryPolicy.maximumRecoveryAttempts,
              Date() < cooldownDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(owner.restartCount, HealthRecoveryPolicy.maximumRecoveryAttempts)
        XCTAssertEqual(owner.stopCount, 0)

        owner.shouldFailRestart = false
        manager.start(tunnel.id)
        let startDeadline = Date().addingTimeInterval(2)
        while owner.startCount == 0, Date() < startDeadline {
            if manager.busyIDs.isEmpty {
                manager.start(tunnel.id)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(owner.startCount, 1, "人工启动应重新打开隧道并重置恢复代次")
        await manager.shutdownAsync()
    }

    @MainActor
    func testRemovingTunnelCancelsPendingRecovery() async throws {
        let tunnel = TunnelConfig(
            id: "stage1-remove-pending",
            name: "Remove Pending Recovery",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage1RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = makeManager(
            owner: owner,
            config: AppConfig(tunnels: [tunnel]),
            probeResult: .failure,
            sleep: { nanoseconds in
                if nanoseconds == HealthRecoveryPolicy.backoffNanoseconds(for: 1) {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        )

        let deadline = Date().addingTimeInterval(1)
        while owner.probeCount < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        manager.removeTunnel(tunnel.id)
        await manager.shutdownAsync()

        XCTAssertGreaterThanOrEqual(owner.probeCount, 3)
        XCTAssertEqual(owner.restartCount, 0, "删除隧道后不得执行已排队的恢复任务")
    }

    func testProductionHealthStateKeepsBoundedRetriesPastHistoricalLimit() {
        var state = HealthRecoveryState()
        let now: UInt64 = 1_000_000_000

        for attempt in 1...(HealthRecoveryPolicy.maximumRecoveryAttempts + 3) {
            XCTAssertEqual(
                state.record(
                    .failed(reason: "fixture"),
                    status: .running(pid: 7),
                    keepAlive: true,
                    nowUptimeNanoseconds: now
                ),
                .observe
            )
            XCTAssertEqual(
                state.record(
                    .failed(reason: "fixture"),
                    status: .running(pid: 7),
                    keepAlive: true,
                    nowUptimeNanoseconds: now
                ),
                .observe
            )
            XCTAssertEqual(
                state.record(
                    .failed(reason: "fixture"),
                    status: .running(pid: 7),
                    keepAlive: true,
                    nowUptimeNanoseconds: now
                ),
                .schedule(
                    attempt: attempt,
                    delayNanoseconds: HealthRecoveryPolicy.backoffNanoseconds(for: attempt)
                )
            )

            XCTAssertEqual(
                state.finishRecovery(
                success: false,
                nowUptimeNanoseconds: now
                ),
                .observe
            )
        }

        XCTAssertEqual(state.recoveryAttempts, HealthRecoveryPolicy.maximumRecoveryAttempts + 3)
        XCTAssertNil(state.cooldownUntilUptimeNanoseconds)
        XCTAssertEqual(
            HealthRecoveryPolicy.backoffNanoseconds(for: state.recoveryAttempts),
            60_000_000_000
        )
    }

    func testConfirmedFailureSchedulesOnceAndNeverExhaustsPermanentRecovery() {
        var state = HealthRecoveryState()
        XCTAssertEqual(
            state.record(.failed(reason: "probe-1"), status: .running(pid: 7), keepAlive: true),
            .observe
        )
        XCTAssertEqual(
            state.record(.failed(reason: "probe-2"), status: .running(pid: 7), keepAlive: true),
            .observe
        )

        XCTAssertEqual(
            state.confirmedFailure(),
            .schedule(attempt: 1, delayNanoseconds: 0),
            "明确 launchd/IP 故障必须只记一次，不能受既有探针计数干扰"
        )
        for attempt in 2...(HealthRecoveryPolicy.maximumRecoveryAttempts + 3) {
            XCTAssertEqual(
                state.confirmedFailure(),
                .schedule(
                    attempt: attempt,
                    delayNanoseconds: HealthRecoveryPolicy.backoffNanoseconds(for: attempt)
                )
            )
        }
        XCTAssertNil(state.cooldownUntilUptimeNanoseconds)
        XCTAssertEqual(
            HealthRecoveryPolicy.backoffNanoseconds(for: state.recoveryAttempts),
            60_000_000_000,
            "永久重试允许封顶退避，但不得耗尽后停机"
        )
    }

    func testRecoveryBackoffAndStableConfirmationContract() {
        XCTAssertEqual(
            (1...7).map(HealthRecoveryPolicy.backoffNanoseconds),
            [0, 5, 10, 30, 60, 60, 60].map { UInt64($0) * 1_000_000_000 }
        )

        var state = HealthRecoveryState()
        XCTAssertEqual(state.confirmedFailure(), .schedule(attempt: 1, delayNanoseconds: 0))
        XCTAssertEqual(
            state.record(.satisfied(status: 200), status: .running(pid: 7), keepAlive: true),
            .observe
        )
        XCTAssertEqual(state.recoveryAttempts, 1, "单次成功不能清除恢复退避")
        XCTAssertEqual(state.confirmedFailure(), .schedule(attempt: 2, delayNanoseconds: 5_000_000_000))
        XCTAssertEqual(
            state.record(.satisfied(status: 200), status: .running(pid: 8), keepAlive: true),
            .observe
        )
        XCTAssertEqual(state.recoveryAttempts, 2)
        XCTAssertEqual(
            state.record(.satisfied(status: 200), status: .running(pid: 8), keepAlive: true),
            .observe
        )
        XCTAssertEqual(state.recoveryAttempts, 0, "连续两次成功才确认恢复并清零")
    }

    @MainActor
    func testInvalidReloadRetainsEffectiveConfig() {
        let current = AppConfig(tunnels: [
            TunnelConfig(id: "stage1-effective", name: "Effective", command: ["/usr/bin/true"])
        ])
        let owner = Stage1RecordingOwner(config: current)
        let manager = makeManager(owner: owner, config: current, probeResult: .success)
        owner.shouldFailLoadConfig = true

        manager.reloadConfig()

        XCTAssertEqual(manager.config, current)
        XCTAssertTrue(manager.lastError?.contains("重新加载配置失败") == true)
    }

    @MainActor
    private func makeManager(
        owner: Stage1RecordingOwner,
        config: AppConfig,
        probeResult: Stage1ProbeResult,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    ) -> TunnelManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = ProbeService { _ in
            switch probeResult {
            case .success:
                return 200
            case .failure:
                throw URLError(.cannotConnectToHost)
            }
        }
        return TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: Stage1PassingPreStartChecker(),
            probeService: service,
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: sleep
        )
    }
}

private enum Stage1ProbeResult {
    case success
    case failure
}

private struct Stage1OwnerError: Error, Sendable {}

private struct Stage1PassingPreStartChecker: ECSPreStartChecking {
    func check(tunnel: TunnelConfig) throws {}

    func checkAsync(tunnel: TunnelConfig) async throws {}
}

private final class Stage1RecordingOwner: RustLifecycleOwner, RustHealthStatusReader, @unchecked Sendable {
    private let configured: AppConfig
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let restartReleaseSemaphore = DispatchSemaphore(value: 0)
    var shouldFailLoadConfig = false
    var shouldFailRestart = false
    var blockRestart = false

    init(config: AppConfig) {
        configured = config
    }

    var probeCount: Int { count("status") }
    var startCount: Int { count("start") }
    var restartCount: Int { count("restart") }
    var stopCount: Int { count("stop") }

    func loadConfig() throws -> AppConfig {
        if shouldFailLoadConfig { throw Stage1OwnerError() }
        return configured
    }

    func saveConfig(_ config: AppConfig) throws {
        record("saveConfig")
    }

    func beginOperation(id: String) throws -> UInt64 {
        record("beginOperation")
        return UInt64(count("beginOperation"))
    }

    func cancelOperation(id: String, generation: UInt64) throws {
        record("cancelOperation")
    }

    func snapshot() throws -> RustCoreClient.Snapshot {
        record("snapshot")
        let statuses = Dictionary(uniqueKeysWithValues: configured.tunnels.map {
            ($0.id, TunnelStatus.running(pid: 7))
        })
        return RustCoreClient.Snapshot(config: configured, statuses: statuses)
    }

    func status(id: String) throws -> TunnelStatus {
        record("status")
        return .running(pid: 7)
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("start")
        return .running(pid: 7)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("stop")
        return .notLoaded
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("restart")
        if blockRestart {
            restartReleaseSemaphore.wait()
        }
        if shouldFailRestart { throw Stage1OwnerError() }
        return .running(pid: 7)
    }

    func releaseRestart() {
        blockRestart = false
        restartReleaseSemaphore.signal()
    }

    func remove(id: String, generation: UInt64?) throws {
        record("remove")
    }

    func shutdown() throws -> Int {
        record("shutdown")
        return 0
    }

    private func record(_ name: String) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    private func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name, default: 0]
    }
}
