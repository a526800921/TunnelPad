import XCTest
@testable import TunnelPadCore
@testable import tunnelpad

final class TunnelRemarksTests: XCTestCase {
    func testFormTrimsRemarkAndPreservesExecutionFields() throws {
        var form = TunnelFormState()
        form.name = "  后台隧道  "
        form.remark = "  用于后台 🚀 \"内网\"  "
        form.commandText = "/usr/bin/ssh\n-N"
        form.keepAlive = false
        form.throttleInterval = 17

        let tunnel = try form.makeTunnel(id: "admin-tunnel")

        XCTAssertEqual(tunnel.name, "后台隧道")
        XCTAssertEqual(tunnel.remark, "用于后台 🚀 \"内网\"")
        XCTAssertEqual(tunnel.command, ["/usr/bin/ssh", "-N"])
        XCTAssertFalse(tunnel.keepAlive)
        XCTAssertEqual(tunnel.throttleInterval, 17)
        XCTAssertEqual(tunnel.launchdLabel, "com.jafish.tunnelpad.admin-tunnel")
    }

    func testFormAllowsBlankRemark() throws {
        var form = TunnelFormState()
        form.name = "隧道"
        form.remark = " \n\t "
        form.commandText = "/bin/true"

        let tunnel = try form.makeTunnel(id: "tunnel")

        XCTAssertEqual(tunnel.remark, "")
    }

    func testFormLoadsExistingRemark() {
        let tunnel = TunnelConfig(
            id: "existing", name: "已有", remark: "  说明  ", command: ["/bin/true"]
        )

        XCTAssertEqual(TunnelFormState(tunnel: tunnel).remark, "  说明  ")
    }

    func testSidebarSubtitlePrefersTrimmedRemark() {
        let tunnel = TunnelConfig(
            id: "admin-tunnel", name: "后台", remark: "  用于后台访问  ", command: ["/bin/true"]
        )

        XCTAssertEqual(TunnelDisplay.subtitle(for: tunnel), "用于后台访问")
    }

    func testSidebarSubtitleFallsBackToLaunchdLabel() {
        let tunnel = TunnelConfig(
            id: "reverse-ssh", name: "反向", remark: " \n", command: ["/bin/true"]
        )

        XCTAssertEqual(TunnelDisplay.subtitle(for: tunnel), tunnel.launchdLabel)
    }
}
