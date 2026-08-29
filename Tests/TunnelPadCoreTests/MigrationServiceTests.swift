import XCTest
@testable import TunnelPadCore

final class MigrationServiceTests: XCTestCase {

    private var tempHome: URL!
    private var paths: TunnelPaths!
    private var launchAgentsDir: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = TunnelPaths(homeDirectory: tempHome)
        launchAgentsDir = paths.launchAgentsDirectory
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func writeLegacyPlist(label: String) throws -> URL {
        let url = launchAgentsDir.appendingPathComponent("\(label).plist")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/ssh</string>
                <string>-N</string>
                <string>-L</string>
                <string>127.0.0.1:8081:127.0.0.1:8081</string>
                <string>root@ecs.example.invalid</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """
        try Data(xml.utf8).write(to: url)
        return url
    }

    private func makeAgent(label: String) throws -> LegacyAgent {
        try LegacyImporter.parsePlist(at: writeLegacyPlist(label: label))
    }

    private func makeService(_ runner: MockProcessRunner) -> MigrationService {
        MigrationService(
            paths: paths,
            executor: LaunchCtlExecutor(runner: runner, uid: 501),
            pollDelay: {}
        )
    }

    func testSuccessfulTakeoverMovesBackupAndBootstrapsNewLabel() throws {
        let agent = try makeAgent(label: "com.jafish.motorcycle-manual.admin-tunnel")
        let originalURL = agent.plistURL
        let runner = MockProcessRunner(results: [
            ProcessResult(exitCode: 0),  // bootout 旧
            ProcessResult(exitCode: 0),  // bootstrap 新
            ProcessResult(exitCode: 0, stdout: "gui/501/com.jafish.tunnelpad.admin-tunnel = {\n\tstate = running\n\tpid = 100\n}"),
        ])
        let service = makeService(runner)

        let outcome = try service.takeover(agent: agent)

        XCTAssertFalse(outcome.rolledBack)
        XCTAssertEqual(outcome.tunnel.id, "admin-tunnel")
        XCTAssertEqual(outcome.tunnel.launchdLabel, "com.jafish.tunnelpad.admin-tunnel")

        // 备份：旧 plist 已移动到 migration-backup
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(outcome.backupURL.path.contains("migration-backup"))

        // 命令序列：bootout 旧 → bootstrap 新 → print 新
        let calls = runner.recordedCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].arguments, ["bootout", "gui/501/com.jafish.motorcycle-manual.admin-tunnel"])
        XCTAssertEqual(calls[1].arguments.first, "bootstrap")
        XCTAssertEqual(calls[1].arguments.dropFirst().first, "gui/501")
        XCTAssertTrue(calls[1].arguments.last?.hasSuffix("com.jafish.tunnelpad.admin-tunnel.plist") ?? false)
        XCTAssertEqual(calls[2].arguments, ["print", "gui/501/com.jafish.tunnelpad.admin-tunnel"])

        // 新 plist 已生成且 ProgramArguments 等价
        let rendered = try LegacyImporter.parsePlist(at: paths.launchdPlistURL(for: outcome.tunnel))
        XCTAssertEqual(rendered.programArguments, agent.programArguments)
        XCTAssertEqual(rendered.label, "com.jafish.tunnelpad.admin-tunnel")
    }

    func testBootstrapFailureTriggersRollback() throws {
        let label = "com.jafish.motorcycle-manual.reverse-ssh"
        let agent = try makeAgent(label: label)
        let originalURL = agent.plistURL
        let runner = MockProcessRunner(results: [
            ProcessResult(exitCode: 0),  // bootout 旧
            ProcessResult(exitCode: 1, stderr: "Bootstrap failed: 5"),  // bootstrap 新失败
            ProcessResult(exitCode: 0),  // 回滚：bootout 新（尽力）
            ProcessResult(exitCode: 0),  // 回滚：bootout 旧（尽力）
            ProcessResult(exitCode: 0),  // 回滚：bootstrap 旧
        ])
        let service = makeService(runner)

        XCTAssertThrowsError(try service.takeover(agent: agent))

        // 旧 plist 已还原到 LaunchAgents
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        let restored = try LegacyImporter.parsePlist(at: originalURL)
        XCTAssertEqual(restored.label, label)
        XCTAssertEqual(restored.programArguments, agent.programArguments)

        // 回滚序列包含 bootstrap 旧 agent
        let calls = runner.recordedCalls
        let bootstraps = calls.filter { $0.arguments.first == "bootstrap" }
        XCTAssertEqual(bootstraps.count, 2)
        XCTAssertTrue(bootstraps[1].arguments.last?.hasSuffix("\(label).plist") ?? false)
    }

    func testVerifyTimeoutTriggersRollback() throws {
        let label = "com.jafish.motorcycle-manual.admin-tunnel"
        let agent = try makeAgent(label: label)
        // print 一直查不到服务 → 验证超时；bootout/bootstrap 均成功以让回滚完成
        let runner = MockProcessRunner(defaultResult: ProcessResult(exitCode: 0)) { _, arguments in
            if arguments.first == "print" {
                return ProcessResult(exitCode: 3, stderr: "Could not find service")
            }
            return nil
        }
        let service = makeService(runner)

        XCTAssertThrowsError(try service.takeover(agent: agent)) { error in
            guard case MigrationError.verifyFailed = error else {
                return XCTFail("期待 verifyFailed，实际 \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.plistURL.path))

        // 回滚序列确实执行了 bootstrap 旧 agent
        let bootstraps = runner.recordedCalls.filter { $0.arguments.first == "bootstrap" }
        XCTAssertEqual(bootstraps.count, 2)
        XCTAssertTrue(bootstraps[1].arguments.last?.hasSuffix("\(label).plist") ?? false)
    }

    func testInvalidAgentIsRejectedWithoutTouchingAnything() throws {
        let agent = LegacyAgent(
            label: "com.other.something",
            plistURL: launchAgentsDir.appendingPathComponent("x.plist"),
            programArguments: ["/usr/bin/ssh"],
            keepAlive: true,
            runAtLoad: true,
            throttleInterval: nil
        )
        let runner = MockProcessRunner()
        let service = makeService(runner)

        XCTAssertThrowsError(try service.takeover(agent: agent))
        XCTAssertTrue(runner.recordedCalls.isEmpty)
    }
}
