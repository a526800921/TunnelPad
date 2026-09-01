import Foundation
import Darwin

/// 日志文件的兼容状态视图；不把系统错误文本暴露给旧调用方。
public enum LogFileState: Equatable, Sendable {
    case missing
    case readable
    case unreadable
}

/// 日志文件当前可读状态。
public enum LogFileStatus: Equatable, Sendable {
    case available
    case missing
    case error(String)
}

/// 某条隧道在一个单调版本上的完整日志快照。
public struct LogSnapshot: Equatable, Sendable {
    public let tunnelID: String
    public let version: UInt64
    public let text: String
    public let status: LogFileStatus

    public var fileState: LogFileState {
        switch status {
        case .available: return .readable
        case .missing: return .missing
        case .error: return .unreadable
        }
    }

    public init(tunnelID: String, version: UInt64, text: String, status: LogFileStatus) {
        self.tunnelID = tunnelID
        self.version = version
        self.text = text
        self.status = status
    }
}

/// 日志采集器发布的事件；快照是 UI 的权威渲染输入。
public struct LogEvent: Equatable, Sendable {
    public let tunnelID: String
    public let version: UInt64
    public let appendedText: String
    public let snapshot: LogSnapshot

    public init(tunnelID: String, version: UInt64, appendedText: String, snapshot: LogSnapshot) {
        self.tunnelID = tunnelID
        self.version = version
        self.appendedText = appendedText
        self.snapshot = snapshot
    }
}

/// 当前隧道的一次日志订阅。取消只移除 UI 订阅，不停止后台采集。
public struct LogSession: Sendable {
    public let snapshot: LogSnapshot
    public let events: AsyncStream<LogEvent>

    private let cancellation: (@Sendable () -> Void)?

    init(
        snapshot: LogSnapshot,
        events: AsyncStream<LogEvent>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        self.snapshot = snapshot
        self.events = events
        self.cancellation = cancellation
    }

    /// 兼容仅持有 stream 的旧构造方式。
    public init(snapshot: LogSnapshot, events: AsyncStream<LogEvent>) {
        self.snapshot = snapshot
        self.events = events
        self.cancellation = nil
    }

    public func cancel() {
        cancellation?()
    }
}

private enum LogPolicy {
    static let memoryLineLimit = 500
    static let maxLineCharacters = 8_000
    static let persistedLineLimit = 2_000
}

enum LogEventStoreError: Error, CustomStringConvertible {
    case invalidUTF8
    case lockUnavailable
    case fileChanged
    case io(String)

    var description: String {
        switch self {
        case .invalidUTF8: return "日志文件包含无效 UTF-8"
        case .lockUnavailable: return "日志文件当前被其他写入者占用"
        case .fileChanged: return "日志文件在裁剪期间发生变化"
        case let .io(message): return message
        }
    }
}

/// 按字节解析日志，允许多字节 UTF-8 字符跨读取边界。
struct LogLineParser: Sendable {
    private(set) var lines: [String] = []
    private var partialData = Data()

    mutating func reset() {
        lines.removeAll(keepingCapacity: true)
        partialData.removeAll(keepingCapacity: true)
    }

    mutating func consume(_ data: Data) throws {
        guard !data.isEmpty else { return }
        var combined = partialData
        combined.append(data)
        var cursor = combined.startIndex

        while let newline = combined[cursor...].firstIndex(of: 0x0A) {
            let lineData = Data(combined[cursor..<newline])
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw LogEventStoreError.invalidUTF8
            }
            lines.append(Self.limited(line.hasSuffix("\r") ? String(line.dropLast()) : line))
            if lines.count > LogPolicy.memoryLineLimit {
                lines.removeFirst(lines.count - LogPolicy.memoryLineLimit)
            }
            cursor = combined.index(after: newline)
        }
        partialData = Data(combined[cursor...])
    }

    var renderedText: String {
        var visible = lines
        if !partialData.isEmpty, let partial = String(data: partialData, encoding: .utf8) {
            visible = Array(visible.suffix(max(0, LogPolicy.memoryLineLimit - 1)))
            visible.append(Self.limited(partial))
        }
        return visible.joined(separator: "\n")
    }

    private static func limited(_ value: String) -> String {
        String(value.prefix(LogPolicy.maxLineCharacters))
    }
}

