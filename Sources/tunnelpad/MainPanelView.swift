import AppKit
import SwiftUI
import TunnelPadCore

/// 主面板：左侧固定隧道列表，右侧详情（操作 + 内嵌日志），详情标题栏右上角是设置入口。
/// 不用 NavigationSplitView：它自带的侧栏折叠控件与"固定侧栏"的产品约定相悖，
/// 改用 HSplitView 保留拖拽调宽。
struct MainPanelView: View {
    @EnvironmentObject private var manager: TunnelManager
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var selectedID: String?
    @State private var settingsTunnel: TunnelConfig?
    @State private var showNewTunnel = false
    @State private var deleteCandidate: TunnelConfig?
    @State private var legacyAgents: [LegacyAgent] = []

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            detailPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            appDelegate.markMainWindowVisible()
        }
        .task {
            await manager.refreshAsync()
            rescanLegacyAgents()
            if selectedID == nil {
                selectedID = manager.config.tunnels.first?.id
            }
        }
        // 用与视图生命周期绑定的可取消任务刷新，避免 onReceive 在状态发布后
        // 重建 Timer 订阅，导致 refresh -> @Published -> 重建订阅的反馈环。
        .task(id: appDelegate.isMainWindowVisible) {
            guard appDelegate.isMainWindowVisible else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard appDelegate.isMainWindowVisible else { return }
                await manager.refreshAsync()
            }
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
                showNewTunnel = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!manager.busyIDs.isEmpty)
            .help("新增隧道")
            Button {
                Task {
                    await manager.reloadConfigAsync()
                    rescanLegacyAgents()
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("重新加载 config.json")
            Spacer()
            Button {
                deleteCandidate = selectedTunnel
            } label: {
                Image(systemName: "trash")
            }
            .tint(.red)
            .disabled(selectedTunnel == nil || manager.busyIDs.contains(selectedID ?? ""))
            .help("删除选中隧道")
            .confirmationDialog(
                deleteCandidate.map { "删除「\($0.name)」？" } ?? "删除隧道？",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { isPresented in
                        if !isPresented { deleteCandidate = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let candidate = deleteCandidate {
                    Button("删除隧道与日志（不可恢复）", role: .destructive) {
                        let id = candidate.id
                        deleteCandidate = nil
                        Task { await manager.removeTunnelAsync(id) }
                    }
                }
                Button("取消", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: {
                Text("将停止实例并删除其配置条目、生成的 plist 与日志文件。")
            }
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
        .sheet(isPresented: $showNewTunnel) {
            NewTunnelSheet()
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
                .disabled(manager.busyIDs.contains(selectedTunnel?.id ?? ""))
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
