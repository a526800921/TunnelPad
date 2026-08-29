import Foundation

public struct ConfigLoadResult: Sendable, Equatable {
    public var config: AppConfig
    /// 因损坏或不兼容被改名留档的原文件位置（无则 nil）。
    public var recoveredFrom: URL?

    public init(config: AppConfig, recoveredFrom: URL? = nil) {
        self.config = config
        self.recoveredFrom = recoveredFrom
    }
}

/// config.json 读写与损坏恢复：损坏/版本不兼容 → 改名留档 → 重建空配置。
public struct ConfigStore: Sendable {
    public let paths: TunnelPaths

    public init(paths: TunnelPaths) {
        self.paths = paths
    }

    public func load() -> ConfigLoadResult {
        let url = paths.configURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return ConfigLoadResult(config: AppConfig(), recoveredFrom: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            return ConfigLoadResult(config: config, recoveredFrom: nil)
        } catch {
            try? fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            let archiveURL = paths.supportDirectory
                .appendingPathComponent("config.json.corrupt-\(Self.timestamp())")
            try? fileManager.moveItem(at: url, to: archiveURL)
            return ConfigLoadResult(config: AppConfig(), recoveredFrom: archiveURL)
        }
    }

    public func save(_ config: AppConfig) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: paths.configURL, options: .atomic)
    }

    /// 文件名安全的时间戳，供损坏留档与迁移备份共用。
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
