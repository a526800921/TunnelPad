import AppKit
import SwiftUI
import TunnelPadCore

/// 内嵌日志面板：显示隧道日志文件末 500 行，支持 2s 自动刷新与复制。
struct LogView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager

    @State private var text = ""
    @State private var fileMissing = false
    @State private var autoRefresh = true

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("日志")
                    .font(.headline)
                Spacer()
                Toggle("自动刷新", isOn: $autoRefresh)
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
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(fileMissing ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-bottom")
                }
                .frame(maxHeight: .infinity)
                .onChange(of: text) { _, _ in
                    // 自动刷新时跟随最新内容；手动刷新不打断回看位置。
                    if autoRefresh {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
            Text(manager.paths.logURL(for: tunnel).path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in
            if autoRefresh { load() }
        }
    }

    private var logText: String {
        if fileMissing {
            return "日志文件尚未生成（隧道启动后写入）"
        }
        return text.isEmpty ? " " : text
    }

    private func load() {
        let url = manager.paths.logURL(for: tunnel)
        if let tail = LogTail.lastLines(of: url, maxLines: 500) {
            text = tail
            fileMissing = false
        } else {
            text = ""
            fileMissing = true
        }
    }
}
