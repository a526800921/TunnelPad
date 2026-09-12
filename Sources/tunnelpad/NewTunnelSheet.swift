import SwiftUI
import TunnelPadCore

/// 新建隧道弹窗：与隧道设置弹窗同构的空白表单（无预填模板）。
/// 保存时由显示名自动生成 id（弹窗内实时预览），只写配置不自动启动。
struct NewTunnelSheet: View {
    @EnvironmentObject private var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var form = TunnelFormState()
    @State private var errorMessage: String?

    /// 名称非空时实时预览将要生成的 id。
    private var previewID: String? {
        let trimmed = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
            TextField("隧道名称", text: $form.name)
            Text("备注说明")
                .font(.callout)
            TextField("用于说明隧道用途", text: $form.remark)
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
            Text("launchd（当前阶段唯一支持的执行器）")
                .foregroundStyle(.secondary)

            Text("命令（每行一个参数，首行为可执行文件路径）")
                .font(.callout)
            TextEditor(text: $form.commandText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )

            Toggle("断线自动重连（keepAlive）", isOn: $form.keepAlive)
            Toggle("随 App 启动自动拉起（登录自启场景使用）", isOn: $form.autoStart)
            HStack(spacing: 8) {
                Text("重启间隔")
                    .font(.callout)
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
            Text("状态探针")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("启用探针（隧道本机侧 HTTP 检查，绕过系统代理）", isOn: $form.probeEnabled)
            if form.probeEnabled {
                Text("URL")
                    .font(.callout)
                TextField("http://127.0.0.1:8080/health", text: $form.probeURL)
                HStack(spacing: 8) {
                    Text("期望状态码")
                        .font(.callout)
                    TextField("200 或 200,301", text: $form.probeStatuses)
                        .frame(width: 140)
                }
            }
        }
    }

    // MARK: - 保存

    private func save() {
        do {
            let id = TunnelID.generate(from: form.name.trimmingCharacters(in: .whitespacesAndNewlines), existing: Set(manager.config.tunnels.map(\.id)))
            // 不能用全局 lastError 判断成败：它由多种操作写入且从不清除，历史错误会阻止弹窗关闭。
            if manager.addTunnel(try form.makeTunnel(id: id)) {
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
}
