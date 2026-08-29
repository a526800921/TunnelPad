import XCTest
import Foundation
@testable import TunnelPadCore

final class AppProcessExecutorTests: XCTestCase {

    private var tempHome: URL!
    private var paths: TunnelPaths!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-appexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = TunnelPaths(homeDirectory: tempHome)
    }

    override func tearDownWithError() throws {
        executor?.shutdownAll()
        try? FileManager.default.removeItem(at: tempHome)
    }

    private var executor: AppProcessExecutor!

    private func makeExecutor(restartDelay: TimeInterval? = nil) -> AppProcessExecutor {
        AppProcessExecutor(paths: paths, restartDelayOverride: restartDelay)
    }

    private func sleepTunnel(keepAlive: Bool = false, throttle: Int = 1) -> TunnelConfig {
        TunnelConfig(
            id: "demo-sleep",
            name: "demo-sleep",
            command: ["/bin/sleep", "60"],
            executor: .app,
            keepAlive: keepAlive,
            throttleInterval: throttle
        )
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func testStartRunsChildAndWritesPidfile() throws {
        executor = makeExecutor()
        let tunnel = sleepTunnel()
        try executor.start(tunnel)

        guard case .running(let pid) = executor.status(id: tunnel.id), let pid else {
            return XCTFail("期待 running")
        }
        XCTAssertEqual(kill(pid, 0), 0, "子进程应存活")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pidfileURL(for: tunnel).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logURL(for: tunnel).path))
    }

    func testStopTerminatesChildAndRemovesPidfile() throws {
        executor = makeExecutor()
        let tunnel = sleepTunnel()
        try executor.start(tunnel)
        guard case .running(let pid) = executor.status(id: tunnel.id), let pid else {
            return XCTFail("期待 running")
        }

        executor.stop(tunnel)

        XCTAssertEqual(executor.status(id: tunnel.id), .notLoaded)
        XCTAssertFalse(kill(pid, 0) == 0, "子进程应已终止")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pidfileURL(for: tunnel).path))
    }

    func testKeepAliveRestartsAfterExternalKill() throws {
        executor = makeExecutor(restartDelay: 0.2)
        let tunnel = sleepTunnel(keepAlive: true)
        try executor.start(tunnel)
        guard case .running(let firstPid) = executor.status(id: tunnel.id), let firstPid else {
            return XCTFail("期待首次 running")
        }

        kill(firstPid, SIGKILL)

        let restarted = waitUntil {
            if case .running(let pid?) = self.executor.status(id: tunnel.id) {
                return pid != firstPid
            }
            return false
        }
        XCTAssertTrue(restarted, "keepAlive 应在延迟后重启子进程")
        executor.stop(tunnel)
    }

    func testManualStopIsNotRestarted() throws {
        executor = makeExecutor(restartDelay: 0.1)
        let tunnel = sleepTunnel(keepAlive: true)
        try executor.start(tunnel)

        executor.stop(tunnel)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(executor.status(id: tunnel.id), .notLoaded, "手动停止后不应被 keepAlive 拉起")
    }
    func testShutdownAllKillsChildren() throws {
        executor = makeExecutor()
        let tunnel = sleepTunnel()
        try executor.start(tunnel)
        guard case .running(let pid) = executor.status(id: tunnel.id), let pid else {
            return XCTFail("期待 running")
        }

        executor.shutdownAll()

        XCTAssertFalse(kill(pid, 0) == 0)
        XCTAssertEqual(executor.status(id: tunnel.id), .notLoaded)
    }

    func testStartIsIdempotentWhenRunning() throws {
        executor = makeExecutor()
        let tunnel = sleepTunnel()
        try executor.start(tunnel)
        guard case .running(let firstPid) = executor.status(id: tunnel.id), let firstPid else {
            return XCTFail("期待 running")
        }

        try executor.start(tunnel)
        guard case .running(let secondPid) = executor.status(id: tunnel.id) else {
            return XCTFail("期待仍为 running")
        }
        XCTAssertEqual(firstPid, secondPid, "重复 start 不应再拉起新进程")
        executor.stop(tunnel)
    }
}
