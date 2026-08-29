import Foundation

public enum ConfigError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int)
}

/// config.json 顶层结构。version 必须等于 1，否则按损坏恢复处理。
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var tunnels: [TunnelConfig]

    public init(version: Int = AppConfig.currentVersion, tunnels: [TunnelConfig] = []) {
        self.version = version
        self.tunnels = tunnels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw ConfigError.unsupportedSchemaVersion(found: version)
        }
        self.version = version
        tunnels = try container.decode([TunnelConfig].self, forKey: .tunnels)
    }

    private enum CodingKeys: String, CodingKey {
        case version, tunnels
    }
}
