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

    private let store: any TunnelConfigRepository
    private let launchdRuntime: any LaunchdExecuting
    private let appRuntime: any AppExecuting
    private let lifecycleCoordinator: TunnelLifecycleCoordinator
    private let probeCoordinator: ProbeCoordinator
    private let rustCoreShadow: RustCoreShadow
    private let rustCore: RustCoreClient?
    private var runtimeState = TunnelRuntimeState()
    private var probeTask: Task<Void, Never>?
    private var probeGeneration: UInt = 0
    private var refreshGeneration: UInt = 0
    /// 每个隧道的操作代际：异步操作即使底层系统调用无法立即取消，
    /// 也不能在后续操作已经开始后把旧结果写回门面。
    private var operationGenerations: [String: UInt] = [:]

    public convenience init(
        paths: TunnelPaths,
        executor: LaunchCtlExecutor = LaunchCtlExecutor()
    ) {
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
            executor: executor,
            configRepository: ConfigStore(paths: paths),
            probeService: ProbeService(),
            rustCoreShadow: RustCoreShadow(),
            rustCore: rustCore
        )
    }

    init(
        paths: TunnelPaths,
        executor: LaunchCtlExecutor,
        configRepository: any TunnelConfigRepository,
        probeService: ProbeService,
        rustCoreShadow: RustCoreShadow = RustCoreShadow(),
        rustCore: RustCoreClient? = nil
    ) {
        self.paths = paths
        self.executor = executor
        let appExecutor = AppProcessExecutor(paths: paths)
        self.appExecutor = appExecutor
        self.rustCoreShadow = rustCoreShadow
        self.migrationService = MigrationService(paths: paths, executor: executor)
        self.store = configRepository
        self.launchdRuntime = executor
        self.appRuntime = appExecutor
        self.lifecycleCoordinator = TunnelLifecycleCoordinator(
            paths: paths,
            launchd: executor,
            app: appExecutor
        )
        self.probeCoordinator = ProbeCoordinator(service: probeService)
        self.rustCore = rustCore
        if let rustCore {
            do {
                self.config = try rustCore.loadConfig()
            } catch {
                self.config = AppConfig()
                self.lastError = String(describing: error)
            }
        } else {
            let loaded = store.load()
            self.config = loaded.config
            self.rustCoreShadow.validateConfig(self.config)
            if let recovered = loaded.recoveredFrom {
                self.lastMessage = "配置文件损坏，已留档 \(recovered.lastPathComponent)，已重建空配置"
            }
        }
    }

    public func tunnel(id: String) -> TunnelConfig? {
        config.tunnels.first { $0.id == id }
    }

    /// 手动编辑 config.json 后重新加载；丢弃已移除隧道的状态与探针缓存。
    public func reloadConfig() {
        if let rustCore {
            do {
                config = try rustCore.loadConfig()
                let validIDs = Set(config.tunnels.map(\.id))
                updateRuntime { $0.prune(to: validIDs) }
                lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
                refresh()
            } catch {
                lastError = "Rust Core 重新加载配置失败：\(error)"
            }
            return
        }
        let loaded = store.load()
        config = loaded.config
        let validIDs = Set(config.tunnels.map(\.id))
        updateRuntime { $0.prune(to: validIDs) }
        rustCoreShadow.validateConfig(config)
        if let recovered = loaded.recoveredFrom {
            lastMessage = "配置文件损坏，已留档 \(recovered.lastPathComponent)，已重建空配置"
        } else {
            lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
        }
        refresh()
    }

    /// 异步重新加载配置：文件读取在后台执行，完成后沿用同步入口的状态裁剪和提示语义。
    public func reloadConfigAsync() async {
        if let rustCore {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try rustCore.loadConfig()
                }.value
                guard !Task.isCancelled else { return }
                config = loaded
                let validIDs = Set(config.tunnels.map(\.id))
                updateRuntime { $0.prune(to: validIDs) }
                lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "Rust Core 重新加载配置失败：\(error)"
            }
            return
        }
        let snapshot = config
        let loaded = await Task.detached(priority: .utility) { [store] in
            store.load()
        }.value
        // 如果读取期间已有保存/删除操作提交了新内存态，丢弃这次旧磁盘快照，
        // 避免“重新加载”覆盖刚完成的用户编辑。
        guard snapshot == config, !Task.isCancelled else { return }
        config = loaded.config
        let validIDs = Set(config.tunnels.map(\.id))
        updateRuntime { $0.prune(to: validIDs) }
        rustCoreShadow.validateConfig(config)
        if let recovered = loaded.recoveredFrom {
            lastMessage = "配置文件损坏，已留档 \(recovered.lastPathComponent)，已重建空配置"
        } else {
            lastMessage = "已重新加载配置，共 \(config.tunnels.count) 条隧道"
        }
        await refreshAsync()
    }

    /// 保存对单条隧道的修改并持久化；切换执行器时先停掉旧执行器下的实例。
    /// 运行中的隧道继续沿用旧参数，直到下次重启。
    public func updateTunnel(_ tunnel: TunnelConfig) {
        guard !runtimeState.busyIDs.contains(tunnel.id) else { return }
        guard let index = config.tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        if let rustCore {
            guard tunnel.executor == .launchd else {
                lastError = "保存「\(tunnel.name)」失败：阶段 5 仅支持 launchd 执行器"
                return
            }
            let old = config.tunnels[index]
            config.tunnels[index] = tunnel
            do {
                try rustCore.saveConfig(config)
                if tunnel.probe == nil {
                    updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
                }
                lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
            } catch {
                config.tunnels[index] = old
                lastError = "保存配置失败：\(error)"
                return
            }
            refresh()
            return
        }
        let old = config.tunnels[index]
        config.tunnels[index] = tunnel

        if old.executor != tunnel.executor {
            switch old.executor {
            case .launchd:
                _ = try? launchdRuntime.bootout(label: old.launchdLabel)
            case .app:
                appRuntime.stop(old)
            }
        }
        do {
            try store.save(config)
            if tunnel.probe == nil {
                updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
            }
            lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
        } catch {
            config.tunnels[index] = old
            lastError = "保存配置失败：\(error)"
        }
        refresh()
    }

    /// 异步编辑入口：切换执行器时把旧实例的停止放到后台，避免设置窗口被最多 5 秒的
    /// app 进程收尾阻塞；保存格式、提示语和同步入口保持一致。
    public func updateTunnelAsync(_ tunnel: TunnelConfig) async {
        guard let operation = beginOperation(for: tunnel.id) else { return }
        defer { endOperation(for: tunnel.id, generation: operation) }
        guard let index = config.tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        if let rustCore {
            guard tunnel.executor == .launchd else {
                lastError = "保存「\(tunnel.name)」失败：阶段 5 仅支持 launchd 执行器"
                return
            }
            var nextConfig = config
            nextConfig.tunnels[index] = tunnel
            let configToSave = nextConfig
            do {
                try await Task.detached(priority: .utility) {
                    try rustCore.saveConfig(configToSave)
                }.value
                guard isCurrentOperation(tunnel.id, generation: operation), !Task.isCancelled else { return }
                config = nextConfig
                if tunnel.probe == nil {
                    updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
                }
                lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "保存配置失败：\(error)"
            }
            return
        }
        let old = config.tunnels[index]

        if old.executor != tunnel.executor {
            _ = await lifecycleCoordinator.stop(old)
            guard isCurrentOperation(tunnel.id, generation: operation), !Task.isCancelled else { return }
        }

        config.tunnels[index] = tunnel
        do {
            try store.save(config)
            if tunnel.probe == nil {
                updateRuntime { $0.setProbeResult(nil, for: tunnel.id) }
            }
            lastMessage = "已保存「\(tunnel.name)」的配置；运行中的隧道在下次重启后使用新参数"
        } catch {
            config.tunnels[index] = old
            lastError = "保存配置失败：\(error)"
            return
        }
        await refreshAsync()
    }

    /// 删除单条隧道：停止实例 → 清理生成的 plist/pidfile → 删除日志 → 从配置移除并落盘。
    /// 实例停止与配置写入失败即中断并保留配置；日志清理失败仅告警不中断。操作不可恢复。
    public func removeTunnel(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        if let rustCore {
            do {
                try rustCore.remove(id: id)
                config.tunnels.removeAll { $0.id == id }
                updateRuntime {
                    $0.setStatus(nil, for: id)
                    $0.setProbeResult(nil, for: id)
                }
                refresh()
            } catch {
                lastError = "删除「\(tunnel.name)」失败：\(error)"
            }
            return
        }

        switch tunnel.executor {
        case .launchd:
            if launchdRuntime.status(label: tunnel.launchdLabel) != .notLoaded {
                do {
                    try launchdRuntime.bootout(label: tunnel.launchdLabel)
                } catch {
                    lastError = "删除「\(tunnel.name)」失败：停止实例出错 \(error)"
                    return
                }
                if launchdRuntime.status(label: tunnel.launchdLabel) != .notLoaded {
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
            appRuntime.stop(tunnel)
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
        updateRuntime {
            $0.setStatus(nil, for: id)
            $0.setProbeResult(nil, for: id)
        }
        refresh()
    }

    /// 异步删除入口：先在后台停止实例，再回到门面完成配置/产物提交。
    /// 同步 removeTunnel 保留给兼容调用方；UI 使用此入口避免主线程等待进程退出。
    public func removeTunnelAsync(_ id: String) async {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        if let rustCore {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try rustCore.remove(id: id)
                }.value
                guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
                config.tunnels.removeAll { $0.id == id }
                updateRuntime {
                    $0.setStatus(nil, for: id)
                    $0.setProbeResult(nil, for: id)
                }
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "删除「\(tunnel.name)」失败：\(error)"
            }
            return
        }

        if let stopError = await lifecycleCoordinator.stopForDeletion(tunnel) {
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
            lastError = "删除「\(tunnel.name)」失败：停止实例出错 \(stopError)"
            return
        }
        guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
        if tunnel.executor == .launchd {
            let status = await lifecycleCoordinator.status(for: tunnel)
            guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
            if status != .notLoaded {
                lastError = "删除「\(tunnel.name)」失败：实例未成功停止"
                return
            }
        }

        let plistURL = paths.launchdPlistURL(for: tunnel)
        if tunnel.executor == .launchd, FileManager.default.fileExists(atPath: plistURL.path) {
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                lastError = "删除「\(tunnel.name)」失败：清理 plist 出错 \(error)"
                return
            }
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
        updateRuntime {
            $0.setStatus(nil, for: id)
            $0.setProbeResult(nil, for: id)
        }
        await refreshAsync()
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

        if let rustCore {
            guard tunnel.executor == .launchd else {
                lastError = "新增「\(tunnel.name)」失败：阶段 5 仅支持 launchd 执行器"
                return
            }
            var nextConfig = config
            nextConfig.tunnels.append(tunnel)
            do {
                try rustCore.saveConfig(nextConfig)
                config = nextConfig
            } catch {
                lastError = "新增「\(tunnel.name)」失败：\(error)"
                return
            }
            refresh()
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
        if let rustCore {
            do {
                let snapshot = try rustCore.snapshot()
                config = snapshot.config
                updateRuntime { $0.setStatuses(snapshot.statuses) }
            } catch {
                lastError = "Rust Core 刷新状态失败：\(error)"
            }
            runProbes()
            return
        }
        var nextStatuses = runtimeState.statuses
        for tunnel in config.tunnels {
            switch tunnel.executor {
            case .launchd:
                nextStatuses[tunnel.id] = launchdRuntime.status(label: tunnel.launchdLabel)
            case .app:
                nextStatuses[tunnel.id] = appRuntime.status(id: tunnel.id)
            }
        }
        // 避免状态未变化时重复发布，减少 SwiftUI 无意义的重建。
        if nextStatuses != runtimeState.statuses {
            updateRuntime { $0.setStatuses(nextStatuses) }
        }
        runProbes()
    }

    /// 异步状态刷新：系统查询在后台进行，完成后以同样的状态快照发布到 UI。
    public func refreshAsync() async {
        refreshGeneration &+= 1
        let currentGeneration = refreshGeneration
        if let rustCore {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try rustCore.snapshot()
                }.value
                guard currentGeneration == refreshGeneration, !Task.isCancelled else { return }
                config = snapshot.config
                updateRuntime { $0.setStatuses(snapshot.statuses) }
                runProbes()
            } catch is CancellationError {
                return
            } catch {
                lastError = "Rust Core 刷新状态失败：\(error)"
            }
            return
        }
        let snapshot = config.tunnels
        let nextStatuses = await lifecycleCoordinator.statuses(for: snapshot)
        guard currentGeneration == refreshGeneration, snapshot == config.tunnels else { return }
        let validIDs = Set(config.tunnels.map(\.id))
        updateRuntime { state in
            state.setStatuses(nextStatuses.filter { validIDs.contains($0.key) })
        }
        runProbes()
    }

    /// 异步执行配置了探针的隧道探测，完成后更新展示。
    private func runProbes() {
        let probes = config.tunnels.compactMap { tunnel -> (String, ProbeConfig)? in
            guard let probe = tunnel.probe else { return nil }
            return (tunnel.id, probe)
        }
        probeGeneration &+= 1
        let currentGeneration = probeGeneration
        probeTask?.cancel()
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
        let validProbes = Dictionary(uniqueKeysWithValues: config.tunnels.compactMap { tunnel -> (String, ProbeConfig)? in
            guard let probe = tunnel.probe else { return nil }
            return (tunnel.id, probe)
        })
        updateRuntime { state in
            for (id, result) in results {
                guard validProbes[id] != nil, state.probeResults[id] != result else { continue }
                state.setProbeResult(result, for: id)
            }
        }
    }

    // MARK: - 启停

    public func start(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        if let rustCore {
            do {
                let status = try rustCore.start(id: id)
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已启动"
            } catch {
                lastError = "启动「\(tunnel.name)」失败：\(error)"
            }
            return
        }
        let outcome = lifecycleCoordinator.startSync(tunnel)
        apply(outcome)
        if outcome.refresh { refresh() }
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行启动。
    public func startAsync(_ id: String) async {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        if let rustCore {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try rustCore.start(id: id)
                }.value
                guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已启动"
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "启动「\(tunnel.name)」失败：\(error)"
            }
            return
        }

        let outcome = await lifecycleCoordinator.start(tunnel)
        guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
        apply(outcome)
        if outcome.refresh { await refreshAsync() }
    }

    public func stop(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        if let rustCore {
            do {
                let status = try rustCore.stop(id: id)
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已停止"
            } catch {
                lastError = "停止「\(tunnel.name)」失败：\(error)"
            }
            return
        }
        apply(lifecycleCoordinator.stopSync(tunnel))
        refresh()
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行停止。
    public func stopAsync(_ id: String) async {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        if let rustCore {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try rustCore.stop(id: id)
                }.value
                guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已停止"
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "停止「\(tunnel.name)」失败：\(error)"
            }
            return
        }

        let outcome = await lifecycleCoordinator.stop(tunnel)
        guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
        apply(outcome)
        await refreshAsync()
    }

    public func restart(_ id: String) {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }
        if let rustCore {
            do {
                let status = try rustCore.restart(id: id)
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已重启"
            } catch {
                lastError = "重启「\(tunnel.name)」失败：\(error)"
            }
            return
        }
        apply(lifecycleCoordinator.restartSync(tunnel))
        refresh()
    }

    /// 异步兼容入口，供 UI 在不阻塞主线程的情况下执行重启。
    public func restartAsync(_ id: String) async {
        guard let tunnel = tunnel(id: id) else { return }
        guard let operation = beginOperation(for: id) else { return }
        defer { endOperation(for: id, generation: operation) }

        if let rustCore {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try rustCore.restart(id: id)
                }.value
                guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
                updateRuntime { $0.setStatus(status, for: id) }
                lastMessage = "「\(tunnel.name)」已重启"
                await refreshAsync()
            } catch is CancellationError {
                return
            } catch {
                lastError = "重启「\(tunnel.name)」失败：\(error)"
            }
            return
        }

        let outcome = await lifecycleCoordinator.restart(tunnel)
        guard isCurrentOperation(id, generation: operation), !Task.isCancelled else { return }
        apply(outcome)
        await refreshAsync()
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

    /// 应用退出时由 Rust owner 统一停止全部受管 launchd 隧道并关闭 handle。
    /// 注入 Swift 执行器的初始化仅供现有测试/迁移材料使用，不作为生产回退。
    public func shutdownAsync() async {
        probeTask?.cancel()
        if let rustCore {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try rustCore.shutdown()
                }.value
            } catch is CancellationError {
                return
            } catch {
                lastError = "Rust Core 退出清理失败：\(error)"
            }
            return
        }

        for tunnel in config.tunnels where tunnel.executor == .launchd {
            _ = await lifecycleCoordinator.stop(tunnel)
        }
        appExecutor.shutdownAll()
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

    private func updateRuntime(_ body: (inout TunnelRuntimeState) -> Void) {
        var next = runtimeState
        body(&next)
        guard next != runtimeState else { return }
        runtimeState = next
        if statuses != next.statuses { statuses = next.statuses }
        if probeResults != next.probeResults { probeResults = next.probeResults }
        if busyIDs != next.busyIDs { busyIDs = next.busyIDs }
    }

    private func beginOperation(for id: String) -> UInt? {
        guard !runtimeState.busyIDs.contains(id) else { return nil }
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
    }

    private func apply(_ outcome: TunnelOperationOutcome) {
        if let message = outcome.message { lastMessage = message }
        if let error = outcome.error { lastError = error }
    }
}
