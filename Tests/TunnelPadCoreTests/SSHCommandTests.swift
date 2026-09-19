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

    func testRemotePortCleanupTargetAcceptsProductionShapeAndDropsForwardings() throws {
        let target = try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh",
            "-i", "/tmp/motorcycle.pem",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-N", "-T",
            "-R", "127.0.0.1:18080:127.0.0.1:8080",
            "-L", "127.0.0.1:10080:100.100.100.200:80",
            "root@47.109.202.254",
        ])

        XCTAssertEqual(target.port, 18080)
        XCTAssertEqual(target.resource, "root@47.109.202.254:22/tcp/18080")
        XCTAssertFalse(target.sshArguments.contains("-R"))
        XCTAssertFalse(target.sshArguments.contains("-L"))
        XCTAssertTrue(target.sshArguments.starts(with: ["-F", "/dev/null", "-i", "/tmp/motorcycle.pem"]))
        XCTAssertEqual(Array(target.sshArguments.suffix(5)), ["/usr/bin/python3", "-I", "-S", "-", "18080"])
    }

    func testRemotePortCleanupTargetRejectsDangerousOrAmbiguousArguments() {
        let base = [
            "/usr/bin/ssh", "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080",
            "root@47.109.202.254",
        ]
        let tail = Array(base.dropFirst())
        let rejected: [[String]] = [
            ["ssh"] + tail,
            ["/usr/bin/ssh", "-F", "/tmp/config"] + tail,
            ["/usr/bin/ssh", "-J", "jump"] + tail,
            ["/usr/bin/ssh", "-S", "/tmp/control"] + tail,
            ["/usr/bin/ssh", "-W", "host:22"] + tail,
            ["/usr/bin/ssh", "-D", "1080"] + tail,
            ["/usr/bin/ssh", "-o", "ProxyCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "LocalCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "RemoteCommand=bad"] + tail,
            ["/usr/bin/ssh", "-p22"] + tail,
            base + ["uname"],
            ["/usr/bin/ssh", "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "-R", "127.0.0.1:18081:127.0.0.1:8081", "root@47.109.202.254"],
        ]

        for command in rejected {
            XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget(command), "应拒绝：\(command)")
        }
    }

    func testRemotePortCleanupTargetRequiresLoopbackReverseForward() {
        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-N", "root@47.109.202.254",
        ]))
        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-N", "-R", "0.0.0.0:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
    }
}
