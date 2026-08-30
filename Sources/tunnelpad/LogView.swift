import AppKit
import SwiftUI
import TunnelPadCore

/// 内嵌日志面板：显示隧道日志文件末 500 行。
/// 使用 AppKit 原生文本视图渲染日志，避免 macOS SwiftUI ScrollView 在动态尺寸
/// 与自动滚动同时存在时反复触发布局计算。显式「自动滚动」开关默认开启：
/// 开=刷新后自动滚到最新内容；关=自由回看历史，刷新不改变滚动位置。
/// 刷新是静默的：内容未变化时不写 @State，避免每个刷新周期都触发重绘。
struct LogView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager

    @State private var text = ""
    @State private var fileMissing = false
    @State private var autoScroll = true

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("日志")
                    .font(.headline)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button {
                    load()
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
        .onAppear(perform: load)
        .onReceive(timer) { _ in
            load()
        }
    }

    private var logText: String {
        if fileMissing {
            return "日志文件尚未生成（隧道启动后写入）"
        }
        return text.isEmpty ? " " : text
    }

    /// 静默读取日志尾部：内容未变化时不写 @State，避免每个刷新周期都触发重绘。
    private func load() {
        let url = manager.paths.logURL(for: tunnel)
        if let tail = LogTail.lastLines(of: url, maxLines: 500) {
            guard tail != text || fileMissing else { return }
            text = tail
            fileMissing = false
        } else {
            guard !text.isEmpty || !fileMissing else { return }
            text = ""
            fileMissing = true
        }
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
