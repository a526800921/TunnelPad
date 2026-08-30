import XCTest
@testable import TunnelPadCore

final class RustCoreClientTests: XCTestCase {
    func testReleaseOwnerLoadsSnapshotAndClosesHandle() throws {
        let libraryURL = try releaseLibraryURL()
        let home = try makeTemporaryHome(named: "owner-snapshot")
        defer { try? FileManager.default.removeItem(at: home) }

        let tunnel = TunnelConfig(
            id: "owner-a",
            name: "Owner A",
            command: ["/usr/bin/true"]
        )
        try ConfigStore(paths: TunnelPaths(homeDirectory: home))
            .save(AppConfig(tunnels: [tunnel]))

        let client = try RustCoreClient(
            paths: TunnelPaths(homeDirectory: home),
            libraryURL: libraryURL
        )
        let snapshot = try client.snapshot()

        XCTAssertEqual(snapshot.config.tunnels, [tunnel])
        XCTAssertEqual(snapshot.statuses[tunnel.id], .notLoaded)

        try client.shutdown()
        XCTAssertThrowsError(try client.snapshot()) { error in
            guard case let RustCoreClient.ClientError.remote(code, _) = error else {
                return XCTFail("shutdown 后应返回 owner closed，实际为：\(error)")
            }
            XCTAssertEqual(code, 9)
        }
    }

    func testOwnerRejectsAppConfigWithoutSwiftFallback() throws {
        let libraryURL = try releaseLibraryURL()
        let home = try makeTemporaryHome(named: "owner-app-rejected")
        defer { try? FileManager.default.removeItem(at: home) }

        let tunnel = TunnelConfig(
            id: "owner-app",
            name: "App 不支持",
            command: ["/usr/bin/true"],
            executor: .app
        )
        try ConfigStore(paths: TunnelPaths(homeDirectory: home))
            .save(AppConfig(tunnels: [tunnel]))

        XCTAssertThrowsError(
            try RustCoreClient(
                paths: TunnelPaths(homeDirectory: home),
                libraryURL: libraryURL
            )
        ) { error in
            guard case let RustCoreClient.ClientError.createFailed(reason) = error else {
                return XCTFail("app 配置应在 Rust owner 创建时拒绝，实际为：\(error)")
            }
            XCTAssertTrue(reason.contains("仅支持 launchd"))
        }
    }

    private func releaseLibraryURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let libraryURL = root.appendingPathComponent("rust/target/release/libtunnelpad_core.dylib")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: libraryURL.path),
            "先执行 cargo build --release --manifest-path rust/Cargo.toml"
        )
        return libraryURL
    }

    private func makeTemporaryHome(named name: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
