import XCTest
@testable import TunnelPadCore

final class TunnelIDTests: XCTestCase {

    func testSlugify() {
        XCTAssertEqual(TunnelID.generate(from: "Demo Add!", existing: []), "demo-add")
        XCTAssertEqual(TunnelID.generate(from: "  admin  ", existing: []), "admin")
        XCTAssertEqual(TunnelID.generate(from: "生产-环境隧道", existing: []), "tunnel", "非 ASCII 名称全部剔除后回退 tunnel")
        XCTAssertEqual(TunnelID.generate(from: "!!!", existing: []), "tunnel")
        XCTAssertEqual(TunnelID.generate(from: "a--b__c", existing: []), "a-b-c", "连续非法字符合并为单个连字符")
        XCTAssertEqual(TunnelID.generate(from: "", existing: []), "tunnel")
    }

    func testConflictAppendsSequence() {
        XCTAssertEqual(TunnelID.generate(from: "demo", existing: ["demo"]), "demo-2")
        XCTAssertEqual(TunnelID.generate(from: "demo", existing: ["demo", "demo-2", "demo-3"]), "demo-4")
        // 后缀占用不影响新名字
        XCTAssertEqual(TunnelID.generate(from: "demo-2", existing: ["demo-2"]), "demo-2-2")
    }
}
