import Foundation

/// 迁移接管结果。
public struct MigrationOutcome: Sendable, Equatable {
    public let tunnel: TunnelConfig
    public let backupURL: URL
    public let rolledBack: Bool
    public let message: String

    public init(tunnel: TunnelConfig, backupURL: URL, rolledBack: Bool, message: String) {
        self.tunnel = tunnel
        self.backupURL = backupURL
        self.rolledBack = rolledBack
        self.message = message
    }
}

public enum MigrationError: Error, Equatable, Sendable {
    case invalidAgent(label: String, reason: String)
    case backupFailed(label: String, underlying: String)
    case verifyFailed(label: String)
    case rollbackFailed(label: String, reason: String)
}

/// 迁移接管编排：备份（移动）→ bootout 旧 → bootstrap 新 → 验证运行。
/// 备份先行是硬约束：备份完成前绝不触碰 launchd；bootstrap 失败立即回滚。
public struct MigrationService: Sendable {
    public let paths: TunnelPaths
    public let executor: LaunchCtlExecutor
    /// 轮询间隔（测试注入 no-op 免等待）。
    private let pollDelay: @Sendable () -> Void

    public init(
        paths: TunnelPaths,
        executor: LaunchCtlExecutor,
        pollDelay: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.25) }
    ) {
        self.paths = paths
        self.executor = executor
        self.pollDelay = pollDelay
    }

    /// 接管单个旧 agent。任一步失败即回滚该条（恢复备份 plist 并 bootstrap 旧 agent）。
    public func takeover(agent: LegacyAgent) throws -> MigrationOutcome {
        guard let tunnel = LegacyImporter.tunnelConfig(from: agent), !tunnel.command.isEmpty else {
            throw MigrationError.invalidAgent(
                label: agent.label,
                reason: "无法从 Label 派生合法隧道 id，或 ProgramArguments 为空"
            )
        }

        let backupURL: URL
        do {
            backupURL = try backup(agent: agent)
        } catch {
            throw MigrationError.backupFailed(label: agent.label, underlying: String(describing: error))
        }

        do {
            // 旧 plist 已移走；bootout 只卸载已加载实例，未加载不算错误。
            try executor.bootout(label: agent.label)
            let newPlistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
            try executor.bootstrap(label: tunnel.launchdLabel, plistURL: newPlistURL)
            try verifyRunning(label: tunnel.launchdLabel)
            return MigrationOutcome(
                tunnel: tunnel,
                backupURL: backupURL,
                rolledBack: false,
                message: "接管完成：\(tunnel.name) 已由 \(tunnel.launchdLabel) 接管并运行"
            )
        } catch let error {
            do {
                try rollback(agent: agent, backupURL: backupURL, newLabel: tunnel.launchdLabel)
            } catch let rollbackError {
                throw MigrationError.rollbackFailed(
                    label: agent.label,
                    reason: "回滚失败（需人工恢复备份 \(backupURL.path)）：\(String(describing: rollbackError))；原始错误：\(String(describing: error))"
                )
            }
            throw error
        }
    }

    // MARK: - 步骤

    /// 备份 = 把旧 plist 移动到 migration-backup（移动而非复制：留在 LaunchAgents
    /// 会在下次登录随 RunAtLoad 与新 agent 双跑，抢端口或抢反向转发）。
    private func backup(agent: LegacyAgent) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.migrationBackupDirectory, withIntermediateDirectories: true)
        let stamp = ConfigStore.timestamp()
        var candidate = paths.migrationBackupDirectory
            .appendingPathComponent("\(stamp)-\(agent.label).plist")
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = paths.migrationBackupDirectory
                .appendingPathComponent("\(stamp)-\(counter)-\(agent.label).plist")
            counter += 1
        }
        try fileManager.moveItem(at: agent.plistURL, to: candidate)
        return candidate
    }

    /// 验证新 agent 真正进入 running（bootstrap + RunAtLoad 后给 launchd 一点启动时间）。
    private func verifyRunning(label: String) throws {
        for _ in 0..<20 {
            if case .running = executor.status(label: label) { return }
            pollDelay()
        }
        throw MigrationError.verifyFailed(label: label)
    }

    private func rollback(agent: LegacyAgent, backupURL: URL, newLabel: String) throws {
        _ = try? executor.bootout(label: newLabel)
        // 若旧实例此前 bootout 失败仍在运行，这里补一次；已卸载则 not-found 不算错误。
        _ = try? executor.bootout(label: agent.label)
        try FileManager.default.moveItem(at: backupURL, to: agent.plistURL)
        try executor.bootstrap(label: agent.label, plistURL: agent.plistURL)
    }
}
