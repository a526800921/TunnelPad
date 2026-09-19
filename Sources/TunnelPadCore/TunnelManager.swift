import Foundation
import Combine

/// UI 层的隧道管理器：配置、状态、启停与迁移编排的 @MainActor 门面。
@MainActor
public final class TunnelManager: ObservableObject {
    public let paths: TunnelPaths
    public let shutdownHandle: Shutdown.OwnerHandle

    @Published public private(set) var config: AppConfig
    @Published public private(set) var statuses: [String: TunnelStatus] = [:]
    @Published public private(set) var probeResults: [String: ProbeResult] = [:]
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public var lastMessage: String?
    @Published public var lastError: String?

    private let migrationService: MigrationService
    private let probeCoordinator: ProbeCoordinator
    private let healthProbeCoordinator: ProbeCoordinator
    private let logStore: LogEventStore
    private let rustCore: any RustLifecycleOwner
    private let preStartChecker: any ECSPreStartChecking
    private var runtimeState = TunnelRuntimeState()
    private var probeTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var launchdFailureMonitorTask: Task<Void, Never>?
    private var probeGeneration: UInt = 0
    /// 所有异步状态快照共享请求代次；较旧的后台/手动读取不能覆盖较新的读取。
    private var stateReadGeneration: UInt = 0
    /// 生命周期或有效配置发生变化时失效在途读取，即使底层调用无法立即取消，
    /// 结果也不能再回写到 UI 门面。
    private var stateMutationGeneration: UInt = 0
    /// 每个隧道的操作代际：异步操作即使底层系统调用无法立即取消，
    /// 也不能在后续操作已经开始后把旧结果写回门面。
    private var operationGenerations: [String: UInt] = [:]
    /// Rust owner 的操作代次；Swift generation 只负责 UI busy/结果门禁，
    /// 真正的系统副作用前置校验由 Rust owner 完成。
    private var rustOperationGenerations: [String: UInt64] = [:]
    /// 每条隧道独立维护健康状态；熔断只影响该隧道，监测仍可继续提供只读状态。
    private var healthRecoveryStates: [String: HealthRecoveryState] = [:]
    /// 用户显式停止是独立于瞬时恢复状态的意图。配置编辑/重载不能清除此集合；
    /// 只有显式 start/restart 或删除同一 ID 才能改变它。
    private var manuallyStoppedIDs: Set<String> = []
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    /// 删除隧道后保留代次墓碑，避免不可立即取消的旧任务在同 ID 重建后复活。
    private var recoveryGenerations: [String: UInt] = [:]
    /// 启动阶段只做一次全量状态发现；持续健康循环不再重复扫描所有隧道。
    private var didAttemptInitialHealthStatusSnapshot = false
    /// 显式启停完成后，仅对当前隧道有界重读 launchd 状态，收敛 xpcproxy
    /// 等过渡态；不恢复全局定时 snapshot。
    private static let lifecycleStatusSettleAttempts = 30
    private static let lifecycleStatusSettleDelayNanoseconds: UInt64 = 100_000_000
    private static let defaultLaunchdFailureMonitorIntervalNanoseconds: UInt64 = 1_000_000_000
    private let healthMonitorIntervalNanoseconds: UInt64
    private let launchdFailureMonitorIntervalNanoseconds: UInt64
    private let healthSleep: @Sendable (UInt64) async throws -> Void
    private struct LaunchdFailureObservation: Sendable {
        var isHealthy: Bool
        var pid: Int32?
    }
    private var launchdFailureObservations: [String: LaunchdFailureObservation] = [:]
    /// launchd 报告 running 不能证明 SSH 已建立；只有连接探针成功才清除
    /// 本轮恢复计数。无探针隧道保留恢复历史并继续监听 launchd 异常。
    private var recoveryAwaitingConnectivityConfirmation: Set<String> = []
    private let launchRestoreDiscoveryAttempts: Int
    private let launchRestoreDiscoveryPollNanoseconds: UInt64
    private let appEventLog: AppEventLog
    private let launchClock: LaunchRecoveryClock
    private let recoveryPreflightCoordinator: SharedRecoveryPreflightCoordinator
    private var launchCoordinator: LaunchRecoveryCoordinator?
    private var launchSetupTask: Task<Void, Never>?
    private var launchExcludedIDs: Set<String> = []
    private var launchPendingIDs: Set<String> = []
    private var launchConfigurationValid = false
    private var launchInitialConfig: AppConfig?
    private var isShuttingDown = false
    var launchRecoveryIDs: Set<String> { launchPendingIDs.union(launchCoordinator?.ownedIDs ?? []) }

    private struct HealthMonitorSchedule: Sendable {
        let intervalNanoseconds: UInt64
        let sleep: @Sendable (UInt64) async throws -> Void
    }

    private struct StateReadToken: Sendable, Equatable {
        let readGeneration: UInt
        let mutationGeneration: UInt
    }

    public convenience init(paths: TunnelPaths) {
        let rustCore: RustCoreClient
        do {
            rustCore = try RustCoreClient(paths: paths)
        } catch let error as RustCoreClient.ClientError {
            rustCore = RustCoreClient(failure: error)
        } catch {
            rustCore = RustCoreClient(failure: .unavailable(String(describing: error)))
        }
        self.init(
            paths: paths,
            rustCore: rustCore,
            preStartChecker: ECSPreStartChecker()
        )
    }

    init(
        paths: TunnelPaths,
        rustCore: any RustLifecycleOwner,
        preStartChecker: any ECSPreStartChecking,
        probeService: ProbeService = ProbeService(),
        healthMonitorIntervalNanoseconds: UInt64 = HealthRecoveryPolicy.monitorIntervalNanoseconds,
        launchdFailureMonitorIntervalNanoseconds: UInt64 = TunnelManager.defaultLaunchdFailureMonitorIntervalNanoseconds,
        healthSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        launchRestoreDiscoveryAttempts: Int = 50,
        launchRestoreDiscoveryPollNanoseconds: UInt64 = 100_000_000,
        launchClock: LaunchRecoveryClock = .continuous
    ) {
        self.paths = paths
        self.migrationService = MigrationService(paths: paths, executor: LaunchCtlExecutor())
        self.probeCoordinator = ProbeCoordinator(service: probeService)
        self.healthProbeCoordinator = ProbeCoordinator(service: probeService)
        self.logStore = LogEventStore(paths: paths)
        self.rustCore = rustCore
        self.preStartChecker = preStartChecker
        self.healthMonitorIntervalNanoseconds = healthMonitorIntervalNanoseconds
        self.launchdFailureMonitorIntervalNanoseconds = launchdFailureMonitorIntervalNanoseconds
        self.healthSleep = healthSleep
        self.launchRestoreDiscoveryAttempts = launchRestoreDiscoveryAttempts
        self.launchRestoreDiscoveryPollNanoseconds = launchRestoreDiscoveryPollNanoseconds
        self.appEventLog = AppEventLog(paths: paths)
        self.launchClock = launchClock
        self.recoveryPreflightCoordinator = SharedRecoveryPreflightCoordinator(clock: launchClock)
        self.shutdownHandle = Shutdown.OwnerHandle {
            try rustCore.shutdown()
        }
        do {
            self.config = try rustCore.loadConfig()
            self.launchConfigurationValid = true
            self.launchInitialConfig = self.config
        } catch {
            self.config = AppConfig()
            self.lastError = String(describing: error)
        }
        let logStore = self.logStore
        let initialIDs = self.config.tunnels.map(\.id)
        Task {
            await logStore.sync(tunnelIDs: initialIDs)
        }
        startHealthMonitoring()
        startLaunchdFailureMonitoring()
    }

    deinit {
        probeTask?.cancel()
        healthMonitorTask?.cancel()
        launchdFailureMonitorTask?.cancel()
        recoveryTasks.values.forEach { $0.cancel() }
    }

    public func tunnel(id: String) -> TunnelConfig? {
        config.tunnels.first { $0.id == id }
    }

    /// 返回指定隧道的日志快照与事件流；订阅取消不会停止后台日志采集。
    public func logSession(for tunnelID: String) async -> LogSession {
        await logStore.openSession(for: tunnelID)
    }

    /// 显式刷新指定隧道的日志，供日志面板的刷新按钮和隔离测试使用。
    @discardableResult
    public func refreshLog(for tunnelID: String) async -> LogSnapshot {
        await logStore.refresh(for: tunnelID)
    }

