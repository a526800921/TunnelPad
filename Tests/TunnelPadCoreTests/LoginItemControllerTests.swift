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

    func testRegistrationFailureSurvivesToggleStatusRefreshForImmediateAlert() {
        let service = LoginItemServiceFixture(status: .notRegistered)
        service.registerError = LoginItemFixtureError.registrationDenied
        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.toggle(), .notRegistered)
        XCTAssertEqual(controller.registrationError, "fixture registration denied")

        controller.refresh()
        XCTAssertNil(
            controller.registrationError,
            "后续菜单刷新可以清除已经展示过的错误；toggle 返回时必须仍可读取"
        )
    }
}

private final class LoginItemServiceFixture: LoginItemServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private enum LoginItemFixtureError: LocalizedError {
    case registrationDenied

    var errorDescription: String? { "fixture registration denied" }
}