/// 文件超过上限时原位保留最近行，尽量保持 launchd 已打开的文件身份。
enum LogFileRetention {
    @discardableResult
    static func trimIfNeeded(of url: URL, maxLines: Int = LogPolicy.persistedLineLimit) throws -> Bool {
        guard maxLines > 0, FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw LogEventStoreError.io(String(describing: error))
        }
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LogEventStoreError.lockUnavailable
        }
        defer { _ = flock(handle.fileDescriptor, LOCK_UN) }

        try handle.seek(toOffset: 0)
        let original = try handle.readToEnd() ?? Data()
        guard let text = String(data: original, encoding: .utf8) else {
            throw LogEventStoreError.invalidUTF8
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasTrailingNewline = text.last == "\n"
        if hasTrailingNewline, lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > maxLines else { return false }

        var retained = lines.suffix(maxLines).joined(separator: "\n")
        if hasTrailingNewline { retained.append("\n") }
        let replacement = Data(retained.utf8)

        try handle.seek(toOffset: 0)
        guard (try handle.readToEnd() ?? Data()) == original else {
            throw LogEventStoreError.fileChanged
        }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: replacement)
            try handle.truncate(atOffset: UInt64(replacement.count))
            try handle.synchronize()
        } catch {
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: original)
                try handle.truncate(atOffset: UInt64(original.count))
                try handle.synchronize()
            } catch {
                // 保留首个写入错误；恢复失败也不能报告裁剪成功。
            }
            throw LogEventStoreError.io(String(describing: error))
        }
        return true
    }
}

