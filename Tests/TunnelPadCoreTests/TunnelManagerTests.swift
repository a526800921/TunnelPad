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
}
