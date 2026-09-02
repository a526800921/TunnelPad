import Foundation
import TunnelPadCore

/// 把 HTTP API 请求收敛到 TunnelManager 的 @MainActor 门面。
/// API transport 不直接持有 Rust Core、launchctl 或日志路径。
final class TunnelManagerAPIBackend: TunnelAPIBackend, @unchecked Sendable {
    private let manager: TunnelManager

    init(manager: TunnelManager) {
        self.manager = manager
    }

    func listTunnels() async -> [TunnelAPISummary] {
        await MainActor.run {
            manager.config.tunnels.map { summary(for: $0) }
        }
    }

    func tunnel(id: String) async -> TunnelAPISummary? {
        await MainActor.run {
            guard let tunnel = manager.tunnel(id: id) else { return nil }
            return summary(for: tunnel)
        }
    }

    func operate(id: String, operation: TunnelAPIOperation) async -> TunnelAPIBackendOperationResult {
        let result: TunnelOperationResult
        switch operation {
        case .start:
            result = await manager.startAsync(id)
        case .stop:
            result = await manager.stopAsync(id)
        case .restart:
            result = await manager.restartAsync(id)
        }

        switch result {
        case .notFound:
            return .notFound
        case .inProgress:
            return .inProgress
        case .failed:
            return .failed
        case .completed:
            guard let tunnel = await self.tunnel(id: id) else { return .notFound }
            return .completed(tunnel)
        }
    }

    func logs(id: String) async -> TunnelAPIBackendLogResult {
        guard await tunnel(id: id) != nil else { return .notFound }
        let snapshot = await manager.refreshLog(for: id)
        return .completed(logSnapshot(snapshot))
    }

    func clearLogs(id: String) async -> TunnelAPIBackendLogResult {
        guard await tunnel(id: id) != nil else { return .notFound }
        let snapshot = await manager.clearLog(for: id)
        if case .error = snapshot.status { return .failed }
        return .completed(logSnapshot(snapshot))
    }

    @MainActor
    private func summary(for tunnel: TunnelConfig) -> TunnelAPISummary {
        let status = manager.statuses[tunnel.id]
        let probeResult = manager.probeResults[tunnel.id]
        return Self.makeSummary(
            tunnel: tunnel,
            status: status,
            probeResult: probeResult,
            busy: manager.busyIDs.contains(tunnel.id)
        )
    }

    private static func makeSummary(
        tunnel: TunnelConfig,
        status: TunnelStatus?,
        probeResult: ProbeResult?,
        busy: Bool
    ) -> TunnelAPISummary {
        let (statusText, pid): (String, Int32?) = {
            switch status {
            case .running(let pid): return ("running", pid)
            case .notRunning: return ("not_running", nil)
            case .notLoaded: return ("not_loaded", nil)
            case .other: return ("other", nil)
            case nil: return ("unknown", nil)
            }
        }()

        let probe: TunnelAPIProbeSummary = {
            guard tunnel.probe != nil else {
                return TunnelAPIProbeSummary(enabled: false, status: "disabled")
            }
            switch probeResult {
            case .satisfied(let code):
                return TunnelAPIProbeSummary(enabled: true, status: "satisfied", httpStatus: code)
            case .unexpected(let code):
                return TunnelAPIProbeSummary(enabled: true, status: "unexpected", httpStatus: code)
            case .failed:
                return TunnelAPIProbeSummary(enabled: true, status: "failed")
            case nil:
                return TunnelAPIProbeSummary(enabled: true, status: "unknown")
            }
        }()

        return TunnelAPISummary(
            id: tunnel.id,
            name: tunnel.name,
            remark: tunnel.remark,
            executor: tunnel.executor.rawValue,
            keepAlive: tunnel.keepAlive,
            throttleInterval: tunnel.throttleInterval,
            status: statusText,
            pid: pid,
            busy: busy,
            probe: probe
        )
    }

    private func logSnapshot(_ snapshot: LogSnapshot) -> TunnelAPILogSnapshot {
        let status: String
        switch snapshot.status {
        case .available: status = "available"
        case .missing: status = "missing"
        case .error: status = "error"
        }
        return TunnelAPILogSnapshot(
            tunnelID: snapshot.tunnelID,
            version: snapshot.version,
            status: status,
            text: snapshot.text
        )
    }
}
