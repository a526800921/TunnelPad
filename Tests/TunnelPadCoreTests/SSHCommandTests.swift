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
        let knownHostsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelPad Support \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: knownHostsDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
        let knownHostsFile = knownHostsDirectory.appendingPathComponent("known_hosts")
        try Data().write(to: knownHostsFile)
        let knownHostsOption = "UserKnownHostsFile=\"\(knownHostsFile.path)\""

        let target = try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh",
            "-i", "/tmp/motorcycle.pem",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", knownHostsOption,
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=30",
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
        XCTAssertTrue(target.sshArguments.contains(knownHostsOption))
        XCTAssertTrue(target.sshArguments.contains("GlobalKnownHostsFile=/dev/null"))
        XCTAssertTrue(target.sshArguments.contains("ConnectTimeout=8"))
        XCTAssertFalse(target.sshArguments.contains("ConnectTimeout=30"))
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
            ["/usr/bin/ssh", "-o", "ControlMaster=auto"] + tail,
            ["/usr/bin/ssh", "-o", "ControlPath=/tmp/control"] + tail,
            ["/usr/bin/ssh", "-o", "ControlPersist=yes"] + tail,
            ["/usr/bin/ssh", "-W", "host:22"] + tail,
            ["/usr/bin/ssh", "-D", "1080"] + tail,
            ["/usr/bin/ssh", "-o", "ProxyCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "KnownHostsCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "LocalCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "RemoteCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile="] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=none"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=/dev/null"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=\"/dev/null\""] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=/dev/./null"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=~/.ssh/known_hosts /dev/null"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=%d/../../../../dev/null"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=$HOME/../../../../dev/null"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=/tmp/known_hosts\nProxyCommand=bad"] + tail,
            ["/usr/bin/ssh", "-o", "UserKnownHostsFile=/tmp/known_hosts", "-o", "UserKnownHostsFile=/tmp/other_known_hosts"] + tail,
            ["/usr/bin/ssh", "-o", "GlobalKnownHostsFile="] + tail,
            ["/usr/bin/ssh", "-o", "GlobalKnownHostsFile=none"] + tail,
            ["/usr/bin/ssh", "-o", "ConnectTimeout=invalid"] + tail,
            ["/usr/bin/ssh", "-o", "ConnectTimeout=-1"] + tail,
            ["/usr/bin/ssh", "-p22"] + tail,
            base + ["uname"],
            ["/usr/bin/ssh", "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "-R", "127.0.0.1:18081:127.0.0.1:8081", "root@47.109.202.254"],
        ]

        for command in rejected {
            XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget(command), "应拒绝：\(command)")
        }
    }

    func testRemotePortCleanupTargetRejectsKnownHostsSymlinkToDevice() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/dev/null")
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", "UserKnownHostsFile=\(path.path)",
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
    }

    func testRemotePortCleanupTargetAcceptsKnownHostsSymlinkToRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("known_hosts")
        let link = directory.appendingPathComponent("known_hosts_link")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        XCTAssertNoThrow(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", "UserKnownHostsFile=\(link.path)",
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
    }

    func testRemotePortCleanupTargetAcceptsQuotedKnownHostsPathWithSpaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("known hosts")
        try Data().write(to: path)
        let option = "UserKnownHostsFile=\"\(path.path)\""

        let target = try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", option,
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ])

        XCTAssertTrue(target.sshArguments.contains(option))
    }

    func testRemotePortCleanupTargetRejectsUnwritableFirstKnownHostsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableSecondPath = directory.appendingPathComponent("known_hosts")
        try Data().write(to: writableSecondPath)
        let unwritableFirstPath = "/System/TunnelPad-\(UUID().uuidString)/known_hosts"
        let option = "UserKnownHostsFile=\(unwritableFirstPath) \(writableSecondPath.path)"

        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", option,
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
    }

    func testRemotePortCleanupTargetRejectsReadOnlyFirstKnownHostsFileEvenWhenLaterWritable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableSecondPath = directory.appendingPathComponent("known_hosts")
        try Data().write(to: writableSecondPath)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: "/etc/hosts"))
        let option = "UserKnownHostsFile=/etc/hosts \(writableSecondPath.path)"

        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", option,
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
    }

    func testRemotePortCleanupTargetRejectsDanglingKnownHostsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelpad-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent("known_hosts_link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: directory.appendingPathComponent("missing_known_hosts").path
        )

        XCTAssertThrowsError(try SSHCommand.remotePortCleanupTarget([
            "/usr/bin/ssh", "-o", "UserKnownHostsFile=\(link.path)",
            "-N", "-R", "127.0.0.1:18080:127.0.0.1:8080", "root@47.109.202.254",
        ]))
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
