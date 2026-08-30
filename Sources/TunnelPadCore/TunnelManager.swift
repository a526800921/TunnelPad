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

    /// 手动编辑 config.json 后重新加载；丢弃已移除隧道的状态与探针缓存。
    public func reloadConfig() {
        let loaded = store.load()
        config = loaded.config
        let validIDs = Set(config.tunnels.map(\.id))
        statuses = statuses.filter { validIDs.contains($0.key) }
        probeResults = probeResults.filter { validIDs.contains($0.key) }
        if let recovered = loaded.recoveredFrom {
            lastMessage = "配置文件损坏，已留档 \(recovered.lastPathComponent)，已重建空配置"
        } else {
            lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
        }
        refresh()
    }

    /// 保存对单条隧道的修改并持久化；切换执行器时先停掉旧执行器下的实例。
    /// 运行中的隧道继续沿用旧参数，直到下次重启。
    public func updateTunnel(_ tunnel: TunnelConfig) {
        guard let index = config.tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let old = config.tunnels[index]
        config.tunnels[index] = tunnel

        if old.executor != tunnel.executor {
            switch old.executor {
            case .launchd:
                _ = try? executor.bootout(label: old.launchdLabel)
            case .app:
                appExecutor.stop(old)
            }
        }
        if tunnel.probe == nil {
            probeResults[tunnel.id] = nil
        }

        do {
            try store.save(config)
            lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
        } catch {
            lastError = "保存配置失败：\(error)"
        }
        refresh()
    }

    /// 删除单条隧道：停止实例 → 清理生成的 plist/pidfile → 删除日志 → 从配置移除并落盘。
    /// 实例停止与配置写入失败即中断并保留配置；日志清理失败仅告警不中断。操作不可恢复。
    public func removeTunnel(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard !busyIDs.contains(id) else { return }

        busyIDs.insert(id)
        defer { busyIDs.remove(id) }

        switch tunnel.executor {
        case .launchd:
            if executor.status(label: tunnel.launchdLabel) != .notLoaded {
                do {
                    try executor.bootout(label: tunnel.launchdLabel)
                } catch {
                    lastError = "删除「\(tunnel.name)」失败：停止实例出错 \(error)"
                    return
                }
                if executor.status(label: tunnel.launchdLabel) != .notLoaded {
                    lastError = "删除「\(tunnel.name)」失败：实例未成功停止"
                    return
                }
            }
            let plistURL = paths.launchdPlistURL(for: tunnel)
            if FileManager.default.fileExists(atPath: plistURL.path) {
                do {
                    try FileManager.default.removeItem(at: plistURL)
                } catch {
                    lastError = "删除「\(tunnel.name)」失败：清理 plist 出错 \(error)"
                    return
                }
            }
        case .app:
            appExecutor.stop(tunnel)
        }

        let logURL = paths.logURL(for: tunnel)
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.removeItem(at: logURL)
            if FileManager.default.fileExists(atPath: logURL.path) {
                lastError = "「\(tunnel.name)」已删除，但其日志文件清理失败：\(logURL.path)"
            }
        }

        guard let index = config.tunnels.firstIndex(where: { $0.id == id }) else { return }
        let removed = config.tunnels.remove(at: index)
        do {
            try store.save(config)
        } catch {
            config.tunnels.insert(removed, at: min(index, config.tunnels.count))
            lastError = "删除「\(tunnel.name)」失败：写入配置出错 \(error)"
            return
        }
        statuses[id] = nil
        probeResults[id] = nil
        refresh()
    }

    /// 新增隧道：校验 id 非空/合法/唯一后追加并落盘；不自动启动。保存失败回滚内存态。
    public func addTunnel(_ tunnel: TunnelConfig) {
        let validID = !tunnel.id.isEmpty && tunnel.id.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-")
        }
        guard validID else {
            lastError = "新增「\(tunnel.name)」失败：id 非法（仅限字母、数字、连字符）"
            return
        }
        guard !config.tunnels.contains(where: { $0.id == tunnel.id }) else {
            lastError = "新增「\(tunnel.name)」失败：id「\(tunnel.id)」已存在"
            return
        }

        config.tunnels.append(tunnel)
        do {
            try store.save(config)
        } catch {
            config.tunnels.removeAll { $0.id == tunnel.id }
            lastError = "新增「\(tunnel.name)」失败：写入配置出错 \(error)"
            return
        }
        refresh()
    }

    // MARK: - 状态

    public func refresh() {
        var nextStatuses = statuses
        for tunnel in config.tunnels {
            switch tunnel.executor {
            case .launchd:
                nextStatuses[tunnel.id] = executor.status(label: tunnel.launchdLabel)
            case .app:
                nextStatuses[tunnel.id] = appExecutor.status(id: tunnel.id)
            }
        }
        // 避免状态未变化时重复发布，减少 SwiftUI 无意义的重建。
        if nextStatuses != statuses {
            statuses = nextStatuses
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
                        if self.probeResults[id] != result {
                            self.probeResults[id] = result
                        }
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
