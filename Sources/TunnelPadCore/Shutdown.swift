import Foundation

/// 信号退出路径（SIGTERM/SIGINT：logout、shutdown、kill）。
/// 与正常退出同语义：退出 = 停止全部 launchd 隧道。直接读 config.json，
/// 不依赖 UI 层对象，可从任意线程调用。
public enum Shutdown {
    @discardableResult
    public static func stopAllLaunchdTunnels(paths: TunnelPaths = .standard()) -> Int {
        let executor = LaunchCtlExecutor()
        let config = ConfigStore(paths: paths).load().config
        var stopped = 0
        for tunnel in config.tunnels where tunnel.executor == .launchd {
            if (try? executor.bootout(label: tunnel.launchdLabel)) == true {
                stopped += 1
            }
        }
        return stopped
    }

    /// 信号处理入口：停完全部隧道后立即退出进程。
    public static func stopAllAndExit(paths: TunnelPaths = .standard(), code: Int32 = 0) -> Never {
        stopAllLaunchdTunnels(paths: paths)
        exit(code)
    }
}
