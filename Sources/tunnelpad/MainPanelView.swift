import SwiftUI
import TunnelPadCore

/// 主面板：迁移接管区 + 隧道列表（状态点、启动/停止/重启）+ 操作反馈。
struct MainPanelView: View {
    @EnvironmentObject private var manager: TunnelManager
    @State private var legacyAgents: [LegacyAgent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !legacyAgents.isEmpty {
                migrationSection
            }
            tunnelList
            footer
        }
        .padding(16)
        .onAppear {
            manager.refresh()
            rescanLegacyAgents()
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack {
            Text("TunnelPad")
                .font(.title2.bold())
            Text("SSH 隧道管理")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                manager.refresh()
                rescanLegacyAgents()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新状态")
        }
    }

    private var migrationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("检测到旧版 launchd 隧道，可导入并接管", systemImage: "arrow.triangle.merge")
                    .font(.headline)
                ForEach(legacyAgents, id: \.label) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.label)
                                .font(.callout.monospaced())
                            Text(agent.programArguments.joined(separator: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Button("导入并接管") {
                            Task {
                                await manager.takeOver(agent)
                                rescanLegacyAgents()
                            }
                        }
                        .disabled(manager.busyIDs.contains(agent.label))
                    }
                }
                Text("接管 = 备份旧 plist（移动到 migration-backup）→ 卸载旧 agent → 以 com.jafish.tunnelpad.<id> 重新加载；任一步失败自动回滚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var tunnelList: some View {
        if manager.config.tunnels.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂无隧道配置")
                        .font(.headline)
                    Text("启动时会自动扫描 ~/Library/LaunchAgents 下的旧隧道供接管；也可以手写 config.json 添加隧道。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        } else {
            GroupBox {
                VStack(spacing: 8) {
                    ForEach(manager.config.tunnels) { tunnel in
                        TunnelRowView(tunnel: tunnel)
                    }
                }
                .padding(4)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            } else if let message = manager.lastMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
            }
            Spacer()
            Button("全部启动") { manager.startAll() }
            Button("全部停止") { manager.stopAll() }
        }
    }

    private func rescanLegacyAgents() {
        legacyAgents = manager.legacyAgentsNeedingMigration()
    }
}

// MARK: - 单行

struct TunnelRowView: View {
    let tunnel: TunnelConfig
    @EnvironmentObject private var manager: TunnelManager
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.name).font(.body.bold())
                    Text(tunnel.executor == .launchd ? "launchd" : "app")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    if tunnel.probe != nil {
                        probeBadge
                    }
                }
                Text(tunnel.launchdLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("启动") { manager.start(tunnel.id) }
                    .disabled(!canStart)
                Button("停止") { manager.stop(tunnel.id) }
                    .disabled(!canStop)
                Button("重启") { manager.restart(tunnel.id) }
                    .disabled(!canRestart)
                Button("日志") { showLog = true }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showLog) {
            LogSheetView(tunnel: tunnel)
        }
    }

    @ViewBuilder
    private var probeBadge: some View {
        switch manager.probeResults[tunnel.id] {
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

    private func probeText(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }

    private var status: TunnelStatus? { manager.statuses[tunnel.id] }
    private var busy: Bool { manager.busyIDs.contains(tunnel.id) }

    private var canStart: Bool {
        !busy && !(status?.isRunning ?? false)
    }
    private var canStop: Bool {
        !busy && (status?.isLoaded == true || status?.isRunning == true)
    }
    private var canRestart: Bool { canStop }

    private var dotColor: Color {
        if busy { return .orange }
        switch status {
        case .running: return .green
        case .notRunning, .other: return .yellow
        case .notLoaded, nil: return .gray
        }
    }

    private var statusText: String {
        if busy { return "处理中…" }
        switch status {
        case .running(let pid):
            return pid.map { "运行中（pid \($0)）" } ?? "运行中"
        case .notRunning: return "已加载未运行"
        case .other(let state): return "状态：\(state)"
        case .notLoaded, nil: return "已停止"
        }
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
