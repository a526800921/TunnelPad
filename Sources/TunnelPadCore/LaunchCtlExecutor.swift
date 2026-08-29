import Foundation
import Darwin

/// launchctl 查询到的隧道状态。
public enum TunnelStatus: Equatable, Sendable {
    case running(pid: Int32?)
    case notRunning
    case notLoaded
    case other(state: String)
}

public enum ExecutorError: Error, Equatable, Sendable {
    case commandFailed(operation: String, exitCode: Int32, stderr: String)
}

/// launchd 执行器：bootstrap / bootout / status，标签 `com.jafish.tunnelpad.<id>`。
public struct LaunchCtlExecutor: Sendable {
    public static let launchctlPath = "/bin/launchctl"

    public let runner: any ProcessRunning
    public let uid: uid_t

    public init(runner: any ProcessRunning = SystemProcessRunner(), uid: uid_t = uid_t(getuid())) {
        self.runner = runner
        self.uid = uid
    }

    public var domain: String { "gui/\(uid)" }

    /// 加载并立即启动（生成 plist 固定 RunAtLoad=true）。
    public func bootstrap(label: String, plistURL: URL) throws {
        let result = try runner.run(
            executablePath: Self.launchctlPath,
            arguments: ["bootstrap", domain, plistURL.path]
        )
        guard result.exitCode == 0 else {
            throw ExecutorError.commandFailed(operation: "bootstrap", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// 卸载。返回是否确实卸载了已加载实例；"未加载"不算错误。
    @discardableResult
    public func bootout(label: String) throws -> Bool {
        let result = try runner.run(
            executablePath: Self.launchctlPath,
            arguments: ["bootout", "\(domain)/\(label)"]
        )
        if result.exitCode == 0 { return true }
        if Self.isNotFoundMessage(stderr: result.stderr, stdout: result.stdout) { return false }
        throw ExecutorError.commandFailed(operation: "bootout", exitCode: result.exitCode, stderr: result.stderr)
    }

    /// 查询状态；命令失败（未加载/不可执行）一律按 notLoaded 处理。
    public func status(label: String) -> TunnelStatus {
        guard let result = try? runner.run(
            executablePath: Self.launchctlPath,
            arguments: ["print", "\(domain)/\(label)"]
        ), result.exitCode == 0 else {
            return .notLoaded
        }
        return Self.parseStatus(stdout: result.stdout)
    }

    // MARK: - 解析

    /// 解析 `launchctl print` 输出。只看顶层字段（单制表符缩进），忽略
    /// resource coalition 等嵌套块里的 `state = active`。
    public static func parseStatus(stdout: String) -> TunnelStatus {
        var state: String?
        var pid: Int32?

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard leadingTabCount(line) == 1 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if state == nil, let value = topLevelValue(forKey: "state", in: trimmed) {
                state = value
                continue
            }
            if pid == nil, let value = topLevelValue(forKey: "pid", in: trimmed), let number = Int32(value) {
                pid = number
            }
        }

        switch state {
        case "running": return .running(pid: pid)
        case "not running": return .notRunning
        case .some(let other): return .other(state: other)
        case nil: return .notLoaded
        }
    }

    private static func leadingTabCount(_ line: String) -> Int {
        for (index, character) in line.enumerated() where character != "\t" {
            return index
        }
        return line.count
    }

    private static func topLevelValue(forKey key: String, in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\(key) =") else { return nil }
        guard let equals = trimmedLine.firstIndex(of: "=") else { return nil }
        let value = trimmedLine[trimmedLine.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func isNotFoundMessage(stderr: String, stdout: String) -> Bool {
        let combined = stderr + stdout
        return combined.contains("Could not find service") || combined.contains("No such file or directory")
    }
}
