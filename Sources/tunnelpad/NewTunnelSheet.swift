import SwiftUI
import TunnelPadCore

/// 新建隧道弹窗：与隧道设置弹窗同构的空白表单（无预填模板）。
/// 保存时由显示名自动生成 id（弹窗内实时预览），只写配置不自动启动。
struct NewTunnelSheet: View {
    @EnvironmentObject private var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var commandText = ""
    @State private var executor: ExecutorKind = .launchd
    @State private var keepAlive = true
    @State private var throttleInterval = 10
    @State private var probeEnabled = false
    @State private var probeURL = ""
    @State private var probeStatuses = "200"
    @State private var errorMessage: String?

    /// 名称非空时实时预览将要生成的 id。
    private var previewID: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TunnelID.generate(from: trimmed, existing: Set(manager.config.tunnels.map(\.id)))
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
            Text("新建隧道")
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
            Text("基本信息")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("名称")
                .font(.callout)
            TextField("隧道名称", text: $name)
            if let previewID {
                Text("保存后 id：\(previewID)（由名称自动生成，launchd 标签与日志文件名都由它派生）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("执行")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("执行器")
                .font(.callout)
            Picker("", selection: $executor) {
                Text("launchd").tag(ExecutorKind.launchd)
                Text("app").tag(ExecutorKind.app)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("命令（每行一个参数，首行为可执行文件路径）")
                .font(.callout)
            TextEditor(text: $commandText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )

            Toggle("断线自动重连（keepAlive）", isOn: $keepAlive)
            HStack(spacing: 8) {
                Text("重启间隔")
                    .font(.callout)
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
            Text("状态探针")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("启用探针（隧道本机侧 HTTP 检查，绕过系统代理）", isOn: $probeEnabled)
            if probeEnabled {
                Text("URL")
                    .font(.callout)
                TextField("http://127.0.0.1:8080/health", text: $probeURL)
                HStack(spacing: 8) {
                    Text("期望状态码")
                        .font(.callout)
                    TextField("200 或 200,301", text: $probeStatuses)
                        .frame(width: 140)
                }
            }
        }
    }

    // MARK: - 保存

    private func save() {
        guard let tunnel = buildConfig() else { return }
        manager.addTunnel(tunnel)
        if manager.lastError == nil {
            dismiss()
        }
    }

    /// 校验并组装新配置；失败时写 errorMessage 并返回 nil。校验规则与设置弹窗一致。
    private func buildConfig() -> TunnelConfig? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "名称不能为空"
            return nil
        }

        let args = commandText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

        let id = TunnelID.generate(from: trimmedName, existing: Set(manager.config.tunnels.map(\.id)))
        return TunnelConfig(
            id: id,
            name: trimmedName,
            command: args,
            executor: executor,
            keepAlive: keepAlive,
            throttleInterval: throttleInterval,
            probe: probe
        )
    }
}
