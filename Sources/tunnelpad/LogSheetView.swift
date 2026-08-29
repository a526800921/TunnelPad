import SwiftUI
import TunnelPadCore

/// 日志查看 sheet：显示隧道日志文件末 500 行，支持 2s 自动刷新与复制全部。
struct LogSheetView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var fileMissing = false
    @State private var autoRefresh = true

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("日志：\(tunnel.name)")
                    .font(.headline)
                Text(tunnel.executor == .launchd ? "launchd" : "app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("自动刷新", isOn: $autoRefresh)
                    .toggleStyle(.checkbox)
                Button("刷新") { load() }
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if fileMissing {
                Text("日志文件尚未生成（隧道启动后写入 \(manager.paths.logURL(for: tunnel).path)）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-bottom")
                }
                .onChange(of: text) { _, _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            Text(manager.paths.logURL(for: tunnel).path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear(perform: load)
        .onReceive(timer) { _ in
            if autoRefresh { load() }
        }
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
