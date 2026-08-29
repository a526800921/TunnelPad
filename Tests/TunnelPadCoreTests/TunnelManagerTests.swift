import XCTest
import Foundation
@testable import TunnelPadCore

final class TunnelManagerTests: XCTestCase {

    @MainActor
    func testReloadConfigPicksUpChangesAndDropsRemovedStatuses() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "reload-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        ]))

        let manager = TunnelManager(paths: paths)
        XCTAssertEqual(manager.config.tunnels.map(\.id), ["reload-a"])
        manager.refresh()
        XCTAssertEqual(manager.statuses.keys.sorted(), ["reload-a"])

        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "reload-b", name: "B", command: ["/usr/bin/ssh", "-N", "b"])
        ]))
        manager.reloadConfig()

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["reload-b"], "reload 应读取磁盘上的新配置")
        XCTAssertEqual(manager.statuses.keys.sorted(), ["reload-b"], "已移除隧道的状态缓存应被清理")
        XCTAssertTrue(manager.lastMessage?.contains("重新加载") == true)
    }

    @MainActor
    func testUpdateTunnelPersistsChangesAndClearsDroppedProbe() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(
            id: "edit-a",
            name: "A",
            command: ["/usr/bin/ssh", "-N", "a"],
            probe: ProbeConfig(url: "http://127.0.0.1:1/health", expectedStatuses: [200])
        )
        try store.save(AppConfig(tunnels: [tunnel]))

        let manager = TunnelManager(paths: paths)
        manager.refresh()
        // 探针异步执行，轮询等待写回。
        let deadline = Date().addingTimeInterval(5)
        while manager.probeResults["edit-a"] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(manager.probeResults["edit-a"])

        var updated = tunnel
        updated.name = "A2"
        updated.throttleInterval = 15
        updated.probe = nil
        manager.updateTunnel(updated)

        XCTAssertEqual(manager.config.tunnels[0].name, "A2")
        XCTAssertEqual(manager.config.tunnels[0].throttleInterval, 15)
        XCTAssertNil(manager.probeResults["edit-a"], "移除探针后旧结果应被清理")
        XCTAssertTrue(manager.lastMessage?.contains("已保存") == true)

        let reread = store.load().config
        XCTAssertEqual(reread.tunnels[0].name, "A2", "修改应持久化到 config.json")
        XCTAssertEqual(reread.tunnels[0].command, ["/usr/bin/ssh", "-N", "a"])
        XCTAssertNil(reread.tunnels[0].probe)
    }

    @MainActor
    func testUpdateTunnelIgnoresUnknownID() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "edit-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        ]))

        let manager = TunnelManager(paths: paths)
        manager.updateTunnel(TunnelConfig(id: "ghost", name: "G", command: ["/bin/echo"]))

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["edit-a"], "未知 id 不应新增条目")
        XCTAssertNil(manager.lastMessage, "no-op 不应报成功")
    }

    // MARK: - removeTunnel

    @MainActor
    func testRemoveTunnelDeletesLaunchdArtifactsAndPersists() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(id: "remove-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        try store.save(AppConfig(tunnels: [tunnel]))

        let manager = TunnelManager(paths: paths)
        let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try Data("debug1: test\n".utf8).write(to: paths.logURL(for: tunnel))
        manager.refresh()
        XCTAssertEqual(manager.statuses["remove-a"], .notLoaded)

        manager.removeTunnel("remove-a")

        XCTAssertTrue(manager.config.tunnels.isEmpty, "删除后配置应移除条目")
        XCTAssertTrue(store.load().config.tunnels.isEmpty, "删除应持久化到 config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path), "生成的 plist 应被清理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path), "日志文件应被删除")
        XCTAssertNil(manager.statuses["remove-a"], "状态缓存应被清理")
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testRemoveTunnelStopsAppProcessAndCleansFiles() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(id: "remove-app", name: "App", command: ["/bin/sleep", "30"], executor: .app)
        try store.save(AppConfig(tunnels: [tunnel]))

        let manager = TunnelManager(paths: paths)
        try manager.appExecutor.start(tunnel)
        guard case .running = manager.appExecutor.status(id: "remove-app") else {
            return XCTFail("sleep 进程应已启动")
        }

        manager.removeTunnel("remove-app")

        XCTAssertEqual(manager.appExecutor.status(id: "remove-app"), .notLoaded, "删除应终止子进程")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pidfileURL(for: tunnel).path), "pidfile 应被清理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path), "日志文件应被删除")
        XCTAssertTrue(manager.config.tunnels.isEmpty)
        XCTAssertTrue(store.load().config.tunnels.isEmpty)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testRemoveTunnelAbortsAndKeepsConfigWhenBootoutFails() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(id: "remove-b", name: "B", command: ["/usr/bin/ssh", "-N", "b"])
        try store.save(AppConfig(tunnels: [tunnel]))

        // print 恒报 running（实例停不掉），bootout 恒失败：删除必须中断并保留配置。
        let runner = MockProcessRunner { _, arguments in
            if arguments.first == "print" {
                return ProcessResult(
                    exitCode: 0,
                    stdout: "gui/501/\(tunnel.launchdLabel) = {\n\tstate = running\n\tpid = 123\n}"
                )
            }
            if arguments.first == "bootout" {
                return ProcessResult(exitCode: 3, stderr: "Could not find service")
            }
            return nil
        }
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        let manager = TunnelManager(paths: paths, executor: executor)
        let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try Data("debug1: keep\n".utf8).write(to: paths.logURL(for: tunnel))

        manager.removeTunnel("remove-b")

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["remove-b"], "停止失败必须中断并保留配置")
        XCTAssertEqual(store.load().config.tunnels.map(\.id), ["remove-b"], "中断时不得写入配置")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path), "中断时 plist 应保留")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path), "中断时日志应保留")
        XCTAssertTrue(runner.recordedCalls.contains { $0.arguments.first == "bootout" }, "应尝试过 bootout")
        XCTAssertNotNil(manager.lastError)
    }

    @MainActor
    func testRemoveTunnelUnknownIDIsNoop() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "keep-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        ]))

        let manager = TunnelManager(paths: paths)
        manager.removeTunnel("ghost")

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["keep-a"])
        XCTAssertNil(manager.lastError)
    }
}
