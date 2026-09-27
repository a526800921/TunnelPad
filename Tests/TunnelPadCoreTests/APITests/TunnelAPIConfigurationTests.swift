import Foundation
import NIOHTTP1
import XCTest
@testable import TunnelPadCore

final class TunnelAPIConfigurationTests: XCTestCase {
    func testMissingFilePreservesLoopbackDefault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try TunnelAPIConfiguration.load(from: url), TunnelAPIConfiguration())
    }

    func testExplicitLANConfigurationAndInvalidFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api.json")
        try Data(#"{"host":"10.0.0.2","allowedClientIPs":["10.0.0.30"]}"#.utf8).write(to: url)
        XCTAssertEqual(try TunnelAPIConfiguration.load(from: url),
            TunnelAPIConfiguration(host: "10.0.0.2", allowedClientIPs: ["10.0.0.30"]))
        for json in ["{}", "null", "[]", "broken", #"{"host":"10.0.0.2"}"#,
                     #"{"host":"10.0.0.2","allowedClientIPs":[]}"#,
                     #"{"host":"10.0.0.2","allowedClientIPs":["10.0.0.30"],"port":9998}"#,
                     #"{"host":"10.0.0.2","allowedClientIPs":null}"#] {
            try Data(json.utf8).write(to: url)
            XCTAssertThrowsError(try TunnelAPIConfiguration.load(from: url), json)
        }
        XCTAssertThrowsError(try TunnelAPIConfiguration.load(from: directory))
    }

    func testOnlyCanonicalPrivateIPv4AcceptedForLAN() throws {
        for ip in ["0.0.0.0", "::", "::1", "::ffff:10.0.0.30", "8.8.8.8", "localhost",
                   "10.0.0.30/32", "10.00.0.30", "10.0.0.256", "10.0.0.30 ", "10.0.0", "172.32.1.1", "169.254.1.2"] {
            XCTAssertThrowsError(try TunnelAPIConfiguration(host: ip, allowedClientIPs: ["10.0.0.30"]).validate(), ip)
            XCTAssertThrowsError(try TunnelAPIConfiguration(host: "10.0.0.2", allowedClientIPs: [ip]).validate(), ip)
        }
        for ip in ["10.0.0.30", "172.16.1.2", "172.31.1.2", "192.168.1.2"] {
            XCTAssertNoThrow(try TunnelAPIConfiguration(host: ip, allowedClientIPs: [ip]).validate())
        }
    }

    func testSocketPeerIsAuthoritativeAndExact() {
        let policy = TunnelAPIAccessPolicy(configuration: .init(host: "10.0.0.2", allowedClientIPs: ["10.0.0.30"]))
        let headers = HTTPHeaders([("Host", "10.0.0.2:9998")])
        XCTAssertTrue(policy.permits(peerIP: "10.0.0.30", headers: headers, port: 9998))
        XCTAssertTrue(policy.permits(peerIP: "127.0.0.1", headers: headers, port: 9998))
        for ip: String? in [nil, "10.0.0.3", "10.0.0.2", "10.0.0.300", "::ffff:10.0.0.30"] {
            var forged = headers
            forged.add(name: "X-Forwarded-For", value: "10.0.0.30")
            forged.add(name: "Forwarded", value: "for=10.0.0.30")
            XCTAssertFalse(policy.permits(peerIP: ip, headers: forged, port: 9998))
        }
    }

    func testHostAndBrowserChecksCannotBeBypassed() {
        let policy = TunnelAPIAccessPolicy(configuration: .init(host: "10.0.0.2", allowedClientIPs: ["10.0.0.30"]))
        for headers in [HTTPHeaders(), HTTPHeaders([("Host", "evil.example:9998")]),
                        HTTPHeaders([("Host", "10.0.0.2:9997")]),
                        HTTPHeaders([("Host", "10.0.0.2:9998"), ("Host", "evil.example")]),
                        HTTPHeaders([("Host", "10.0.0.2:9998"), ("Origin", "null")]),
                        HTTPHeaders([("Host", "10.0.0.2:9998"), ("Sec-Fetch-Site", "cross-site")])] {
            XCTAssertFalse(policy.permits(peerIP: "10.0.0.30", headers: headers, port: 9998))
        }
    }
}
