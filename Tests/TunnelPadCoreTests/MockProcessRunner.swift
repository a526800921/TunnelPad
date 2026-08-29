import Foundation
import TunnelPadCore

/// 脚本化 mock：优先按 handler 路由，其次按顺序返回预置结果；队列耗尽时返回
/// `defaultResult`。记录每次调用便于断言命令序列。
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ProcessResult]
    private var defaultResult: ProcessResult
    private let handler: (@Sendable (_ executablePath: String, _ arguments: [String]) -> ProcessResult?)?
    private(set) var calls: [(executablePath: String, arguments: [String])] = []

    init(
        results: [ProcessResult] = [],
        defaultResult: ProcessResult = ProcessResult(exitCode: 0),
        handler: (@Sendable (_ executablePath: String, _ arguments: [String]) -> ProcessResult?)? = nil
    ) {
        self.queue = results
        self.defaultResult = defaultResult
        self.handler = handler
    }

    func run(executablePath: String, arguments: [String]) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append((executablePath, arguments))
        if let handler, let routed = handler(executablePath, arguments) { return routed }
        if queue.isEmpty { return defaultResult }
        return queue.removeFirst()
    }

    var recordedCalls: [(executablePath: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
