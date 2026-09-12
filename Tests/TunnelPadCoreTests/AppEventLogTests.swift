import XCTest
import Foundation
@testable import TunnelPadCore

final class AppEventLogTests: XCTestCase {

    func testWritesAppendLinesWithTimestamp() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-applog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = AppEventLog(paths: TunnelPaths(homeDirectory: home))

        log.write("第一条")
        log.write("第二条", date: Date(timeIntervalSince1970: 1_000))

        let content = try String(contentsOf: TunnelPaths(homeDirectory: home).appEventLogURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[TunnelPad] 第一条"), "实际：\(lines[0])")
        XCTAssertTrue(lines[1].hasSuffix("[TunnelPad] 第二条"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(lines[1].prefix(20))))
    }

    func testRotationKeepsNewerHalf() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-applog-rot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = AppEventLog(paths: TunnelPaths(homeDirectory: home), maxBytes: 600)

        for index in 1...40 {
            log.write("事件 \(index) —— 一些填充内容让体积超过上限")
        }

        let url = TunnelPaths(homeDirectory: home).appEventLogURL
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertLessThanOrEqual(size, 600 + 200, "轮询后体积应回到上限附近")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("事件 40"), "最新事件必须保留")
        XCTAssertFalse(content.contains("事件 1 ——"), "最老事件应被轮转丢弃")
    }
}
