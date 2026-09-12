import ServiceManagement
import TunnelPadCore

/// 登录项状态；`SMAppService.Status` 的可测试映射。
enum LoginItemState: Equatable {
    /// 已注册且获批，下次登录自动启动。
    case enabled
    /// 已注册但等待用户在系统设置中批准。
    case requiresApproval
    /// 未注册。
    case notRegistered
}

/// 「登录时自动启动」开关：`SMAppService.mainApp` 的薄封装。
/// 注册状态由系统持久化，不写入 config.json；App 侧只读写系统状态。
@MainActor
final class LoginItemController: ObservableObject {
    private let service: SMAppService
    private(set) var state: LoginItemState
    private(set) var registrationError: String?

    init(service: SMAppService = .mainApp) {
        self.service = service
        self.state = Self.map(service.status)
    }

    /// 测试与预览用：直接以给定状态构造，不触达系统服务。
    init(state: LoginItemState) {
        self.service = .mainApp
        self.state = state
    }

    /// 开关视觉状态：requiresApproval 已发起注册，也算"开"。
    var isOn: Bool { state != .notRegistered }

    func refresh() {
        state = Self.map(service.status)
        registrationError = nil
    }

    /// 切换注册。返回切换后的最新状态；注册/注销失败时记录
    /// `registrationError` 并保持原状态，由调用方决定如何提示。
    func toggle() -> LoginItemState {
        registrationError = nil
        do {
            switch state {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered:
                try service.register()
            }
        } catch {
            registrationError = error.localizedDescription
        }
        refresh()
        return state
    }

    /// requiresApproval 时引导用户完成系统级批准。
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func map(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }
}
