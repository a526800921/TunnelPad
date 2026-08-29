import AppKit
import SwiftUI
import TunnelPadCore

/// 主面板：左侧固定隧道列表，右侧详情（操作 + 内嵌日志），详情标题栏右上角是设置入口。
/// 不用 NavigationSplitView：它自带的侧栏折叠控件与"固定侧栏"的产品约定相悖，改用 HSplitView 保留拖拽调宽。
struct MainPanelView: View {
    @EnvironmentObject private var manager: TunnelManager
    @State private var selectedID: String?
    @State private var settingsTunnel: TunnelConfig?
    @State private var legacyAgents: [LegacyAgent] = []

    /// 周期刷新状态与探针，避免启动瞬间的过期红标一直挂着。
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            detailPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            manager.refresh()
            rescanLegacyAgents()
            if selectedID == nil {
                selectedID = manager.config.tunnels.first?.id
            }
        }
        .onReceive(refreshTimer) { _ in
            manager.refresh()
        }
        .onChange(of: manager.config.tunnels) { _, tunnels in
            if !tunnels.contains(where: { $0.id == selectedID }) {
                selectedID = tunnels.first?.id
            }
        }
    }

    private var selectedTunnel: TunnelConfig? {
        manager.config.tunnels.first { $0.id == selectedID }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                if !legacyAgents.isEmpty {
                    migrationSection
                }
                Section("SSH 隧道") {
                    ForEach(manager.config.tunnels) { tunnel in
                        TunnelSidebarRow(tunnel: tunnel)
                            .tag(tunnel.id)
                    }
                    if manager.config.tunnels.isEmpty {
                        Text("暂无隧道配置")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            sidebarFooter
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var migrationSection: some View {
        Section("旧版隧道待接管") {
            ForEach(legacyAgents, id: \.label) { agent in
                HStack(spacing: 6) {
                    Text(agent.label)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(agent.programArguments.joined(separator: " "))
                    Spacer()
                    Button("接管") {
                        Task {
                            await manager.takeOver(agent)
                            rescanLegacyAgents()
                        }
                    }
                    .controlSize(.small)
                    .disabled(manager.busyIDs.contains(agent.label))
                }
            }
            Text("接管 = 备份旧 plist（移动到 migration-backup）→ 卸载旧 agent → 以 com.jafish.tunnelpad.<id> 重新加载；任一步失败自动回滚。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                manager.refresh()
                rescanLegacyAgents()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新状态")
            Button {
                manager.reloadConfig()
                rescanLegacyAgents()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("重新加载 config.json")
            Spacer()
        }
    }

    // MARK: - 详情区

    private var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            if let tunnel = selectedTunnel {
                TunnelDetailView(tunnel: tunnel)
            } else {
                emptyDetail
            }
            Divider()
            messageBar
        }
        .sheet(item: $settingsTunnel) { tunnel in
            TunnelSettingsSheet(tunnel: tunnel)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            if let tunnel = selectedTunnel {
                Text(tunnel.name)
                    .font(.title2.bold())
                TunnelDisplay.executorBadge(tunnel.executor)
                if tunnel.probe != nil {
                    TunnelDisplay.probeBadge(manager.probeResults[tunnel.id])
                }
            } else {
                Text("TunnelPad")
                    .font(.title2.bold())
                Text("SSH 隧道管理")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedTunnel != nil {
                Button {
                    settingsTunnel = selectedTunnel
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 26)
                }
                .buttonStyle(.bordered)
                .help("隧道设置")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyDetail: some View {
        VStack(spacing: 6) {
            Text(manager.config.tunnels.isEmpty ? "暂无隧道配置" : "未选择隧道")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("配置文件：\(manager.paths.configURL.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 消息栏只承载错误；信息类文案（已保存/已启动等）已按界面优化计划移除，操作结果以状态点与列表变化呈现。
    @ViewBuilder
    private var messageBar: some View {
        if let error = manager.lastError {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    private func rescanLegacyAgents() {
        legacyAgents = manager.legacyAgentsNeedingMigration()
    }
}

// MARK: - 侧栏行

struct TunnelSidebarRow: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TunnelDisplay.dotColor(
                    manager.statuses[tunnel.id],
                    busy: manager.busyIDs.contains(tunnel.id)
                ))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(tunnel.name)
                        .fontWeight(.semibold)
                    TunnelDisplay.executorBadge(tunnel.executor)
                }
                Text(tunnel.launchdLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 详情区

struct TunnelDetailView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager
    @State private var confirmDelete = false

    private var status: TunnelStatus? { manager.statuses[tunnel.id] }
    private var busy: Bool { manager.busyIDs.contains(tunnel.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("操作")
                .font(.headline)
            HStack(spacing: 12) {
                statusCapsule
                if case .running(let pid)? = status, let pid {
                    Text("PID: \(pid)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { manager.start(tunnel.id) } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(!TunnelDisplay.canStart(status, busy: busy))
                Button { manager.stop(tunnel.id) } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!TunnelDisplay.canStop(status, busy: busy))
                Button { manager.restart(tunnel.id) } label: {
                    Label("重启", systemImage: "arrow.clockwise")
                }
                .disabled(!TunnelDisplay.canRestart(status, busy: busy))
                Button { confirmDelete = true } label: {
                    Label("删除…", systemImage: "trash")
                }
                .tint(.red)
                .disabled(busy)
                .confirmationDialog(
                    "删除「\(tunnel.name)」？",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("删除隧道与日志（不可恢复）", role: .destructive) {
                        manager.removeTunnel(tunnel.id)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将停止实例并删除其配置条目、生成的 plist 与日志文件。")
                }
            }
            Divider()
            LogView(tunnel: tunnel)
                .id(tunnel.id)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusCapsule: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(TunnelDisplay.dotColor(status, busy: busy))
                .frame(width: 8, height: 8)
            Text(TunnelDisplay.shortStatus(status, busy: busy))
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(TunnelDisplay.dotColor(status, busy: busy).opacity(0.12)))
    }
}

// MARK: - 共享展示片段

/// 状态点、状态文案、徽章等供侧栏与详情复用的展示逻辑。
enum TunnelDisplay {
    static func dotColor(_ status: TunnelStatus?, busy: Bool) -> Color {
        if busy { return .orange }
        switch status {
        case .running: return .green
        case .notRunning, .other: return .yellow
        case .notLoaded, nil: return .gray
        }
    }

    /// 完整状态文案（含 pid），侧栏提示与旧版行文案保持一致。
    static func statusText(_ status: TunnelStatus?, busy: Bool) -> String {
        if busy { return "处理中…" }
        switch status {
        case .running(let pid):
            return pid.map { "运行中（pid \($0)）" } ?? "运行中"
        case .notRunning: return "已加载未运行"
        case .other(let state): return "状态：\(state)"
        case .notLoaded, nil: return "已停止"
        }
    }

    /// 详情区的短状态；pid 在旁边单独展示。
    static func shortStatus(_ status: TunnelStatus?, busy: Bool) -> String {
        if busy { return "处理中…" }
        switch status {
        case .running: return "运行中"
        case .notRunning: return "已加载未运行"
        case .other(let state): return "状态：\(state)"
        case .notLoaded, nil: return "已停止"
        }
    }

    static func canStart(_ status: TunnelStatus?, busy: Bool) -> Bool {
        !busy && !(status?.isRunning ?? false)
    }

    static func canStop(_ status: TunnelStatus?, busy: Bool) -> Bool {
        !busy && (status?.isLoaded == true || status?.isRunning == true)
    }

    static func canRestart(_ status: TunnelStatus?, busy: Bool) -> Bool {
        canStop(status, busy: busy)
    }

    static func executorBadge(_ kind: ExecutorKind) -> some View {
        Text(kind == .launchd ? "launchd" : "app")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    @ViewBuilder
    static func probeBadge(_ result: ProbeResult?) -> some View {
        switch result {
        case .satisfied(let status):
            probeText("探针 \(status) ✓", color: .green)
        case .unexpected(let status):
            probeText("探针 \(status) !", color: .orange)
        case .failed:
            probeText("探针失败", color: .red)
        case nil:
            probeText("探针 …", color: .gray)
        }
    }

    private static func probeText(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }
}

extension TunnelStatus {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isLoaded: Bool {
        switch self {
        case .notLoaded: return false
        default: return true
        }
    }
}
