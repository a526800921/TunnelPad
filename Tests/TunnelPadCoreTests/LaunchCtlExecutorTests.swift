import XCTest
@testable import TunnelPadCore

final class LaunchCtlExecutorTests: XCTestCase {

    private let domain = "gui/501"
    private let label = "com.jafish.tunnelpad.admin-tunnel"

    func testParseStatusRunning() {
        let stdout = """
        gui/501/com.jafish.tunnelpad.admin-tunnel = {
        \tstate = running
        \tpid = 73448
        \tlast exit code = 0

        \tresource coalition = {
        \t\tstate = active
        \t}
        }
        """
        XCTAssertEqual(LaunchCtlExecutor.parseStatus(stdout: stdout), .running(pid: 73448))
    }

    func testParseStatusNotRunning() {
        let stdout = "gui/501/x = {\n\tstate = not running\n}"
        XCTAssertEqual(LaunchCtlExecutor.parseStatus(stdout: stdout), .notRunning)
    }

    func testParseStatusEmptyOutput() {
        XCTAssertEqual(LaunchCtlExecutor.parseStatus(stdout: ""), .notLoaded)
    }

    func testStatusReturnsNotLoadedWhenPrintFails() {
        let runner = MockProcessRunner(
            results: [],
            defaultResult: ProcessResult(exitCode: 3, stderr: "Could not find service \"\(label)\" in domain gui/501")
        )
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        XCTAssertEqual(executor.status(label: label), .notLoaded)
    }

    func testBootstrapArgumentsAndSuccess() throws {
        let runner = MockProcessRunner(results: [ProcessResult(exitCode: 0)])
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        let plistURL = URL(fileURLWithPath: "/tmp/x.plist")

        try executor.bootstrap(label: label, plistURL: plistURL)

        let calls = runner.recordedCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executablePath, "/bin/launchctl")
        XCTAssertEqual(calls[0].arguments, ["bootstrap", domain, "/tmp/x.plist"])
    }

    func testBootstrapFailureThrows() {
        let runner = MockProcessRunner(
            results: [ProcessResult(exitCode: 5, stderr: "Bootstrap failed")],
            defaultResult: ProcessResult(exitCode: 0)
        )
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        XCTAssertThrowsError(try executor.bootstrap(label: label, plistURL: URL(fileURLWithPath: "/tmp/x.plist")))
    }

    func testBootoutSuccessReturnsTrue() throws {
        let runner = MockProcessRunner(results: [ProcessResult(exitCode: 0)])
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        XCTAssertTrue(try executor.bootout(label: label))
        XCTAssertEqual(runner.recordedCalls[0].arguments, ["bootout", "\(domain)/\(label)"])
    }

    func testBootoutNotFoundIsNotAnError() throws {
        let runner = MockProcessRunner(
            results: [ProcessResult(exitCode: 3, stderr: "Could not find service \"\(label)\" in domain gui/501")],
            defaultResult: ProcessResult(exitCode: 0)
        )
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        XCTAssertFalse(try executor.bootout(label: label))
    }

    func testBootoutUnexpectedFailureThrows() {
        let runner = MockProcessRunner(
            results: [ProcessResult(exitCode: 9, stderr: "Operation not permitted")],
            defaultResult: ProcessResult(exitCode: 0)
        )
        let executor = LaunchCtlExecutor(runner: runner, uid: 501)
        XCTAssertThrowsError(try executor.bootout(label: label))
    }
}
