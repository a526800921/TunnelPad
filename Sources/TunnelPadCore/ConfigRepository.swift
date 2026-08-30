import Foundation

/// 配置持久化边界。
///
/// `TunnelManager` 只依赖这个能力，不再绑定具体的文件实现，便于在不触碰
/// `config.json` 格式的前提下替换存储或注入失败场景。
protocol TunnelConfigRepository: Sendable {
    func load() -> ConfigLoadResult
    func save(_ config: AppConfig) throws
}

extension ConfigStore: TunnelConfigRepository {}
