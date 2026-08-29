import XCTest
@testable import TunnelPadCore

final class ProbeTests: XCTestCase {

    func testProbeConfigDefaults() throws {
        let json = #"{"url": "http://127.0.0.1:8081/admin"}"#
        let probe = try JSONDecoder().decode(ProbeConfig.self, from: Data(json.utf8))
        XCTAssertEqual(probe.url, "http://127.0.0.1:8081/admin")
        XCTAssertEqual(probe.expectedStatuses, [200])
    }

    func testTunnelConfigBackwardCompatibleWithoutProbe() throws {
        let json = #"{"version":1,"tunnels":[{"id":"x","name":"X","command":["/bin/true"]}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.tunnels.first?.probe)
    }

    func testTunnelConfigDecodesProbe() throws {
        let json = """
        {"version":1,"tunnels":[{"id":"x","name":"X","command":["/bin/true"],
          "probe":{"url":"http://127.0.0.1:8081/admin","expectedStatuses":[200,401]}}]}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.tunnels.first?.probe, ProbeConfig(url: "http://127.0.0.1:8081/admin", expectedStatuses: [200, 401]))
    }

    func testProbeSatisfiedWhenStatusInExpected() async {
        let service = ProbeService { _ in 401 }
        let result = await service.check(ProbeConfig(url: "http://example.invalid/", expectedStatuses: [200, 401]))
        XCTAssertEqual(result, .satisfied(status: 401))
    }

    func testProbeUnexpectedWhenStatusOutsideExpected() async {
        let service = ProbeService { _ in 403 }
        let result = await service.check(ProbeConfig(url: "http://example.invalid/", expectedStatuses: [200, 401]))
        XCTAssertEqual(result, .unexpected(status: 403))
    }

    func testProbeFailedOnThrow() async {
        let service = ProbeService { _ in throw URLError(.cannotConnectToHost) }
        let result = await service.check(ProbeConfig(url: "http://example.invalid/"))
        guard case .failed = result else {
            return XCTFail("期待 failed，实际 \(result)")
        }
    }

    func testProbeFailedOnInvalidURL() async {
        let service = ProbeService { _ in 200 }
        let result = await service.check(ProbeConfig(url: ""))
        guard case .failed = result else {
            return XCTFail("期待 failed，实际 \(result)")
        }
    }
}
