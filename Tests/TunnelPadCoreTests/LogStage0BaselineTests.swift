import Foundation
import XCTest
@testable import TunnelPadCore

final class LogStage0BaselineTests: XCTestCase {

    func testCurrentPollingBaselineDoesNotExposeAppendUntilNextRefresh() throws {
        let fixture = try IsolatedLogFileFixture()
        defer { fixture.remove() }

        try fixture.write("line-1\n")
        var visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))

        try fixture.append("line-2\n")
        XCTAssertEqual(visibleText, "line-1")

        visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))
        XCTAssertEqual(visibleText, "line-1\nline-2")
    }

    func testCurrentPollingBaselineReopensWithSnapshotAfterPanelWasClosed() throws {
        let fixture = try IsolatedLogFileFixture()
        defer { fixture.remove() }

        try fixture.write("before-close\n")
        var visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))

        try fixture.append("while-closed\n")
        XCTAssertEqual(visibleText, "before-close")

        visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))
        XCTAssertEqual(visibleText, "before-close\nwhile-closed")
    }

    func testCurrentPollingBaselineObservesReplacementOnlyOnNextRead() throws {
        let fixture = try IsolatedLogFileFixture()
        defer { fixture.remove() }

        try fixture.write("old-file\n")
        var visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))

        try fixture.replace(with: "new-file\n")
        XCTAssertEqual(visibleText, "old-file")

        visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))
        XCTAssertEqual(visibleText, "new-file")
    }

    func testCurrentPollingBaselineReadsUtf8WithoutFinalNewline() throws {
        let fixture = try IsolatedLogFileFixture()
        defer { fixture.remove() }

        try fixture.write("中文 🚀\n尾部没有换行")

        XCTAssertEqual(
            LogTail.lastLines(of: fixture.url, maxLines: 500),
            "中文 🚀\n尾部没有换行"
        )
    }

    func testCurrentPollingBaselineDoesNotTrimPhysicalFileTo2000Lines() throws {
        let fixture = try IsolatedLogFileFixture()
        defer { fixture.remove() }

        let content = (1...2_001).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(content)

        XCTAssertEqual(try fixture.logicalLineCount(), 2_001)
        let visibleText = try XCTUnwrap(LogTail.lastLines(of: fixture.url, maxLines: 500))
        XCTAssertEqual(visibleText.split(separator: "\n").count, 500)
        XCTAssertTrue(visibleText.hasSuffix("line-2001"))
    }

    func testLaunchdBaselineUsesOneStablePerTunnelLogForBothStreams() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-log-stage0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let tunnel = TunnelConfig(id: "stage0-log", name: "阶段 0", command: ["/bin/true"])
        let paths = TunnelPaths(homeDirectory: home)
        let logURL = paths.logURL(for: tunnel)
        let plist = LaunchdPlistRenderer.plistDictionary(for: tunnel, logURL: logURL)

        XCTAssertEqual(plist["StandardOutPath"] as? String, logURL.path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, logURL.path)
        XCTAssertEqual(logURL.lastPathComponent, "stage0-log.log")
    }
}

private final class IsolatedLogFileFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-log-stage0-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("tunnel.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func replace(with text: String) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func logicalLineCount() throws -> Int {
        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
