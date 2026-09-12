import Foundation

/// App 事件日志：启动恢复等 App 侧事件的追加式文本日志（`app.log`）。
/// 隧道进程输出与其保留策略（高水位压缩）由 launchd 重定向与 Rust owner 负责，
/// 本文件只承载低频 App 事件；写入即追加一行，超过上限时保留较新的一半。
public final class AppEventLog: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(paths: TunnelPaths, maxBytes: Int = 512 * 1024) {
        self.fileURL = paths.appEventLogURL
        self.maxBytes = maxBytes
    }

    /// 追加一条事件；时间戳为 ISO8601。写入失败静默，日志不得影响主流程。
    public func write(_ message: String, date: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: date)) [TunnelPad] \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
        rotateIfNeeded(fileManager)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// 超限时保留较新的一半并丢弃首行残段，避免 App 事件日志无限增长。
    private func rotateIfNeeded(_ fileManager: FileManager) {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int, size > maxBytes,
            let content = fileManager.contents(atPath: fileURL.path),
            content.count > maxBytes / 2
        else { return }
        var tail = content.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        fileManager.createFile(atPath: fileURL.path, contents: Data(tail))
    }
}
