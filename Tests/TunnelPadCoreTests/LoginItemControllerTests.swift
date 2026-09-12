import XCTest
import ServiceManagement
@testable import TunnelPadCore
@testable import tunnelpad

/// 登录项状态映射与开关语义；不触达真实 SMAppService 注册（避免污染系统登录项），
/// register/unregister 的真实行为由用户登录验收覆盖。
@MainActor
final class LoginItemControllerTests: XCTestCase {

    func testMapsSMAppServiceStatus() {
        XCTAssertEqual(LoginItemController.map(.enabled), .enabled)
        XCTAssertEqual(LoginItemController.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemController.map(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemController.map(.notFound), .notRegistered, "bundle 缺失按未注册处理")
    }

    func testSwitchSemantics() {
        XCTAssertTrue(LoginItemController(state: .enabled).isOn)
        XCTAssertTrue(LoginItemController(state: .requiresApproval).isOn, "待批准表示注册已发起，视觉上为开")
        XCTAssertFalse(LoginItemController(state: .notRegistered).isOn)
    }
}
