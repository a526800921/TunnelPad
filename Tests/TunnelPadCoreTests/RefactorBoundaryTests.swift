import XCTest
import Foundation
@testable import TunnelPadCore

private actor ProbeStartSignal {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

final class RefactorBoundaryTests: XCTestCase {
    func testRuntimeStatePrunesAndUpdatesAsOneValue() {
        var state = TunnelRuntimeState()
        state.setStatus(.running(pid: 7), for: "a")
        state.setProbeResult(.satisfied(status: 200), for: "a")
        state.setBusy(true, for: "a")

        state.prune(to: ["b"])

        XCTAssertTrue(state.statuses.isEmpty)
        XCTAssertTrue(state.probeResults.isEmpty)
        XCTAssertEqual(state.busyIDs, ["a"], "状态裁剪不应隐式改变操作占用集合")
    }

    func testProbeCoordinatorDropsCancelledGeneration() async {
        let signal = ProbeStartSignal()
        let service = ProbeService(perform: { _ in
            await signal.markStarted()
            try? await Task.sleep(nanoseconds: 500_000_000)
            return 200
        })
        let coordinator = ProbeCoordinator(service: service)
        let probe = ProbeConfig(url: "http://127.0.0.1/health")

        let task = Task {
            await coordinator.run([(id: "a", probe: probe)])
        }
        await signal.waitUntilStarted()
        await coordinator.cancel()

        let result = await task.value
        XCTAssertNil(result, "取消后迟到的探针结果不能写回")
    }

    func testConfigStoreConformsToRepositoryBoundary() {
        let paths = TunnelPaths(homeDirectory: FileManager.default.temporaryDirectory)
        let repository: any TunnelConfigRepository = ConfigStore(paths: paths)
        XCTAssertEqual(repository.load().config, AppConfig())
    }

}
