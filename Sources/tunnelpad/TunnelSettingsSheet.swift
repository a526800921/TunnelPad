import SwiftUI
import TunnelPadCore

/// 隧道设置弹窗：编辑当前选中隧道的配置（名称/执行器/命令/keepAlive/探针），保存写回 config.json。
struct TunnelSettingsSheet: View {
    /// 打开弹窗时的配置快照；id 不可改，只作保存定位。
    let tunnel: TunnelConfig

    @EnvironmentObject private var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var commandText: String
    @State private var executor: ExecutorKind
    @State private var keepAlive: Bool
    @State private var throttleInterval: Int
    @State private var probeEnabled: Bool
    @State private var probeURL: String
    @State private var probeStatuses: String
    @State private var errorMessage: String?

    init(tunnel: TunnelConfig) {
        self.tunnel = tunnel
        _name = State(initialValue: tunnel.name)
        _commandText = State(initialValue: tunnel.command.joined(separator: "\n"))
        _executor = State(initialValue: tunnel.executor)
        _keepAlive = State(initialValue: tunnel.keepAlive)
        _throttleInterval = State(initialValue: tunnel.throttleInterval)
        _probeEnabled = State(initialValue: tunnel.probe != nil)
        _probeURL = State(initialValue: tunnel.probe?.url ?? "")
        _probeStatuses = State(
            initialValue: tunnel.probe.map { probe in
                probe.expectedStatuses.map(String.init).joined(separator: ", ")
            } ?? "200"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicSection
                    executionSection
                    probeSection
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                    Text("id 不可修改：\(tunnel.id)（launchd 标签与日志文件名都由它派生）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("配置文件：\(manager.paths.configURL.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 620)
    }

    // MARK: - 区块

    private var header: some View {
        HStack {
            Text("隧道设置")
                .font(.headline)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("基本信息")
            fieldLabel("名称")
            TextField("隧道名称", text: $name)
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("执行")
            fieldLabel("执行器")
            Picker("", selection: $executor) {
                Text("launchd").tag(ExecutorKind.launchd)
                Text("app").tag(ExecutorKind.app)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            fieldLabel("命令（每行一个参数，首行为可执行文件路径）")
            TextEditor(text: $commandText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
            if SSHCommand.isSSH(parsedCommand) {
                Toggle("SSH 详细日志（追加 -v 参数）", isOn: sshVerbose)
            }

            Toggle("断线自动重连（keepAlive）", isOn: $keepAlive)
            HStack(spacing: 8) {
                fieldLabel("重启间隔")
                TextField("10", value: $throttleInterval, format: .number.grouping(.never))
                    .frame(width: 64)
                Text("秒（意外退出后再次拉起的最小间隔）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("状态探针")
            Toggle("启用探针（隧道本机侧 HTTP 检查，绕过系统代理）", isOn: $probeEnabled)
            if probeEnabled {
                fieldLabel("URL")
                TextField("http://127.0.0.1:8080/health", text: $probeURL)
                HStack(spacing: 8) {
                    fieldLabel("期望状态码")
                    TextField("200 或 200,301", text: $probeStatuses)
                        .frame(width: 140)
                }
            }
        }
    }

    // MARK: - 保存

    /// 命令文本解析出的参数数组，与 buildConfig 的解析规则一致。
    private var parsedCommand: [String] {
        commandText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 「SSH 详细日志」开关：状态取自命令里的独立 -v，切换即改写命令文本。
    private var sshVerbose: Binding<Bool> {
        Binding(
            get: { SSHCommand.hasVerboseFlag(parsedCommand) },
            set: { enabled in
                let updated = enabled
                    ? SSHCommand.addingVerboseFlag(parsedCommand)
                    : SSHCommand.removingVerboseFlag(parsedCommand)
                commandText = updated.joined(separator: "\n")
            }
        )
    }

    private func save() {
        guard let updated = buildConfig() else { return }
        manager.updateTunnel(updated)
        dismiss()
    }

    /// 校验并组装新配置；失败时写 errorMessage 并返回 nil。
    private func buildConfig() -> TunnelConfig? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "名称不能为空"
            return nil
        }

        let args = parsedCommand
        guard let first = args.first, !first.isEmpty else {
            errorMessage = "命令至少需要一行可执行文件路径"
            return nil
        }

        guard throttleInterval >= 1 else {
            errorMessage = "重启间隔至少为 1 秒"
            return nil
        }

        var probe: ProbeConfig?
        if probeEnabled {
            let trimmedURL = probeURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else {
                errorMessage = "探针 URL 无效"
                return nil
            }
            let statuses = probeStatuses
                .split(whereSeparator: { ",， ".contains($0) })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { (100...599).contains($0) }
            guard !statuses.isEmpty else {
                errorMessage = "期望状态码无效（示例：200 或 200,301）"
                return nil
            }
            probe = ProbeConfig(url: trimmedURL, expectedStatuses: statuses)
        }

        return TunnelConfig(
            id: tunnel.id,
            name: trimmedName,
            command: args,
            executor: executor,
            keepAlive: keepAlive,
            throttleInterval: throttleInterval,
            probe: probe
        )
    }

    // MARK: - 小部件

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
    }
}
