import XCTest
@testable import TunnelPadCore

final class TunnelConfigTests: XCTestCase {

    func testLabelDerivation() {
        let tunnel = TunnelConfig(id: "admin-tunnel", name: "后台", command: ["/usr/bin/ssh"])
        XCTAssertEqual(tunnel.launchdLabel, "com.jafish.tunnelpad.admin-tunnel")
    }

    func testIDValidation() {
        XCTAssertTrue(TunnelConfig.isValidID("admin-tunnel"))
        XCTAssertTrue(TunnelConfig.isValidID("reverse-ssh"))
        XCTAssertFalse(TunnelConfig.isValidID(""))
        XCTAssertFalse(TunnelConfig.isValidID("Admin"))
        XCTAssertFalse(TunnelConfig.isValidID("a b"))
        XCTAssertFalse(TunnelConfig.isValidID("a.b"))
    }

    func testDecodingDefaults() throws {
        let json = #"{"version":1,"tunnels":[{"id":"x","name":"X","command":["/bin/true"]}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let tunnel = try XCTUnwrap(config.tunnels.first)
        XCTAssertEqual(tunnel.executor, .launchd)
        XCTAssertTrue(tunnel.keepAlive)
        XCTAssertEqual(tunnel.throttleInterval, 10)
    }

    func testDecodingRejectsInvalidID() {
        let json = #"{"version":1,"tunnels":[{"id":"Bad.ID","name":"X","command":["/bin/true"]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)))
    }

    func testDecodingRejectsEmptyCommand() {
        let json = #"{"version":1,"tunnels":[{"id":"x","name":"X","command":[]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)))
    }

    func testRoundtripPreservesFields() throws {
        let original = AppConfig(tunnels: [
            TunnelConfig(id: "reverse-ssh", name: "反向", command: ["/usr/bin/ssh", "-N", "-R", "127.0.0.1:22022:127.0.0.1:22", "root@ecs.example.invalid"],
                         executor: .launchd, keepAlive: true, throttleInterval: 15)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
