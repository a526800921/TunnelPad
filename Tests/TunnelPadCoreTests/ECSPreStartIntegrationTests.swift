import Foundation
import XCTest
@testable import TunnelPadCore

final class ECSPreStartIntegrationTests: XCTestCase {

    @MainActor
    func testSSHStartRunsPreflightBeforeRustOwner() throws {
        let order = OrderLog()
        let tunnel = TunnelConfig(
            id: "ssh-start",
            name: "SSH start",
            command: ["/usr/bin/ssh", "-N", "example"]
        )
        let owner = RecordingRustOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = RecordingPreStartChecker(outcome: .success, order: order)
        let manager = TunnelManager(
            paths: temporaryPaths(),
            rustCore: owner,
            preStartChecker: checker
        )

        manager.start(tunnel.id)

        XCTAssertEqual(order.values, ["preflight-sync", "begin", "start"])
        XCTAssertEqual(checker.syncIDs, [tunnel.id])
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testSSHRestartAsyncRunsPreflightBeforeRustOwner() async {
        let order = OrderLog()
        let tunnel = TunnelConfig(
            id: "ssh-restart",
            name: "SSH restart",
            command: ["ssh", "-N", "example"]
        )
        let owner = RecordingRustOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = RecordingPreStartChecker(outcome: .success, order: order)
        let manager = TunnelManager(
            paths: temporaryPaths(),
            rustCore: owner,
            preStartChecker: checker
        )

        let result = await manager.restartAsync(tunnel.id)

        XCTAssertEqual(order.values, ["preflight-async", "begin", "restart"])
        XCTAssertEqual(checker.asyncIDs, [tunnel.id])
        XCTAssertEqual(result, .completed(status: .running(pid: 100)))
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testSSHStartFailureDoesNotCreateRustOperation() {
        let order = OrderLog()
        let tunnel = TunnelConfig(
            id: "ssh-failure",
            name: "SSH failure",
            command: ["/usr/bin/ssh", "-N", "example"]
        )
        let owner = RecordingRustOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = RecordingPreStartChecker(
            outcome: .failure(.commandFailed(exitCode: 7)),
            order: order
        )
        let manager = TunnelManager(
            paths: temporaryPaths(),
            rustCore: owner,
            preStartChecker: checker
        )

        manager.start(tunnel.id)

        XCTAssertEqual(order.values, ["preflight-sync"])
        XCTAssertTrue(owner.calls.isEmpty)
        XCTAssertEqual(manager.busyIDs, [])
        XCTAssertTrue(manager.lastError?.contains("退出码 7") == true)
    }

    @MainActor
    func testCancelledSSHStartDoesNotCreateRustOperation() async {
        let order = OrderLog()
        let tunnel = TunnelConfig(
            id: "ssh-cancel",
            name: "SSH cancel",
            command: ["/usr/bin/ssh", "-N", "example"]
        )
        let owner = RecordingRustOwner(config: AppConfig(tunnels: [tunnel]), order: order)
        let checker = RecordingPreStartChecker(outcome: .cancelled, order: order)
        let manager = TunnelManager(
            paths: temporaryPaths(),
            rustCore: owner,
            preStartChecker: checker
        )

        await manager.startAsync(tunnel.id)

        XCTAssertEqual(order.values, ["preflight-async"])
        XCTAssertTrue(owner.calls.isEmpty)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testNonSSHStartBypassesProductionPreflight() throws {
        let runner = RecordingPreflightRunner(result: ProcessResult(exitCode: 7))
        let checker = ECSPreStartChecker(
            scriptURL: nil,
            runner: runner,
            environment: [:],
            timeout: 1
        )
        let tunnel = TunnelConfig(
            id: "non-ssh",
            name: "Non SSH",
            command: ["/bin/echo", "hello"]
        )
        let owner = RecordingRustOwner(config: AppConfig(tunnels: [tunnel]), order: nil)
        let manager = TunnelManager(
            paths: temporaryPaths(),
            rustCore: owner,
            preStartChecker: checker
        )

        manager.start(tunnel.id)

        XCTAssertTrue(runner.syncCalls.isEmpty)
        XCTAssertEqual(owner.calls, ["begin", "start"])
        XCTAssertNil(manager.lastError)
    }

    func testExternalCredentialPathsArePassedWithoutAllowingArbitraryEnvironment() throws {
        let scriptURL = temporaryScriptURL()
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: scriptURL)

        let runner = RecordingPreflightRunner(result: ProcessResult(exitCode: 0))
        let environment = ECSPreStartChecker.defaultEnvironment(from: [
            "PATH": "/usr/bin",
            "HOME": "/tmp/test-home",
            "TUNNELPAD_CONFIG_FILE": "/tmp/external/ecs.env",
            "TUNNELPAD_ALIYUN_CONFIG": "/tmp/external/aliyun-config.json",
            "AWS_SECRET_ACCESS_KEY": "must-not-pass"
        ])
        let checker = ECSPreStartChecker(
            scriptURL: scriptURL,
            runner: runner,
            environment: environment,
            timeout: 1
        )
        let tunnel = TunnelConfig(
            id: "env-paths",
            name: "Environment paths",
            command: ["/usr/bin/ssh", "-N", "example"]
        )

        try checker.check(tunnel: tunnel)

        XCTAssertEqual(runner.syncCalls.count, 1)
        XCTAssertEqual(runner.syncCalls[0].executablePath, "/bin/bash")
        XCTAssertEqual(runner.syncCalls[0].arguments, [scriptURL.path])
        XCTAssertEqual(runner.syncCalls[0].environment["TUNNELPAD_CONFIG_FILE"], "/tmp/external/ecs.env")
        XCTAssertEqual(
            runner.syncCalls[0].environment["TUNNELPAD_ALIYUN_CONFIG"],
            "/tmp/external/aliyun-config.json"
        )
        XCTAssertNil(runner.syncCalls[0].environment["AWS_SECRET_ACCESS_KEY"])
    }

    func testDefaultEnvironmentSuppliesFinderFallbacks() {
        let environment = ECSPreStartChecker.defaultEnvironment(from: [
            "PATH": "/usr/bin",
            "AWS_SECRET_ACCESS_KEY": "must-not-pass"
        ])

        let pathEntries = Set((environment["PATH"] ?? "").split(separator: ":").map(String.init))
        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/bin"))
        XCTAssertEqual(
            environment["HOME"],
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    }

    func testNonzeroOutputIsMappedWithoutLeakingStderr() throws {
        let scriptURL = temporaryScriptURL()
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try Data("#!/bin/bash\nexit 7\n".utf8).write(to: scriptURL)

        let runner = RecordingPreflightRunner(
            result: ProcessResult(exitCode: 7, stderr: "secret-value-and-public-ip")
        )
        let checker = ECSPreStartChecker(
            scriptURL: scriptURL,
            runner: runner,
            environment: [:],
            timeout: 1
        )
        let tunnel = TunnelConfig(
            id: "error-map",
            name: "Error map",
            command: ["/usr/bin/ssh", "-N", "example"]
        )

        XCTAssertThrowsError(try checker.check(tunnel: tunnel)) { error in
            guard let preStartError = error as? ECSPreStartError else {
                return XCTFail("应返回 ECS 前置错误，实际为：\(error)")
            }
            XCTAssertEqual(preStartError, .commandFailed(exitCode: 7))
            XCTAssertFalse(preStartError.localizedDescription.contains("secret-value-and-public-ip"))
            XCTAssertTrue(preStartError.localizedDescription.contains("退出码 7"))
        }
    }

    func testAsyncTimeoutIsReported() async throws {
        let scriptURL = temporaryScriptURL()
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try Data("#!/bin/bash\nsleep 1\n".utf8).write(to: scriptURL)

        let runner = RecordingPreflightRunner(
            result: ProcessResult(exitCode: 0),
            asyncDelayNanoseconds: 500_000_000
        )
        let checker = ECSPreStartChecker(
            scriptURL: scriptURL,
            runner: runner,
            environment: [:],
            timeout: 0.01
        )
        let tunnel = TunnelConfig(
            id: "timeout",
            name: "Timeout",
            command: ["/usr/bin/ssh", "-N", "example"]
        )

        do {
            try await checker.checkAsync(tunnel: tunnel)
            XCTFail("超时应失败")
        } catch let error as ECSPreStartError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testSystemRunnerCapturesSuccessfulOutput() async throws {
        let runner = SystemECSPreflightProcessRunner()

        let result = try await runner.runAsync(
            executablePath: "/bin/echo",
            arguments: ["tunnelpad-ok"],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "tunnelpad-ok\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testSystemRunnerSyncTimeoutTerminatesProcess() {
        let runner = SystemECSPreflightProcessRunner()

        XCTAssertThrowsError(
            try runner.run(
                executablePath: "/bin/sleep",
                arguments: ["1"],
                environment: [:],
                timeout: 0.01
            )
        ) { error in
            XCTAssertEqual(error as? ECSPreflightProcessError, .timedOut)
        }
    }

    func testSystemRunnerCancellationStopsAsyncPreflight() async throws {
        let scriptURL = temporaryScriptURL()
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try Data("#!/bin/bash\nsleep 1\n".utf8).write(to: scriptURL)

        let checker = ECSPreStartChecker(
            scriptURL: scriptURL,
            runner: SystemECSPreflightProcessRunner(),
            environment: [:],
            timeout: 5
        )
        let tunnel = TunnelConfig(
            id: "system-cancel",
            name: "System cancel",
            command: ["/usr/bin/ssh", "-N", "example"]
        )
        let task = Task {
            try await checker.checkAsync(tunnel: tunnel)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("取消应在 Rust 调用前抛出")
        } catch is CancellationError {
            // 预期：取消终止外部进程，并且不把结果继续交给前置成功路径。
        }
    }

    private func temporaryPaths() -> TunnelPaths {
        TunnelPaths(
            homeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnelpad-ecs-prestart-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func temporaryScriptURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-ecs-prestart-\(UUID().uuidString)", isDirectory: false)
    }
}

private final class OrderLog: @unchecked Sendable {
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

private final class RecordingPreStartChecker: ECSPreStartChecking, @unchecked Sendable {
    enum Outcome: Sendable {
        case success
        case failure(ECSPreStartError)
        case cancelled
    }

    private let outcome: Outcome
    private let order: OrderLog
    private let lock = NSLock()
    private(set) var syncIDs: [String] = []
    private(set) var asyncIDs: [String] = []

    init(outcome: Outcome, order: OrderLog) {
        self.outcome = outcome
        self.order = order
    }

    func check(tunnel: TunnelConfig) throws {
        recordSyncID(tunnel.id)
        order.append("preflight-sync")
        try resolve()
    }

    func checkAsync(tunnel: TunnelConfig) async throws {
        recordAsyncID(tunnel.id)
        order.append("preflight-async")
        try resolve()
    }

    private func recordSyncID(_ id: String) {
        lock.lock()
        syncIDs.append(id)
        lock.unlock()
    }

    private func recordAsyncID(_ id: String) {
        lock.lock()
        asyncIDs.append(id)
        lock.unlock()
    }

    private func resolve() throws {
        switch outcome {
        case .success:
            return
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

private final class RecordingRustOwner: RustLifecycleOwner, @unchecked Sendable {
    private let configuration: AppConfig
    private let order: OrderLog?
    private let lock = NSLock()
    private(set) var calls: [String] = []

    init(config: AppConfig, order: OrderLog?) {
        configuration = config
        self.order = order
    }

    func loadConfig() throws -> AppConfig { configuration }
    func saveConfig(_ config: AppConfig) throws {}

    func beginOperation(id: String) throws -> UInt64 {
        record("begin")
        return 1
    }

    func cancelOperation(id: String, generation: UInt64) throws {
        record("cancel")
    }

    func snapshot() throws -> RustCoreClient.Snapshot {
        RustCoreClient.Snapshot(
            config: configuration,
            statuses: Dictionary(uniqueKeysWithValues: configuration.tunnels.map { ($0.id, .notLoaded) })
        )
    }

    func start(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("start")
        return .running(pid: 100)
    }

    func stop(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("stop")
        return .notRunning
    }

    func restart(id: String, generation: UInt64?) throws -> TunnelStatus {
        record("restart")
        return .running(pid: 100)
    }

    func remove(id: String, generation: UInt64?) throws {
        record("remove")
    }

    func shutdown() throws -> Int {
        record("shutdown")
        return 0
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
        order?.append(call)
    }
}

private final class RecordingPreflightRunner: ECSPreflightProcessRunning, @unchecked Sendable {
    struct SyncCall {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let result: ProcessResult
    private let asyncDelayNanoseconds: UInt64
    private let lock = NSLock()
    private(set) var syncCalls: [SyncCall] = []
    private(set) var asyncCalls: [SyncCall] = []

    init(result: ProcessResult, asyncDelayNanoseconds: UInt64 = 0) {
        self.result = result
        self.asyncDelayNanoseconds = asyncDelayNanoseconds
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        syncCalls.append(SyncCall(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        ))
        lock.unlock()
        return result
    }

    func runAsync(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        recordAsyncCall(SyncCall(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        ))
        if asyncDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: asyncDelayNanoseconds)
        }
        return result
    }

    private func recordAsyncCall(_ call: SyncCall) {
        lock.lock()
        asyncCalls.append(call)
        lock.unlock()
    }
}
