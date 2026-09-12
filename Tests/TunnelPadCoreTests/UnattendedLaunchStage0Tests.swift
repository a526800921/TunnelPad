import XCTest
@testable import TunnelPadCore

/// 阶段 0 的旧 owner 测试夹具：新客户端对缺少严格能力的旧库保持关闭。
@MainActor
final class UnattendedLaunchStage0Tests: XCTestCase {
    func testBaselineNetworkRecoveryDoesNotRetryLaunchAfterVirtualDay() async throws {
        let paths = TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-stage0-\(UUID().uuidString)", isDirectory: true))
        let owner = LaunchStage0Owner()
        let checker = LaunchStage0Preflight()
        let clock = LaunchStage0Clock()
        let manager = TunnelManager(
            paths: paths, rustCore: owner, preStartChecker: checker,
            healthSleep: { try await clock.sleep($0) }
        )
        await manager.restoreAutoStartTunnels()
        XCTAssertEqual(checker.calls, 0)
        XCTAssertEqual(owner.starts, 0)
        try await waitForSleeper(clock)

        checker.setOnline()
        await clock.advance(by: 86_400_000_000_000)
        try await waitForSleeper(clock)
        await manager.refreshAsync()
        await manager.restoreAutoStartTunnels()

        XCTAssertEqual(checker.calls, 0, "旧 owner 无严格能力，网络恢复也不得退回宽松启动")
        XCTAssertEqual(owner.starts, 0)
        XCTAssertEqual(manager.statuses["boot"], .notLoaded)
        await manager.shutdownAsync()
        try FileManager.default.removeItem(at: paths.homeDirectory)
    }

    func testManualClockResumesOnlyDueWaitsAndSupportsCancellation() async throws {
        let clock = LaunchStage0Clock()
        let wait = Task { try await clock.sleep(10) }
        try await waitForSleeper(clock)
        await clock.advance(by: 9)
        let stillPending = await clock.pendingCount
        XCTAssertEqual(stillPending, 1)
        await clock.advance(by: 1)
        try await wait.value
        let next = Task { try await clock.sleep(10) }
        try await waitForSleeper(clock)
        next.cancel()
        do {
            try await next.value
            XCTFail("时钟等待取消应抛出 CancellationError")
        } catch is CancellationError {}
        let remaining = await clock.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    private func waitForSleeper(_ clock: LaunchStage0Clock) async throws {
        for _ in 0..<1_000 {
            if await clock.pendingCount > 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("测试时钟未收到等待者")
        throw CancellationError()
    }
}

/// 单调虚拟时钟；不执行真实网络等待，测试驱动 advance。
private actor LaunchStage0Clock {
    private var now: UInt64 = 0
    private var waiters: [UUID: (UInt64, CheckedContinuation<Void, Error>)] = [:]
    var pendingCount: Int { waiters.count }

    func sleep(_ delay: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (now + delay, continuation)
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func advance(by elapsed: UInt64) {
        now += elapsed
        let due = waiters.filter { $0.value.0 <= now }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
}

private final class LaunchStage0Preflight: ECSPreStartChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func setOnline() { lock.withLock { online = true } }
    func check(tunnel: TunnelConfig) throws {
        let ready = lock.withLock { count += 1; return online }
        if !ready { throw ECSPreStartError.timedOut }
    }
    func checkAsync(tunnel: TunnelConfig) async throws { try check(tunnel: tunnel) }
}

private final class LaunchStage0Owner: RustLifecycleOwner, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let config = AppConfig(tunnels: [
        TunnelConfig(id: "boot", name: "启动基线", command: ["/bin/true"], autoStart: true)
    ])
    var starts: Int { lock.withLock { count } }
    func loadConfig() throws -> AppConfig { config }
    func saveConfig(_ config: AppConfig) throws {}
    func beginOperation(id: String) throws -> UInt64 { 1 }
    func cancelOperation(id: String, generation: UInt64) throws {}
    func snapshot() throws -> RustCoreClient.Snapshot {
        RustCoreClient.Snapshot(config: config, statuses: ["boot": .notLoaded])
    }
    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.withLock { count += 1 }
        return .running(pid: nil)
    }
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus { .notLoaded }
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus { .running(pid: nil) }
    func remove(id: String, generation: UInt64?) throws {}
    func shutdown() throws -> Int { 0 }
}
