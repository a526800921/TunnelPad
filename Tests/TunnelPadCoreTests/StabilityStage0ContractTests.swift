import XCTest
@testable import TunnelPadCore

/// 阶段 0 的行为契约 fixture。
///
/// 这些测试只冻结后续实现必须满足的输入/输出，不接入生产恢复逻辑，
/// 也不调用真实 launchctl、SSH、ECS 或用户隧道。
final class StabilityStage0ContractTests: XCTestCase {

    func testHealthRecoveryUsesThreeFailuresFixedBackoffAndStopsAfterTenthFailedAttempt() {
        var contract = HealthRecoveryContract()

        for attempt in 1...10 {
            XCTAssertEqual(
                contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: true),
                .observe
            )
            XCTAssertEqual(
                contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: true),
                .observe
            )
            XCTAssertEqual(
                contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: true),
                .scheduleRestart(attempt: attempt, delaySeconds: HealthRecoveryContract.backoff(for: attempt))
            )

            let stop = contract.finishRestart(success: false)
            if attempt == 10 {
                XCTAssertEqual(stop, .stopAndMonitor(attempt: 10))
            } else {
                XCTAssertEqual(stop, .observe)
            }
        }

        XCTAssertEqual(contract.state, .stoppedAfterRecovery)
        XCTAssertEqual(
            contract.record(.failed(reason: "still down"), status: .notRunning, keepAlive: true),
            .observe,
            "熔断停止后继续检测，但不能再次自动拉起"
        )
    }

    func testHealthRecoverySuccessClearsCountersAndKeepAliveFalseNeverSchedulesRecovery() {
        var contract = HealthRecoveryContract()

        XCTAssertEqual(
            contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: true),
            .observe
        )
        XCTAssertEqual(
            contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: true),
            .observe
        )
        XCTAssertEqual(
            contract.record(.satisfied(status: 200), status: .running(pid: 42), keepAlive: true),
            .observe
        )

        XCTAssertEqual(
            contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: false),
            .observe,
            "keepAlive=false 不进入自动恢复计数"
        )
        XCTAssertEqual(
            contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: false),
            .observe
        )
        XCTAssertEqual(
            contract.record(.failed(reason: "fixture"), status: .running(pid: 42), keepAlive: false),
            .observe
        )
        XCTAssertEqual(contract.recoveryAttempts, 0)
    }

    func testHealthRecoveryIsolatedPerTunnelAndManualStopCancelsPendingRecovery() {
        var first = HealthRecoveryContract()
        var second = HealthRecoveryContract()

        for _ in 0..<3 {
            _ = first.record(.failed(reason: "fixture"), status: .running(pid: 1), keepAlive: true)
        }
        XCTAssertEqual(first.recoveryAttempts, 1)
        XCTAssertEqual(second.recoveryAttempts, 0)

        first.manualStop()
        XCTAssertEqual(first.finishRestart(success: false), .observe)
        XCTAssertEqual(first.state, .manuallyStopped)

        for _ in 0..<3 {
            _ = second.record(.failed(reason: "fixture"), status: .running(pid: 2), keepAlive: true)
        }
        XCTAssertEqual(second.recoveryAttempts, 1)
        XCTAssertEqual(second.state, .running)
    }

    func testOperationGenerationRejectsLateResultsAfterCancellationAndNewOperation() {
        var gate = OperationGenerationContract()
        let oldGeneration = gate.begin()

        XCTAssertTrue(gate.cancel(oldGeneration))
        let newGeneration = gate.begin()

        XCTAssertFalse(gate.accepts(oldGeneration), "旧任务完成后不得回写当前隧道状态")
        XCTAssertTrue(gate.accepts(newGeneration))
        XCTAssertFalse(gate.cancel(oldGeneration), "重复取消旧代次不得影响新操作")
    }

    func testConfigReloadRetainsEffectiveConfigWhenCandidateIsInvalid() {
        let current = AppConfig(tunnels: [
            TunnelConfig(id: "keep", name: "Keep", command: ["/usr/bin/ssh", "-N"])
        ])
        var contract = ConfigReloadContract(effective: current)
        let replacement = AppConfig(tunnels: [
            TunnelConfig(id: "replacement", name: "Replacement", command: ["/usr/bin/ssh", "-N"])
        ])

        XCTAssertEqual(contract.reload(.valid(replacement)), .applied)
        XCTAssertEqual(contract.effective, replacement)
        XCTAssertEqual(contract.reload(.invalid), .retainedCurrent)
        XCTAssertEqual(contract.effective, replacement, "解析失败不能把当前有效配置裁剪成空配置")
    }

    func testECSRuntimeReconnectRequiresMatchingPublicSourcesAndSuccessfulSync() {
        let contract = ECSRuntimeSourceContract()

        XCTAssertEqual(
            contract.evaluate(.publicIPv4("203.0.113.10"), .publicIPv4("203.0.113.10"), syncSucceeded: true),
            .allowReconnect(ip: "203.0.113.10")
        )
        XCTAssertEqual(
            contract.evaluate(.publicIPv4("203.0.113.10"), .publicIPv4("198.51.100.8"), syncSucceeded: true),
            .failClosed
        )
        XCTAssertEqual(
            contract.evaluate(.privateIPv4, .publicIPv4("203.0.113.10"), syncSucceeded: true),
            .failClosed
        )
        XCTAssertEqual(
            contract.evaluate(.publicIPv4("203.0.113.10"), .publicIPv4("203.0.113.10"), syncSucceeded: false),
            .failClosed
        )
    }
}

