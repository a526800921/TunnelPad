import Foundation
import XCTest
@testable import TunnelPadCore

final class StabilityStage2Tests: XCTestCase {

    @MainActor
    func testStartupReconcilesManagedStatusesWithoutPanel() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-startup-status",
            name: "Startup status",
            command: ["/usr/bin/ssh", "-N"]
        )
        let owner = Stage2RecordingOwner(config: AppConfig(tunnels: [tunnel]))
        let manager = makeManager(
            owner: owner,
            checker: Stage2PreStartChecker(outcome: .success, requiresQuiescence: true, order: Stage2OrderLog()),
            config: AppConfig(tunnels: [tunnel]),
            probes: Stage2ProbeSequence(failures: 0)
        )

        try await Self.waitUntil(timeout: 2) {
            owner.snapshotCallCount > 0
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.statuses[tunnel.id], .running(pid: 7))
        XCTAssertTrue(owner.lifecycleEvents.isEmpty, "启动状态发现不得依赖或触发生命周期操作")
        await manager.shutdownAsync()
    }

    @MainActor
    func testStartupSnapshotFailureDoesNotTriggerLifecycle() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-startup-failure",
            name: "Startup failure",
            command: ["/usr/bin/ssh", "-N"]
        )
        let owner = Stage2RecordingOwner(
            config: AppConfig(tunnels: [tunnel]),
            snapshotFails: true
        )
        let manager = makeManager(
            owner: owner,
            checker: Stage2PreStartChecker(outcome: .success, requiresQuiescence: true, order: Stage2OrderLog()),
            config: AppConfig(tunnels: [tunnel]),
            probes: Stage2ProbeSequence(failures: 0)
        )

        try await Self.waitUntil(timeout: 2) {
            owner.snapshotCallCount > 0
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(owner.lifecycleEvents.isEmpty, "状态未知时启动不得猜测性操作隧道")
        XCTAssertNil(manager.statuses[tunnel.id])
        await manager.shutdownAsync()
    }

    @MainActor
    func testLateHealthSnapshotCannotOverwriteManualStart() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-late-snapshot",
            name: "Late snapshot",
            command: ["/usr/bin/ssh", "-N"]
        )
        let owner = Stage2BlockingSnapshotOwner(
            config: AppConfig(tunnels: [tunnel]),
            firstSnapshotStatus: .notLoaded,
            subsequentSnapshotStatus: .running(pid: 42)
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage2-late-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: Stage2PreStartChecker(
                outcome: .success,
                requiresQuiescence: false,
                order: Stage2OrderLog()
            ),
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        try await Self.waitUntil(timeout: 2) {
            owner.snapshotCallCount > 0
        }
        manager.start(tunnel.id)
        owner.releaseFirstSnapshot()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(owner.startCount, 1)
        XCTAssertEqual(manager.statuses[tunnel.id], .running(pid: 42), "旧健康快照不得覆盖手动启动结果")
        await manager.shutdownAsync()
    }

    @MainActor
    func testLateHealthProbeCannotOverwriteManualStop() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-late-probe",
            name: "Late probe",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let owner = Stage2RecordingOwner(config: AppConfig(tunnels: [tunnel]), stopStatus: .notRunning)
        let probeGate = Stage2BlockingProbeGate()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage2-late-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: Stage2PreStartChecker(
                outcome: .success,
                requiresQuiescence: false,
                order: Stage2OrderLog()
            ),
            probeService: ProbeService { _ in
                try await probeGate.nextStatus()
            },
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { _ in
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        )

        try await Self.waitUntil(timeout: 2) {
            probeGate.started
        }
        manager.stop(tunnel.id)
        probeGate.releaseFirstProbe()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.statuses[tunnel.id], .notRunning)
        XCTAssertNil(manager.probeResults[tunnel.id], "旧健康探针结果不得在手动停止后写回")
        await manager.shutdownAsync()
    }

    @MainActor
    func testOlderSnapshotCannotOverrideNewerRefresh() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-snapshot-order",
            name: "Snapshot order",
            command: ["/usr/bin/ssh", "-N"]
        )
        let owner = Stage2BlockingSnapshotOwner(
            config: AppConfig(tunnels: [tunnel]),
            firstSnapshotStatus: .notLoaded,
            subsequentSnapshotStatus: .running(pid: 84)
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage2-snapshot-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: Stage2PreStartChecker(
                outcome: .success,
                requiresQuiescence: false,
                order: Stage2OrderLog()
            ),
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        try await Self.waitUntil(timeout: 2) {
            owner.snapshotCallCount > 0
        }
        await manager.refreshAsync()
        XCTAssertEqual(manager.statuses[tunnel.id], .running(pid: 84))

        owner.releaseFirstSnapshot()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.statuses[tunnel.id], .running(pid: 84), "较早健康快照不得覆盖较新的刷新结果")
        await manager.shutdownAsync()
    }

    @MainActor
    func testShutdownInvalidatesPendingHealthResults() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-shutdown-read",
            name: "Shutdown read",
            command: ["/usr/bin/ssh", "-N"]
        )
        let owner = Stage2BlockingSnapshotOwner(
            config: AppConfig(tunnels: [tunnel]),
            firstSnapshotStatus: .running(pid: 99)
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage2-shutdown-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: Stage2PreStartChecker(
                outcome: .success,
                requiresQuiescence: false,
                order: Stage2OrderLog()
            ),
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )

        try await Self.waitUntil(timeout: 2) {
            owner.snapshotCallCount > 0
        }
        let shutdownTask = Task { @MainActor in
            await manager.shutdownAsync()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        owner.releaseFirstSnapshot()
        await shutdownTask.value

        XCTAssertNil(manager.statuses[tunnel.id], "退出开始后的旧快照不得回写 UI")
    }

    @MainActor
    func testECSRecoveryStopsBeforePreflightAndStartsAfterSuccess() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-ecs-order",
            name: "ECS order",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let order = Stage2OrderLog()
        let owner = Stage2RecordingOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = Stage2PreStartChecker(outcome: .success, requiresQuiescence: true, order: order)
        let probes = Stage2ProbeSequence(failures: 3)
        let manager = makeManager(
            owner: owner,
            checker: checker,
            config: AppConfig(tunnels: [tunnel]),
            probes: probes
        )

        try await Self.waitUntil(timeout: 2) {
            owner.lifecycleEvents.contains("start")
        }

        XCTAssertEqual(order.values, ["stop", "preflight", "start"])
        XCTAssertEqual(owner.lifecycleEvents, ["stop", "start"])
        XCTAssertEqual(checker.asyncIDs, [tunnel.id])
        XCTAssertEqual(owner.lifecycleEvents.first, "stop")
        XCTAssertEqual(owner.lifecycleEvents.last, "start")
        XCTAssertNil(manager.lastError)
        await manager.shutdownAsync()
    }

    @MainActor
    func testECSRecoveryDoesNotStartWhenPreflightFails() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-ecs-failure",
            name: "ECS failure",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let order = Stage2OrderLog()
        let owner = Stage2RecordingOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = Stage2PreStartChecker(
            outcome: .failure(.commandFailed(exitCode: 5)),
            requiresQuiescence: true,
            order: order
        )
        let manager = makeManager(
            owner: owner,
            checker: checker,
            config: AppConfig(tunnels: [tunnel]),
            probes: Stage2ProbeSequence(failures: 3)
        )

        try await Self.waitUntil(timeout: 2) {
            checker.asyncIDs.count >= 1
        }

        XCTAssertEqual(order.values, ["stop", "preflight"])
        XCTAssertEqual(owner.lifecycleEvents, ["stop"])
        XCTAssertEqual(checker.asyncIDs, [tunnel.id])
        XCTAssertTrue(manager.lastError?.contains("第 1/10 次失败") == true)
        await manager.shutdownAsync()
    }

    @MainActor
    func testECSPreflightFailureKeepsBoundedRecoveryAttempts() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-ecs-retry",
            name: "ECS retry",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let order = Stage2OrderLog()
        let probes = Stage2ProbeSequence(failures: 3, failUntilReleased: true)
        let owner = Stage2RecordingOwner(
            config: AppConfig(tunnels: [tunnel]),
            order: order,
            onStart: probes.release
        )
        let checker = Stage2PreStartChecker(
            outcomes: [.failure(.commandFailed(exitCode: 5)), .success],
            requiresQuiescence: true,
            order: order
        )
        let manager = makeManager(
            owner: owner,
            checker: checker,
            config: AppConfig(tunnels: [tunnel]),
            probes: probes
        )

        try await Self.waitUntil(timeout: 2) {
            owner.lifecycleEvents.contains("start")
        }

        XCTAssertEqual(
            order.values,
            ["stop", "preflight", "stop", "preflight", "start"],
            "第一次同步失败后应沿用下一次有界恢复，而不是因 notLoaded 截断"
        )
        XCTAssertEqual(checker.asyncIDs, [tunnel.id, tunnel.id])
        XCTAssertEqual(manager.lastMessage, "「ECS retry」已自动恢复")
        await manager.shutdownAsync()
    }

    @MainActor
    func testECSRecoveryRequiresNotLoadedStopBeforePreflight() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-ecs-not-quiesced",
            name: "ECS not quiesced",
            command: ["/usr/bin/ssh", "-N"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let order = Stage2OrderLog()
        let owner = Stage2RecordingOwner(
            config: AppConfig(tunnels: [tunnel]),
            order: order,
            stopStatus: .notRunning
        )
        let checker = Stage2PreStartChecker(outcome: .success, requiresQuiescence: true, order: order)
        let manager = makeManager(
            owner: owner,
            checker: checker,
            config: AppConfig(tunnels: [tunnel]),
            probes: Stage2ProbeSequence(failures: 3)
        )

        try await Self.waitUntil(timeout: 2) {
            owner.lifecycleEvents.contains("stop")
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(order.values, ["stop"])
        XCTAssertEqual(owner.lifecycleEvents, ["stop"])
        XCTAssertTrue(checker.asyncIDs.isEmpty, "未确认 notLoaded 时不得运行 ECS 前置")
        XCTAssertTrue(owner.events.filter { $0 == "start" || $0 == "restart" }.isEmpty)
        await manager.shutdownAsync()
    }

    @MainActor
    func testNonSSHAutomaticRecoveryKeepsRestartPath() async throws {
        let tunnel = TunnelConfig(
            id: "stage2-non-ssh",
            name: "Non SSH",
            command: ["/bin/echo", "hello"],
            probe: ProbeConfig(url: "http://fixture.invalid/health")
        )
        let order = Stage2OrderLog()
        let owner = Stage2RecordingOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = Stage2PreStartChecker(outcome: .success, requiresQuiescence: true, order: order)
        let manager = makeManager(
            owner: owner,
            checker: checker,
            config: AppConfig(tunnels: [tunnel]),
            probes: Stage2ProbeSequence(failures: 3)
        )

        try await Self.waitUntil(timeout: 2) {
            owner.lifecycleEvents.contains("restart")
        }

        XCTAssertEqual(order.values, ["restart"])
        XCTAssertEqual(owner.lifecycleEvents, ["restart"])
        XCTAssertTrue(checker.asyncIDs.isEmpty, "非 SSH 隧道不应运行 ECS 前置")
        await manager.shutdownAsync()
    }

    @MainActor
    private func makeManager(
        owner: Stage2RecordingOwner,
        checker: Stage2PreStartChecker,
        config: AppConfig,
        probes: Stage2ProbeSequence
    ) -> TunnelManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-stability-stage2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = ProbeService { _ in
            try await probes.nextStatus()
        }
        return TunnelManager(
            paths: TunnelPaths(homeDirectory: home),
            rustCore: owner,
            preStartChecker: checker,
            probeService: service,
            healthMonitorIntervalNanoseconds: 1_000_000,
            healthSleep: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "等待阶段 2 恢复 fixture 超时")
    }
}

