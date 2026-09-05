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
        let payload = String(repeating: "x", count: 300)
        let content = (1...2_001).map { "line-\($0)-\(payload)" }.joined(separator: "\n") + "\n"
        try fixture.write(content)

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let snapshot = await store.openSession(for: fixture.id).snapshot
        let visibleLines = snapshot.text.split(separator: "\n")
        XCTAssertEqual(visibleLines.count, 500)
        XCTAssertTrue(visibleLines.first?.hasPrefix("line-1502-") == true)
        XCTAssertTrue(visibleLines.last?.hasPrefix("line-2001-") == true)

        let retained = try String(contentsOf: fixture.logURL, encoding: .utf8)
        let retainedLines = retained.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(retainedLines.count, 2_000)
        XCTAssertTrue(retainedLines.first?.hasPrefix("line-2-") == true)
        XCTAssertTrue(retainedLines.last?.hasPrefix("line-2001-") == true)
    }

    func testRetentionWaitsForHighWatermarkAndDoesNotRecompactEveryAppend() async throws {
        let fixture = try LogEventFixture(id: "high-watermark")
        defer { fixture.cleanup() }
        let smallPayload = String(repeating: "s", count: 120)
        try fixture.write((1...2_001).map { "base-\($0)-\(smallPayload)" }.joined(separator: "\n") + "\n")

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        _ = await store.openSession(for: fixture.id)
        try fixture.append("below-threshold\n")
        _ = await store.refresh(for: fixture.id)
        XCTAssertEqual(logicalLines(try Data(contentsOf: fixture.logURL)).count, 2_002)

        let growthPayload = String(repeating: "g", count: 200)
        let growth = (1...2_000).map { "growth-\($0)-\(growthPayload)" }.joined(separator: "\n") + "\n"
        try fixture.append(growth)
        _ = await store.refresh(for: fixture.id)
        let retainedAfterWatermark = logicalLines(try Data(contentsOf: fixture.logURL))
        XCTAssertEqual(retainedAfterWatermark.count, 2_000)
        XCTAssertTrue(retainedAfterWatermark.last?.hasPrefix("growth-2000-") == true)

        try fixture.append("one-more-line\n")
        _ = await store.refresh(for: fixture.id)
        let retainedAfterSingleAppend = logicalLines(try Data(contentsOf: fixture.logURL))
        XCTAssertEqual(retainedAfterSingleAppend.count, 2_001)
        XCTAssertEqual(retainedAfterSingleAppend.last, "one-more-line")
    }

    func testRetentionCountsCRLFAndPreservesRawLineEndings() throws {
        let fixture = try LogEventFixture(id: "crlf-retention")
        defer { fixture.cleanup() }
        let content = (1...2_001).map { "line-\($0)" }.joined(separator: "\r\n") + "\r\n"
        let original = Data(content.utf8)
        try fixture.write(original)

        XCTAssertTrue(try LogFileRetention.trimIfNeeded(of: fixture.logURL))

        let retained = try Data(contentsOf: fixture.logURL)
        XCTAssertNotNil(retained.range(of: Data("\r\n".utf8)))
        XCTAssertNil(retained.range(of: Data("line-1\r\n".utf8)))
        XCTAssertEqual(logicalLines(retained).count, 2_000)
        XCTAssertEqual(logicalLines(retained).first, "line-2")
        XCTAssertEqual(logicalLines(retained).last, "line-2001")
    }

    func testRetentionSupportsMixedLineEndingsAndUnterminatedFinalLine() throws {
        let fixture = try LogEventFixture(id: "mixed-retention")
        defer { fixture.cleanup() }
        try fixture.write(Data("old\r\nkeep-a\nkeep-b\r\nbare\rvalue".utf8))

        XCTAssertTrue(try LogFileRetention.trimIfNeeded(of: fixture.logURL, maxLines: 2))
        XCTAssertEqual(try String(contentsOf: fixture.logURL, encoding: .utf8), "keep-b\r\nbare\rvalue")
    }

    func testRetentionLeavesEmptyAndSmallFilesUntouched() throws {
        let emptyFixture = try LogEventFixture(id: "empty-retention")
        defer { emptyFixture.cleanup() }
        try emptyFixture.write(Data())
        XCTAssertFalse(try LogFileRetention.trimIfNeeded(of: emptyFixture.logURL))
        XCTAssertEqual(try Data(contentsOf: emptyFixture.logURL), Data())

        let smallFixture = try LogEventFixture(id: "small-retention")
        defer { smallFixture.cleanup() }
        let original = Data("one\r\ntwo\rthree".utf8)
        try smallFixture.write(original)
        XCTAssertFalse(try LogFileRetention.trimIfNeeded(of: smallFixture.logURL, maxLines: 3))
        XCTAssertEqual(try Data(contentsOf: smallFixture.logURL), original)
    }

    func testRetentionScansTailOfLargeCRLFFileForBoundedCost() throws {
        let fixture = try LogEventFixture(id: "large-crlf-retention")
        defer { fixture.cleanup() }
        let payload = String(repeating: "x", count: 390)
        let content = (1...20_001).map { "line-\($0)-\(payload)" }.joined(separator: "\r\n") + "\r\n"
        let original = Data(content.utf8)
        try fixture.write(original)

        var metrics: LogRetentionMetrics? = LogRetentionMetrics()
        XCTAssertTrue(try LogFileRetention.trimIfNeeded(of: fixture.logURL, maxLines: 2_000, metrics: &metrics))
        XCTAssertLessThan(metrics?.scanBytes ?? UInt64(original.count), UInt64(original.count / 2))
        XCTAssertEqual(logicalLines(try Data(contentsOf: fixture.logURL)).count, 2_000)
    }

    func testRetentionDefersWhenFileIsLockedAndRetriesLater() async throws {
        let fixture = try LogEventFixture(id: "locked-retention")
        defer { fixture.cleanup() }
        let payload = String(repeating: "x", count: 300)
        let content = (1...2_001).map { "line-\($0)-\(payload)" }.joined(separator: "\n") + "\n"
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
        XCTAssertTrue(retainedLines.first?.hasPrefix("line-2-") == true)
        XCTAssertTrue(retainedLines.last?.hasPrefix("line-2001-") == true)
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

    func testClearTruncatesInPlaceAndPublishesMonotonicSnapshot() async throws {
        let fixture = try LogEventFixture(id: "clear")
        defer { fixture.cleanup() }
        try fixture.write("before\n")

        let store = LogEventStore(paths: fixture.paths, pollIntervalNanoseconds: 60_000_000_000)
        let session = await store.openSession(for: fixture.id)
        let cleared = await store.clear(for: fixture.id)

        XCTAssertEqual(cleared.text, "")
        XCTAssertEqual(cleared.status, .available)
        XCTAssertGreaterThan(cleared.version, session.snapshot.version)
        XCTAssertEqual(try String(contentsOf: fixture.logURL, encoding: .utf8), "")

        let event = try await nextEvent(from: session.events)
        XCTAssertEqual(event.snapshot, cleared)
        XCTAssertEqual(event.appendedText, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.logURL.path))
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

private func logicalLines(_ data: Data) -> [String] {
    var lines: [String] = []
    var start = data.startIndex

    for index in data.indices where data[index] == 0x0A {
        let rawLine = data[start..<index]
        let lineData = rawLine.last == 0x0D ? Data(rawLine.dropLast()) : Data(rawLine)
        lines.append(String(decoding: lineData, as: UTF8.self))
        start = data.index(after: index)
    }

    if start < data.endIndex {
        lines.append(String(decoding: data[start...], as: UTF8.self))
    }

    return lines
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
