import Foundation
import Darwin

/// 日志写入的 Sendable 包装（线程安全由调用方锁纪律保证；FileHandle 写单个文件并发追加安全）。
private final class LogWriter: @unchecked Sendable {
    let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        handle.write(data)
    }

    func close() {
        try? handle.close()
    }
}

/// app 执行器：直接托管子进程（ModelPad 模式）。
/// - start：spawn `command`（不经 shell），stdout/stderr 追加写入日志文件，写 pidfile。
/// - stop：SIGTERM → 最多 5s → SIGKILL；删除 pidfile。
/// - keepAlive：意外退出（非手动停止）延迟 `throttleInterval` 秒自动重启。
/// - shutdownAll：退出 app 时终止全部子进程（正常退出路径）。
/// 信号退出路径（SIGTERM/SIGINT）无法访问本对象内存，改由 `Shutdown` 按 pidfile 终止。
public final class AppProcessExecutor: @unchecked Sendable {

    private final class Context: @unchecked Sendable {
        let process: Process
        let tunnel: TunnelConfig
        let logWriter: LogWriter
        let generation: Int
        var manualStop = false

        init(process: Process, tunnel: TunnelConfig, logWriter: LogWriter, generation: Int) {
            self.process = process
            self.tunnel = tunnel
            self.logWriter = logWriter
            self.generation = generation
        }
    }

    private var contexts: [String: Context] = [:]
    private let lock = NSLock()
    private let paths: TunnelPaths
    /// 测试注入：覆盖 keepAlive 重启延迟（秒）；nil 用 tunnel.throttleInterval。
    private let restartDelayOverride: TimeInterval?

    public init(paths: TunnelPaths, restartDelayOverride: TimeInterval? = nil) {
        self.paths = paths
        self.restartDelayOverride = restartDelayOverride
    }

    // MARK: - 生命周期

    public func start(_ tunnel: TunnelConfig) throws {
        lock.lock()
        if let existing = contexts[tunnel.id], existing.process.isRunning {
            lock.unlock()
            return
        }
        lock.unlock()

        let logWriter = try openLogWriter(for: tunnel)
        let generation = nextGeneration(for: tunnel.id)
        let process = try spawn(tunnel, logWriter: logWriter, generation: generation)

        lock.lock()
        contexts[tunnel.id] = Context(process: process, tunnel: tunnel, logWriter: logWriter, generation: generation)
        lock.unlock()

        try writePidfile(pid: process.processIdentifier, tunnel: tunnel)
    }

    public func stop(_ tunnel: TunnelConfig) {
        lock.lock()
        guard let ctx = contexts.removeValue(forKey: tunnel.id) else {
            lock.unlock()
            removePidfile(tunnel)
            return
        }
        ctx.manualStop = true
        let process = ctx.process
        let pid = process.processIdentifier
        lock.unlock()

        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }

        closeLogHandle(ctx)
        removePidfile(tunnel)
    }

    public func restart(_ tunnel: TunnelConfig) throws {
        stop(tunnel)
        try start(tunnel)
    }

    public func status(id: String) -> TunnelStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = contexts[id], ctx.process.isRunning else { return .notLoaded }
        return .running(pid: ctx.process.processIdentifier)
    }

    /// 退出 app 路径：终止全部子进程（SIGTERM → 最多 5s → SIGKILL）。
    public func shutdownAll() {
        lock.lock()
        let all = Array(contexts.values)
        contexts.removeAll()
        for ctx in all { ctx.manualStop = true }
        lock.unlock()

        for ctx in all {
            let process = ctx.process
            let pid = process.processIdentifier
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
                process.waitUntilExit()
            }
            closeLogHandle(ctx)
            removePidfile(ctx.tunnel)
        }
    }

    public func managedIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(contexts.keys).sorted()
    }

    // MARK: - 内部

    private func nextGeneration(for id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (contexts[id]?.generation ?? 0) + 1
    }

    private func openLogWriter(for tunnel: TunnelConfig) throws -> LogWriter {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        let url = paths.logURL(for: tunnel)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return LogWriter(handle: handle)
    }

    private func appendLog(_ ctx: Context, _ line: String) {
        ctx.logWriter.write(Data("\(line)\n".utf8))
    }

    private func spawn(_ tunnel: TunnelConfig, logWriter: LogWriter, generation: Int) throws -> Process {
        guard !tunnel.command.isEmpty else {
            throw ExecutorError.commandFailed(operation: "spawn", exitCode: -1, stderr: "command 为空")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tunnel.command[0])
        process.arguments = Array(tunnel.command.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 管道输出追加到日志文件
        for pipe in [stdoutPipe, stderrPipe] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                logWriter.write(data)
            }
        }

        let ctx = Context(process: process, tunnel: tunnel, logWriter: logWriter, generation: generation)
        let executor = self

        process.terminationHandler = { proc in
            executor.handleTermination(ctx: ctx, process: proc)
        }

        try process.run()
        appendLog(ctx, "[\(Self.timestamp())] spawned pid=\(process.processIdentifier) (executor=app)")
        return process
    }

    /// 进程退出回调：摘除上下文；手动停止由 stop() 收尾；
    /// 意外退出记日志并（keepAlive 时）延迟重启。
    private func handleTermination(ctx: Context, process: Process) {
        lock.lock()
        let current = contexts[ctx.tunnel.id]
        guard let current, current.generation == ctx.generation else {
            lock.unlock()
            return
        }
        contexts.removeValue(forKey: ctx.tunnel.id)
        let manualStop = ctx.manualStop
        lock.unlock()

        guard !manualStop else { return }

        appendLog(ctx, "[\(Self.timestamp())] process exited unexpectedly code=\(process.terminationStatus)")
        closeLogHandle(ctx)
        removePidfile(ctx.tunnel)

        guard ctx.tunnel.keepAlive else { return }

        let delay = restartDelayOverride ?? TimeInterval(ctx.tunnel.throttleInterval)
        let tunnel = ctx.tunnel
        let executor = self
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            try? executor.start(tunnel)
        }
    }

    private func writePidfile(pid: Int32, tunnel: TunnelConfig) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: paths.pidfileURL(for: tunnel), options: .atomic)
    }

    private func removePidfile(_ tunnel: TunnelConfig) {
        try? FileManager.default.removeItem(at: paths.pidfileURL(for: tunnel))
    }

    private func closeLogHandle(_ ctx: Context) {
        ctx.logWriter.close()
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
