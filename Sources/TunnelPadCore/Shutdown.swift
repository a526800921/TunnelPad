import Foundation
import Darwin

/// 退出清理路径（SIGTERM/SIGINT：logout、shutdown、kill）。
/// 与正常退出同语义：退出 = 停止全部托管隧道（launchd bootout + app 子进程终止）。
/// 直接读 config.json 与 pidfile，不依赖 UI 层对象，可从任意线程调用。
/// 注意：信号安装与处理必须保持 nonisolated——闭包若继承 @MainActor 隔离，
/// 会在全局队列触发时被 dispatch_assert_queue 断言崩溃。
public enum Shutdown {

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// 安装 SIGTERM/SIGINT 处理：与正常退出同语义（停全部托管隧道后退出）。
    public static func installSignalHandlers() {
        for signalNumber: Int32 in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global())
            source.setEventHandler { stopAllAndExit() }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 停止全部托管隧道：launchd 执行器 bootout，app 执行器按 pidfile 终止。
    /// 返回成功停止的条数。
    @discardableResult
    public static func stopAllManagedTunnels(paths: TunnelPaths = .standard()) -> Int {
        let executor = LaunchCtlExecutor()
        let config = ConfigStore(paths: paths).load().config
        var stopped = 0
        for tunnel in config.tunnels {
            switch tunnel.executor {
            case .launchd:
                if (try? executor.bootout(label: tunnel.launchdLabel)) == true {
                    stopped += 1
                }
            case .app:
                if killByPidfile(at: paths.pidfileURL(for: tunnel)) {
                    stopped += 1
                }
            }
        }
        return stopped
    }

    /// 信号处理入口：停完全部隧道后立即退出进程。
    public static func stopAllAndExit(paths: TunnelPaths = .standard(), code: Int32 = 0) -> Never {
        stopAllManagedTunnels(paths: paths)
        exit(code)
    }

    /// 按 pidfile 终止进程（SIGTERM）；进程已不存在时清理 pidfile。
    @discardableResult
    public static func killByPidfile(at url: URL, signalNumber: Int32 = SIGTERM) -> Bool {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: url),
              let pid = Int32(String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            try? fileManager.removeItem(at: url)
            return false
        }
        guard kill(pid, 0) == 0 else {
            try? fileManager.removeItem(at: url)
            return false
        }
        kill(pid, signalNumber)
        try? fileManager.removeItem(at: url)
        return true
    }
}
