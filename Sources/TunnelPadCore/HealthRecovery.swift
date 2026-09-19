import Foundation

/// 阶段 1 固定的健康恢复策略；不暴露为 config.json 设置项。
struct HealthRecoveryPolicy: Sendable, Equatable {
    static let failureThreshold = 3
    /// 仅作为历史行为的回归测试刻度；不再是恢复耗尽上限。
    static let maximumRecoveryAttempts = 10
    static let monitorIntervalNanoseconds: UInt64 = 10_000_000_000

    static func backoffNanoseconds(for attempt: Int) -> UInt64 {
        switch attempt {
        case 1: return 10_000_000_000
        case 2: return 30_000_000_000
        case 3: return 60_000_000_000
        default: return 300_000_000_000
        }
    }
}

enum HealthRecoveryError: Error {
    case lifecycleUnavailable
    case restartDidNotRun
}

/// 单条隧道的健康恢复状态。状态只允许由 TunnelManager 在主 actor 上提交，
/// 自动恢复任务本身不能直接修改状态，避免迟到结果倒灌。
struct HealthRecoveryState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case monitoring
        case manuallyStopped
    }

    enum Action: Sendable, Equatable {
        case observe
        case schedule(attempt: Int, delayNanoseconds: UInt64)
        case cooldown(delayNanoseconds: UInt64)
    }

    private(set) var phase: Phase = .monitoring
    private(set) var consecutiveFailures = 0
    private(set) var recoveryAttempts = 0
    private(set) var cooldownUntilUptimeNanoseconds: UInt64?

    mutating func record(
        _ result: ProbeResult,
        status: TunnelStatus?,
        keepAlive: Bool,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Action {
        guard phase == .monitoring else { return .observe }

        if let cooldownUntil = cooldownUntilUptimeNanoseconds {
            if nowUptimeNanoseconds < cooldownUntil {
                if case .satisfied = result {
                    self.cooldownUntilUptimeNanoseconds = nil
                    consecutiveFailures = 0
                    recoveryAttempts = 0
                }
                return .observe
            }
            self.cooldownUntilUptimeNanoseconds = nil
        }

        guard keepAlive, Self.isRunning(status) else {
            consecutiveFailures = 0
            return .observe
        }

        if case .satisfied = result {
            consecutiveFailures = 0
            recoveryAttempts = 0
            return .observe
        }

        consecutiveFailures += 1
        guard consecutiveFailures >= HealthRecoveryPolicy.failureThreshold else {
            return .observe
        }
        consecutiveFailures = 0

        if recoveryAttempts < Int.max {
            recoveryAttempts += 1
        }
        return .schedule(
            attempt: recoveryAttempts,
            delayNanoseconds: HealthRecoveryPolicy.backoffNanoseconds(for: recoveryAttempts)
        )
    }

    /// launchd/PID/IP 漂移等已经确认的故障不再伪造三次探针失败。
    /// 该入口始终保留下一次恢复意图，尝试次数只用于计算有上限的退避，
    /// 不会因为达到历史 `maximumRecoveryAttempts` 而进入永久停止状态。
    mutating func confirmedFailure(delayOverrideNanoseconds: UInt64? = nil) -> Action {
        guard phase == .monitoring else { return .observe }
        consecutiveFailures = 0
        cooldownUntilUptimeNanoseconds = nil
        if recoveryAttempts < Int.max {
            recoveryAttempts += 1
        }
        let delay = delayOverrideNanoseconds
            ?? HealthRecoveryPolicy.backoffNanoseconds(for: recoveryAttempts)
        return .schedule(attempt: recoveryAttempts, delayNanoseconds: delay)
    }

    mutating func finishRecovery(
        success: Bool,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Action {
        guard phase == .monitoring else { return .observe }
        guard success else { return .observe }

        consecutiveFailures = 0
        recoveryAttempts = 0
        cooldownUntilUptimeNanoseconds = nil
        return .observe
    }

    mutating func manualStop() {
        phase = .manuallyStopped
        consecutiveFailures = 0
        cooldownUntilUptimeNanoseconds = nil
    }

    mutating func manualStart() {
        phase = .monitoring
        consecutiveFailures = 0
        recoveryAttempts = 0
        cooldownUntilUptimeNanoseconds = nil
    }

    private static func isRunning(_ status: TunnelStatus?) -> Bool {
        guard case .running? = status else { return false }
        return true
    }
}
