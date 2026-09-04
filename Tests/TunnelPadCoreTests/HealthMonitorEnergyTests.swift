import Foundation
import XCTest
@testable import TunnelPadCore

final class HealthMonitorEnergyTests: XCTestCase {

    @MainActor
    func testHealthyCyclesDoNotRescanAllTunnelStatuses() async throws {
        let probed = TunnelConfig(
            id: "energy-probed",
            name: "Probed",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health", expectedStatuses: [200])
        )
        let unprobed = TunnelConfig(
            id: "energy-unprobed",
            name: "Unprobed",
            command: ["/usr/bin/ssh", "-N"]
        )
        let config = AppConfig(tunnels: [probed, unprobed])
        let owner = EnergyRecordingOwner(config: config)
        let manager = makeManager(owner: owner, config: config, probeResult: .satisfied)

        try await Self.waitUntil(timeout: 1) { owner.loadConfigCount >= 5 }
        await manager.shutdownAsync()

        XCTAssertEqual(owner.snapshotCount, 1, "启动状态发现最多执行一次全量 snapshot")
        XCTAssertTrue(owner.statusIDs.isEmpty, "健康探针满足时不应读取任何 launchd 单条状态")
        XCTAssertGreaterThanOrEqual(owner.loadConfigCount, 5)
    }

    @MainActor
    func testFailedProbeOnlyReadsTargetTunnelStatus() async throws {
        let probed = TunnelConfig(
            id: "energy-failed",
            name: "Failed probe",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health", expectedStatuses: [200])
        )
        let unprobed = TunnelConfig(
            id: "energy-unprobed-failed",
            name: "Unprobed",
            command: ["/usr/bin/ssh", "-N"]
        )
        let config = AppConfig(tunnels: [probed, unprobed])
        let owner = EnergyRecordingOwner(config: config)
        let manager = makeManager(owner: owner, config: config, probeResult: .failed)

        try await Self.waitUntil(timeout: 1) { owner.statusCount >= 3 }
        await manager.shutdownAsync()

        XCTAssertEqual(owner.snapshotCount, 1, "失败探针也不应重新触发全量 snapshot")
        XCTAssertFalse(owner.statusIDs.isEmpty)
        XCTAssertTrue(
            owner.statusIDs.allSatisfy { $0 == probed.id },
            "状态复核只能针对探针异常的隧道"
        )
    }

    @MainActor
    func testUnknownTargetStatusDoesNotTriggerRecovery() async throws {
        let tunnel = TunnelConfig(
            id: "energy-unknown",
            name: "Unknown status",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health", expectedStatuses: [200])
        )
        let config = AppConfig(tunnels: [tunnel])
        let owner = EnergyRecordingOwner(config: config, statusFails: true)
        let manager = makeManager(owner: owner, config: config, probeResult: .failed)

        try await Self.waitUntil(timeout: 1) { owner.statusCount >= 3 }
        await manager.shutdownAsync()

        XCTAssertEqual(owner.restartCount, 0, "状态未知时不得触发自动恢复")
        XCTAssertEqual(owner.snapshotCount, 1)
    }

    @MainActor
    private func makeManager(
        owner: EnergyRecordingOwner,
        config: AppConfig,
        probeResult: EnergyProbeResult
    ) -> TunnelManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-energy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let probeService = ProbeService { _ in
            switch probeResult {
            case .satisfied:
                return 200
            case .failed:
                throw URLError(.cannotConnectToHost)
            }
        }
        return TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: EnergyPassingPreStartChecker(),
            probeService: probeService,
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
            }
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待能耗优化 fixture 超时")
    }
}

private enum EnergyProbeResult {
    case satisfied
    case failed
}

private struct EnergyPassingPreStartChecker: ECSPreStartChecking {
    func check(tunnel: TunnelConfig) throws {}

    func checkAsync(tunnel: TunnelConfig) async throws {}
}

private struct EnergyOwnerError: Error, Sendable {}

private final class EnergyRecordingOwner: RustLifecycleOwner, RustHealthStatusReader, @unchecked Sendable {
    private let configuration: AppConfig
    private let statusFails: Bool
    private let lock = NSLock()
    private var events: [String] = []
    private var requestedStatusIDs: [String] = []

    init(config: AppConfig, statusFails: Bool = false) {
        configuration = config
        self.statusFails = statusFails
    }

    var snapshotCount: Int { count("snapshot") }
    var loadConfigCount: Int { count("loadConfig") }
    var statusCount: Int { count("status") }
    var restartCount: Int { count("restart") }

    var statusIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedStatusIDs
    }

    func loadConfig() throws -> AppConfig {
        record("loadConfig")
        return configuration
    }

    func saveConfig(_ config: AppConfig) throws {
        record("saveConfig")
    }

    func beginOperation(id: String) throws -> UInt64 {
        record("beginOperation")
        return 1
    }

    func cancelOperation(id: String, generation: UInt64) throws {
        record("cancelOperation")
    }

    func snapshot() throws -> RustCoreClient.Snapshot {
        record("snapshot")
        return RustCoreClient.Snapshot(
            config: configuration,
            statuses: Dictionary(uniqueKeysWithValues: configuration.tunnels.map {
                ($0.id, TunnelStatus.running(pid: 7))
            })
        )
    }

    func status(id: String) throws -> TunnelStatus {
        lock.lock()
        requestedStatusIDs.append(id)
        lock.unlock()
        record("status")
        if statusFails { throw EnergyOwnerError() }
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
        return .running(pid: 7)
    }

    func remove(id: String, generation: UInt64?) throws {
        record("remove")
    }

    func shutdown() throws -> Int {
        record("shutdown")
        return 0
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private func count(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == event }.count
    }
}
