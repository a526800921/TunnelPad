import AppKit
import TunnelPadCore

/// 菜单栏图标控制器：打开菜单时按当前隧道与状态重绘全部菜单项
///（状态点 + 名称，点击切换启停），并提供全部启动/停止、主面板与退出。
@MainActor
final class MenuBarController: NSObject {

    private nonisolated(unsafe) var statusItem: NSStatusItem?
    private let manager: TunnelManager
    private let onShowPanel: () -> Void

    private static let dotSize: CGFloat = 8
    private static let greenDot = MenuBarController.makeDot(color: .systemGreen)
    private static let yellowDot = MenuBarController.makeDot(color: .systemYellow)
    private static let orangeDot = MenuBarController.makeDot(color: .systemOrange)
    private static let grayDot = MenuBarController.makeDot(color: .systemGray)

    init(manager: TunnelManager, onShowPanel: @escaping () -> Void) {
        self.manager = manager
        self.onShowPanel = onShowPanel
        super.init()
        setup()
    }

    deinit {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = Self.makeIcon()
        button.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - 菜单构建

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        manager.refresh()

        let tunnels = manager.config.tunnels
        if tunnels.isEmpty {
            let empty = NSMenuItem(title: "暂无隧道配置", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for tunnel in tunnels {
            let status = manager.statuses[tunnel.id]
            let item = NSMenuItem(
                title: tunnel.name,
                action: #selector(toggleTunnel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tunnel.id
            item.image = Self.dotImage(for: status, busy: manager.busyIDs.contains(tunnel.id))
            item.isEnabled = tunnel.executor == .launchd
            menu.addItem(item)
        }

        if !tunnels.isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(self.item(title: "启动全部", action: #selector(startAll)))
            menu.addItem(self.item(title: "停止全部", action: #selector(stopAll)))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(self.item(title: "打开主面板", action: #selector(showPanel)))
        menu.addItem(self.item(title: "退出 TunnelPad", action: #selector(quitApp)))
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 动作

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switch manager.statuses[id] {
        case .running, .notRunning, .other:
            manager.stop(id)
        case .notLoaded, nil:
            manager.start(id)
        }
    }

    @objc private func startAll() { manager.startAll() }
    @objc private func stopAll() { manager.stopAll() }
    @objc private func showPanel() { onShowPanel() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - 图标

    private static func dotImage(for status: TunnelStatus?, busy: Bool) -> NSImage? {
        if busy { return orangeDot }
        switch status {
        case .running: return greenDot
        case .notRunning, .other: return yellowDot
        case .notLoaded, nil: return grayDot
        }
    }

    private static func makeDot(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: dotSize, height: dotSize))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: dotSize, height: dotSize)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func makeIcon() -> NSImage {
        let symbol = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "TunnelPad"
        )
        return symbol ?? makeFallbackIcon()
    }

    private static func makeFallbackIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = true
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2),
                                xRadius: 4, yRadius: 4)
        path.lineWidth = 1.2
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}
