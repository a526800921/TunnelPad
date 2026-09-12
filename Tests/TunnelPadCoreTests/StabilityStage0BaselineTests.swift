import Foundation
import XCTest
@testable import TunnelPadCore

final class StabilityStage0BaselineTests: XCTestCase {

    func testThreeProbeFailuresRemainProbeResults() async {
        let service = ProbeService { _ in
            throw URLError(.cannotConnectToHost)
        }
        let probe = ProbeConfig(url: "http://127.0.0.1:1/health")

        var results: [ProbeResult] = []
        for _ in 0..<3 {
            results.append(await service.check(probe))
        }

        XCTAssertEqual(results.count, 3)
        for result in results {
            guard case .failed = result else {
                return XCTFail("连续失败应保持为 ProbeResult.failed，实际为：\(result)")
            }
        }
    }

    @MainActor
    func testProbeFailureDoesNotInvokeLifecycleRecovery() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let tunnel = TunnelConfig(
            id: "probe-failure",
            name: "Probe Failure",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://127.0.0.1:1/health")
        )
        let owner = RecordingStabilityOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: PassingStabilityPreStartChecker()
        )

        manager.refresh()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(manager.probeResults[tunnel.id], "未运行隧道不应执行失败端点探针")

        let lifecycleCalls = owner.calls().filter {
            ["start", "stop", "restart", "remove", "shutdown"].contains($0)
        }
        XCTAssertTrue(lifecycleCalls.isEmpty, "未运行隧道不应触发生命周期恢复：\(lifecycleCalls)")
        await manager.shutdownAsync()
    }

    func testCorruptConfigCurrentlyArchivesAndReturnsEmptyConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-corrupt-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let store = ConfigStore(paths: paths)
        let effectiveConfig = AppConfig(tunnels: [
            TunnelConfig(id: "effective", name: "Effective", command: ["/usr/bin/true"])
        ])
        try store.save(effectiveConfig)
        XCTAssertEqual(store.load().config, effectiveConfig)

        try Data("{\"version\":1,\"tunnels\":[".utf8).write(to: paths.configURL)

        let result = store.load()
        XCTAssertEqual(result.config, AppConfig(), "当前损坏配置读取会退化为空配置，这是待修复基线")
        let archived = try XCTUnwrap(result.recoveredFrom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configURL.path))
    }

    func testHalfWrittenConfigCurrentlyArchivesAndReturnsEmptyConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-half-written-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let store = ConfigStore(paths: paths)
        let halfWritten = "{\"version\":1,\"tunnels\":[{\"id\":\"half\""
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data(halfWritten.utf8).write(to: paths.configURL)

        let result = store.load()
        XCTAssertEqual(result.config, AppConfig(), "当前半写入配置读取会退化为空配置，这是待修复基线")
        let archived = try XCTUnwrap(result.recoveredFrom)
        XCTAssertEqual(try Data(contentsOf: archived), Data(halfWritten.utf8))
    }
}

private struct PassingStabilityPreStartChecker: ECSPreStartChecking {
    func check(tunnel: TunnelConfig) throws {}

    func checkAsync(tunnel: TunnelConfig) async throws {}
}

private final class RecordingStabilityOwner: RustLifecycleOwner, @unchecked Sendable {
    private let config: AppConfig
    private let lock = NSLock()
    private var recordedCalls: [String] = []

    init(config: AppConfig) {
        self.config = config
    }

    func calls() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func loadConfig() throws -> AppConfig {
        record("loadConfig")
        return config
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
        let statuses = Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, TunnelStatus.notLoaded) })
        return RustCoreClient.Snapshot(config: config, statuses: statuses)
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("start")
        return .running(pid: nil)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("stop")
        return .notRunning
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("restart")
        return .running(pid: nil)
    }

    func remove(id: String, generation: UInt64?) throws {
        record("remove")
    }

    func shutdown() throws -> Int {
        record("shutdown")
        return 0
    }

    private func record(_ call: String) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}
