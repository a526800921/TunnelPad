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

    /// app 执行器子进程的 pidfile 目录（信号退出路径据此终止残留子进程）。
    public var runDirectory: URL {
        supportDirectory.appendingPathComponent("run", isDirectory: true)
    }

    public func pidfileURL(for tunnel: TunnelConfig) -> URL {
        runDirectory.appendingPathComponent("\(tunnel.id).pid")
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
}
