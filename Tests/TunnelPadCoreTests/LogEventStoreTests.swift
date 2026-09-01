import Foundation
import Darwin
import XCTest
@testable import TunnelPadCore

final class LogEventStoreTests: XCTestCase {

    func testAppendPublishesOneEventAndNoEventWithoutNewBytes() async throws {
        let fixture = try LogEventFixture(id: "append")
        defer { fixture.cleanup() }
        try fixture.write("A\n")

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let session = await store.openSession(for: fixture.id)
        XCTAssertEqual(session.snapshot.text, "A")

        try fixture.append("B\n")
        _ = await store.refresh(for: fixture.id)
        let event = try await nextEvent(from: session.events)
        XCTAssertEqual(event.tunnelID, fixture.id)
        XCTAssertEqual(event.appendedText, "B\n")
        XCTAssertEqual(event.snapshot.text, "A\nB")
        XCTAssertGreaterThan(event.version, session.snapshot.version)

        _ = await store.refresh(for: fixture.id)
        let unchanged = await store.snapshot(for: fixture.id)
        XCTAssertEqual(unchanged.version, event.version)
    }

    func testFileWatcherPublishesAppendWithoutManualRefresh() async throws {
        let fixture = try LogEventFixture(id: "watcher")
        defer { fixture.cleanup() }
        try fixture.write("before\n")

        let store = LogEventStore(paths: fixture.paths)
        let session = await store.openSession(for: fixture.id)
        try fixture.append("from-watcher\n")

        let event = try await nextEvent(from: session.events, timeoutNanoseconds: 2_000_000_000)
        XCTAssertEqual(event.snapshot.text, "before\nfrom-watcher")
    }

    func testSplitUTF8DoesNotPublishReplacementCharacters() async throws {
        let fixture = try LogEventFixture(id: "utf8")
        defer { fixture.cleanup() }

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let session = await store.openSession(for: fixture.id)
        let bytes = Array("🚀\n".utf8)
        try fixture.append(Data(bytes.prefix(2)))
        _ = await store.refresh(for: fixture.id)
        let partial = await store.snapshot(for: fixture.id)
        XCTAssertEqual(partial.text, "")

        try fixture.append(Data(bytes.dropFirst(2)))
        _ = await store.refresh(for: fixture.id)
        let event = try await nextEvent(from: session.events)
        XCTAssertEqual(event.snapshot.text, "🚀")
        XCTAssertFalse(event.snapshot.text.contains("�"))
    }

    func testMemoryCacheKeepsLatest500AndFileKeepsLatest2000Lines() async throws {
        let fixture = try LogEventFixture(id: "limits")
        defer { fixture.cleanup() }
        let content = (1...2_001).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(content)

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let snapshot = await store.openSession(for: fixture.id).snapshot
        let visibleLines = snapshot.text.split(separator: "\n")
        XCTAssertEqual(visibleLines.count, 500)
        XCTAssertEqual(visibleLines.first, "line-1502")
        XCTAssertEqual(visibleLines.last, "line-2001")

        let retained = try String(contentsOf: fixture.logURL, encoding: .utf8)
        let retainedLines = retained.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(retainedLines.count, 2_000)
        XCTAssertEqual(retainedLines.first, "line-2")
        XCTAssertEqual(retainedLines.last, "line-2001")
    }

