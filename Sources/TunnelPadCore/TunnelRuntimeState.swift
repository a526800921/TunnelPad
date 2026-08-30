import Foundation

/// TunnelManager 对外发布的运行时状态的内部聚合。
///
/// UI 仍然读取 TunnelManager 上的三个兼容属性；聚合结构只负责让状态更新
/// 经过单一边界，避免启停、刷新和探针任务分别修改散落的字典/集合。
struct TunnelRuntimeState: Sendable, Equatable {
    var statuses: [String: TunnelStatus] = [:]
    var probeResults: [String: ProbeResult] = [:]
    var busyIDs: Set<String> = []

    mutating func prune(to validIDs: Set<String>) {
        statuses = statuses.filter { validIDs.contains($0.key) }
        probeResults = probeResults.filter { validIDs.contains($0.key) }
    }

    mutating func setStatus(_ status: TunnelStatus?, for id: String) {
        statuses[id] = status
    }

    mutating func setProbeResult(_ result: ProbeResult?, for id: String) {
        probeResults[id] = result
    }

    mutating func setStatuses(_ next: [String: TunnelStatus]) {
        statuses = next
    }

    mutating func setBusy(_ busy: Bool, for id: String) {
        if busy {
            busyIDs.insert(id)
        } else {
            busyIDs.remove(id)
        }
    }
}
