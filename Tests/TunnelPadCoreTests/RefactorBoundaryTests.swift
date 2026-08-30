import XCTest
import Foundation
@testable import TunnelPadCore

private actor ProbeStartSignal {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private struct FailingRepository: TunnelConfigRepository {
    let initial: AppConfig

    func load() -> ConfigLoadResult {
        ConfigLoadResult(config: initial)
    }

    func save(_ config: AppConfig) throws {
        struct SaveFailure: Error {}
        throw SaveFailure()
    }
}

final class RefactorBoundaryTests: XCTestCase {
    func testRuntimeStatePrunesAndUpdatesAsOneValue() {
        var state = TunnelRuntimeState()
        state.setStatus(.running(pid: 7), for: "a")
        state.setProbeResult(.satisfied(status: 200), for: "a")
        state.setBusy(true, for: "a")

        state.prune(to: ["b"])

        XCTAssertTrue(state.statuses.isEmpty)
        XCTAssertTrue(state.probeResults.isEmpty)
        XCTAssertEqual(state.busyIDs, ["a"], "状态裁剪不应隐式改变操作占用集合")
    }

    func testProbeCoordinatorDropsCancelledGeneration() async {
        let signal = ProbeStartSignal()
        let service = ProbeService(perform: { _ in
            await signal.markStarted()
            try? await Task.sleep(nanoseconds: 500_000_000)
            return 200
        })
        let coordinator = ProbeCoordinator(service: service)
        let probe = ProbeConfig(url: "http://127.0.0.1/health")

        let task = Task {
            await coordinator.run([(id: "a", probe: probe)])
        }
        await signal.waitUntilStarted()
        await coordinator.cancel()

        let result = await task.value
        XCTAssertNil(result, "取消后迟到的探针结果不能写回")
    }

    func testConfigStoreConformsToRepositoryBoundary() {
        let paths = TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory)
        let repository: any TunnelConfigRepository = ConfigStore(paths: paths)
        XCTAssertEqual(repository.load().config, AppConfig())
    }

    @MainActor
    func testAsyncLifecycleKeepsExistingUserMessage() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-async-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let tunnel = TunnelConfig(id: "async-a", name: "异步 A", command: ["/usr/bin/ssh", "-N", "a"])
        try ConfigStore(paths: paths).save(AppConfig(tunnels: [tunnel]))
        let runner = MockProcessRunner { _, arguments in
            if arguments.first == "print" {
                return ProcessResult(exitCode: 0, stdout: "gui/501/\(tunnel.launchdLabel) = {\n\tstate = not running\n}")
            }
            return ProcessResult(exitCode: 0)
        }
        let manager = TunnelManager(paths: paths, executor: LaunchCtlExecutor(runner: runner, uid: 501))

        await manager.startAsync(tunnel.id)

        XCTAssertEqual(manager.lastMessage, "「异步 A」已启动")
        XCTAssertTrue(runner.recordedCalls.contains { $0.arguments.first == "bootstrap" })

        await manager.stopAsync(tunnel.id)
        XCTAssertEqual(manager.lastMessage, "「异步 A」已停止")
        XCTAssertTrue(runner.recordedCalls.contains { $0.arguments.first == "bootout" })
    }

    @MainActor
    func testAsyncRemoveStopsAppAndCommitsConfiguration() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-async-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let tunnel = TunnelConfig(id: "async-remove", name: "异步删除", command: ["/bin/sleep", "30"], executor: .app)
        try ConfigStore(paths: paths).save(AppConfig(tunnels: [tunnel]))
        let manager = TunnelManager(paths: paths)
        try manager.appExecutor.start(tunnel)

        await manager.removeTunnelAsync(tunnel.id)

        XCTAssertTrue(manager.config.tunnels.isEmpty)
        XCTAssertEqual(manager.appExecutor.status(id: tunnel.id), .notLoaded)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testAsyncRemoveSkipsBootoutWhenLaunchdIsNotLoaded() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-async-remove-not-loaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let tunnel = TunnelConfig(id: "async-remove-not-loaded", name: "未加载", command: ["/usr/bin/ssh", "-N", "a"])
        try ConfigStore(paths: paths).save(AppConfig(tunnels: [tunnel]))
        let runner = MockProcessRunner { _, arguments in
            if arguments.first == "print" {
                return ProcessResult(exitCode: 3, stderr: "Could not find service")
            }
            if arguments.first == "bootout" {
                return ProcessResult(exitCode: 3, stderr: "unexpected bootout")
            }
            return ProcessResult(exitCode: 0)
        }
        let manager = TunnelManager(
            paths: paths,
            executor: LaunchCtlExecutor(runner: runner, uid: 501)
        )

        await manager.removeTunnelAsync(tunnel.id)

        XCTAssertTrue(manager.config.tunnels.isEmpty)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(runner.recordedCalls.contains { $0.arguments.first == "bootout" })
    }

    @MainActor
    func testUpdateRollsBackMemoryWhenRepositorySaveFails() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-update-rollback-\(UUID().uuidString)", isDirectory: true)
        let paths = TunnelPaths(homeDirectory: home)
        let original = TunnelConfig(id: "rollback", name: "原始", command: ["/usr/bin/ssh", "-N", "a"])
        let manager = TunnelManager(
            paths: paths,
            executor: LaunchCtlExecutor(runner: MockProcessRunner(), uid: 501),
            configRepository: FailingRepository(initial: AppConfig(tunnels: [original])),
            probeService: ProbeService(perform: { _ in 200 })
        )

        var updated = original
        updated.name = "不应落盘"
        manager.updateTunnel(updated)

        XCTAssertEqual(manager.config.tunnels.first, original)
        XCTAssertEqual(manager.lastError, "保存配置失败：SaveFailure()")
    }

    @MainActor
    func testAsyncAppLifecycleSequenceKeepsConfigAndCleansArtifacts() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-async-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = TunnelPaths(homeDirectory: home)
        let tunnel = TunnelConfig(
            id: "async-lifecycle",
            name: "异步生命周期",
            command: ["/bin/sleep", "60"],
            executor: .app
        )
        try ConfigStore(paths: paths).save(AppConfig(tunnels: [tunnel]))
        let manager = TunnelManager(paths: paths)

        await manager.refreshAsync()
        await manager.startAsync(tunnel.id)
        guard case .running = manager.statuses[tunnel.id] else {
            return XCTFail("异步启动后应显示 running")
        }

        await manager.stopAsync(tunnel.id)
        XCTAssertEqual(manager.statuses[tunnel.id], .notLoaded)
        await manager.restartAsync(tunnel.id)
        guard case .running = manager.statuses[tunnel.id] else {
            return XCTFail("异步重启后应显示 running")
        }

        await manager.removeTunnelAsync(tunnel.id)
        XCTAssertTrue(manager.config.tunnels.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pidfileURL(for: tunnel).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path))
    }
}