    func testRetentionDefersWhenFileIsLockedAndRetriesLater() async throws {
        let fixture = try LogEventFixture(id: "locked-retention")
        defer { fixture.cleanup() }
        let content = (1...2_001).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(content)

        let descriptor = open(fixture.logURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        _ = await store.openSession(for: fixture.id)
        let retainedWhileLocked = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertEqual(retainedWhileLocked.split(separator: "\n", omittingEmptySubsequences: true).count, 2_001)

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        _ = await store.refresh(for: fixture.id)
        let retainedAfterUnlock = try String(contentsOf: fixture.logURL, encoding: .utf8)
        let retainedLines = retainedAfterUnlock.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(retainedLines.count, 2_000)
        XCTAssertEqual(retainedLines.first, "line-2")
        XCTAssertEqual(retainedLines.last, "line-2001")
    }

    func testFileReplacementResetsOffsetWithoutRepeatingOldContent() async throws {
        let fixture = try LogEventFixture(id: "replace")
        defer { fixture.cleanup() }
        try fixture.write("old\n")

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let session = await store.openSession(for: fixture.id)
        try fixture.replace(with: "new\n")
        _ = await store.refresh(for: fixture.id)

        let event = try await nextEvent(from: session.events)
        XCTAssertEqual(event.snapshot.text, "new")
        XCTAssertFalse(event.snapshot.text.contains("old"))
        XCTAssertEqual(event.snapshot.fileState, .readable)
    }

    func testTwoTunnelsKeepEventsAndVersionsIsolated() async throws {
        let first = try LogEventFixture(id: "first")
        let second = try LogEventFixture(id: "second", sharedPaths: first.paths)
        defer { first.cleanup(); second.cleanup() }
        try first.write("A\n")
        try second.write("B\n")

        let store = LogEventStore(paths: first.paths, pollIntervalNanoseconds: 60_000_000_000)
        let firstSession = await store.openSession(for: first.id)
        let secondSession = await store.openSession(for: second.id)
        try first.append("A2\n")
        _ = await store.refresh(for: first.id)

        let firstEvent = try await nextEvent(from: firstSession.events)
        XCTAssertEqual(firstEvent.tunnelID, first.id)
        XCTAssertEqual(firstEvent.snapshot.text, "A\nA2")
        let secondSnapshot = await store.snapshot(for: second.id)
        XCTAssertEqual(secondSnapshot.text, "B")
        XCTAssertEqual(secondSnapshot.version, secondSession.snapshot.version)
    }

    func testClosingAndReopeningUsesLatestSnapshotWithoutStoppingCollector() async throws {
        let fixture = try LogEventFixture(id: "reopen")
        defer { fixture.cleanup() }
        try fixture.write("before\n")

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let firstSession = await store.openSession(for: fixture.id)
        firstSession.cancel()
        try fixture.append("during-close\n")
        _ = await store.refresh(for: fixture.id)

        let reopened = await store.openSession(for: fixture.id)
        XCTAssertEqual(reopened.snapshot.text, "before\nduring-close")
        XCTAssertGreaterThan(reopened.snapshot.version, firstSession.snapshot.version)
        reopened.cancel()
    }

    func testInvalidUTF8ProducesExplicitErrorState() async throws {
        let fixture = try LogEventFixture(id: "invalid")
        defer { fixture.cleanup() }
        try fixture.write(Data([0xFF, 0x0A]))

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let snapshot = await store.openSession(for: fixture.id).snapshot
        if case .error = snapshot.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("无效 UTF-8 必须进入明确错误状态")
        }
        XCTAssertTrue(snapshot.text.isEmpty)
    }

    func testLineIsLimitedTo8000Characters() async throws {
        let fixture = try LogEventFixture(id: "line-limit")
        defer { fixture.cleanup() }
        try fixture.write(String(repeating: "x", count: 8_100))

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let snapshot = await store.openSession(for: fixture.id).snapshot
        XCTAssertEqual(snapshot.text.count, 8_000)
    }

    private func nextEvent(
        from stream: AsyncStream<LogEvent>,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> LogEvent {
        try await withThrowingTaskGroup(of: LogEvent.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let event = await iterator.next() else {
                    throw NSError(domain: "LogEventStoreTests", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "事件流提前结束"
                    ])
                }
                return event
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NSError(domain: "LogEventStoreTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "等待日志事件超时"
                ])
            }
            defer { group.cancelAll() }
            guard let event = try await group.next() else {
                throw NSError(domain: "LogEventStoreTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "事件任务未返回结果"
                ])
            }
            return event
        }
    }
}

private struct LogEventFixture {
    let id: String
    let home: URL
    let paths: TunnelPaths

    init(id: String, sharedPaths: TunnelPaths? = nil) throws {
        self.id = id
        if let sharedPaths {
            self.paths = sharedPaths
            self.home = sharedPaths.homeDirectory
        } else {
            self.home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnelpad-log-event-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            self.paths = TunnelPaths(homeDirectory: home)
        }
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    }

    var logURL: URL {
        paths.logURL(for: TunnelConfig(id: id, name: id, command: ["/usr/bin/false"]))
    }

    func write(_ text: String) throws { try write(Data(text.utf8)) }

    func write(_ data: Data) throws {
        try data.write(to: logURL, options: .atomic)
    }

    func append(_ text: String) throws { try append(Data(text.utf8)) }

    func append(_ data: Data) throws {
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL)
        }
    }

    func replace(with text: String) throws {
        try Data(text.utf8).write(to: logURL, options: .atomic)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}
