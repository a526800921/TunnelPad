import AppKit
import SwiftUI
import TunnelPadCore

/// 内嵌日志面板：订阅后台日志事件并显示当前隧道的有界快照。
/// 使用 AppKit 原生文本视图渲染日志，避免 macOS SwiftUI ScrollView 在动态尺寸
/// 与自动滚动同时存在时反复触发布局计算。显式「自动滚动」开关默认开启：
/// 开=收到新事件后自动滚到最新内容；关=自由回看历史，新事件不改变滚动位置。
struct LogView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager
    @EnvironmentObject private var appDelegate: AppDelegate

    @State private var text = ""
    @State private var fileStatus: LogFileStatus = .missing
    @State private var version: UInt64 = 0
    @State private var autoScroll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("日志")
                    .font(.headline)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button {
                    Task { _ = await manager.refreshLog(for: tunnel.id) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
            LogTextView(text: logText, autoScroll: autoScroll)
                .frame(minHeight: 160)
            Text(manager.paths.logURL(for: tunnel).path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .task(id: "\(tunnel.id):\(appDelegate.isMainWindowVisible)") {
            guard appDelegate.isMainWindowVisible else { return }
            version = 0
            text = ""
            fileStatus = .missing

            let session = await manager.logSession(for: tunnel.id)
            defer { session.cancel() }
            apply(session.snapshot)

            for await event in session.events {
                guard !Task.isCancelled else { return }
                guard event.tunnelID == tunnel.id, event.version > version else { continue }
                apply(event.snapshot)
            }
        }
    }

    private var logText: String {
        switch fileStatus {
        case .missing:
            return "日志文件尚未生成（隧道启动后写入）"
        case let .error(message):
            return "日志读取失败：\(message)"
        case .available:
            return text.isEmpty ? " " : text
        }
    }

    private func apply(_ snapshot: LogSnapshot) {
        guard snapshot.tunnelID == tunnel.id, snapshot.version >= version else { return }
        version = snapshot.version
        text = snapshot.text
        fileStatus = snapshot.status
    }
}

/// 原生 NSTextView 负责滚动与文本排版，避免 SwiftUI ScrollView 的尺寸反馈环。
private struct LogTextView: NSViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        textView.string = text
        if autoScroll {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}
