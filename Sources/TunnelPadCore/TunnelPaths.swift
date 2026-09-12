import Foundation

/// 集中管理 TunnelPad 的全部磁盘路径，测试可注入 home 目录。
public struct TunnelPaths: Sendable, Equatable {
    public let homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    /// 真实环境路径（基于当前用户 home）。
    public static func standard() -> TunnelPaths {
        TunnelPaths(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// TunnelPad 自己的 Application Support 目录（生成的 launchd plist 存这里，不进 ~/Library/LaunchAgents）。
    public var supportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/TunnelPad", isDirectory: true)
    }

    public var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public var launchdDirectory: URL {
        supportDirectory.appendingPathComponent("launchd", isDirectory: true)
    }

    public var migrationBackupDirectory: URL {
        supportDirectory.appendingPathComponent("migration-backup", isDirectory: true)
    }

    /// 日志放 `~/Library/Logs/TunnelPad`，避开 TCC 限制路径。
    public var logsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Logs/TunnelPad", isDirectory: true)
    }

    public var launchAgentsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public func launchdPlistURL(for tunnel: TunnelConfig) -> URL {
        launchdDirectory.appendingPathComponent("\(tunnel.launchdLabel).plist")
    }

    public func logURL(for tunnel: TunnelConfig) -> URL {
        logsDirectory.appendingPathComponent("\(tunnel.id).log")
    }

    /// App 事件日志（启动恢复等 App 侧事件）；隧道进程输出仍走各自的 `logURL(for:)`。
    public var appEventLogURL: URL {
        logsDirectory.appendingPathComponent("app.log")
    }
}
