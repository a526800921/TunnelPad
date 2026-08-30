import AppKit
import TunnelPadCore

/// 菜单栏图标控制器：打开菜单时按当前隧道与状态重绘全部菜单项
///（状态点 + 名称，点击切换启停），并提供主面板与退出入口。
@MainActor
final class MenuBarController: NSObject {

    /// 供 AppKit 持久化此状态项可见性与位置的稳定标识。
    // 菜单栏服务按 bundle ID 缓存状态项宿主记录，损坏后无法清除（killall
    // ControlCenter、LaunchServices 重注册、重启 Mac、autosave 换版本均无效，
    // 而任意新 bundle ID 图标立即可见），app 因此于 2026-08-30 迁移到
    // com.jafish.tunnelpad.app（见 docs/plans/tunnelpad-v1.md 打包约定）。
    // 新 ID 下本 autosave 是全新记录，保持稳定即可，无需再版本化。
    private static let statusItemAutosaveName = "com.jafish.tunnelpad.menu-bar"

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
        statusItem?.autosaveName = Self.statusItemAutosaveName
        guard let button = statusItem?.button else { return }
        let image = Self.makeMenuBarIcon(size: 22)
        button.image = image
        button.imagePosition = .imageOnly
        // `squareLength` 是 AppKit 的负值哨兵（当前 macOS 为 -2），不能写入 button.frame。
        // 让 NSStatusItem 按菜单栏高度自行布局按钮，避免得到负坐标的 2x2 frame。
        statusItem?.isVisible = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - 菜单构建

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

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
            item.isEnabled = !manager.busyIDs.contains(tunnel.id)
            menu.addItem(item)
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
            Task { await manager.stopAsync(id) }
        case .notLoaded, nil:
            Task { await manager.startAsync(id) }
        }
    }

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

    private static func makeMenuBarIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = true
        image.accessibilityDescription = "TunnelPad"
        image.lockFocus()

        let inset: CGFloat = 1
        let borderRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.2
        NSColor.black.setStroke()
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let text = "T" as NSString
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size - textSize.width) / 2,
            y: (size - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
        // 菜单打开不能等待 launchctl；先展示最近缓存，再在后台刷新一次。
        Task { [weak self, weak menu] in
            guard let self else { return }
            await manager.refreshAsync()
            if let menu { rebuildMenu(menu) }
        }
    }
}
