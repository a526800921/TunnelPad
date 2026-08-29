import XCTest
@testable import TunnelPadCore

final class LegacyImporterTests: XCTestCase {

    /// 与真实旧 agent 同构的 fixture（主机名使用占位值，遵守仓库敏感信息红线）。
    private static let legacyAdminPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.jafish.motorcycle-manual.admin-tunnel</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/bin/ssh</string>
            <string>-i</string>
            <string>/Users/test/.ssh/example.pem</string>
            <string>-o</string>
            <string>ExitOnForwardFailure=yes</string>
            <string>-N</string>
            <string>-T</string>
            <string>-L</string>
            <string>127.0.0.1:8081:127.0.0.1:8081</string>
            <string>root@ecs.example.invalid</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ProcessType</key>
        <string>Background</string>
        <key>ThrottleInterval</key>
        <integer>10</integer>
    </dict>
    </plist>
    """

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFixture(_ name: String, content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testParseAndConvertPreservesCommandExactly() throws {
        let url = try writeFixture("admin.plist", content: Self.legacyAdminPlist)
        let agent = try LegacyImporter.parsePlist(at: url)

        XCTAssertEqual(agent.label, "com.jafish.motorcycle-manual.admin-tunnel")
        XCTAssertTrue(agent.keepAlive)
        XCTAssertTrue(agent.runAtLoad)
        XCTAssertEqual(agent.throttleInterval, 10)

        let tunnel = try XCTUnwrap(LegacyImporter.tunnelConfig(from: agent))
        XCTAssertEqual(tunnel.id, "admin-tunnel")
        XCTAssertEqual(tunnel.name, "admin-tunnel")
        XCTAssertEqual(tunnel.command, [
            "/usr/bin/ssh",
            "-i",
            "/Users/test/.ssh/example.pem",
            "-o",
            "ExitOnForwardFailure=yes",
            "-N",
            "-T",
            "-L",
            "127.0.0.1:8081:127.0.0.1:8081",
            "root@ecs.example.invalid",
        ])
        XCTAssertEqual(tunnel.launchdLabel, "com.jafish.tunnelpad.admin-tunnel")
    }

    func testScanOnlyPicksProjectPrefix() throws {
        _ = try writeFixture("a.plist", content: Self.legacyAdminPlist)
        _ = try writeFixture("b.plist", content: Self.legacyAdminPlist.replacingOccurrences(
            of: "com.jafish.motorcycle-manual.admin-tunnel",
            with: "com.other.reversed"
        ))

        let agents = LegacyImporter.scan(in: tempDir)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.label, "com.jafish.motorcycle-manual.admin-tunnel")
    }

    func testTunnelIDRejectsInvalidSuffix() {
        XCTAssertNil(LegacyImporter.tunnelID(for: "com.other.reversed"))
        XCTAssertNil(LegacyImporter.tunnelID(for: "com.jafish.motorcycle-manual.Bad.ID"))
        XCTAssertEqual(LegacyImporter.tunnelID(for: "com.jafish.motorcycle-manual.reverse-ssh"), "reverse-ssh")
    }

    func testTunnelConfigNilWhenArgumentsEmpty() throws {
        let url = try writeFixture(
            "empty.plist",
            content: Self.legacyAdminPlist
                .replacingOccurrences(of: "com.jafish.motorcycle-manual.admin-tunnel", with: "com.jafish.motorcycle-manual.noargs")
        )
        let agent = try LegacyImporter.parsePlist(at: url)
        let stripped = LegacyAgent(
            label: agent.label,
            plistURL: agent.plistURL,
            programArguments: [],
            keepAlive: agent.keepAlive,
            runAtLoad: agent.runAtLoad,
            throttleInterval: agent.throttleInterval
        )
        XCTAssertNil(LegacyImporter.tunnelConfig(from: stripped))
    }
}
