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
    @Published private(set) var isMainWindowVisible = false

    override init() {
        self.manager = TunnelManager(paths: .standard())
        super.init()
    }

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Shutdown.installSignalHandlers()
        menuBarController = MenuBarController(manager: manager) { [weak self] in
            self?.showMainWindow()
        }
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 关闭窗口不退出，隧道管理常驻菜单栏
    }

    /// 正常退出（菜单退出 / Cmd+Q / AppleScript quit）先由 Rust owner 停止全部受管 launchd 隧道，再结束进程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        Task { @MainActor in
            await manager.shutdownAsync()
            sender.reply(toApplicationShouldTerminate: true)
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
        isMainWindowVisible = true
    }
}

// MARK: - NSWindowDelegate（关闭只隐藏）

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        isMainWindowVisible = false
        return false
    }
}
