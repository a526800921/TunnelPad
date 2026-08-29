import XCTest
@testable import TunnelPadCore

final class ConfigStoreTests: XCTestCase {

    private var tempHome: URL!
    private var paths: TunnelPaths!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = TunnelPaths(homeDirectory: tempHome)
        store = ConfigStore(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testMissingFileReturnsEmptyConfig() {
        let result = store.load()
        XCTAssertEqual(result.config, AppConfig())
        XCTAssertNil(result.recoveredFrom)
    }

    func testSaveLoadRoundtrip() throws {
        var config = AppConfig()
        config.tunnels = [TunnelConfig(id: "admin-tunnel", name: "后台", command: ["/usr/bin/ssh", "-N"])]
        try store.save(config)

        let loaded = store.load()
        XCTAssertEqual(loaded.config, config)
        XCTAssertNil(loaded.recoveredFrom)
    }

    func testCorruptFileIsArchivedAndRebuilt() throws {
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: paths.configURL)

        let result = store.load()
        XCTAssertEqual(result.config, AppConfig())
        let archived = try XCTUnwrap(result.recoveredFrom)
        XCTAssertTrue(archived.lastPathComponent.hasPrefix("config.json.corrupt-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configURL.path))
    }

    func testUnsupportedVersionIsTreatedAsCorrupt() throws {
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let json = #"{"version":99,"tunnels":[]}"#
        try Data(json.utf8).write(to: paths.configURL)

        let result = store.load()
        XCTAssertEqual(result.config, AppConfig())
        XCTAssertNotNil(result.recoveredFrom)
    }
}
