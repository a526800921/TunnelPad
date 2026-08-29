import XCTest
@testable import TunnelPadCore

final class LogTailTests: XCTestCase {

    func testLastLinesReturnsTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let content = (1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: url)

        let tail = try XCTUnwrap(LogTail.lastLines(of: url, maxLines: 3))
        XCTAssertEqual(tail, "line-8\nline-9\nline-10")
    }

    func testWholeFileWhenFewerLinesThanLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("only\none\n".utf8).write(to: url)
        XCTAssertEqual(LogTail.lastLines(of: url, maxLines: 500), "only\none")
    }

    func testMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-missing-\(UUID().uuidString).log")
        XCTAssertNil(LogTail.lastLines(of: url))
    }
}

final class ShutdownPidfileTests: XCTestCase {

    private func waitUntilKilled(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return kill(pid, 0) != 0
    }

    func testKillByPidfileTerminatesLiveProcessAndRemovesFile() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier

        let pidfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-pid-\(UUID().uuidString).pid")
        try Data("\(pid)\n".utf8).write(to: pidfile)

        XCTAssertTrue(Shutdown.killByPidfile(at: pidfile))
        XCTAssertTrue(waitUntilKilled(pid), "pidfile 终止应使进程退出")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidfile.path))

        process.waitUntilExit()
    }

    func testKillByPidfileCleansStaleFile() throws {
        let pidfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-pid-\(UUID().uuidString).pid")
        // 99999999 极不可能存在；kill(pid,0) != 0 走清理分支
        try Data("99999999\n".utf8).write(to: pidfile)

        XCTAssertFalse(Shutdown.killByPidfile(at: pidfile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidfile.path))
    }

    func testKillByPidfileWithGarbageContent() throws {
        let pidfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-pid-\(UUID().uuidString).pid")
        try Data("not-a-pid\n".utf8).write(to: pidfile)

        XCTAssertFalse(Shutdown.killByPidfile(at: pidfile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidfile.path))
    }
}
