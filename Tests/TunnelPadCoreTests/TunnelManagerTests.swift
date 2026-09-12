import XCTest
import Foundation
@testable import TunnelPadCore

final class TunnelManagerTests: XCTestCase {

    @MainActor
    func testReloadConfigPicksUpChangesAndDropsRemovedStatuses() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(
                id: "reload-a", name: "A", remark: "原备注",
                command: ["/usr/bin/ssh", "-N", "a"]
            )
        ]))

        let manager = TunnelManager(paths: paths)
        XCTAssertEqual(manager.config.tunnels.map(\.id), ["reload-a"])
        manager.refresh()
        XCTAssertEqual(manager.statuses.keys.sorted(), ["reload-a"])

        try store.save(AppConfig(tunnels: [
            TunnelConfig(
                id: "reload-b", name: "B", remark: "外部说明",
                command: ["/usr/bin/ssh", "-N", "b"]
            )
        ]))
        manager.reloadConfig()

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["reload-b"], "reload 应读取磁盘上的新配置")
        XCTAssertEqual(manager.config.tunnels[0].remark, "外部说明", "reload 应更新列表备注")
        XCTAssertEqual(manager.statuses.keys.sorted(), ["reload-b"], "已移除隧道的状态缓存应被清理")
        XCTAssertTrue(manager.lastMessage?.contains("重新加载") == true)
    }

    @MainActor
    func testUpdateTunnelPersistsChangesAndClearsDroppedProbe() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(
            id: "edit-a",
            name: "A",
            remark: "旧说明",
            command: ["/usr/bin/ssh", "-N", "a"],
            probe: ProbeConfig(url: "http://127.0.0.1:1/health", expectedStatuses: [200])
        )
        try store.save(AppConfig(tunnels: [tunnel]))

        let manager = TunnelManager(paths: paths)
        manager.refresh()
        // 探针异步执行，轮询等待写回。
        let deadline = Date().addingTimeInterval(5)
        while manager.probeResults["edit-a"] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(manager.probeResults["edit-a"])

        var updated = tunnel
        updated.name = "A2"
        updated.remark = "新的用途说明"
        updated.throttleInterval = 15
        updated.probe = nil
        let saved = await manager.updateTunnelAsync(updated)
        XCTAssertTrue(saved, "编辑保存应返回 true")

        XCTAssertEqual(manager.config.tunnels[0].name, "A2")
        XCTAssertEqual(manager.config.tunnels[0].remark, "新的用途说明")
        XCTAssertEqual(manager.config.tunnels[0].throttleInterval, 15)
        XCTAssertNil(manager.probeResults["edit-a"], "移除探针后旧结果应被清理")
        XCTAssertTrue(manager.lastMessage?.contains("已保存") == true)

        let reread = store.load().config
        XCTAssertEqual(reread.tunnels[0].name, "A2", "修改应持久化到 config.json")
        XCTAssertEqual(reread.tunnels[0].remark, "新的用途说明", "备注修改应持久化到 config.json")
        XCTAssertEqual(reread.tunnels[0].command, ["/usr/bin/ssh", "-N", "a"])
        XCTAssertNil(reread.tunnels[0].probe)
    }

    // MARK: - removeTunnel

    @MainActor
    func testRemoveTunnelDeletesLaunchdArtifactsAndPersists() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        let tunnel = TunnelConfig(id: "remove-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        try store.save(AppConfig(tunnels: [tunnel]))

        let manager = TunnelManager(paths: paths)
        let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try Data("debug1: test\n".utf8).write(to: paths.logURL(for: tunnel))
        manager.refresh()
        XCTAssertEqual(manager.statuses["remove-a"], .notLoaded)

        manager.removeTunnel("remove-a")

        XCTAssertTrue(manager.config.tunnels.isEmpty, "删除后配置应移除条目")
        XCTAssertTrue(store.load().config.tunnels.isEmpty, "删除应持久化到 config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path), "生成的 plist 应被清理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path), "日志文件应被删除")
        XCTAssertNil(manager.statuses["remove-a"], "状态缓存应被清理")
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testRemoveTunnelUnknownIDIsNoop() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "keep-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        ]))

        let manager = TunnelManager(paths: paths)
        manager.removeTunnel("ghost")

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["keep-a"])
        XCTAssertNil(manager.lastError)
    }

    // MARK: - addTunnel

    @MainActor
    func testAddTunnelPersistsWithoutStarting() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "base", name: "B", command: ["/usr/bin/ssh", "-N", "b"])
        ]))

        let manager = TunnelManager(paths: paths)
        XCTAssertTrue(manager.addTunnel(TunnelConfig(id: "new-a", name: "A", command: ["/bin/sleep", "30"])), "成功新增应返回 true")

        XCTAssertEqual(manager.config.tunnels.map(\.id), ["base", "new-a"], "新增应追加到列表末尾")
        XCTAssertEqual(store.load().config.tunnels.map(\.id), ["base", "new-a"], "新增应持久化到 config.json")
        XCTAssertNil(manager.lastError)
        manager.refresh()
        XCTAssertEqual(manager.statuses["new-a"], .notLoaded, "新增后不应自动启动")
    }

    @MainActor
    func testAddTunnelRejectsDuplicateAndInvalidIDs() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(tunnels: [
            TunnelConfig(id: "dup", name: "D", command: ["/usr/bin/ssh", "-N", "d"])
        ]))

        let manager = TunnelManager(paths: paths)
        XCTAssertFalse(manager.addTunnel(TunnelConfig(id: "dup", name: "Again", command: ["/bin/echo"])), "重复 id 应返回 false")
        XCTAssertEqual(manager.config.tunnels.count, 1, "重复 id 应被拒绝")
        XCTAssertNotNil(manager.lastError)

        manager.lastError = nil
        XCTAssertFalse(manager.addTunnel(TunnelConfig(id: "Bad_ID", name: "Bad", command: ["/bin/echo"])), "非法 id 应返回 false")
        XCTAssertEqual(manager.config.tunnels.count, 1, "非法 id 应被拒绝")
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(store.load().config.tunnels.count, 1, "拒绝时不得写入配置")
    }

    // MARK: - updateTunnelAsync

    @MainActor
    func testUpdateTunnelAsyncReturnsSaveOutcome() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let paths = TunnelPaths(homeDirectory: tempHome)
        let owner = StubLifecycleOwner(config: AppConfig(tunnels: [
            TunnelConfig(id: "edit-a", name: "A", command: ["/usr/bin/ssh", "-N", "a"])
        ]))
        let manager = TunnelManager(paths: paths, rustCore: owner, preStartChecker: PassingPreStartChecker())

        // 成功路径：返回 true，内存配置更新并落盘，不写 lastError。
        var updated = try XCTUnwrap(manager.config.tunnels.first)
        updated.name = "A2"
        let savesBefore = owner.saveCount
        let saved = await manager.updateTunnelAsync(updated)
        XCTAssertTrue(saved, "成功保存应返回 true")
        XCTAssertEqual(owner.saveCount, savesBefore + 1, "saveConfig 应恰好被调用一次")
        XCTAssertEqual(manager.config.tunnels[0].name, "A2", "内存配置应更新")
        XCTAssertEqual(owner.currentConfig.tunnels[0].name, "A2", "落盘内容应为新配置")
        XCTAssertNil(manager.lastError)

        // 落盘失败：返回 false，lastError 给出原因，内存配置保持原值。
        owner.failSaveConfig = true
        manager.lastError = nil
        var broken = manager.config.tunnels[0]
        broken.name = "A3"
        let savesAfterSuccess = owner.saveCount
        let failedSave = await manager.updateTunnelAsync(broken)
        XCTAssertFalse(failedSave, "落盘失败应返回 false")
        XCTAssertEqual(owner.saveCount, savesAfterSuccess + 1, "失败路径也应尝试落盘")
        XCTAssertNotNil(manager.lastError, "失败应在 lastError 给出原因")
        XCTAssertEqual(manager.config.tunnels[0].name, "A2", "失败不得更新内存配置")

        // 未知 id：返回 false 并报错，不得静默 no-op。
        manager.lastError = nil
        let ghostSave = await manager.updateTunnelAsync(TunnelConfig(id: "ghost", name: "G", command: ["/bin/echo"]))
        XCTAssertFalse(ghostSave, "未知 id 应返回 false")
        XCTAssertNotNil(manager.lastError, "未知 id 不得静默失败")
        XCTAssertEqual(manager.config.tunnels.map(\.id), ["edit-a"], "未知 id 不得新增条目")
    }

    // MARK: - restoreAutoStartTunnels

    @MainActor
    func testRestoreAutoStartTunnelsHonorsGates() async throws {
        let paths = TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-restore-\(UUID().uuidString)", isDirectory: true))
        let owner = StubLifecycleOwner(config: AppConfig(tunnels: [
            TunnelConfig(id: "boot-on", name: "恢复", command: ["/bin/true"], autoStart: true),
            TunnelConfig(id: "boot-running", name: "已运行", command: ["/bin/true"], autoStart: true),
            TunnelConfig(id: "boot-off", name: "不恢复", command: ["/bin/true"]),
            TunnelConfig(id: "boot-fail", name: "失败", command: ["/bin/true"], autoStart: true),
        ]))
        owner.statusOverrides = ["boot-running": .running(pid: 100)]
        owner.failStartIDs = ["boot-fail"]
        let manager = TunnelManager(
            paths: paths, rustCore: owner, preStartChecker: PassingPreStartChecker(),
            launchRestoreDiscoveryAttempts: 20, launchRestoreDiscoveryPollNanoseconds: 20_000_000
        )

        await manager.restoreAutoStartTunnels()

        // R1 已运行跳过、R4 autoStart=false 不参与、R3 失败不阻断；顺序保持配置序。
        XCTAssertEqual(owner.startedIDs, ["boot-on", "boot-fail"], "只拉起未运行的 autoStart 隧道，失败条也尝试")
        XCTAssertNotNil(manager.lastError, "启动失败原因应可见")
        XCTAssertEqual(manager.statuses["boot-on"], .running(pid: nil), "成功启动的隧道状态应为 running")
        XCTAssertEqual(manager.statuses["boot-off"], .notLoaded, "autoStart=false 仅不启动，状态发现照常覆盖")

        // 全过程写入 App 事件日志（app.log），失败原因可追溯。
        let appLog = try String(contentsOf: paths.appEventLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("自动拉起「恢复」成功"), "实际日志：\(appLog)")
        XCTAssertTrue(appLog.contains("自动拉起「失败」失败：启动「失败」失败：transport(\"模拟启动失败\")"), "实际日志：\(appLog)")
        XCTAssertTrue(appLog.contains("启动恢复完成：成功 1，失败 1，跳过 0，候选 3"))
        XCTAssertFalse(appLog.contains("「不恢复」"), "autoStart=false 不应出现在恢复日志")

        // R5：同进程重复触发不得再次启动。
        await manager.restoreAutoStartTunnels()
        XCTAssertEqual(owner.startedIDs, ["boot-on", "boot-fail"], "恢复入口每次进程生命周期只执行一次")
    }

    @MainActor
    func testRestoreAutoStartSkipsAllWhenDiscoveryFails() async throws {
        let paths = TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-restore-fail-\(UUID().uuidString)", isDirectory: true))
        let owner = StubLifecycleOwner(config: AppConfig(tunnels: [
            TunnelConfig(id: "boot-on", name: "恢复", command: ["/bin/true"], autoStart: true)
        ]))
        owner.failSnapshot = true
        let manager = TunnelManager(
            paths: paths, rustCore: owner, preStartChecker: PassingPreStartChecker(),
            launchRestoreDiscoveryAttempts: 3, launchRestoreDiscoveryPollNanoseconds: 10_000_000
        )

        // R6：状态发现失败（恢复自身刷新与健康监测首轮快照均拿不到状态）→
        // fail-closed 全部跳过，不盲目启动。lastError 依赖哪个读取者幸存，不作断言。
        await manager.restoreAutoStartTunnels()

        XCTAssertTrue(owner.startedIDs.isEmpty, "状态未知时不得启动")
        let appLog = try String(contentsOf: paths.appEventLogURL, encoding: .utf8)
        XCTAssertTrue(appLog.contains("状态发现超时"), "实际日志：\(appLog)")
    }
}

