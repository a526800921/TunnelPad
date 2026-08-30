import Foundation

/// launchd 执行能力的内部边界；不改变现有 LaunchCtlExecutor 公共类型。
protocol LaunchdExecuting: Sendable {
    func bootstrap(label: String, plistURL: URL) throws
    @discardableResult
    func bootout(label: String) throws -> Bool
    func status(label: String) -> TunnelStatus
}

extension LaunchCtlExecutor: LaunchdExecuting {}

/// app 子进程执行能力的内部边界；UI 仍可继续使用 AppProcessExecutor。
protocol AppExecuting: Sendable {
    func start(_ tunnel: TunnelConfig) throws
    func stop(_ tunnel: TunnelConfig)
    func restart(_ tunnel: TunnelConfig) throws
    func status(id: String) -> TunnelStatus
}

extension AppProcessExecutor: AppExecuting {}