private enum Stage2OwnerError: Error, Sendable {
    case snapshotFailed
}

private final class Stage2OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func append(_ value: String) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }
}

private final class Stage2ProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var failUntilReleased: Bool

    init(failures: Int, failUntilReleased: Bool = false) {
        remainingFailures = failures
        self.failUntilReleased = failUntilReleased
    }

    func nextStatus() async throws -> Int {
        if consumeFailure() {
            throw URLError(.cannotConnectToHost)
        }
        return 200
    }

    func release() {
        lock.lock()
        failUntilReleased = false
        lock.unlock()
    }

    private func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if remainingFailures > 0 {
            remainingFailures -= 1
            return true
        }
        return failUntilReleased
    }
}

private final class Stage2PreStartChecker: ECSPreStartChecking, @unchecked Sendable {
    enum Outcome: Sendable {
        case success
        case failure(ECSPreStartError)
    }

    let requiresAutomaticRecoveryQuiescence: Bool
    private var outcomes: [Outcome]
    private let order: Stage2OrderLog
    private let lock = NSLock()
    private(set) var asyncIDs: [String] = []

    init(outcome: Outcome, requiresQuiescence: Bool, order: Stage2OrderLog) {
        self.outcomes = [outcome]
        requiresAutomaticRecoveryQuiescence = requiresQuiescence
        self.order = order
    }