    /// 通过日志 owner 原位清空指定隧道日志；不删除配置、plist、隧道或 watcher。
    @discardableResult
    public func clearLog(for tunnelID: String) async -> LogSnapshot {
        await logStore.clear(for: tunnelID)
    }

    /// 手动编辑 config.json 后重新加载；丢弃已移除隧道的状态与探针缓存。
    public func reloadConfig() {
        invalidateStateReads()
        do {
            let loaded = try rustCore.loadConfig()
            applyEffectiveConfig(loaded)
            invalidateStateReads()
            lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
            syncLogStore()
            refresh()
        } catch {
            lastError = "Rust Core 重新加载配置失败：\(error)"
        }
    }

    /// 异步重新加载配置：文件读取在后台执行，完成后沿用同步入口的状态裁剪和提示语义。
    public func reloadConfigAsync() async {
        invalidateStateReads()
        let mutationGeneration = stateMutationGeneration
        let rustCore = self.rustCore
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try rustCore.loadConfig()
            }.value
            guard mutationGeneration == stateMutationGeneration, !Task.isCancelled else { return }
            applyEffectiveConfig(loaded)
            invalidateStateReads()
            lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
            syncLogStore()
            await refreshAsync()
        } catch is CancellationError {
            return
        } catch {
            lastError = "Rust Core 重新加载配置失败：\(error)"
        }
    }

    /// 异步编辑入口：把配置写入放到后台，避免设置窗口被磁盘操作阻塞。
    /// 返回是否保存成功（内存配置已更新并落盘）；每条失败路径都会把原因写入 `lastError`。
    @discardableResult
    public func updateTunnelAsync(_ tunnel: TunnelConfig) async -> Bool {
        let runtimeChanged = self.tunnel(id: tunnel.id)?.matchesLaunchRuntime(tunnel) != true
        if runtimeChanged { await cancelLaunchRecoveryAndWait(tunnel.id) }
        else { await launchCoordinator?.waitForActive(tunnel.id) }
        guard let operation = beginOperation(for: tunnel.id, cancelsRecovery: runtimeChanged) else {
            lastError = "保存「\(tunnel.name)」失败：隧道正在执行其他操作，请稍后再试"
            return false
        }
        defer { endOperation(for: tunnel.id, generation: operation) }
        guard let index = config.tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
            lastError = "保存「\(tunnel.name)」失败：隧道不存在或已被删除"
            return false
        }
        var nextConfig = config
        nextConfig.tunnels[index] = tunnel
        let configToSave = nextConfig
        let rustCore = self.rustCore
        do {
            try await Task.detached(priority: .utility) {
                try rustCore.saveConfig(configToSave)
            }.value
            guard isCurrentOperation(tunnel.id, generation: operation), !Task.isCancelled else {
                lastError = "保存「\(tunnel.name)」未完成：操作已失效，请重试"
                return false
            }
            config = nextConfig
            if runtimeChanged {
                launchdFailureObservations.removeValue(forKey: tunnel.id)
                recoveryAwaitingConnectivityConfirmation.remove(tunnel.id)
                if !manuallyStoppedIDs.contains(tunnel.id) {
                    healthRecoveryStates.removeValue(forKey: tunnel.id)
                }
            }
            if tunnel.probe == nil {
                updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
            }
            lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
        } catch {
            lastError = "保存配置失败：\(error)"
            return false
        }
        await refreshAsync()
        return true
    }

    // MARK: - 启动恢复

    /// 冻结本次启动候选并启动有限并发队列。首次失败按单调时钟持续限频重试。
    public func restoreAutoStartTunnels() async {
        guard !hasCompletedLaunchRestore, !isShuttingDown else { return }
        hasCompletedLaunchRestore = true
        launchPendingIDs = Set(config.tunnels.filter(\.autoStart).map(\.id)).subtracting(launchExcludedIDs)
        launchSetupTask = Task { [weak self] in await self?.prepareLaunchRecovery() }
        await launchSetupTask?.value
    }

    private func prepareLaunchRecovery() async {
        guard let owner = rustCore as? any RustLaunchRecoveryOwner else {
            launchPendingIDs.removeAll(); appEventLog.write("启动恢复不可用：Core 缺少严格启动能力"); return
        }
        do {
            guard try await Task.detached(priority: .utility, operation: { try owner.supportsLaunchRecovery() }).value else {
                launchPendingIDs.removeAll(); appEventLog.write("启动恢复不可用：Core 能力版本不匹配"); return
            }
        } catch {
            launchPendingIDs.removeAll(); appEventLog.write("启动恢复不可用：Core 能力探测失败"); return
        }
        var reported = false
        while !launchConfigurationValid && !Task.isCancelled && !isShuttingDown {
            do {
                let loaded = try await Task.detached(priority: .utility) { try owner.loadConfig() }.value
                guard !Task.isCancelled, !isShuttingDown else { return }
                applyEffectiveConfig(loaded); launchConfigurationValid = true; launchInitialConfig = loaded
            } catch {
                if !reported { appEventLog.write("启动恢复等待有效配置，300 秒后复查"); reported = true }
                do { try await launchClock.sleep(300) } catch { return }
            }
        }
        guard !Task.isCancelled, !isShuttingDown else { return }
        let candidates = (launchInitialConfig ?? config).tunnels.filter { $0.autoStart && !launchExcludedIDs.contains($0.id) }
        launchPendingIDs = Set(candidates.map(\.id))
        var resource = "ecs-unresolved"
        if candidates.contains(where: { SSHCommand.isSSH($0.command) }), let checker = preStartChecker as? any LaunchPreflightChecking {
            resource = (try? await checker.launchResource()) ?? resource
        }
        guard !Task.isCancelled, !isShuttingDown else { return }
        let coordinator = LaunchRecoveryCoordinator(clock: launchClock, attempt: { [weak self] tunnel in
            guard let self else { return .cancelled }
            return await self.performLaunchRecovery(tunnel)
        }, handoff: { [weak self] tunnel, status in
            guard let self, !self.isShuttingDown, !self.launchExcludedIDs.contains(tunnel.id), self.tunnel(id: tunnel.id)?.matchesLaunchRuntime(tunnel) == true else { return }
            self.updateRuntime { $0.setStatus(status, for: tunnel.id) }
            self.resetHealthRecovery(for: tunnel.id, phase: .monitoring)
            self.appEventLog.write("自动拉起「\(tunnel.name)」已确认运行；交接健康监测")
            // 已经处于 running 的 launchd 实例会在启动恢复中早退；交接后补做一次
            // 只读 ECS 复核，避免已有实例绕过连接建立前的公网 IP 前置。
            Task { [weak self] in
                await self?.runInitialIPDriftCheck()
            }
        }, report: { [weak self] tunnel, category, count in
            self?.appEventLog.write("自动拉起「\(tunnel.name)」等待重试：\(category.rawValue)，累计 \(count) 次")
        })
        launchCoordinator = coordinator
        let validCandidates = candidates.filter { !launchExcludedIDs.contains($0.id) && self.tunnel(id: $0.id)?.matchesLaunchRuntime($0) == true }
        for tunnel in validCandidates { cancelRecovery(for: tunnel.id) }
        coordinator.start(validCandidates.map { .init(tunnel: $0, resource: SSHCommand.isSSH($0.command) ? resource : nil) })
        launchPendingIDs.removeAll()
        appEventLog.write("启动恢复队列已建立：候选 \(validCandidates.count) 条")
    }

    private func performLaunchRecovery(_ expected: TunnelConfig) async -> LaunchRecoveryOutcome {
        let id = expected.id
        guard !isShuttingDown, !launchExcludedIDs.contains(id), tunnel(id: id)?.matchesLaunchRuntime(expected) == true, !Task.isCancelled,
              let owner = rustCore as? any RustLaunchRecoveryOwner else { return .cancelled }
        guard let operation = beginOperation(for: id, cancelsRecovery: false) else { return .retry(.transient) }
        defer { endOperation(for: id, generation: operation) }
        let deadline = launchClock.now() + 55
        do {
            guard let generation = try await Task.detached(priority: .utility, operation: { try owner.beginLaunchRecovery(id: id) }).value else {
                return .retry(.transient)
            }
            if Task.isCancelled { try? owner.cancelOperation(id: id, generation: generation); return .cancelled }
            rustOperationGenerations[id] = generation
            return try await withTaskCancellationHandler(operation: {
                try await executeLaunchAttempt(expected, owner: owner, generation: generation, operation: operation, deadline: deadline)
            }, onCancel: { try? owner.cancelOperation(id: id, generation: generation) })
        } catch is CancellationError { return .cancelled }
        catch RustCoreClient.ClientError.remote(let code, _) where code == 14 { return .retry(.transient) }
        catch RustCoreClient.ClientError.remote(let code, _) where [8, 9, 13].contains(code) { return .cancelled }
        catch ECSPreStartError.timedOut { return .retry(.transient) }
        catch ECSPreflightProcessError.timedOut { return .retry(.transient) }
        catch is ECSPreStartError { return .retry(.local) }
        catch { return .retry(.unknown) }
    }

    private func executeLaunchAttempt(_ expected: TunnelConfig, owner: any RustLaunchRecoveryOwner,
        generation: UInt64, operation: UInt, deadline: TimeInterval) async throws -> LaunchRecoveryOutcome {
        let id = expected.id
        func validate() throws {
            try Task.checkCancellation()
            guard !isShuttingDown, !launchExcludedIDs.contains(id), tunnel(id: id)?.matchesLaunchRuntime(expected) == true,
                  isCurrentOperation(id, generation: operation) else { throw CancellationError() }
        }
        func remaining() -> TimeInterval { max(0, deadline - launchClock.now()) }
        try validate()
        var budget = remaining()
        guard budget > 0 else { return .retry(.transient) }
        var status = try await Task.detached(priority: .utility) { [budget] in try owner.launchRecoveryStatus(id: id, generation: generation, timeout: min(2, budget)) }.value
        try validate()
        if case .running(let pid) = status, let pid, pid > 0 {
            let requiresSingleOwnerMigration = expected.autoStart
                && expected.keepAlive
                && SSHCommand.isSSH(expected.command)
            if !requiresSingleOwnerMigration {
                return .running(.running(pid: pid))
            }
            budget = remaining()
            status = try await Task.detached(priority: .utility) { [budget] in
                try owner.launchRecoveryStop(id: id, generation: generation, timeout: budget)
            }.value
            try validate()
        }
        if status == .notRunning {
            budget = remaining()
            status = try await Task.detached(priority: .utility) { [budget] in try owner.launchRecoveryStop(id: id, generation: generation, timeout: budget) }.value
            try validate()
        }
        guard status == .notLoaded else { return .retry(.transient) }
        budget = remaining()
        guard budget > 0 else { return .retry(.transient) }
        if SSHCommand.isSSH(expected.command) {
            guard let checker = preStartChecker as? any LaunchPreflightChecking else { return .retry(.local) }
            let result = try await checker.checkLaunch(tunnel: expected, timeout: min(30, budget))
            try validate()
            if result.category == .cancelled { return .cancelled }
            guard result.exitCode == 0 && result.category == .success else { return .retry(result.category == .success ? .unknown : result.category) }
        }
        budget = remaining()
        guard budget > 0 else { return .retry(.transient) }
        let final = try await Task.detached(priority: .utility) { [budget] in try owner.launchRecoveryStart(tunnel: expected, generation: generation, timeout: budget) }.value
        try validate()
        if case .running(let pid) = final, let pid, pid > 0 { return .running(.running(pid: pid)) }
        return .retry(.transient)
    }

    private func cancelLaunchRecovery(_ id: String) {
        launchExcludedIDs.insert(id)
        launchPendingIDs.remove(id)
        launchCoordinator?.cancel(id)
    }
    private func cancelLaunchRecoveryAndWait(_ id: String) async {
        cancelLaunchRecovery(id)
        await launchCoordinator?.cancelAndWait(id)
    }

    private var hasCompletedLaunchRestore = false

    /// 删除单条隧道：停止实例 → 清理生成的 plist → 删除日志 → 从配置移除并落盘。
    /// 实例停止与配置写入失败即中断并保留配置；日志清理失败仅告警不中断。操作不可恢复。
    public func removeTunnel(_ id: String) {
        if launchRecoveryIDs.contains(id) {
            cancelLaunchRecovery(id)
            Task { _ = await removeTunnelAsync(id) }
            return
        }
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        guard let rustGeneration = beginRustOperation(for: id) else { return }
        let rustCore = self.rustCore
        do {
            try rustCore.remove(id: id, generation: rustGeneration)
            config.tunnels.removeAll { $0.id == id }
            updateRuntime {
                $0.setStatus(nil, for: id)
                $0.setProbeResult(nil, for: id)
            }
            healthRecoveryStates.removeValue(forKey: id)
            manuallyStoppedIDs.remove(id)
            syncLogStore()
            refresh()
        } catch {
            lastError = "删除「\(tunnel.name)」失败：\(error)"
        }
    }

    /// 异步删除入口：先在后台停止实例，再回到门面完成配置/产物提交。
    /// 同步 removeTunnel 保留给兼容调用方；UI 使用此入口避免主线程等待进程退出。
    public func removeTunnelAsync(_ id: String) async {
        await cancelLaunchRecoveryAndWait(id)
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        guard let rustGeneration = beginRustOperation(for: id) else { return }
        let rustCore = self.rustCore
        do {
            try await runRustOperation(id: id, generation: rustGeneration) {
                try rustCore.remove(id: id, generation: rustGeneration)
            }
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
            config.tunnels.removeAll { $0.id == id }
            updateRuntime {
                $0.setStatus(nil, for: id)
                $0.setProbeResult(nil, for: id)
            }
            healthRecoveryStates.removeValue(forKey: id)
            manuallyStoppedIDs.remove(id)
            syncLogStore()
            await refreshAsync()
        } catch is CancellationError {
            return
        } catch {
            if isStaleRustOperation(error) { return }
            lastError = "删除「\(tunnel.name)」失败：\(error)"
        }
    }

    /// 新增隧道：校验 id 非空/合法/唯一后追加并落盘；不自动启动。保存失败回滚内存态。
    /// 返回是否保存成功；失败原因写入 `lastError`。
    @discardableResult
    public func addTunnel(_ tunnel: TunnelConfig) -> Bool {
        let validID = !tunnel.id.isEmpty && tunnel.id.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-")
        }
        guard validID else {
            lastError = "新增「\(tunnel.name)」失败：id 非法（仅限字母、数字、连字符）"
            return false
        }
        guard !config.tunnels.contains(where: { $0.id == tunnel.id }) else {
            lastError = "新增「\(tunnel.name)」失败：id「\(tunnel.id)」已存在"
            return false
        }

        var nextConfig = config
        nextConfig.tunnels.append(tunnel)
        invalidateStateReads()
        do {
            try rustCore.saveConfig(nextConfig)
            config = nextConfig
        } catch {
            lastError = "新增「\(tunnel.name)」失败：\(error)"
            return false
        }
        syncLogStore()
        refresh()
        return true
    }

    // MARK: - 状态

    public func refresh() {
        let token = beginStateRead()
        do {
            let snapshot = try rustCore.snapshot()
            guard isCurrentStateRead(token) else { return }
            let previousIDs = Set(config.tunnels.map(\.id))
            applyEffectiveConfig(snapshot.config)
            applyStatusSnapshot(snapshot.statuses)
            if previousIDs != Set(config.tunnels.map(\.id)) {
                syncLogStore()
            }
        } catch {
            guard isCurrentStateRead(token) else { return }
            invalidateProbeResults()
            updateRuntime { state in
                for id in Array(state.probeResults.keys) { state.setProbeResult(nil, for: id) }
            }
            lastError = "Rust Core 刷新状态失败：\(error)"
            return
        }
        runProbes()
    }

    /// 异步状态刷新：系统查询在后台进行，完成后以同样的状态快照发布到 UI。
    public func refreshAsync() async {
        let token = beginStateRead()
        do {
            let rustCore = self.rustCore
            let snapshot = try await Task.detached(priority: .utility) {
                try rustCore.snapshot()
            }.value
            guard isCurrentStateRead(token), !Task.isCancelled else { return }
            let previousIDs = Set(config.tunnels.map(\.id))
            applyEffectiveConfig(snapshot.config)
            applyStatusSnapshot(snapshot.statuses)
            if previousIDs != Set(config.tunnels.map(\.id)) {
                syncLogStore()
            }
            runProbes()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentStateRead(token) else { return }
            invalidateProbeResults()
            updateRuntime { state in
                for id in Array(state.probeResults.keys) { state.setProbeResult(nil, for: id) }
            }
            lastError = "Rust Core 刷新状态失败：\(error)"
            return
        }
    }

    /// 只接受已经由 Rust owner 校验过的有效配置；无效候选在调用方的 catch
    /// 中保留当前配置，不能先写入空配置再裁剪运行时状态。
    private func applyEffectiveConfig(_ nextConfig: AppConfig) {
        let oldByID = Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: nextConfig.tunnels.map { ($0.id, $0) })
        let changedIDs = Set(oldByID.keys).union(nextByID.keys).filter { oldByID[$0] != nextByID[$0] }
        for id in changedIDs {
            let runtimeChanged = oldByID[id].flatMap { old in
                nextByID[id].map { !old.matchesLaunchRuntime($0) }
            } ?? true
            guard runtimeChanged else { continue }
            // 首次有效配置可能在 App 启动后才读到；新增项此时仍属于冻结候选。
            // 只有原来已经存在的候选发生运行时变化/删除才排除本轮启动恢复。
            if oldByID[id] != nil {
                cancelLaunchRecovery(id)
            }
            cancelRecovery(for: id)
            launchdFailureObservations.removeValue(forKey: id)
            if !manuallyStoppedIDs.contains(id) {
                healthRecoveryStates.removeValue(forKey: id)
            }
        }
        if !changedIDs.isEmpty {
            invalidateProbeResults()
        }

        config = nextConfig
        let validIDs = Set(nextConfig.tunnels.map(\.id))
        manuallyStoppedIDs.formIntersection(validIDs)
        updateRuntime { state in
            state.prune(to: validIDs)
            for id in changedIDs { state.setProbeResult(nil, for: id) }
        }
    }

    /// 异步执行配置了探针的隧道探测，完成后更新展示。
    private func runProbes() {
        let probes = config.tunnels.compactMap { tunnel -> (String, ProbeConfig)? in
            guard let probe = tunnel.probe, isProbeEligible(tunnel.id) else { return nil }
            return (tunnel.id, probe)
        }
        invalidateProbeResults()
        let currentGeneration = probeGeneration
        guard !probes.isEmpty else {
            Task { await probeCoordinator.cancel() }
            probeTask = nil
            return
        }

        let coordinator = probeCoordinator
        probeTask = Task { [weak self] in
            let results = await coordinator.run(probes)
            guard !Task.isCancelled, let self, let results else { return }
            self.applyProbeResults(results, generation: currentGeneration)
        }
    }

    private func applyProbeResults(_ results: [String: ProbeResult], generation: UInt) {
        guard generation == probeGeneration else { return }
        applyProbeResults(results)
    }

    private func applyProbeResults(_ results: [String: ProbeResult]) {
        let validProbes = Dictionary(uniqueKeysWithValues: config.tunnels.compactMap { tunnel -> (String, ProbeConfig)? in
            guard let probe = tunnel.probe, isProbeEligible(tunnel.id) else { return nil }
            return (tunnel.id, probe)
        })
        updateRuntime { state in
            for (id, result) in results {
                guard validProbes[id] != nil, state.probeResults[id] != result else { continue }
                state.setProbeResult(result, for: id)
            }
        }
    }

    // MARK: - 后台健康监测

    /// 健康监测由 TunnelManager 持有，不依赖主窗口的出现、隐藏或切换隧道。
    /// UI 刷新仍可执行一次性探针，但使用独立 coordinator，不能取消后台监测。
    private func startHealthMonitoring() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runHealthProbeCycle()
                guard !Task.isCancelled,
                      let schedule = self?.healthMonitorSchedule() else { return }
                do {
                    try await schedule.sleep(schedule.intervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func healthMonitorSchedule() -> HealthMonitorSchedule {
        HealthMonitorSchedule(
            intervalNanoseconds: healthMonitorIntervalNanoseconds,
            sleep: healthSleep
        )
    }

    /// 观察受管 SSH 的 launchd 生命周期。连接断开、实例退出或 PID 变化都
    /// 立即进入同一条 bootout-first → ECS 前置 → start 恢复链；不让 KeepAlive
    /// 先用旧规则反复重连，再等待另一个低频任务发现漂移。
    private func startLaunchdFailureMonitoring() {
        guard preStartChecker is any ECSIPDriftChecking,
              rustCore is any RustHealthStatusReader else { return }
        launchdFailureMonitorTask?.cancel()
        launchdFailureMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.healthSleep(self.launchdFailureMonitorIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.runLaunchdFailureCycle()
            }
        }
    }

    private func runLaunchdFailureCycle() async {
        guard !Task.isCancelled, !isShuttingDown,
              let reader = rustCore as? any RustHealthStatusReader else { return }
        let candidates = unattendedRecoveryCandidates()
        for candidate in candidates {
            let id = candidate.id
            guard !Task.isCancelled, !isShuttingDown,
                  !busyIDs.contains(id), !launchRecoveryIDs.contains(id),
                  recoveryTasks[id] == nil else { continue }
            let status: TunnelStatus
            do {
                status = try await Task.detached(priority: .utility) {
                    try reader.status(id: id)
                }.value
            } catch {
                // 状态不确定时不推断抖动，也不执行 bootout 或同步。
                launchdFailureObservations.removeValue(forKey: id)
                continue
            }
            guard !Task.isCancelled, !isShuttingDown,
                  self.tunnel(id: id)?.matchesLaunchRuntime(candidate) == true else { return }
            updateRuntime { $0.setStatus(status, for: id) }
            observeLaunchdFailure(for: candidate, status: status)
        }
    }

    private func observeLaunchdFailure(for tunnel: TunnelConfig, status: TunnelStatus) {
        guard !manuallyStoppedIDs.contains(tunnel.id) else {
            launchdFailureObservations.removeValue(forKey: tunnel.id)
            recoveryAwaitingConnectivityConfirmation.remove(tunnel.id)
            return
        }
        let id = tunnel.id
        let currentPID: Int32?
        let isHealthy: Bool
        if case .running(let pid?) = status, pid > 0 {
            currentPID = pid
            isHealthy = true
        } else {
            currentPID = nil
            isHealthy = false
        }

        if let previous = launchdFailureObservations[id] {
            let didChange = previous.isHealthy != isHealthy || previous.pid != currentPID
            launchdFailureObservations[id] = LaunchdFailureObservation(
                isHealthy: isHealthy,
                pid: currentPID
            )

            // 从非健康回到 running 是恢复观察，不是新的故障；只有再次退出或
            // PID 再次变化，才启动下一轮 bootout-first 恢复。
            guard didChange, (!isHealthy || (previous.isHealthy && isHealthy)) else { return }
        } else {
            launchdFailureObservations[id] = LaunchdFailureObservation(
                isHealthy: isHealthy,
                pid: currentPID
            )
            // 第一次观察到非健康状态也必须恢复：启动后如果 KeepAlive 已经在
            // 抖动，不能要求先积累三次 PID 变化。
            guard !isHealthy else { return }
        }

        launchdFailureObservations.removeValue(forKey: id)
        triggerAutomaticRecovery(
            for: tunnel,
            reason: "SSH 连接异常（launchd 状态或 PID 发生变化）",
            delayOverrideNanoseconds: 0,
            allowNotRunning: true
        )
    }

    /// 启动交接时只做一次只读 ECS 复核；运行期间的主触发来自 launchd
    /// 生命周期异常，恢复链中的 `checkAsync` 会在重新启动前完成同步。
    private func runInitialIPDriftCheck() async {
        guard !Task.isCancelled, !isShuttingDown,
              let checker = preStartChecker as? any ECSIPDriftChecking,
              let reader = rustCore as? any RustHealthStatusReader else { return }

        let candidates = unattendedRecoveryCandidates()
        for candidate in candidates {
            let id = candidate.id
            guard !Task.isCancelled, !isShuttingDown,
                  !busyIDs.contains(id), !launchRecoveryIDs.contains(id),
                  recoveryTasks[id] == nil else { continue }
            let status: TunnelStatus
            do {
                status = try await Task.detached(priority: .utility) {
                    try reader.status(id: id)
                }.value
            } catch {
                // 无法确认当前是否运行时 fail-closed，不执行 ECS 写入或重启。
                continue
            }
            guard !Task.isCancelled, !isShuttingDown,
                  self.tunnel(id: id)?.matchesLaunchRuntime(candidate) == true else { return }
            updateRuntime { $0.setStatus(status, for: id) }
            guard isRunning(status), !busyIDs.contains(id), !launchRecoveryIDs.contains(id) else { continue }

            do {
                let result = try await checker.checkCurrentState(tunnel: candidate, timeout: 30)
                guard !Task.isCancelled, !isShuttingDown,
                      self.tunnel(id: id)?.matchesLaunchRuntime(candidate) == true else { return }
                if ["ip_drift", "transaction_pending"].contains(result.sanitizedCode) {
                    triggerAutomaticRecovery(
                        for: candidate,
                        reason: "ECS SSH `/32` 漂移",
                        delayOverrideNanoseconds: 0,
                        allowNotRunning: false
                    )
                } else if result.exitCode != 0 {
                    appEventLog.write("自动复核「\(candidate.name)」失败：\(result.sanitizedCode)")
                }
            } catch is CancellationError {
                return
            } catch {
                appEventLog.write("自动复核「\(candidate.name)」异常：\(error)")
            }
        }
    }

    /// 把单次明确的无人值守故障映射为现有健康恢复状态机的阈值事件。
    /// 已确认的 IP 漂移和每次新观察到的 launchd 断开都立即执行；只有同一
    /// 恢复任务内部的同步/生命周期失败使用有上限退避。
    private func triggerAutomaticRecovery(
        for tunnel: TunnelConfig,
        reason: String,
        delayOverrideNanoseconds: UInt64?,
        allowNotRunning: Bool = false
    ) {
        let id = tunnel.id
        guard recoveryTasks[id] == nil, !busyIDs.contains(id), !launchRecoveryIDs.contains(id),
              self.tunnel(id: id)?.matchesLaunchRuntime(tunnel) == true else { return }
        guard allowNotRunning || isRunning(statuses[id]) else { return }

        var state = healthRecoveryStates[id] ?? HealthRecoveryState()
        let action = state.confirmedFailure(
            delayOverrideNanoseconds: delayOverrideNanoseconds
        )
        healthRecoveryStates[id] = state

        guard case .schedule(let attempt, let delayNanoseconds) = action else { return }
        recoveryAwaitingConnectivityConfirmation.insert(id)
        appEventLog.write("检测到「\(tunnel.name)」\(reason)，开始 bootout→同步→重启")
        scheduleRecovery(
            for: id,
            tunnelName: tunnel.name,
            attempt: attempt,
            delayNanoseconds: delayNanoseconds
        )
    }

    private func runHealthProbeCycle() async {
        guard !Task.isCancelled else { return }

        let token = beginStateRead()
        let rustCore = self.rustCore
        let loadedConfig: AppConfig
        do {
            loadedConfig = try await Task.detached(priority: .utility) {
                try rustCore.loadConfig()
            }.value
        } catch {
            // 配置读取失败时不使用旧配置触发自动恢复。
            return
        }
        guard isCurrentStateRead(token), !Task.isCancelled else { return }

        if config != loadedConfig {
            let previousIDs = Set(config.tunnels.map(\.id))
            applyEffectiveConfig(loadedConfig)
            if previousIDs != Set(config.tunnels.map(\.id)) {
                syncLogStore()
            }
        }

        // 保留启动时的状态发现，兼容无主窗口时的状态展示；只允许一次全量
        // snapshot。后续只复核配置了探针的目标，不扫描无探针隧道。
        if !didAttemptInitialHealthStatusSnapshot {
            didAttemptInitialHealthStatusSnapshot = true
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try rustCore.snapshot()
                }.value
                guard isCurrentStateRead(token), !Task.isCancelled else { return }
                let previousIDs = Set(config.tunnels.map(\.id))
                applyEffectiveConfig(snapshot.config)
                applyStatusSnapshot(snapshot.statuses)
                if previousIDs != Set(config.tunnels.map(\.id)) {
                    syncLogStore()
                }
            } catch {
                // 初始快照失败时由下方目标状态复核决定是否允许探针。
            }
        }

        var probes: [(String, ProbeConfig)] = []
        for tunnel in config.tunnels {
            guard let probe = tunnel.probe,
                  !busyIDs.contains(tunnel.id), !launchRecoveryIDs.contains(tunnel.id) else { continue }
            if let reader = rustCore as? any RustHealthStatusReader {
                do {
                    let status = try await Task.detached(priority: .utility) {
                        try reader.status(id: tunnel.id)
                    }.value
                    guard isCurrentStateRead(token), !Task.isCancelled else { return }
                    updateRuntime { $0.setStatus(status, for: tunnel.id) }
                } catch {
                    guard isCurrentStateRead(token), !Task.isCancelled else { return }
                    invalidateProbeResults()
                    updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
                    // 状态超时仍可推进既有的安全恢复，但不能发送 HTTP 或保留绿色结果。
                    if reader.isStatusQueryTimeout(error), isRunning(statuses[tunnel.id]) {
                        recordHealthResult(.failed(reason: "运行状态查询超时"), for: tunnel.id)
                    }
                    continue
                }
            } else {
                // 缺少目标状态复核能力时后台监测保持 fail-closed。
                continue
            }
            guard isCurrentStateRead(token), !Task.isCancelled else { return }
            if isProbeEligible(tunnel.id) {
                probes.append((tunnel.id, probe))
            } else if canRetryQuiescedRecovery(
                for: tunnel.id, tunnel: tunnel, state: healthRecoveryStates[tunnel.id]
            ) {
                // 预检失败后 SSH 可能已停止；沿用有界恢复计数，不依赖停机 HTTP 探测。
                recordHealthResult(.failed(reason: "等待已停止隧道恢复"), for: tunnel.id)
            }
        }
        guard !probes.isEmpty else {
            await healthProbeCoordinator.cancel()
            return
        }

        let generation = probeGeneration
        var results: [String: ProbeResult] = [:]
        for probe in probes {
            // 每次发送前复核代次，防止串行批次在其他隧道停止后继续发出请求。
            guard isCurrentStateRead(token), generation == probeGeneration,
                  !Task.isCancelled, isProbeEligible(probe.0) else { return }
            guard let result = await healthProbeCoordinator.run([probe]) else { return }
            results.merge(result) { _, latest in latest }
        }
        guard isCurrentStateRead(token), generation == probeGeneration,
              !Task.isCancelled else { return }
        applyProbeResults(results, generation: generation)
        for (id, result) in results {
            guard isCurrentStateRead(token), !Task.isCancelled else { return }
            guard isProbeEligible(id), rustCore is any RustHealthStatusReader else { continue }
            recordHealthResult(result, for: id)
        }
    }

    private func isProbeEligible(_ id: String) -> Bool {
        isRunning(statuses[id]) && !busyIDs.contains(id) && !launchRecoveryIDs.contains(id)
    }

    private func recordHealthResult(_ result: ProbeResult, for id: String) {
        guard !launchRecoveryIDs.contains(id) else { return }
        guard let tunnel = tunnel(id: id) else { return }
        // 等待或执行恢复期间只观察探针，不推进失败计数；本次恢复结束后，
        // 下一轮健康结果再决定是否进入下一次尝试。
        guard recoveryTasks[id] == nil, !runtimeState.busyIDs.contains(id) else { return }
        var state = healthRecoveryStates[id] ?? HealthRecoveryState()
        let mayRetryWithoutRunning = canRetryQuiescedRecovery(for: id, tunnel: tunnel, state: state)
        let healthStatus = mayRetryWithoutRunning && !isRunning(statuses[id])
            ? TunnelStatus.running(pid: nil)
            : statuses[id]
        let action = state.record(
            result,
            status: healthStatus,
            keepAlive: tunnel.keepAlive
        )
        healthRecoveryStates[id] = state

        if case .satisfied = result,
           recoveryAwaitingConnectivityConfirmation.remove(id) != nil {
            lastMessage = "「\(tunnel.name)」已自动恢复（连接探针已确认）"
            appEventLog.write("「\(tunnel.name)」连接探针已确认恢复，自动恢复计数已清除")
        }

        switch action {
        case .observe:
            return
        case .schedule(let attempt, let delayNanoseconds):
            recoveryAwaitingConnectivityConfirmation.insert(id)
            scheduleRecovery(
                for: id,
                tunnelName: tunnel.name,
                attempt: attempt,
                delayNanoseconds: delayNanoseconds
            )
        case .cooldown:
            // 自动恢复的进度与冷却不写 lastError：lastError 只供新增/设置弹窗
            // 就地展示操作错误，后台写入无处展示，还会污染弹窗的错误判断。
            break
        }
    }

    private func scheduleRecovery(
        for id: String,
        tunnelName: String,
        attempt: Int,
        delayNanoseconds: UInt64
    ) {
        guard recoveryTasks[id] == nil else { return }
        let generation = (recoveryGenerations[id] ?? 0) &+ 1
        recoveryGenerations[id] = generation
        let sleep = healthSleep
        recoveryTasks[id] = Task { [weak self] in
            var nextAttempt = attempt
            var nextDelay = delayNanoseconds
            while !Task.isCancelled {
                do {
                    try await sleep(nextDelay)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                let outcome = await self.performAutomaticRecovery(
                    id: id,
                    tunnelName: tunnelName,
                    attempt: nextAttempt,
                    generation: generation
                )
                switch outcome {
                case .recovered, .cancelled:
                    self.clearRecoveryTask(for: id, generation: generation)
                    return
                case .retry(let code, let delayOverrideNanoseconds):
                    guard let retry = self.prepareAutomaticRetry(
                        id: id,
                        generation: generation,
                        failureCode: code,
                        delayOverrideNanoseconds: delayOverrideNanoseconds
                    ) else {
                        self.clearRecoveryTask(for: id, generation: generation)
                        return
                    }
                    nextAttempt = retry.attempt
                    nextDelay = retry.delayNanoseconds
                }
            }
            self?.clearRecoveryTask(for: id, generation: generation)
        }
    }

    private enum AutomaticRecoveryOutcome {
        case recovered
        case retry(code: String, delayOverrideNanoseconds: UInt64? = nil)
        case cancelled
    }

    private struct AutomaticRecoveryPreflightFailure: Error {
        let result: LaunchPreflightResult
    }

    private func prepareAutomaticRetry(
        id: String,
        generation: UInt,
        failureCode: String,
        delayOverrideNanoseconds: UInt64?
    ) -> (attempt: Int, delayNanoseconds: UInt64)? {
        guard !isShuttingDown,
              recoveryGenerations[id] == generation,
              let tunnel = tunnel(id: id),
              tunnel.keepAlive else { return nil }
        var state = healthRecoveryStates[id] ?? HealthRecoveryState()
        guard state.phase == .monitoring else { return nil }
        let action = state.confirmedFailure(
            delayOverrideNanoseconds: delayOverrideNanoseconds
        )
        healthRecoveryStates[id] = state
        guard case .schedule(let attempt, let delayNanoseconds) = action else { return nil }
        let seconds = delayNanoseconds / 1_000_000_000
        appEventLog.write("「\(tunnel.name)」自动恢复未完成（\(failureCode)），\(seconds) 秒后继续尝试")
        return (attempt, delayNanoseconds)
    }

    private func clearRecoveryTask(for id: String, generation: UInt) {
        if recoveryGenerations[id] == generation {
            recoveryTasks[id] = nil
        }
    }

    private func performAutomaticRecovery(
        id: String,
        tunnelName: String,
        attempt: Int,
        generation: UInt
    ) async -> AutomaticRecoveryOutcome {
        guard recoveryGenerations[id] == generation else { return .cancelled }
        guard let tunnel = tunnel(id: id), tunnel.keepAlive else { return .cancelled }
        let recoveryState = healthRecoveryStates[id]
        guard recoveryState?.phase == .monitoring,
              recoveryState?.recoveryAttempts == attempt else { return .cancelled }

        let rustCore = self.rustCore
        guard let statusReader = rustCore as? any RustHealthStatusReader else {
            return .retry(code: "status_capability_unavailable")
        }
        var currentStatus: TunnelStatus
        do {
            currentStatus = try await Task.detached(priority: .utility) {
                try statusReader.status(id: id)
            }.value
        } catch {
            // 仅对受控的 launchctl 超时使用已有运行态缓存；Rust stop
            // 仍会重新读取/核验目标 label 与完整进程身份。
            guard statusReader.isStatusQueryTimeout(error),
                  let cachedStatus = statuses[id],
                  isRunning(cachedStatus) else { return .retry(code: "status_unavailable") }
            currentStatus = cachedStatus
        }
        guard recoveryGenerations[id] == generation, !Task.isCancelled else { return .cancelled }
        guard (isRunning(currentStatus) || (recoveryState?.recoveryAttempts ?? 0) > 0) else {
            return .retry(code: "not_running")
        }
        guard !runtimeState.busyIDs.contains(id) else { return .retry(code: "operation_busy") }
        updateRuntime { $0.setStatus(currentStatus, for: id) }

        guard let operation = beginOperation(for: id, cancelsRecovery: false) else {
            return .retry(code: "operation_busy")
        }
        defer { endOperation(for: id, generation: operation) }

        do {
            var status: TunnelStatus
            if SSHCommand.isSSH(tunnel.command),
               preStartChecker.requiresAutomaticRecoveryQuiescence {
                guard let nextRustGeneration = beginRustOperation(for: id) else {
                    throw HealthRecoveryError.lifecycleUnavailable
                }
                let stoppedStatus = try await runRustOperation(id: id, generation: nextRustGeneration) {
                    try rustCore.stop(id: id, generation: nextRustGeneration)
                }
                var stopped = stoppedStatus == .notLoaded
                if !stopped {
                    // launchd 在 bootout 后可能短暂报告 SIGTERMed 等过渡状态；
                    // 只在有界重读确认 notLoaded 后才允许执行 ECS/start。
                    for retry in 0..<30 {
                        try Task.checkCancellation()
                        let settledStatus = try await Task.detached(priority: .utility) {
                            try statusReader.status(id: id)
                        }.value
                        if settledStatus == .notLoaded {
                            stopped = true
                            break
                        }
                        if retry < 29 {
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                }
                guard stopped,
                      !Task.isCancelled,
                      recoveryGenerations[id] == generation,
                      isCurrentOperation(id, generation: operation) else {
                    throw HealthRecoveryError.lifecycleUnavailable
                }
                updateRuntime { $0.setStatus(.notLoaded, for: id) }

                try await runCoordinatedRecoveryPreflight(tunnel: tunnel)
                guard !Task.isCancelled, recoveryGenerations[id] == generation else { return .cancelled }
                status = try await runRustOperation(id: id, generation: nextRustGeneration) {
                    try rustCore.start(id: id, generation: nextRustGeneration)
                }
            } else {
                try await runCoordinatedRecoveryPreflight(tunnel: tunnel)
                guard !Task.isCancelled, recoveryGenerations[id] == generation else { return .cancelled }
                guard let nextRustGeneration = beginRustOperation(for: id) else {
                    throw HealthRecoveryError.lifecycleUnavailable
                }
                status = try await runRustOperation(id: id, generation: nextRustGeneration) {
                    try rustCore.restart(id: id, generation: nextRustGeneration)
                }
            }
            if !isRunning(status) {
                // bootstrap/restart 后 launchd 可能先返回 xpcproxy 等过渡态；
                // 只有有界重读确认 running 才把恢复记为成功。
                for retry in 0..<30 {
                    try Task.checkCancellation()
                    let settledStatus = try await Task.detached(priority: .utility) {
                        try statusReader.status(id: id)
                    }.value
                    if isRunning(settledStatus) {
                        status = settledStatus
                        break
                    }
                    if retry < 29 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            guard isRunning(status),
                  recoveryGenerations[id] == generation,
                  isCurrentOperation(id, generation: operation),
                  !Task.isCancelled else {
                throw HealthRecoveryError.restartDidNotRun
            }
            updateRuntime { $0.setStatus(status, for: id) }
            if tunnel.probe != nil {
                lastMessage = "「\(tunnelName)」已启动，等待连接探针确认"
            } else {
                lastMessage = "「\(tunnelName)」已启动；未配置连接探针，继续监控运行异常"
            }
            return .recovered
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard recoveryGenerations[id] == generation, !Task.isCancelled else { return .cancelled }
            let failure = automaticRecoveryFailure(error)
            return .retry(
                code: failure.code,
                delayOverrideNanoseconds: failure.delayOverrideNanoseconds
            )
        }
    }

    private func runCoordinatedRecoveryPreflight(tunnel: TunnelConfig) async throws {
        guard SSHCommand.isSSH(tunnel.command),
              let resourceChecker = preStartChecker as? any LaunchPreflightChecking else {
            try await preStartChecker.checkAsync(tunnel: tunnel)
            return
        }
        let resource = try await resourceChecker.launchResource()
        try Task.checkCancellation()
        let result = try await recoveryPreflightCoordinator.run(resource: resource) {
            try await resourceChecker.checkLaunch(tunnel: tunnel, timeout: 30)
        }
        try Task.checkCancellation()
        if result.category == .cancelled {
            throw CancellationError()
        }
        guard result.exitCode == 0, result.category == .success else {
            throw AutomaticRecoveryPreflightFailure(result: result)
        }
    }

    private func automaticRecoveryFailure(
        _ error: Error
    ) -> (code: String, delayOverrideNanoseconds: UInt64?) {
        if let preflight = error as? AutomaticRecoveryPreflightFailure {
            let result = preflight.result
            let delaySeconds: Int
            if result.category == .auth {
                delaySeconds = 300
            } else if result.retryHint > 0 {
                delaySeconds = min(result.retryHint, 300)
            } else {
                delaySeconds = 0
            }
            let delay = delaySeconds > 0
                ? UInt64(delaySeconds) * 1_000_000_000
                : nil
            return (
                "ecs_\(result.category.rawValue)_\(result.sanitizedCode)",
                delay
            )
        }
        if error is ECSPreStartError { return ("ecs_preflight_failed", nil) }
        if error is ECSPreflightProcessError { return ("ecs_preflight_process_failed", nil) }
        if error is HealthRecoveryError { return ("lifecycle_unavailable", nil) }
        if let clientError = error as? RustCoreClient.ClientError,
           case .remote(let code, _) = clientError {
            return ("core_\(code)", nil)
        }
        return ("lifecycle_failed", nil)
    }

    private func cancelRecovery(for id: String) {
        recoveryGenerations[id] = (recoveryGenerations[id] ?? 0) &+ 1
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = nil
        launchdFailureObservations.removeValue(forKey: id)
        recoveryAwaitingConnectivityConfirmation.remove(id)
    }

    private func beginStateRead() -> StateReadToken {
        stateReadGeneration &+= 1
        return StateReadToken(
            readGeneration: stateReadGeneration,
            mutationGeneration: stateMutationGeneration
        )
    }

    private func isCurrentStateRead(_ token: StateReadToken) -> Bool {
        token.readGeneration == stateReadGeneration &&
            token.mutationGeneration == stateMutationGeneration
    }

    private func invalidateProbeResults() {
        probeGeneration &+= 1
        probeTask?.cancel()
        probeTask = nil
    }

    private func invalidateStateReads() {
        stateMutationGeneration &+= 1
        invalidateProbeResults()
    }

    private func resetHealthRecovery(for id: String, phase: HealthRecoveryState.Phase) {
        cancelRecovery(for: id)
        launchdFailureObservations.removeValue(forKey: id)
        var state = healthRecoveryStates[id] ?? HealthRecoveryState()
        switch phase {
        case .monitoring:
            state.manualStart()
        case .manuallyStopped:
            state.manualStop()
        }
        healthRecoveryStates[id] = state
    }

    private func isRunning(_ status: TunnelStatus?) -> Bool {
        guard case .running? = status else { return false }
        return true
    }

    /// 手动启动/重启后，launchd 可能先返回 xpcproxy 等过渡态。
    /// 只在本次生命周期操作仍有效时查询当前隧道，避免把瞬时状态永久留在 UI/API 缓存中。
    private func settleLifecycleStatus(
        id: String,
        initialStatus: TunnelStatus,
        operation: UInt
    ) async -> TunnelStatus {
        switch initialStatus {
        case .running, .notRunning:
            return initialStatus
        case .notLoaded, .other:
            break
        }

        guard let statusReader = rustCore as? any RustHealthStatusReader else {
            return initialStatus
        }

        var status = initialStatus
        for retry in 0..<Self.lifecycleStatusSettleAttempts {
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else {
                return status
            }
            do {
                status = try await Task.detached(priority: .utility) {
                    try statusReader.status(id: id)
                }.value
            } catch {
                return status
            }
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else {
                return status
            }
            updateRuntime { $0.setStatus(status, for: id) }
            if isRunning(status) {
                return status
            }
            if retry < Self.lifecycleStatusSettleAttempts - 1 {
                do {
                    try await Task.sleep(nanoseconds: Self.lifecycleStatusSettleDelayNanoseconds)
                } catch {
                    return status
                }
            }
        }
        return status
    }

    /// ECS 前置失败后，SSH 实例已被安全卸载，但恢复代次仍需沿用既有退避/熔断。
    /// 只有当前 ECS checker 明确要求 quiescence 且已有失败恢复代次时，才允许
    /// 停止态继续累计下一轮失败；手动停止或初始未运行隧道仍不会被自动拉起。
    private func canRetryQuiescedRecovery(
        for id: String,
        tunnel: TunnelConfig,
        state: HealthRecoveryState?
    ) -> Bool {
        guard SSHCommand.isSSH(tunnel.command),
              preStartChecker.requiresAutomaticRecoveryQuiescence else { return false }
        return (state?.recoveryAttempts ?? 0) > 0
    }

    /// 仅监控本次 App 启动时已经声明为无人值守的隧道。运行期间新增或把
    /// autoStart 从 false 改为 true 的配置，留到下次 App 启动再接管。
    private func unattendedRecoveryCandidates() -> [TunnelConfig] {
        let initial = launchInitialConfig ?? config
        let eligibleIDs = Set(initial.tunnels.filter {
            $0.autoStart && $0.keepAlive && SSHCommand.isSSH($0.command)
        }.map(\.id))
        return config.tunnels.filter {
            eligibleIDs.contains($0.id)
                && $0.autoStart
                && $0.keepAlive
                && SSHCommand.isSSH($0.command)
                && !manuallyStoppedIDs.contains($0.id)
        }
    }

    // MARK: - 启停

    public func start(_ id: String) {
        if launchRecoveryIDs.contains(id) {
            cancelLaunchRecovery(id)
            Task { _ = await startAsync(id) }
            return
        }
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.remove(id)
        resetHealthRecovery(for: id, phase: .monitoring)
        do {
            try preStartChecker.check(tunnel: tunnel)
            guard let rustGeneration = beginRustOperation(for: id) else { return }
            let status = try rustCore.start(id: id, generation: rustGeneration)
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已启动"
        } catch let error as ECSPreStartError {
            lastError = "启动「\(tunnel.name)」失败：\(error.errorDescription ?? "ECS 公网 IP 同步失败")"
        } catch {
            lastError = "启动「\(tunnel.name)」失败：\(error)"
        }
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行启动。
    @discardableResult
    public func startAsync(_ id: String) async -> TunnelOperationResult {
        await cancelLaunchRecoveryAndWait(id)
        guard let tunnel = tunnel(id: id) else { return .notFound }
        guard let operation = beginOperation(for: id) else { return .inProgress }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.remove(id)
        resetHealthRecovery(for: id, phase: .monitoring)

        let preStartChecker = self.preStartChecker
        let rustCore = self.rustCore
        do {
            try await preStartChecker.checkAsync(tunnel: tunnel)
            guard !Task.isCancelled else { return .failed }
            guard let rustGeneration = beginRustOperation(for: id) else { return .failed }
            let status = try await runRustOperation(id: id, generation: rustGeneration) {
                try rustCore.start(id: id, generation: rustGeneration)
            }
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return .failed }
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已启动"
            await refreshAsync()
            let settledStatus = await settleLifecycleStatus(
                id: id,
                initialStatus: status,
                operation: operation
            )
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return .failed }
            updateRuntime { $0.setStatus(settledStatus, for: id) }
            return .completed(status: settledStatus)
        } catch is CancellationError {
            return .failed
        } catch let error as ECSPreStartError {
            if isCurrentOperation(id, generation: operation) {
                lastError = "启动「\(tunnel.name)」失败：\(error.errorDescription ?? "ECS 公网 IP 同步失败")"
            }
            return .failed
        } catch {
            if isStaleRustOperation(error) { return .failed }
            lastError = "启动「\(tunnel.name)」失败：\(error)"
            return .failed
        }
    }

    public func stop(_ id: String) {
        if launchRecoveryIDs.contains(id) {
            cancelLaunchRecovery(id)
            Task { _ = await stopAsync(id) }
            return
        }
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.insert(id)
        resetHealthRecovery(for: id, phase: .manuallyStopped)
        guard let rustGeneration = beginRustOperation(for: id) else { return }
        do {
            let status = try rustCore.stop(id: id, generation: rustGeneration)
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已停止"
        } catch {
            lastError = "停止「\(tunnel.name)」失败：\(error)"
        }
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行停止。
    @discardableResult
    public func stopAsync(_ id: String) async -> TunnelOperationResult {
        await cancelLaunchRecoveryAndWait(id)
        guard let tunnel = tunnel(id: id) else { return .notFound }
        guard let operation = beginOperation(for: id) else { return .inProgress }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.insert(id)
        resetHealthRecovery(for: id, phase: .manuallyStopped)

        guard let rustGeneration = beginRustOperation(for: id) else { return .failed }
        let rustCore = self.rustCore
        do {
            let status = try await runRustOperation(id: id, generation: rustGeneration) {
                try rustCore.stop(id: id, generation: rustGeneration)
            }
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return .failed }
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已停止"
            await refreshAsync()
            return .completed(status: status)
        } catch is CancellationError {
            return .failed
        } catch {
            if isStaleRustOperation(error) { return .failed }
            lastError = "停止「\(tunnel.name)」失败：\(error)"
            return .failed
        }
    }

    public func restart(_ id: String) {
        if launchRecoveryIDs.contains(id) {
            cancelLaunchRecovery(id)
            Task { _ = await restartAsync(id) }
            return
        }
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.remove(id)
        resetHealthRecovery(for: id, phase: .monitoring)
        do {
            try preStartChecker.check(tunnel: tunnel)
            guard let rustGeneration = beginRustOperation(for: id) else { return }
            let status = try rustCore.restart(id: id, generation: rustGeneration)
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已重启"
        } catch let error as ECSPreStartError {
            lastError = "重启「\(tunnel.name)」失败：\(error.errorDescription ?? "ECS 公网 IP 同步失败")"
        } catch {
            lastError = "重启「\(tunnel.name)」失败：\(error)"
        }
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行重启。
    @discardableResult
    public func restartAsync(_ id: String) async -> TunnelOperationResult {
        await cancelLaunchRecoveryAndWait(id)
        guard let tunnel = tunnel(id: id) else { return .notFound }
        guard let operation = beginOperation(for: id) else { return .inProgress }
        defer { endOperation(for: id, generation: operation) }
        manuallyStoppedIDs.remove(id)
        resetHealthRecovery(for: id, phase: .monitoring)

        let preStartChecker = self.preStartChecker
        let rustCore = self.rustCore
        do {
            try await preStartChecker.checkAsync(tunnel: tunnel)
            guard !Task.isCancelled else { return .failed }
            guard let rustGeneration = beginRustOperation(for: id) else { return .failed }
            let status = try await runRustOperation(id: id, generation: rustGeneration) {
                try rustCore.restart(id: id, generation: rustGeneration)
            }
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return .failed }
            updateRuntime { $0.setStatus(status, for: id) }
            lastMessage = "「\(tunnel.name)」已重启"
            await refreshAsync()
            let settledStatus = await settleLifecycleStatus(
                id: id,
                initialStatus: status,
                operation: operation
            )
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return .failed }
            updateRuntime { $0.setStatus(settledStatus, for: id) }
            return .completed(status: settledStatus)
        } catch is CancellationError {
            return .failed
        } catch let error as ECSPreStartError {
            if isCurrentOperation(id, generation: operation) {
                lastError = "重启「\(tunnel.name)」失败：\(error.errorDescription ?? "ECS 公网 IP 同步失败")"
            }
            return .failed
        } catch {
            if isStaleRustOperation(error) { return .failed }
            lastError = "重启「\(tunnel.name)」失败：\(error)"
            return .failed
        }
    }

    /// 应用退出时由 Rust owner 统一停止全部受管 launchd 隧道并关闭 handle。
    @discardableResult
    public func shutdownAsync() async -> Bool {
        isShuttingDown = true
        launchSetupTask?.cancel()
        await launchSetupTask?.value
        await launchCoordinator?.shutdown()
        launchPendingIDs.removeAll()
        invalidateStateReads()
        probeTask?.cancel()
        healthMonitorTask?.cancel()
        launchdFailureMonitorTask?.cancel()
        let monitorTask = healthMonitorTask
        let launchdFailureTask = launchdFailureMonitorTask
        let pendingRecoveryTasks = Array(recoveryTasks.values)
        pendingRecoveryTasks.forEach { $0.cancel() }
        recoveryTasks.removeAll()
        await healthProbeCoordinator.cancel()
        await monitorTask?.value
        await launchdFailureTask?.value
        for task in pendingRecoveryTasks {
            await task.value
        }
        do {
            let rustCore = self.rustCore
            _ = try await Task.detached(priority: .userInitiated) {
                try rustCore.shutdown()
            }.value
        } catch is CancellationError {
            resumeAfterFailedShutdown()
            return false
        } catch {
            lastError = "Rust Core 退出清理失败：\(error)"
            resumeAfterFailedShutdown()
            return false
        }
        await logStore.shutdown()
        return true
    }

    /// 退出清理 fail-closed 时 App 不退出；恢复无人值守监测，让后续重试和
    /// 显式操作仍可继续，而不是把一次 launchctl 异常变成静默停机。
    private func resumeAfterFailedShutdown() {
        isShuttingDown = false
        launchSetupTask = nil
        launchCoordinator = nil
        startHealthMonitoring()
        startLaunchdFailureMonitoring()
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
        guard let operation = beginOperation(for: agent.label) else { return }
        defer { endOperation(for: agent.label, generation: operation) }

        let service = migrationService
        let outcome = await Task.detached(priority: .userInitiated) { () -> TakeoverOutcome in
            do {
                return TakeoverOutcome(success: try service.takeover(agent: agent), failureDescription: nil)
            } catch {
                return TakeoverOutcome(success: nil, failureDescription: String(describing: error))
            }
        }.value

        guard isCurrentOperation(agent.label, generation: operation), !Task.isCancelled else { return }

        if let success = outcome.success {
            config.tunnels.append(success.tunnel)
            do {
                try rustCore.saveConfig(config)
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

    private func updateRuntime(_ body: (inout TunnelRuntimeState) -> Void) {
        var next = runtimeState
        body(&next)
        if next.statuses != runtimeState.statuses || next.busyIDs != runtimeState.busyIDs {
            invalidateProbeResults()
        }
        for id in Array(next.probeResults.keys) {
            if !isRunning(next.statuses[id]) || next.busyIDs.contains(id)
                || next.statuses[id] != runtimeState.statuses[id] {
                next.setProbeResult(nil, for: id)
            }
        }
        guard next != runtimeState else { return }
        runtimeState = next
        if statuses != next.statuses { statuses = next.statuses }
        if probeResults != next.probeResults { probeResults = next.probeResults }
        if busyIDs != next.busyIDs { busyIDs = next.busyIDs }
    }

    private func syncLogStore() {
        let store = logStore
        let ids = config.tunnels.map(\.id)
        Task {
            await store.sync(tunnelIDs: ids)
        }
    }

    private func beginOperation(for id: String, cancelsRecovery: Bool = true) -> UInt? {
        if cancelsRecovery {
            cancelLaunchRecovery(id)
            cancelRecovery(for: id)
        }
        guard !runtimeState.busyIDs.contains(id) else { return nil }
        invalidateStateReads()
        let generation = (operationGenerations[id] ?? 0) &+ 1
        operationGenerations[id] = generation
        updateRuntime { $0.setBusy(true, for: id) }
        return generation
    }

    private func isCurrentOperation(_ id: String, generation: UInt) -> Bool {
        operationGenerations[id] == generation && runtimeState.busyIDs.contains(id)
    }

    private func endOperation(for id: String, generation: UInt) {
        guard operationGenerations[id] == generation else { return }
        updateRuntime { $0.setBusy(false, for: id) }
        rustOperationGenerations.removeValue(forKey: id)
        invalidateStateReads()
    }

    private func beginRustOperation(for id: String) -> UInt64? {
        do {
            let generation = try rustCore.beginOperation(id: id)
            rustOperationGenerations[id] = generation
            return generation
        } catch {
            lastError = "Rust Core 开始隧道操作失败：\(error)"
            return nil
        }
    }

    private func runRustOperation<T: Sendable>(
        id: String,
        generation: UInt64,
        body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try body()
            }.value
        }, onCancel: {
            try? rustCore.cancelOperation(id: id, generation: generation)
        })
    }

    private func applyStatusSnapshot(_ nextStatuses: [String: TunnelStatus]) {
        let busyStatuses = runtimeState.statuses.filter { runtimeState.busyIDs.contains($0.key) }
        let mergedStatuses = nextStatuses.merging(busyStatuses) { _, current in current }
        updateRuntime { $0.setStatuses(mergedStatuses) }
    }

    private func isStaleRustOperation(_ error: Error) -> Bool {
        guard let error = error as? RustCoreClient.ClientError else { return false }
        return error.isStaleOperation
    }
}
