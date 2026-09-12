import Foundation

/// 单调时间是策略的一部分；测试驱动同一协调器而不是复制重试算法。
struct LaunchRecoveryClock: Sendable {
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async throws -> Void
    static let continuous: Self = {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: {
            let duration = origin.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }, sleep: { try await clock.sleep(for: .seconds(max(0, $0))) })
    }()
}

enum LaunchRecoveryCategory: String, Codable, Sendable {
    case transient, auth, local, unknown, cancelled, success
}

struct LaunchPreflightResult: Codable, Sendable {
    let version: Int
    let stage: String
    let category: LaunchRecoveryCategory
    let retryHint: Int
    let sanitizedCode: String
    let exitCode: Int
}

enum LaunchRecoveryOutcome: Sendable {
    case running(TunnelStatus)
    case retry(LaunchRecoveryCategory)
    case cancelled
}

/// 容量与所有权集中在 MainActor。取消后 active 项保留到后端清理实际完成。
@MainActor
final class LaunchRecoveryCoordinator {
    struct Candidate: Sendable {
        let tunnel: TunnelConfig
        let resource: String?
    }
    private struct Entry {
        let candidate: Candidate
        let order: Int
        var due: TimeInterval
        var failures = 0
        var cancelled = false
        var lastCategory: LaunchRecoveryCategory?
        var lastLog: TimeInterval = -.infinity
    }
    typealias Attempt = @MainActor @Sendable (TunnelConfig) async -> LaunchRecoveryOutcome
    private let clock: LaunchRecoveryClock
    private let attempt: Attempt
    private let handoff: @MainActor (TunnelConfig, TunnelStatus) -> Void
    private let report: @MainActor (TunnelConfig, LaunchRecoveryCategory, Int) -> Void
    private var entries: [String: Entry] = [:]
    private var active: [String: Task<Void, Never>] = [:]
    private var heldResources: Set<String> = []
    private var cooldowns: [String: TimeInterval] = [:]
    private var wake: Task<Void, Never>?
    private var stopped = false
    private(set) var firstPassIDs: Set<String> = []
    var ownedIDs: Set<String> { Set(entries.keys) }
    var activeCount: Int { active.count }

    init(clock: LaunchRecoveryClock = .continuous, attempt: @escaping Attempt,
         handoff: @escaping @MainActor (TunnelConfig, TunnelStatus) -> Void,
         report: @escaping @MainActor (TunnelConfig, LaunchRecoveryCategory, Int) -> Void) {
        self.clock = clock; self.attempt = attempt; self.handoff = handoff; self.report = report
    }
    deinit { wake?.cancel(); active.values.forEach { $0.cancel() } }

    func start(_ candidates: [Candidate]) {
        guard entries.isEmpty, !stopped else { return }
        for (index, candidate) in candidates.enumerated() {
            entries[candidate.tunnel.id] = Entry(candidate: candidate, order: index, due: clock.now())
        }
        pump()
    }
    func cancel(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.cancelled = true
        if let task = active[id] { entries[id] = entry; task.cancel() }
        else { entries.removeValue(forKey: id) }
        pump()
    }
    func waitForActive(_ id: String) async { await active[id]?.value }
    func cancelAndWait(_ id: String) async {
        let task = active[id]
        cancel(id)
        await task?.value
    }
    func shutdown() async {
        stopped = true; wake?.cancel(); wake = nil
        let tasks = Array(active.values)
        for id in Array(entries.keys) { cancel(id) }
        for task in tasks { await task.value }
    }
    private func pump() {
        wake?.cancel(); wake = nil
        guard !stopped else { return }
        let now = clock.now()
        let waiting = entries.values.filter { !$0.cancelled && active[$0.candidate.tunnel.id] == nil }
            .sorted { ($0.due, $0.order) < ($1.due, $1.order) }
        for entry in waiting {
            guard active.count < 2 else { break }
            let id = entry.candidate.tunnel.id
            if let resource = entry.candidate.resource,
               heldResources.contains(resource) || (cooldowns[resource] ?? 0) > now { continue }
            guard entry.due <= now else { continue }
            if let resource = entry.candidate.resource { heldResources.insert(resource) }
            let attempt = self.attempt
            active[id] = Task { [weak self] in
                let result = await attempt(entry.candidate.tunnel)
                self?.finished(id, result: Task.isCancelled ? .cancelled : result)
            }
        }
        // Occupied resources wait for completion events, not a polling timer/global slot.
        guard active.count < 2 else { return }
        let next = entries.values.filter { !$0.cancelled && active[$0.candidate.tunnel.id] == nil && !heldResources.contains($0.candidate.resource ?? "") }
            .map { max($0.due, cooldowns[$0.candidate.resource ?? ""] ?? 0) }.min()
        if let next {
            let clock = self.clock
            wake = Task { [weak self] in
                do { try await clock.sleep(max(0, next - clock.now())); try Task.checkCancellation() }
                catch { return }
                self?.pump()
            }
        }
    }
    private func finished(_ id: String, result: LaunchRecoveryOutcome) {
        active.removeValue(forKey: id)
        guard var entry = entries[id] else { return }
        if let resource = entry.candidate.resource { heldResources.remove(resource) }
        firstPassIDs.insert(id)
        if entry.cancelled || stopped {
            entries.removeValue(forKey: id); pump(); return
        }
        switch result {
        case .running(let status):
            guard case .running(let pid) = status, let pid, pid > 0 else {
                finishedRetry(id, entry: entry, category: .unknown); return
            }
            entries.removeValue(forKey: id)
            handoff(entry.candidate.tunnel, status)
        case .retry(let category):
            finishedRetry(id, entry: entry, category: category); return
        case .cancelled:
            entry.cancelled = true; entries.removeValue(forKey: id)
        }
        pump()
    }
    private func finishedRetry(_ id: String, entry initial: Entry, category: LaunchRecoveryCategory) {
        var entry = initial
        entry.failures += 1
        let delay: TimeInterval
        switch category {
        case .auth: delay = 1800
        case .local, .unknown: delay = 300
        default: delay = [5.0, 15, 30, 60, 300][min(entry.failures - 1, 4)]
        }
        entry.due = clock.now() + delay
        if category == .auth, let resource = entry.candidate.resource { cooldowns[resource] = entry.due }
        if entry.lastCategory != category || clock.now() - entry.lastLog >= 1800 {
            report(entry.candidate.tunnel, category, entry.failures)
            entry.lastCategory = category; entry.lastLog = clock.now()
        }
        entries[id] = entry
        pump()
    }
}

protocol RustLaunchRecoveryOwner: RustLifecycleOwner {
    func supportsLaunchRecovery() throws -> Bool
    func beginLaunchRecovery(id: String) throws -> UInt64?
    func launchRecoveryStatus(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus?
    func launchRecoveryStart(tunnel: TunnelConfig, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus?
    func launchRecoveryStop(id: String, generation: UInt64, timeout: TimeInterval) throws -> TunnelStatus?
}

extension TunnelConfig {
    /// 显示字段不改变本次启动资格；运行字段变化必须失效候选。
    func matchesLaunchRuntime(_ other: TunnelConfig) -> Bool {
        id == other.id && command == other.command && executor == other.executor && keepAlive == other.keepAlive
            && throttleInterval == other.throttleInterval && probe == other.probe && autoStart == other.autoStart
    }
}
