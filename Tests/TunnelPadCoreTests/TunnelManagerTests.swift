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
}