    init(outcomes: [Outcome], requiresQuiescence: Bool, order: Stage2OrderLog) {
        self.outcomes = outcomes
        requiresAutomaticRecoveryQuiescence = requiresQuiescence
        self.order = order
    }

    func check(tunnel: TunnelConfig) throws {
        try resolve(tunnel: tunnel)
    }

    func checkAsync(tunnel: TunnelConfig) async throws {
        guard SSHCommand.isSSH(tunnel.command) else { return }
        order.append("preflight")
        recordAsyncID(tunnel.id)
        try resolve(tunnel: tunnel)
    }

    private func recordAsyncID(_ id: String) {
        lock.lock()
        asyncIDs.append(id)
        lock.unlock()
    }

    private func resolve(tunnel: TunnelConfig) throws {
        guard SSHCommand.isSSH(tunnel.command) else { return }
        switch nextOutcome() {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func nextOutcome() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if outcomes.count > 1 {
            return outcomes.removeFirst()
        }
        return outcomes.first ?? .success
    }
}

private final class Stage2RecordingOwner: RustLifecycleOwner, @unchecked Sendable {
    private let configuration: AppConfig
    private let order: Stage2OrderLog?
    private let onStart: (@Sendable () -> Void)?
    private let snapshotFails: Bool
    private let lock = NSLock()
    private(set) var events: [String] = []
    private let stopStatus: TunnelStatus
    private var currentStatus: TunnelStatus = .running(pid: 7)

