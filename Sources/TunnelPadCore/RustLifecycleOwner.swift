import Foundation

/// TunnelManager 依赖的 Rust Core 生命周期最小接口。
///
/// 生产实现仍是 RustCoreClient；协议只用于让启动前置检查可以在测试中
/// 注入 fake owner，不创建第二个生命周期 owner，也不改变 FFI 契约。
protocol RustLifecycleOwner: Sendable {
    func loadConfig() throws -> AppConfig
    func saveConfig(_ config: AppConfig) throws
    func beginOperation(id: String) throws -> UInt64
    func cancelOperation(id: String, generation: UInt64) throws
    func snapshot() throws -> RustCoreClient.Snapshot
    func start(id: String, generation: UInt64?) throws -> TunnelStatus
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus
    func remove(id: String, generation: UInt64?) throws
    func shutdown() throws -> Int
}

extension RustCoreClient: RustLifecycleOwner {}

/// 健康监测按需读取单条隧道状态的能力，不扩大生命周期 owner 的公共契约。
/// 不具备该能力的 owner 在健康监测中 fail-closed，不使用旧状态触发恢复。
protocol RustHealthStatusReader: Sendable {
    func status(id: String) throws -> TunnelStatus

    /// 仅用于健康恢复区分受控的 launchctl 状态查询超时；其他错误仍
    /// fail-closed，不使用旧状态触发生命周期副作用。
    func isStatusQueryTimeout(_ error: Error) -> Bool
}

extension RustHealthStatusReader {
    func isStatusQueryTimeout(_ error: Error) -> Bool { false }
}

extension RustCoreClient: RustHealthStatusReader {}
