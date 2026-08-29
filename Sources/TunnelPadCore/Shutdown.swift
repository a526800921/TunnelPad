import Foundation

/// 信号退出路径（SIGTERM/SIGINT：logout、shutdown、kill）。
/// 与正常退出同语义：退出 = 停止全部 launchd 隧道。直接读 config.json，
/// 不依赖 UI 层对象，可从任意线程调用。
/// 注意：信号安装与处理必须保持 nonisolated——闭包若继承 @MainActor 隔离，
/// 会在全局队列触发时被 dispatch_assert_queue 断言崩溃。
public enum Shutdown {
    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// 安装 SIGTERM/SIGINT 处理：与正常退出同语义（停全部 launchd 隧道后退出）。
    public static func installSignalHandlers() {
        for signalNumber: Int32 in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global())
            source.setEventHandler { stopAllAndExit() }
            source.resume()
            signalSources.append(source)
        }
    }

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