/// launchd 日志文件的后台增量采集、每隧道缓存和事件发布 owner。
public actor LogEventStore {
    public static let memoryLineLimit = LogPolicy.memoryLineLimit
    public static let lineCharacterLimit = LogPolicy.maxLineCharacters
    public static let fileLineLimit = LogPolicy.persistedLineLimit

    private struct State {
        var parser = LogLineParser()
        var identity: FileIdentity?
        var offset: UInt64 = 0
        var snapshot: LogSnapshot
        var subscribers: [UUID: AsyncStream<LogEvent>.Continuation] = [:]

        init(id: String) {
            snapshot = LogSnapshot(tunnelID: id, version: 0, text: "", status: .missing)
        }

        mutating func finish() {
            for subscriber in subscribers.values { subscriber.finish() }
            subscribers.removeAll()
        }
    }

    private let paths: TunnelPaths
    private var states: [String: State] = [:]
    private var watchers: [String: LogFileWatcher] = [:]
    private var isShutdown = false

    public init(paths: TunnelPaths) {
        self.paths = paths
    }

    /// 兼容旧 fixture 的注入初始化器；生产采集不使用固定 Timer。
    init(paths: TunnelPaths, pollIntervalNanoseconds _: UInt64) {
        self.paths = paths
    }

    public func sync(tunnelIDs: [String]) {
        guard !isShutdown else { return }
        let desired = Set(tunnelIDs)
        for id in desired {
            ensureState(id)
            ensureWatcher(id)
            _ = refreshState(id, publish: false)
        }
        let stale = states.keys.filter { !desired.contains($0) }
        for id in stale { remove(tunnelID: id) }
    }

    public func openSession(for tunnelID: String) -> LogSession {
        guard !isShutdown else {
            let snapshot = LogSnapshot(tunnelID: tunnelID, version: 0, text: "", status: .error("日志采集器已关闭"))
            let stream = AsyncStream<LogEvent> { $0.finish() }
            return LogSession(snapshot: snapshot, events: stream)
        }
        ensureState(tunnelID)
        ensureWatcher(tunnelID)
        _ = refreshState(tunnelID, publish: false)

        let token = UUID()
        let (stream, continuation) = AsyncStream<LogEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        states[tunnelID]?.subscribers[token] = continuation
        let cancellation: @Sendable () -> Void = { [weak self] in
            Task { await self?.cancelSubscriber(tunnelID: tunnelID, token: token) }
        }
        return LogSession(snapshot: states[tunnelID]!.snapshot, events: stream, cancellation: cancellation)
    }

    /// 兼容旧调用标签。
    public func openSession(tunnelID: String) -> LogSession {
        openSession(for: tunnelID)
    }

    @discardableResult
    public func refresh(for tunnelID: String) -> LogSnapshot {
        guard !isShutdown else {
            return LogSnapshot(tunnelID: tunnelID, version: 0, text: "", status: .error("日志采集器已关闭"))
        }
        ensureState(tunnelID)
        ensureWatcher(tunnelID)
        return refreshState(tunnelID, publish: true)
    }

    /// 兼容旧 fixture 的一次显式采集入口。
    func pollNow(tunnelID: String) {
        _ = refresh(for: tunnelID)
    }

    public func snapshot(for tunnelID: String) -> LogSnapshot {
        if let state = states[tunnelID] { return state.snapshot }
        return refresh(for: tunnelID)
    }

    public func startMonitoring(tunnelID: String) {
        ensureState(tunnelID)
        ensureWatcher(tunnelID)
        _ = refreshState(tunnelID, publish: false)
    }

    public func remove(tunnelID: String) {
        watchers.removeValue(forKey: tunnelID)?.cancel()
        if var state = states.removeValue(forKey: tunnelID) { state.finish() }
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
        let ids = Array(states.keys)
        for id in ids {
            if var state = states[id] { state.finish(); states[id] = state }
        }
        states.removeAll()
    }

    private func ensureState(_ tunnelID: String) {
        if states[tunnelID] == nil { states[tunnelID] = State(id: tunnelID) }
    }

    private func ensureWatcher(_ tunnelID: String) {
        guard watchers[tunnelID] == nil, !isShutdown else { return }
        let url = logURL(for: tunnelID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        watchers[tunnelID] = LogFileWatcher(url: url) { [weak self] flags in
            Task { await self?.fileDidChange(tunnelID: tunnelID, flags: flags) }
        }
    }

    private func fileDidChange(tunnelID: String, flags: UInt32) {
        guard !isShutdown, states[tunnelID] != nil else { return }
        _ = refreshState(tunnelID, publish: true)
        let mask = UInt32(
            DispatchSource.FileSystemEvent.rename.rawValue |
            DispatchSource.FileSystemEvent.delete.rawValue |
            DispatchSource.FileSystemEvent.revoke.rawValue
        )
        let path = logURL(for: tunnelID)
        let changedKind = FileManager.default.fileExists(atPath: path.path) != watchers[tunnelID]?.watchesFile
        if flags & mask != 0 || changedKind {
            watchers.removeValue(forKey: tunnelID)?.cancel()
            ensureWatcher(tunnelID)
        }
    }

    private func cancelSubscriber(tunnelID: String, token: UUID) {
        states[tunnelID]?.subscribers.removeValue(forKey: token)
    }

    private func refreshState(_ tunnelID: String, publish: Bool) -> LogSnapshot {
        ensureState(tunnelID)
        var state = states[tunnelID]!
        let url = logURL(for: tunnelID)
        let previous = state.snapshot

        do { _ = try LogFileRetention.trimIfNeeded(of: url) } catch { /* 保留原文件，下一次继续尝试 */ }

        guard FileManager.default.fileExists(atPath: url.path) else {
            state.parser.reset(); state.identity = nil; state.offset = 0
            state.snapshot = nextSnapshot(
                id: tunnelID, previous: previous, text: "", status: .missing,
                appendedText: "", state: &state, publish: publish
            )
            states[tunnelID] = state
            return state.snapshot
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            state.parser.reset(); state.identity = nil; state.offset = 0
            state.snapshot = nextSnapshot(
                id: tunnelID, previous: previous, text: "", status: .error(String(describing: error)),
                appendedText: "", state: &state, publish: publish
            )
            states[tunnelID] = state
            return state.snapshot
        }

        let identity = FileIdentity(attributes: attributes)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if state.identity != identity || size < state.offset {
            state.parser.reset(); state.offset = 0
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: state.offset)
            let data = try handle.readToEnd() ?? Data()
            try state.parser.consume(data)
            state.offset = size
            state.identity = identity
            state.snapshot = nextSnapshot(
                id: tunnelID, previous: previous, text: state.parser.renderedText, status: .available,
                appendedText: appendText(data: data, old: previous.text, new: state.parser.renderedText),
                state: &state, publish: publish
            )
        } catch {
            state.parser.reset(); state.identity = nil; state.offset = 0
            state.snapshot = nextSnapshot(
                id: tunnelID, previous: previous, text: "", status: .error(String(describing: error)),
                appendedText: "", state: &state, publish: publish
            )
        }
        states[tunnelID] = state
        return state.snapshot
    }

    private func nextSnapshot(
        id: String,
        previous: LogSnapshot,
        text: String,
        status: LogFileStatus,
        appendedText: String,
        state: inout State,
        publish: Bool
    ) -> LogSnapshot {
        guard previous.text != text || previous.status != status else { return previous }
        let snapshot = LogSnapshot(tunnelID: id, version: previous.version &+ 1, text: text, status: status)
        let onlyIncompleteFirstWrite = previous.status == .missing && status == .available && text.isEmpty
        if publish && !onlyIncompleteFirstWrite {
            let event = LogEvent(tunnelID: id, version: snapshot.version, appendedText: appendedText, snapshot: snapshot)
            for subscriber in state.subscribers.values { subscriber.yield(event) }
        }
        return snapshot
    }

    private func appendText(data: Data, old: String, new: String) -> String {
        if let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty { return decoded }
        guard new.hasPrefix(old) else { return new }
        return String(new.dropFirst(old.count))
    }

    private func logURL(for tunnelID: String) -> URL {
        paths.logsDirectory.appendingPathComponent("\(tunnelID).log")
    }
}

/// 保留现有阶段 1 fixture 使用的名称；唯一实现仍是 LogEventStore。
public typealias LogStore = LogEventStore

private struct FileIdentity: Equatable, Sendable {
    let fileNumber: UInt64
    let deviceNumber: UInt64

    init(attributes: [FileAttributeKey: Any]) {
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

private final class LogFileWatcher: @unchecked Sendable {
    let watchesFile: Bool
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, callback: @escaping @Sendable (UInt32) -> Void) {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let watchedURL = fileExists ? url : url.deletingLastPathComponent()
        let descriptor = Darwin.open(watchedURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: DispatchQueue(label: "TunnelPad.LogWatcher", qos: .utility)
        )
        self.watchesFile = fileExists
        self.source = source
        source.setEventHandler { [weak source] in
            guard let source else { return }
            callback(UInt32(truncatingIfNeeded: source.data.rawValue))
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }
}