    init(
        config: AppConfig,
        order: Stage2OrderLog? = nil,
        stopStatus: TunnelStatus = .notLoaded,
        snapshotFails: Bool = false,
        onStart: (@Sendable () -> Void)? = nil
    ) {
        configuration = config
        self.order = order
        self.stopStatus = stopStatus
        self.snapshotFails = snapshotFails
        self.onStart = onStart
    }

    var lifecycleEvents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { ["stop", "start", "restart"].contains($0) }
    }

    var snapshotCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == "snapshot" }.count
    }

    func loadConfig() throws -> AppConfig { configuration }
    func saveConfig(_ config: AppConfig) throws { record("saveConfig") }

    func beginOperation(id: String) throws -> UInt64 {
        lock.lock()
        let generation = UInt64(events.count)
        lock.unlock()
        record("beginOperation")
        return generation
    }

    func cancelOperation(id: String, generation: UInt64) throws {
        record("cancelOperation")
    }

    func snapshot() throws -> RustCoreClient.Snapshot {
        record("snapshot")
        if snapshotFails {
            throw Stage2OwnerError.snapshotFailed
        }
        lock.lock()
        let status = currentStatus
        lock.unlock()
        let statuses = Dictionary(uniqueKeysWithValues: configuration.tunnels.map {
            ($0.id, status)
        })
        return RustCoreClient.Snapshot(config: configuration, statuses: statuses)
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("start")
        lock.lock()
        currentStatus = .running(pid: 7)
        lock.unlock()
        onStart?()
        return .running(pid: 7)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("stop")
        lock.lock()
        currentStatus = stopStatus
        lock.unlock()
        return stopStatus
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("restart")
        lock.lock()
        currentStatus = .running(pid: 7)
        lock.unlock()
        return .running(pid: 7)
    }

    func remove(id: String, generation: UInt64?) throws {
        record("remove")
    }

    func shutdown() throws -> Int {
        record("shutdown")
        return 0
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
        if ["stop", "start", "restart"].contains(event) {
            order?.append(event)
        }
    }
}

private final class Stage2BlockingSnapshotOwner: RustLifecycleOwner, @unchecked Sendable {
    private let configuration: AppConfig
    private let firstSnapshotStatus: TunnelStatus
    private let subsequentSnapshotStatus: TunnelStatus
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var snapshotCount = 0
    private var currentStatus: TunnelStatus = .notLoaded
    private var starts = 0

    init(
        config: AppConfig,
        firstSnapshotStatus: TunnelStatus,
        subsequentSnapshotStatus: TunnelStatus = .notLoaded
    ) {
        configuration = config
        self.firstSnapshotStatus = firstSnapshotStatus
        self.subsequentSnapshotStatus = subsequentSnapshotStatus
    }

    var snapshotCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotCount
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func loadConfig() throws -> AppConfig { configuration }
    func saveConfig(_ config: AppConfig) throws {}
    func beginOperation(id: String) throws -> UInt64 { 1 }
    func cancelOperation(id: String, generation: UInt64) throws {}

    func snapshot() throws -> RustCoreClient.Snapshot {
        lock.lock()
        let isFirst = snapshotCount == 0
        snapshotCount += 1
        let status = isFirst ? firstSnapshotStatus : subsequentSnapshotStatus
        lock.unlock()
        if isFirst {
            releaseGate.wait()
        }
        return RustCoreClient.Snapshot(
            config: configuration,
            statuses: Dictionary(uniqueKeysWithValues: configuration.tunnels.map { ($0.id, status) })
        )
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.lock()
        starts += 1
        currentStatus = .running(pid: 42)
        lock.unlock()
        return .running(pid: 42)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.lock()
        currentStatus = .notRunning
        lock.unlock()
        return .notRunning
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        try start(id: id, generation: generation)
    }

    func remove(id: String, generation: UInt64?) throws {}
    func shutdown() throws -> Int { 0 }

    func releaseFirstSnapshot() {
        releaseGate.signal()
    }
}

private final class Stage2BlockingProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isFirst = true
    private var didStart = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func nextStatus() async throws -> Int {
        let first = takeFirst()
        if first {
            await waitForRelease()
        }
        return 200
    }

    func releaseFirstProbe() {
        lock.lock()
        isReleased = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func takeFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = isFirst
        isFirst = false
        if first {
            didStart = true
        }
        return first
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
