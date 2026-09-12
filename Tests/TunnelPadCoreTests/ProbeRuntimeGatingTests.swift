import Foundation
import XCTest
@testable import TunnelPadCore

final class ProbeRuntimeGatingTests: XCTestCase {
    @MainActor
    func testStoppedTunnelSharingHealthyEndpointNeverProbes() async throws {
        let owner = ProbeGateOwner(statuses: ["stopped": .notLoaded, "running": .running(pid: 7)])
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        try await wait { manager.probeResults["running"] == .satisfied(status: 401) }
        await manager.refreshAsync()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.probeResults["stopped"])
        await manager.shutdownAsync()
    }

    @MainActor
    func testStoppedAndUnknownTunnelsSendNoHTTP() async throws {
        let owner = ProbeGateOwner(statuses: ["stopped": .notLoaded, "unknown": .running(pid: 7)])
        owner.setStatus(nil, id: "unknown")
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        await manager.refreshAsync()
        try await Task.sleep(for: .milliseconds(100))
        let count = await calls.count()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(manager.probeResults.isEmpty)
        await manager.shutdownAsync()
    }

    @MainActor
    func testStoppingClearsExistingResultAndRejectsLateResponse() async throws {
        let owner = ProbeGateOwner(statuses: ["running": .running(pid: 7)])
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        try await wait { manager.probeResults["running"] != nil }
        await calls.block()
        await manager.refreshAsync()
        try await waitAsync { await calls.hasPending() }
        _ = await manager.stopAsync("running")
        XCTAssertNil(manager.probeResults["running"])
        await calls.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.statuses["running"], .notLoaded)
        XCTAssertNil(manager.probeResults["running"])
        await manager.shutdownAsync()
    }

    @MainActor
    func testHealthyCyclesRefreshPIDAndObserveExternalStop() async throws {
        let owner = ProbeGateOwner(statuses: ["running": .running(pid: 7)])
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        try await wait { manager.probeResults["running"] != nil }
        owner.setStatus(.running(pid: 99), id: "running")
        try await wait { manager.statuses["running"] == .running(pid: 99) }
        owner.setStatus(.notLoaded, id: "running")
        try await wait { manager.statuses["running"] == .notLoaded }
        let count = await calls.count()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.probeResults["running"])
        let finalCount = await calls.count()
        XCTAssertEqual(count, finalCount)
        await manager.shutdownAsync()
    }

    @MainActor
    func testUnknownStatusClearsGreenAndSuspendsHTTP() async throws {
        let owner = ProbeGateOwner(statuses: ["running": .running(pid: 7)])
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        try await wait { manager.probeResults["running"] != nil }
        owner.setStatus(nil, id: "running")
        try await wait { manager.probeResults["running"] == nil }
        let count = await calls.count()
        try await Task.sleep(for: .milliseconds(50))
        let finalCount = await calls.count()
        XCTAssertEqual(count, finalCount)
        await manager.shutdownAsync()
    }

    @MainActor
    func testConfigurationChangeClearsResultAndRejectsOldURLResponse() async throws {
        let owner = ProbeGateOwner(statuses: ["running": .running(pid: 7)])
        let calls = ProbeGateCalls()
        let manager = makeManager(owner, calls: calls)
        try await wait { manager.probeResults["running"] != nil }
        await calls.block()
        await manager.refreshAsync()
        try await waitAsync { await calls.hasPending() }
        var tunnel = try XCTUnwrap(manager.config.tunnels.first)
        tunnel.probe = nil
        let saved = await manager.updateTunnelAsync(tunnel)
        XCTAssertTrue(saved)
        XCTAssertNil(manager.probeResults["running"])
        await calls.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.probeResults["running"])
        await manager.shutdownAsync()
    }

    @MainActor
    func testFailedRefreshClearsResultsAndRejectsLateHTTPForBothEntrypoints() async throws {
        for asynchronous in [false, true] {
            let owner = ProbeGateOwner(statuses: ["running": .running(pid: 7)])
            let calls = ProbeGateCalls()
            let manager = makeManager(owner, calls: calls, interval: 60_000_000_000)
            try await wait { manager.probeResults["running"] != nil }
            await calls.block()
            await manager.refreshAsync()
            try await waitAsync { await calls.hasPending() }
            owner.failSnapshots()
            let before = await calls.count()
            if asynchronous { await manager.refreshAsync() } else { manager.refresh() }
            XCTAssertNil(manager.probeResults["running"])
            await calls.release()
            try await Task.sleep(for: .milliseconds(50))
            let after = await calls.count()
            XCTAssertEqual(before, after, "失败刷新不能使用旧状态发送新请求")
            XCTAssertNil(manager.probeResults["running"], "不能接受失败刷新前的迟到结果")
            await manager.shutdownAsync()
        }
    }

    @MainActor
    func testStopPreventsUnsentRequestInBackgroundBatch() async throws {
        let owner = ProbeGateOwner(statuses: ["a": .running(pid: 7), "b": .running(pid: 8)])
        let calls = ProbeGateCalls()
        await calls.block()
        let manager = makeManager(owner, calls: calls, interval: 60_000_000_000)
        try await waitAsync { await calls.hasPending() }
        _ = await manager.stopAsync("b")
        // stopAsync 可能刷新仍运行的 a，先让该合法请求也抵达阻塞点。
        try await Task.sleep(for: .milliseconds(20))
        let before = await calls.count()
        await calls.release()
        try await Task.sleep(for: .milliseconds(50))
        let after = await calls.count()
        XCTAssertEqual(before, after, "旧批次不得继续发送 b 的请求")
        XCTAssertNil(manager.probeResults["b"])
        await manager.shutdownAsync()
    }

    @MainActor
    private func makeManager(_ owner: ProbeGateOwner, calls: ProbeGateCalls, interval: UInt64 = 10_000_000) -> TunnelManager {
        TunnelManager(
            paths: TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            rustCore: owner,
            preStartChecker: ProbeGateChecker(),
            probeService: ProbeService { request in await calls.perform(request) },
            healthMonitorIntervalNanoseconds: interval
        )
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "等待运行状态超时")
    }

    @MainActor
    private func waitAsync(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

private actor ProbeGateCalls {
    private var requests = 0
    private var blocked = false
    private var continuations: [CheckedContinuation<Int, Never>] = []
    func perform(_ request: URLRequest) async -> Int {
        requests += 1
        if blocked { return await withCheckedContinuation { continuations.append($0) } }
        return 401
    }
    func count() -> Int { requests }
    func block() { blocked = true }
    func hasPending() -> Bool { !continuations.isEmpty }
    func release() {
        blocked = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: 401) }
    }
}

