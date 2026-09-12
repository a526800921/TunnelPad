import SwiftUI
import TunnelPadCore

/// 隧道设置弹窗：编辑当前选中隧道的配置（名称/执行器/命令/keepAlive/探针），保存写回 config.json。
struct TunnelSettingsSheet: View {
    /// 打开弹窗时的配置快照；id 不可改，只作保存定位。
    let tunnel: TunnelConfig

    @EnvironmentObject private var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var form: TunnelFormState
    @State private var errorMessage: String?

    init(tunnel: TunnelConfig) {
        self.tunnel = tunnel
        _form = State(initialValue: TunnelFormState(tunnel: tunnel))
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
            Button("保存") { Task { await save() } }
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
            TextField("隧道名称", text: $form.name)
            fieldLabel("备注说明")
            TextField("用于说明隧道用途", text: $form.remark)
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("执行")
            fieldLabel("执行器")
            Text("launchd（当前阶段唯一支持的执行器）")
                .foregroundStyle(.secondary)

            fieldLabel("命令（每行一个参数，首行为可执行文件路径）")
            TextEditor(text: $form.commandText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
            if SSHCommand.isSSH(form.parsedCommand) {
                Toggle("SSH 详细日志（追加 -v 参数）", isOn: sshVerbose)
            }

            Toggle("断线自动重连（keepAlive）", isOn: $form.keepAlive)
            Toggle("随 App 启动自动拉起（登录自启场景使用）", isOn: $form.autoStart)
            HStack(spacing: 8) {
                fieldLabel("重启间隔")
                TextField("10", value: $form.throttleInterval, format: .number.grouping(.never))
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
            Toggle("启用探针（隧道本机侧 HTTP 检查，绕过系统代理）", isOn: $form.probeEnabled)
            if form.probeEnabled {
                fieldLabel("URL")
                TextField("http://127.0.0.1:8080/health", text: $form.probeURL)
                HStack(spacing: 8) {
                    fieldLabel("期望状态码")
                    TextField("200 或 200,301", text: $form.probeStatuses)
                        .frame(width: 140)
                }
            }
        }
    }

    // MARK: - 保存

    /// 「SSH 详细日志」开关：状态取自命令里的独立 -v，切换即改写命令文本。
    private var sshVerbose: Binding<Bool> {
        Binding(
            get: { form.hasSSHVerboseFlag },
            set: { enabled in
                form.setSSHVerbose(enabled)
            }
        )
    }

    private func save() async {
        do {
            // 只有确认落盘成功才关闭；每条失败路径都会写入 lastError，可就地展示。
            if await manager.updateTunnelAsync(try form.makeTunnel(id: tunnel.id)) {
                dismiss()
            } else {
                errorMessage = manager.lastError
            }
        } catch let error as TunnelFormValidationError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
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
