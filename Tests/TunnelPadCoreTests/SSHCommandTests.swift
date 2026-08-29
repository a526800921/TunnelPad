import XCTest
@testable import TunnelPadCore

final class SSHCommandTests: XCTestCase {

    func testIsSSH() {
        XCTAssertTrue(SSHCommand.isSSH(["/usr/bin/ssh", "-N"]))
        XCTAssertTrue(SSHCommand.isSSH(["ssh"]))
        XCTAssertFalse(SSHCommand.isSSH(["/usr/bin/sshd"]))
        XCTAssertFalse(SSHCommand.isSSH(["/opt/homebrew/bin/autossh"]))
        XCTAssertFalse(SSHCommand.isSSH([]))
    }

    func testHasVerboseFlag() {
        XCTAssertTrue(SSHCommand.hasVerboseFlag(["/usr/bin/ssh", "-v", "-N"]))
        XCTAssertFalse(SSHCommand.hasVerboseFlag(["/usr/bin/ssh", "-vv", "-N"]))
        XCTAssertFalse(SSHCommand.hasVerboseFlag(["/usr/bin/ssh"]))
        XCTAssertFalse(SSHCommand.hasVerboseFlag([]))
    }

    func testAddingVerboseFlag() {
        XCTAssertEqual(
            SSHCommand.addingVerboseFlag(["/usr/bin/ssh", "-i", "/tmp/k", "-N"]),
            ["/usr/bin/ssh", "-v", "-i", "/tmp/k", "-N"]
        )
        // 已有 -v 不重复插入
        XCTAssertEqual(SSHCommand.addingVerboseFlag(["ssh", "-v"]), ["ssh", "-v"])
        XCTAssertEqual(SSHCommand.addingVerboseFlag([]), [])
    }

    func testRemovingVerboseFlag() {
        XCTAssertEqual(
            SSHCommand.removingVerboseFlag(["/usr/bin/ssh", "-v", "-i", "/tmp/k", "-N"]),
            ["/usr/bin/ssh", "-i", "/tmp/k", "-N"]
        )
        // 只删独立的 -v，不碰 -vv 等其他参数
        XCTAssertEqual(
            SSHCommand.removingVerboseFlag(["ssh", "-vv", "-v", "-N"]),
            ["ssh", "-vv", "-N"]
        )
        XCTAssertEqual(SSHCommand.removingVerboseFlag([]), [])
    }
}
