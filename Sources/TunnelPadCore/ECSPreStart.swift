import Foundation

/// ECS 动态 SSH 同步前置检查。非 SSH 命令必须直接放行，不启动外部进程。
protocol ECSPreStartChecking: Sendable {
    func check(tunnel: TunnelConfig) throws
    func checkAsync(tunnel: TunnelConfig) async throws
}

/// 仅供 ECS 前置同步使用的进程协议，不扩展现有 launchctl ProcessRunning，
/// 避免影响既有启动、迁移和差分测试调用图。
protocol ECSPreflightProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult

    func runAsync(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult
}

enum ECSPreflightProcessError: Error, Equatable, Sendable {
    case timedOut
    case launchFailed
}

enum ECSPreStartError: Error, LocalizedError, Equatable, Sendable {
    case scriptUnavailable
    case commandFailed(exitCode: Int32)
    case timedOut
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            return "ECS 公网 IP 同步资源缺失"
        case .commandFailed(let exitCode):
            return "ECS 公网 IP 同步失败（退出码 \(exitCode)：\(Self.message(for: exitCode))）"
        case .timedOut:
            return "ECS 公网 IP 同步超时（30 秒）"
        case .launchFailed:
            return "ECS 公网 IP 同步进程无法启动"
        }
    }

    private static func message(for exitCode: Int32) -> String {
        switch exitCode {
        case 2: return "配置或依赖错误"
        case 3: return "公网 IPv4 探测失败"
        case 4: return "云端状态读取失败或受管规则歧义"
        case 5: return "新增规则失败或未确认"
        case 6: return "旧规则清理失败"
        case 7: return "已有同步进程运行"
        default: return "外部命令失败"
        }
    }
}

struct ECSPreStartChecker: ECSPreStartChecking, Sendable {
    static let bashPath = "/bin/bash"
    static let scriptName = "update-ecs-ssh-ip"
    static let defaultTimeout: TimeInterval = 30
    private static let fallbackPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    let scriptURL: URL?
    let runner: any ECSPreflightProcessRunning
    let environment: [String: String]
    let timeout: TimeInterval

    init(
        scriptURL: URL? = ECSPreStartChecker.defaultScriptURL(),
        runner: any ECSPreflightProcessRunning = SystemECSPreflightProcessRunner(),
        environment: [String: String] = ECSPreStartChecker.defaultEnvironment(),
        timeout: TimeInterval = ECSPreStartChecker.defaultTimeout
    ) {
        self.scriptURL = scriptURL
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    func check(tunnel: TunnelConfig) throws {
        guard SSHCommand.isSSH(tunnel.command) else { return }
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ECSPreStartError.scriptUnavailable
        }

        do {
            let result = try runner.run(
                executablePath: Self.bashPath,
                arguments: [scriptURL.path],
                environment: environment,
                timeout: timeout
            )
            try Self.validate(result)
        } catch ECSPreflightProcessError.timedOut {
            throw ECSPreStartError.timedOut
        } catch ECSPreflightProcessError.launchFailed {
            throw ECSPreStartError.launchFailed
        }
    }

    func checkAsync(tunnel: TunnelConfig) async throws {
        guard SSHCommand.isSSH(tunnel.command) else { return }
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ECSPreStartError.scriptUnavailable
        }
        try Task.checkCancellation()

        do {
            let result = try await runWithTimeout(
                executablePath: Self.bashPath,
                arguments: [scriptURL.path],
                environment: environment
            )
            try Task.checkCancellation()
            try Self.validate(result)
        } catch is CancellationError {
            throw CancellationError()
        } catch ECSPreflightProcessError.timedOut {
            throw ECSPreStartError.timedOut
        } catch ECSPreflightProcessError.launchFailed {
            throw ECSPreStartError.launchFailed
        }
    }

    static func defaultScriptURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent(scriptName)
    }

    static let allowedEnvironmentKeys = [
        "PATH",
        "HOME",
        "TMPDIR",
        "TUNNELPAD_CONFIG_FILE",
        "TUNNELPAD_ALIYUN_CONFIG",
        "ALIBABA_PROFILE",
        "ALIBABA_REGION_ID",
        "ECS_SECURITY_GROUP_ID",
        "TUNNELPAD_IP_ENDPOINT_1",
        "TUNNELPAD_IP_ENDPOINT_2",
        "TUNNELPAD_LOCK_DIR",
        "TUNNELPAD_LOG_FILE",
        "CURL_BIN",
        "ALIYUN_BIN",
        "JQ_BIN",
        "SHASUM_BIN",
        "UUIDGEN_BIN",
    ]

    static func defaultEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = source[key] {
                result[key] = value
            }
        }

        // Finder/launchd 不保证继承登录 shell 的 PATH 或 HOME；外部同步命令
        // 仍只使用 allowlist，但需要稳定找到本机 CLI 和仓库外配置。
        result["PATH"] = mergedPath(source["PATH"])
        result["HOME"] = nonEmpty(source["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return result
    }

    private static func mergedPath(_ inherited: String?) -> String {
        var entries: [String] = []
        var seen = Set<String>()
        let inheritedEntries = (inherited ?? "").split(separator: ":").map(String.init)
        for entry in inheritedEntries + fallbackPathEntries {
            guard !entry.isEmpty, entry.hasPrefix("/") else { continue }
            guard seen.insert(entry).inserted else { continue }
            entries.append(entry)
        }
        return entries.joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func validate(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            // 不把外部 stdout/stderr 原文交给 UI，避免未来脚本变更造成凭证或公网 IP 泄露。
            throw ECSPreStartError.commandFailed(exitCode: result.exitCode)
        }
    }

    private func runWithTimeout(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await runner.runAsync(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment
                )
            }
            group.addTask {
                let nanoseconds = UInt64((min(max(timeout, 0), 86_400) * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ECSPreflightProcessError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ECSPreflightProcessError.timedOut
            }
            return result
        }
    }
}

struct SystemECSPreflightProcessRunner: ECSPreflightProcessRunning, Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = DataBox()
        let stderr = DataBox()
        let group = DispatchGroup()
        do {
            try process.run()
        } catch {
            return try handleLaunchFailure(error)
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
                process.waitUntilExit()
                group.wait()
                throw ECSPreflightProcessError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        group.wait()
        return makeResult(process: process, stdout: stdout.data, stderr: stderr.data)
    }

    func runAsync(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let controller = ProcessController()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                    controller.install(process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                } catch {
                    continuation.resume(throwing: ECSPreflightProcessError.launchFailed)
                    return
                }

                let stdoutData = DataBox()
                let stderrData = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()
                    group.wait()
                    continuation.resume(returning: makeResult(
                        process: process,
                        stdout: stdoutData.data,
                        stderr: stderrData.data
                    ))
                }
            }
        }, onCancel: {
            controller.terminate()
        })
    }

    private func handleLaunchFailure(_ error: Error) throws -> ProcessResult {
        _ = error
        throw ECSPreflightProcessError.launchFailed
    }

    private func makeResult(process: Process, stdout: Data, stderr: Data) -> ProcessResult {
        ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var value: Data {
        get { data }
        set {
            lock.lock()
            storedData = newValue
            lock.unlock()
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var terminationRequested = false

    func install(_ process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        lock.lock()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        let shouldTerminate = terminationRequested
        lock.unlock()
        if shouldTerminate {
            process.terminate()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
        }
    }

    func terminate() {
        lock.lock()
        terminationRequested = true
        let process = self.process
        let stdoutPipe = self.stdoutPipe
        let stderrPipe = self.stderrPipe
        lock.unlock()
        process?.terminate()
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()
    }
}
