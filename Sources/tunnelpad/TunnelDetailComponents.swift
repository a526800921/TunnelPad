import SwiftUI
import TunnelPadCore

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
                Text(TunnelDisplay.subtitle(for: tunnel))
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
                Button { Task { await manager.startAsync(tunnel.id) } } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(!TunnelDisplay.canStart(status, busy: busy))
                Button { Task { await manager.stopAsync(tunnel.id) } } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!TunnelDisplay.canStop(status, busy: busy))
                Button { Task { await manager.restartAsync(tunnel.id) } } label: {
                    Label("重启", systemImage: "arrow.clockwise")
                }
                .disabled(!TunnelDisplay.canRestart(status, busy: busy))
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
    static func subtitle(for tunnel: TunnelConfig) -> String {
        let remark = tunnel.remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return remark.isEmpty ? tunnel.launchdLabel : remark
    }

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
        Text(kind.rawValue)
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
