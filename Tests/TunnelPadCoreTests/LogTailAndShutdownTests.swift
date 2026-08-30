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
