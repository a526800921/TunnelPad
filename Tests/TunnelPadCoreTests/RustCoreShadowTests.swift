import XCTest
@testable import TunnelPadCore

final class RustCoreShadowTests: XCTestCase {
    func testMissingLibraryFallsBackToSwift() {
        let shadow = RustCoreShadow(libraryURL: URL(fileURLWithPath: "/tmp/tunnelpad-missing-rust-core.dylib"))

        XCTAssertFalse(shadow.isAvailable)
        XCTAssertFalse(shadow.validateConfig(AppConfig()))
        XCTAssertNotNil(shadow.failureReason)
    }

    func testABIMismatchDisablesShadow() {
        let shadow = RustCoreShadow(testABI: 2, configParses: true)

        XCTAssertFalse(shadow.isAvailable)
        XCTAssertFalse(shadow.validateConfig(AppConfig()))
    }

    func testParseFailureFallsBackWithoutChangingSwiftConfig() {
        let config = AppConfig(tunnels: [TunnelConfig(id: "demo", name: "Demo", command: ["/usr/bin/true"])])
        let shadow = RustCoreShadow(testABI: RustCoreShadow.expectedABIVersion, configParses: false)

        XCTAssertTrue(shadow.isAvailable)
        XCTAssertFalse(shadow.validateConfig(config))
        XCTAssertFalse(shadow.isAvailable)
        XCTAssertEqual(config.tunnels.first?.id, "demo")
    }

    func testReleaseDylibLoadsAndValidatesConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let libraryURL = root.appendingPathComponent("rust/target/release/libtunnelpad_core.dylib")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: libraryURL.path),
            "先执行 cargo build --release --manifest-path rust/Cargo.toml"
        )

        let shadow = RustCoreShadow(libraryURL: libraryURL)
        let config = AppConfig(tunnels: [TunnelConfig(id: "demo", name: "Demo", command: ["/usr/bin/true"])])

        XCTAssertTrue(shadow.isAvailable)
        XCTAssertTrue(shadow.validateConfig(config))
        XCTAssertFalse(shadow.validateConfig(AppConfig(version: 2)))
        XCTAssertFalse(shadow.isAvailable)
    }

    func testReleaseIncompatibleDylibDisablesShadow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let libraryURL = root.appendingPathComponent("rust/target/release/libtunnelpad_core_incompatible.dylib")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: libraryURL.path),
            "先执行 cargo build --release --manifest-path rust/Cargo.toml"
        )

        let shadow = RustCoreShadow(libraryURL: libraryURL)

        XCTAssertFalse(shadow.isAvailable)
        XCTAssertFalse(shadow.validateConfig(AppConfig()))
        XCTAssertEqual(shadow.failureReason, "Rust ABI 版本不匹配")
    }
}
