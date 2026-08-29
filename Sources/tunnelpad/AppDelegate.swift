import SwiftUI
import AppKit
import TunnelPadCore

/// NSApplicationDelegate：生命周期、菜单栏、主窗口控制与退出语义。
/// 退出 TunnelPad = 停止全部 launchd 隧道（逐条 bootout），这是计划冻结的语义。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    let manager: TunnelManager
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var isTerminating = false
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        self.manager = TunnelManager(paths: .standard())
        super.init()
    }

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        menuBarController = MenuBarController(manager: manager) { [weak self] in
            self?.showMainWindow()
        }
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 关闭窗口不退出，隧道管理常驻菜单栏
    }

    /// 正常退出（菜单退出 / Cmd+Q / AppleScript quit）先逐条 bootout，再结束进程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        let tunnels = manager.config.tunnels
        let executor = manager.executor

        DispatchQueue.global().async {
            for tunnel in tunnels where tunnel.executor == .launchd {
                _ = try? executor.bootout(label: tunnel.launchdLabel)
            }
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - 窗口控制

    func showMainWindow() {
        if mainWindow == nil, let window = NSApp.windows.first(where: { $0.title == "TunnelPad" }) {
            window.delegate = self
            window.isReleasedWhenClosed = false
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSWindowDelegate（关闭只隐藏）

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - 信号处理（SIGTERM/SIGINT 也执行"退出即停"）

extension AppDelegate {

    /// logout / shutdown / kill 等场景与正常退出保持同语义。
    private func installSignalHandlers() {
        for signalNumber: Int32 in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global())
            source.setEventHandler { Shutdown.stopAllAndExit() }
            source.resume()
            signalSources.append(source)
        }
    }
}