private final class ProbeGateOwner: RustLifecycleOwner, RustHealthStatusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotFails = false
    private var values: [String: TunnelStatus]
    private var config: AppConfig
    init(statuses: [String: TunnelStatus]) {
        values = statuses
        config = AppConfig(tunnels: statuses.keys.sorted().map {
            TunnelConfig(id: $0, name: $0, command: ["/usr/bin/ssh", "-N"], keepAlive: false,
                         probe: ProbeConfig(url: "http://fixture.invalid/shared", expectedStatuses: [401]))
        })
    }
    func failSnapshots() { lock.withLock { snapshotFails = true } }
    func setStatus(_ status: TunnelStatus?, id: String) { lock.withLock { values[id] = status } }
    func loadConfig() throws -> AppConfig { lock.withLock { config } }
    func saveConfig(_ config: AppConfig) throws { lock.withLock { self.config = config } }
    func beginOperation(id: String) throws -> UInt64 { 1 }
    func cancelOperation(id: String, generation: UInt64) throws {}
    func snapshot() throws -> RustCoreClient.Snapshot {
        try lock.withLock {
            if snapshotFails { throw URLError(.unknown) }
            return .init(config: config, statuses: values)
        }
    }
    func status(id: String) throws -> TunnelStatus {
        try lock.withLock {
            guard let value = values[id] else { throw URLError(.unknown) }
            return value
        }
    }
    func start(id: String, generation: UInt64?) throws -> TunnelStatus { .running(pid: 7) }
    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        setStatus(.notLoaded, id: id)
        return .notLoaded
    }
    func restart(id: String, generation: UInt64?) throws -> TunnelStatus { .running(pid: 7) }
    func remove(id: String, generation: UInt64?) throws { setStatus(nil, id: id) }
    func shutdown() throws -> Int { 0 }
}

private struct ProbeGateChecker: ECSPreStartChecking {
    func check(tunnel: TunnelConfig) throws {}
    func checkAsync(tunnel: TunnelConfig) async throws {}
}
