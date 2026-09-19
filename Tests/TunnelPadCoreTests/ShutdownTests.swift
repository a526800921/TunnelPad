import XCTest
@testable import TunnelPadCore

final class ShutdownTests: XCTestCase {
    func testOwnerHandleKeepsCleanupFailureDistinctFromZeroStopped() {
        let attempts = ShutdownAttemptBox()
        let handle = Shutdown.OwnerHandle {
            try attempts.next()
        }

        XCTAssertFalse(handle.stopAllManagedTunnelsChecked())
        XCTAssertTrue(handle.stopAllManagedTunnelsChecked())
        XCTAssertEqual(attempts.count, 2)
    }
}

private final class ShutdownAttemptBox: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private var attempts = 0

    var count: Int { lock.withLock { attempts } }

    func next() throws -> Int {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw Failure.injected }
        return 0
    }
}
