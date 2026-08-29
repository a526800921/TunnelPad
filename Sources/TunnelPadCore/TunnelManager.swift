import Foundation
import Combine

/// UI 层的隧道管理器：配置、状态、启停与迁移编排的 @MainActor 门面。
@MainActor
public final class TunnelManager: ObservableObject {
    public let paths: TunnelPaths
    public let executor: LaunchCtlExecutor
    public let appExecutor: AppProcessExecutor
    public let migrationService: MigrationService

    @Published public private(set) var config: AppConfig
    @Published public private(set) var statuses: [String: TunnelStatus] = [:]
    @Published public private(set) var probeResults: [String: ProbeResult] = [:]
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public var lastMessage: String?
    @Published public var lastError: String?

    private let store: ConfigStore
    private let probeService = ProbeService()

    public init(paths: TunnelPaths, executor: LaunchCtlExecutor = LaunchCtlExecutor()) {
        self.paths = paths
        self.executor = executor
        self.appExecutor = AppProcessExecutor(paths: paths)
        self.migrationService = MigrationService(paths: paths, executor: executor)
        self.store = ConfigStore(paths: paths)
        let loaded = store.load()
        self.config = loaded.config
        if let recovered = loaded.recoveredFrom {
            self.lastMessage = "配置文件损坏，已留档 \(recovered.lastPathComponent)，已重建空配置"
        }
    }

    public func tunnel(id: String) -> TunnelConfig? {
        config.tunnels.first { $0.id == id }
    }

    // MARK: - 状态

    public func refresh() {
        for tunnel in config.tunnels {
            switch tunnel.executor {
            case .launchd:
                statuses[tunnel.id] = executor.status(label: tunnel.launchdLabel)
            case .app:
                statuses[tunnel.id] = appExecutor.status(id: tunnel.id)
            }
        }
        runProbes()
    }

    /// 异步执行配置了探针的隧道探测，完成后更新展示。
    private func runProbes() {
        let probes = config.tunnels.compactMap { tunnel -> (String, ProbeConfig)? in
            guard let probe = tunnel.probe else { return nil }
            return (tunnel.id, probe)
        }
        guard !probes.isEmpty else { return }
        let service = probeService
        Task.detached(priority: .utility) { [weak self] in
            for (id, probe) in probes {
                let result = await service.check(probe)
                guard let self else { return }
                await MainActor.run {
                    // 隧道可能已被移除或探针配置已变化，仅按 id 写回
                    if self.config.tunnels.contains(where: { $0.id == id && $0.probe != nil }) {
                        self.probeResults[id] = result
                    }
                }
            }
        }
    }

    // MARK: - 启停

    public func start(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard !busyIDs.contains(id) else { return }

        busyIDs.insert(id)
        defer { busyIDs.remove(id) }

        switch tunnel.executor {
        case .launchd:
            if case .running = executor.status(label: tunnel.launchdLabel) { return }
            do {
                let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
                try executor.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
                lastMessage = "「\(tunnel.name)」已启动"
            } catch {
                lastError = "启动「\(tunnel.name)」失败：\(error)"
            }
        case .app:
            do {
                try appExecutor.start(tunnel)
                lastMessage = "「\(tunnel.name)」已启动（app 执行器）"
            } catch {
                lastError = "启动「\(tunnel.name)」失败：\(error)"
            }
        }
        refresh()
    }

    public func stop(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard !busyIDs.contains(id) else { return }

        busyIDs.insert(id)
        defer { busyIDs.remove(id) }

        switch tunnel.executor {
        case .launchd:
            do {
                try executor.bootout(label: tunnel.launchdLabel)
                lastMessage = "「\(tunnel.name)」已停止"
            } catch {
                lastError = "停止「\(tunnel.name)」失败：\(error)"
            }
        case .app:
            appExecutor.stop(tunnel)
            lastMessage = "「\(tunnel.name)」已停止"
        }
        refresh()
    }

    public func restart(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard !busyIDs.contains(id) else { return }

        busyIDs.insert(id)
        defer { busyIDs.remove(id) }

        switch tunnel.executor {
        case .launchd:
            do {
                _ = try? executor.bootout(label: tunnel.launchdLabel)
                let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
                try executor.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
                lastMessage = "「\(tunnel.name)」已重启"
            } catch {
                lastError = "重启「\(tunnel.name)」失败：\(error)"
            }
        case .app:
            do {
                try appExecutor.restart(tunnel)
                lastMessage = "「\(tunnel.name)」已重启"
            } catch {
                lastError = "重启「\(tunnel.name)」失败：\(error)"
            }
        }
        refresh()
    }

    public func startAll() {
        for tunnel in config.tunnels {
            start(tunnel.id)
        }
    }

    public func stopAll() {
        for tunnel in config.tunnels {
            stop(tunnel.id)
        }
    }

    // MARK: - 迁移

    /// 返回尚未接管的旧手工 agent。
    public func legacyAgentsNeedingMigration() -> [LegacyAgent] {
        let existing = Set(config.tunnels.map(\.id))
        return LegacyImporter.scan(in: paths.launchAgentsDirectory).filter { agent in
            guard let id = LegacyImporter.tunnelID(for: agent.label) else { return false }
            return !existing.contains(id)
        }
    }

    /// 后台执行接管（备份→bootout→bootstrap→验证，失败自动回滚），成功后写入配置。
    public func takeOver(_ agent: LegacyAgent) async {
        busyIDs.insert(agent.label)
        defer { busyIDs.remove(agent.label) }

        let service = migrationService
        let outcome = await Task.detached(priority: .userInitiated) { () -> TakeoverOutcome in
            do {
                return TakeoverOutcome(success: try service.takeover(agent: agent), failureDescription: nil)
            } catch {
                return TakeoverOutcome(success: nil, failureDescription: String(describing: error))
            }
        }.value

        if let success = outcome.success {
            config.tunnels.append(success.tunnel)
            do {
                try store.save(config)
            } catch {
                lastError = "接管成功但保存配置失败：\(error)"
            }
            lastMessage = success.message
        } else {
            lastError = "接管失败：\(outcome.failureDescription ?? "未知错误")"
        }
        refresh()
    }

    private struct TakeoverOutcome: Sendable {
        var success: MigrationOutcome?
        var failureDescription: String?
    }
}