private struct HealthRecoveryContract {
    enum Action: Equatable {
        case observe
        case scheduleRestart(attempt: Int, delaySeconds: Int)
        case stopAndMonitor(attempt: Int)
    }

    enum State: Equatable {
        case running
        case manuallyStopped
        case stoppedAfterRecovery
    }

    static let failureThreshold = 3
    static let maximumRecoveryAttempts = 10

    private(set) var state: State = .running
    private(set) var consecutiveFailures = 0
    private(set) var recoveryAttempts = 0

    static func backoff(for attempt: Int) -> Int {
        switch attempt {
        case 1: return 10
        case 2: return 30
        case 3: return 60
        default: return 300
        }
    }

    mutating func record(
        _ result: ProbeResult,
        status: TunnelStatus,
        keepAlive: Bool
    ) -> Action {
        guard state == .running else { return .observe }

        if case .satisfied = result {
            consecutiveFailures = 0
            recoveryAttempts = 0
            return .observe
        }

        guard keepAlive, case .running = status else { return .observe }
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failureThreshold else { return .observe }
        consecutiveFailures = 0

        guard recoveryAttempts < Self.maximumRecoveryAttempts else {
            state = .stoppedAfterRecovery
            return .stopAndMonitor(attempt: Self.maximumRecoveryAttempts)
        }

        recoveryAttempts += 1
        return .scheduleRestart(
            attempt: recoveryAttempts,
            delaySeconds: Self.backoff(for: recoveryAttempts)
        )
    }

    mutating func finishRestart(success: Bool) -> Action {
        guard state == .running else { return .observe }
        guard success else {
            if recoveryAttempts >= Self.maximumRecoveryAttempts {
                state = .stoppedAfterRecovery
                return .stopAndMonitor(attempt: recoveryAttempts)
            }
            return .observe
        }

        consecutiveFailures = 0
        recoveryAttempts = 0
        return .observe
    }

    mutating func manualStop() {
        state = .manuallyStopped
        consecutiveFailures = 0
    }
}

private struct OperationGenerationContract {
    private var nextGeneration: UInt64 = 0
    private var currentGeneration: UInt64?

    mutating func begin() -> UInt64 {
        nextGeneration &+= 1
        currentGeneration = nextGeneration
        return nextGeneration
    }

    mutating func cancel(_ generation: UInt64) -> Bool {
        guard currentGeneration == generation else { return false }
        currentGeneration = nil
        return true
    }

    func accepts(_ generation: UInt64) -> Bool {
        currentGeneration == generation
    }
}

private struct ConfigReloadContract {
    enum Candidate: Equatable {
        case valid(AppConfig)
        case invalid
    }

    enum Outcome: Equatable {
        case applied
        case retainedCurrent
    }

    private(set) var effective: AppConfig

    mutating func reload(_ candidate: Candidate) -> Outcome {
        switch candidate {
        case .valid(let config):
            effective = config
            return .applied
        case .invalid:
            return .retainedCurrent
        }
    }
}

private struct ECSRuntimeSourceContract {
    enum Source: Equatable {
        case publicIPv4(String)
        case privateIPv4
        case unavailable
    }

    enum Decision: Equatable {
        case allowReconnect(ip: String)
        case failClosed
    }

    func evaluate(_ first: Source, _ second: Source, syncSucceeded: Bool) -> Decision {
        guard case .publicIPv4(let firstIP) = first,
              case .publicIPv4(let secondIP) = second,
              firstIP == secondIP,
              syncSucceeded else {
            return .failClosed
        }
        return .allowReconnect(ip: firstIP)
    }
}
