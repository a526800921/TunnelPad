import Foundation
import Darwin

/// 退出清理路径（SIGTERM/SIGINT：logout、shutdown、kill）。
/// 与正常退出同语义：退出 = 停止全部托管 launchd 隧道。
/// 直接通过 Rust owner 句柄执行，不依赖 UI 层对象，可从任意线程调用。
/// 注意：信号安装与处理必须保持 nonisolated——闭包若继承 @MainActor 隔离，
/// 会在全局队列触发时被 dispatch_assert_queue 断言崩溃。
public enum Shutdown {

    /// 由唯一 Rust owner 提供的同步退出句柄。它是 Sendable 的，因为信号
    /// dispatch source 不在 MainActor 上执行；句柄本身不创建第二个 owner。
    public final class OwnerHandle: @unchecked Sendable {
        private let action: @Sendable () -> Int

        public init(action: @escaping @Sendable () -> Int) {
            self.action = action
        }

        @discardableResult
        public func stopAllManagedTunnels() -> Int {
            action()
        }
    }

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// 安装 SIGTERM/SIGINT 处理：与正常退出同语义（停全部托管隧道后退出）。
    public static func installSignalHandlers(owner: OwnerHandle? = nil) {
        let owner = owner ?? OwnerHandle { stopAllManagedTunnels() }
        for signalNumber: Int32 in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global())
            source.setEventHandler { stopAllAndExit(owner: owner) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 通过一个临时 Rust owner 停止全部托管 launchd 隧道。应用正常运行时
    /// 应传入 TunnelManager 持有的 OwnerHandle，避免同一进程创建第二个 owner。
    @discardableResult
    public static func stopAllManagedTunnels(paths: TunnelPaths = .standard()) -> Int {
        guard let owner = try? RustCoreClient(paths: paths) else { return 0 }
        return (try? owner.shutdown()) ?? 0
    }

    /// 信号处理入口：停完全部隧道后立即退出进程。
    public static func stopAllAndExit(
        paths: TunnelPaths = .standard(),
        code: Int32 = 0,
        owner: OwnerHandle? = nil
    ) -> Never {
        if let owner {
            owner.stopAllManagedTunnels()
        } else {
            stopAllManagedTunnels(paths: paths)
        }
        exit(code)
    }

}
