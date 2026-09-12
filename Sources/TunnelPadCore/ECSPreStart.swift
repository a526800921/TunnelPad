import Foundation

/// ECS 动态 SSH 同步前置检查。非 SSH 命令必须直接放行，不启动外部进程。
protocol ECSPreStartChecking: Sendable {
    /// 自动恢复前是否必须先卸载 launchd 实例，阻止 KeepAlive 绕过同步前置。
    /// 默认 false，保持注入式非 ECS checker 与既有普通恢复路径兼容。
    var requiresAutomaticRecoveryQuiescence: Bool { get }
    func check(tunnel: TunnelConfig) throws
    func checkAsync(tunnel: TunnelConfig) async throws
}

extension ECSPreStartChecking {
    var requiresAutomaticRecoveryQuiescence: Bool { false }
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

    var requiresAutomaticRecoveryQuiescence: Bool { true }

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
    func run(executablePath: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        try BoundedPreflightProcess.run(executable: executablePath, arguments: arguments, environment: environment,
            timeout: timeout, cancellation: PreflightCancellation())
    }

    func runAsync(executablePath: String, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        let cancellation = PreflightCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try BoundedPreflightProcess.run(executable: executablePath, arguments: arguments, environment: environment,
                    timeout: 35, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
    }

}

protocol LaunchPreflightChecking: ECSPreStartChecking {
    func launchResource() async throws -> String
    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult
}

extension ECSPreStartChecker: LaunchPreflightChecking {
    func launchResource() async throws -> String {
        let result = try await launchInvocation(arguments: ["--resource"], timeout: 5)
        struct Resource: Decodable { let version: Int; let resource: String }
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8),
              let resource = try? JSONDecoder().decode(Resource.self, from: data), resource.version == 1,
              resource.resource.count == 16, resource.resource.allSatisfy({ $0.isHexDigit }) else {
            throw ECSPreStartError.commandFailed(exitCode: result.exitCode)
        }
        return resource.resource
    }
    func checkLaunch(tunnel: TunnelConfig, timeout: TimeInterval) async throws -> LaunchPreflightResult {
        guard SSHCommand.isSSH(tunnel.command) else {
            return LaunchPreflightResult(version: 1, stage: "complete", category: .success, retryHint: 0, sanitizedCode: "not_required", exitCode: 0)
        }
        let result = try await launchInvocation(arguments: ["--result-json"], timeout: min(30, timeout))
        guard let data = result.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LaunchPreflightResult.self, from: data),
              decoded.version == 1, decoded.exitCode == Int(result.exitCode) else {
            return LaunchPreflightResult(version: 1, stage: "result", category: .unknown, retryHint: 300, sanitizedCode: "invalid_result", exitCode: 4)
        }
        return decoded
    }
    private func launchInvocation(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else { throw ECSPreStartError.scriptUnavailable }
        try Task.checkCancellation()
        var environment = environment
        environment["TUNNELPAD_PREFLIGHT_TIMEOUT_MS"] = String(Int(min(30, max(0.001, timeout)) * 1000))
        // Guardian owns work + cleanup; caller cancellation waits for the runner to finish.
        let result = try await runner.runAsync(executablePath: Self.bashPath, arguments: [scriptURL.path] + arguments, environment: environment)
        try Task.checkCancellation()
        return result
    }
}
