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
