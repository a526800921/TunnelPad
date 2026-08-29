import XCTest
@testable import TunnelPadCore

final class LaunchdPlistRendererTests: XCTestCase {

    private let tunnel = TunnelConfig(
        id: "admin-tunnel",
        name: "后台",
        command: ["/usr/bin/ssh", "-N", "-T", "-L", "127.0.0.1:8081:127.0.0.1:8081", "root@ecs.example.invalid"],
        keepAlive: true,
        throttleInterval: 10
    )

    func testXMLRoundtripPreservesProgramArgumentsExactly() throws {
        let logURL = URL(fileURLWithPath: "/Users/test/Library/Logs/TunnelPad/admin-tunnel.log")
        let data = try LaunchdPlistRenderer.plistXMLData(for: tunnel, logURL: logURL)
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(raw as? [String: Any])

        let arguments = try XCTUnwrap(dict["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments, tunnel.command)
        XCTAssertEqual(dict["Label"] as? String, "com.jafish.tunnelpad.admin-tunnel")
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(dict["KeepAlive"] as? Bool, true)
        XCTAssertEqual(dict["ProcessType"] as? String, "Background")
        XCTAssertEqual(dict["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(dict["StandardOutPath"] as? String, logURL.path)
        XCTAssertEqual(dict["StandardErrorPath"] as? String, logURL.path)
    }

    func testWritePlistLandsInLaunchdDirectory() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let paths = TunnelPaths(homeDirectory: tempHome)

        let url = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
        XCTAssertEqual(url, paths.launchdPlistURL(for: tunnel))
        XCTAssertTrue(url.path.hasPrefix(paths.launchdDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
