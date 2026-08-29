import Foundation

/// `~/Library/LaunchAgents` 下发现的手工隧道 agent。
public struct LegacyAgent: Equatable, Sendable {
    public let label: String
    public let plistURL: URL
    public let programArguments: [String]
    public let keepAlive: Bool
    public let runAtLoad: Bool
    public let throttleInterval: Int?

    public init(
        label: String,
        plistURL: URL,
        programArguments: [String],
        keepAlive: Bool,
        runAtLoad: Bool,
        throttleInterval: Int?
    ) {
        self.label = label
        self.plistURL = plistURL
        self.programArguments = programArguments
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.throttleInterval = throttleInterval
    }
}

public enum LegacyImporterError: Error, Equatable, Sendable {
    case unreadablePlist(path: String)
    case missingLabel(path: String)
}

/// 扫描并解析旧手工隧道 agent（Label 前缀 `com.jafish.motorcycle-manual.`）。
public enum LegacyImporter {
    public static let labelPrefix = "com.jafish.motorcycle-manual."

    /// 扫描目录，返回按 Label 排序的旧 agent。不硬编码清单，发现即列出。
    public static func scan(in directory: URL, fileManager: FileManager = .default) -> [LegacyAgent] {
        let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension == "plist" }
            .compactMap { try? parsePlist(at: $0) }
            .filter { $0.label.hasPrefix(labelPrefix) }
            .sorted { $0.label < $1.label }
    }

    public static func parsePlist(at url: URL) throws -> LegacyAgent {
        let data = try Data(contentsOf: url)
        let raw = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainers], format: nil)
        guard let dict = raw as? [String: Any] else {
            throw LegacyImporterError.unreadablePlist(path: url.path)
        }
        guard let label = dict["Label"] as? String else {
            throw LegacyImporterError.missingLabel(path: url.path)
        }
        let arguments = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        return LegacyAgent(
            label: label,
            plistURL: url,
            programArguments: arguments,
            keepAlive: dict["KeepAlive"] as? Bool ?? false,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            throttleInterval: dict["ThrottleInterval"] as? Int
        )
    }

    /// `com.jafish.motorcycle-manual.<id>` → `<id>`；后缀不是合法 id 时返回 nil。
    public static func tunnelID(for label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let id = String(label.dropFirst(labelPrefix.count))
        return TunnelConfig.isValidID(id) ? id : nil
    }

    /// 旧 agent → 新配置条目；无法派生合法 id 或命令为空时返回 nil。
    public static func tunnelConfig(from agent: LegacyAgent) -> TunnelConfig? {
        guard let id = tunnelID(for: agent.label), !agent.programArguments.isEmpty else { return nil }
        return TunnelConfig(
            id: id,
            name: id,
            command: agent.programArguments,
            executor: .launchd,
            keepAlive: agent.keepAlive,
            throttleInterval: agent.throttleInterval ?? 10
        )
    }
}
