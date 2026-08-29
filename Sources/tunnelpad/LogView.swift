import AppKit
import SwiftUI
import TunnelPadCore

/// 内嵌日志面板：显示隧道日志文件末 500 行。
/// 滚动交互与 ModelPad 同款：LazyVStack 按行渲染 + 显式「自动滚动」开关（默认开），
/// 开=刷新后自动滚到最新一行；关=自由回看历史，刷新不改变滚动位置。
/// 刷新是静默的：行内容与行数均无变化时不写状态、不重绘。
struct LogView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager

    @State private var lines: [String] = []
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
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if fileMissing {
                            Text("日志文件尚未生成（隧道启动后写入）")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: lines) { _, newLines in
                    guard autoScroll, !newLines.isEmpty else { return }
                    proxy.scrollTo(newLines.count - 1, anchor: .bottom)
                }
                .onAppear {
                    guard !lines.isEmpty else { return }
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
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
            load()
        }
    }

    /// 静默读取日志尾部：行数与内容均未变化时不写 @State，避免每个刷新周期都触发重绘。
    private func load() {
        let url = manager.paths.logURL(for: tunnel)
        if let tail = LogTail.lastLines(of: url, maxLines: 500) {
            let newLines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard newLines != lines || fileMissing else { return }
            lines = newLines
            fileMissing = false
        } else {
            guard !lines.isEmpty || !fileMissing else { return }
            lines = []
            fileMissing = true
        }
    }
}
