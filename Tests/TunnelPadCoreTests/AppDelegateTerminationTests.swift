import XCTest
@testable import tunnelpad

final class AppDelegateTerminationTests: XCTestCase {
    func testRepeatedTerminationWaitsForSingleCleanup() {
        var gate = ApplicationTerminationGate()

        XCTAssertEqual(gate.request(), .startCleanup)
        XCTAssertEqual(
            gate.request(),
            .waitForCleanup,
            "清理尚未完成时的重复退出不能绕过孤儿清理"
        )

        gate.complete(success: true)
        XCTAssertEqual(gate.request(), .terminateNow)
    }

    func testFailedCleanupAllowsOneFreshRetry() {
        var gate = ApplicationTerminationGate()

        XCTAssertEqual(gate.request(), .startCleanup)
        gate.complete(success: false)
        XCTAssertEqual(gate.request(), .startCleanup)
        XCTAssertEqual(gate.request(), .waitForCleanup)
    }
}