/// 可注入失败行为的 Rust 生命周期 owner 桩：saveConfig 记录最新落盘配置，
/// snapshot/loadConfig 均从最新配置读取，模拟 Rust Core 的配置 owner 行为。
private final class StubLifecycleOwner: RustLifecycleOwner, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AppConfig
    var failSaveConfig = false
    var failSnapshot = false
    var failStartIDs: Set<String> = []
    var statusOverrides: [String: TunnelStatus] = [:]
    private var startedIDsStorage: [String] = []

    init(config: AppConfig) {
        self.current = config
    }

    var currentConfig: AppConfig {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCountStorage
    }

    var startedIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return startedIDsStorage
    }

    private var saveCountStorage = 0

    func loadConfig() throws -> AppConfig { currentConfig }

    func saveConfig(_ config: AppConfig) throws {
        lock.lock()
        saveCountStorage += 1
        let shouldFail = failSaveConfig
        if !shouldFail { current = config }
        lock.unlock()
        if shouldFail { throw RustCoreClient.ClientError.unavailable("模拟落盘失败") }
    }

    func beginOperation(id: String) throws -> UInt64 { 1 }

    func cancelOperation(id: String, generation: UInt64) throws {}

    func snapshot() throws -> RustCoreClient.Snapshot {
        lock.lock()
        let shouldFail = failSnapshot
        let config = current
        let overrides = statusOverrides
        lock.unlock()
        if shouldFail {
            throw RustCoreClient.ClientError.transport("模拟状态发现失败")
        }
        let statuses = Dictionary(uniqueKeysWithValues: config.tunnels.map { tunnel in
            (tunnel.id, overrides[tunnel.id] ?? .notLoaded)
        })
        return RustCoreClient.Snapshot(config: config, statuses: statuses)
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        lock.lock()
        startedIDsStorage.append(id)
        let shouldFail = failStartIDs.contains(id)
        lock.unlock()
        if shouldFail {
            throw RustCoreClient.ClientError.transport("模拟启动失败")
        }
        return .running(pid: nil)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus { .notRunning }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus { .running(pid: nil) }

    func remove(id: String, generation: UInt64?) throws {}

    func shutdown() throws -> Int { 0 }
}

private struct PassingPreStartChecker: ECSPreStartChecking {
    func check(tunnel: TunnelConfig) throws {}

    func checkAsync(tunnel: TunnelConfig) async throws {}
}
