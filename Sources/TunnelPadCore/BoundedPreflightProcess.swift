import Foundation
import Darwin

/// 监督器输出仅有小型结构化结果。非阻塞读避免管道/孙进程把取消拖成无界等待。
final class PreflightCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

struct BoundedPreflightProcess {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, cancellation: PreflightCancellation) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        if cancellation.isCancelled { throw CancellationError() }
        do { try process.run() } catch { throw ECSPreflightProcessError.launchFailed }
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeout, 0), 35)
        var cleanupDeadline: TimeInterval?
        var timedOut = false
        var out = Data(), err = Data()
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let outEOF = drain(outFD, into: &out), errEOF = drain(errFD, into: &err)
            if cleanupDeadline == nil && (cancellation.isCancelled || now >= deadline) {
                timedOut = !cancellation.isCancelled
                cleanupDeadline = now + 5
                if process.isRunning { process.terminate() }
            }
            if let cleanupDeadline, now >= cleanupDeadline {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                // Native worker independently detects guardian death and kills its owned group.
                process.waitUntilExit()
                break
            }
            if !process.isRunning && outEOF && errEOF { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if cancellation.isCancelled { throw CancellationError() }
        if timedOut { throw ECSPreflightProcessError.timedOut }
        return ProcessResult(exitCode: process.terminationStatus,
            stdout: String(data: out, encoding: .utf8) ?? "", stderr: String(data: err, encoding: .utf8) ?? "")
    }
    private static func drain(_ fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each turn even when a broken external process continuously writes.
        for _ in 0..<16 {
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size == 0 { return true }
            if size < 0 { return errno != EAGAIN && errno != EINTR }
            if data.count < 1_048_576 { data.append(contentsOf: buffer.prefix(min(size, 1_048_576 - data.count))) }
        }
        return false
    }
}
