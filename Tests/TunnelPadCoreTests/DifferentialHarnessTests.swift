// 阶段 2 差分 harness（Swift 侧）：读取 rust/differential/fixtures/ 的场景，
// 用真实 Swift Core API 执行并产出事件流，写入 rust/target/differential/swift-events.json。
// 对比由 Rust 侧 tests/differential.rs 完成（语义等价比较）。
// 全程 fake 数据 + 隔离临时目录；不触碰真实隧道。

import Foundation
import XCTest
@testable import TunnelPadCore

private struct HarnessSpawnError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 可脚本化的 fake runner：按序消费输出队列，记录全部调用。
final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    struct ScriptedResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    struct Call {
        var result: ScriptedResult?
        var spawnError: String?
    }

    private let script: [Call]
    private(set) var invocations: [[String: Any]] = []
    private var index = 0
    private let lock = NSLock()

    init(script: [Call]) { self.script = script }

    var remainingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return script.count - index
    }

    static func result(_ exitCode: Int32, _ stdout: String, _ stderr: String) -> ScriptedResult {
        ScriptedResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func run(executablePath: String, arguments: [String]) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(["args": arguments])
        guard index < script.count else {
            throw HarnessSpawnError(message: "runner script exhausted")
        }
        let call = script[index]
        index += 1
        if let spawnError = call.spawnError {
            throw HarnessSpawnError(message: spawnError)
        }
        if let result = call.result {
            return ProcessResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        throw HarnessSpawnError(message: "脚本项缺少 result")
    }
}

/// 从 fixture JSON 的 result/spawnError 构造脚本项。
private func scriptCall(_ fixture: [String: Any]) -> ScriptedRunner.Call {
    let result: ScriptedRunner.ScriptedResult? = (fixture["result"] as? [String: Any]).flatMap { resultSpec in
        guard let exitCode = resultSpec["exitCode"] as? Int32,
              let stdout = resultSpec["stdout"] as? String,
              let stderr = resultSpec["stderr"] as? String else { return nil }
        return ScriptedRunner.ScriptedResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
    return ScriptedRunner.Call(result: result, spawnError: fixture["spawnError"] as? String)
}

private enum TunnelStatusEvent {
    static func dict(_ status: TunnelStatus) -> [String: Any] {
        switch status {
        case .running(let pid):
            return ["case": "running", "pid": pid.map { NSNumber(value: $0) } ?? NSNull()]
        case .notRunning:
            return ["case": "notRunning"]
        case .notLoaded:
            return ["case": "notLoaded"]
        case .other(let state):
            return ["case": "other", "state": state]
        }
    }
}

private func makeTempHome(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let home = base.appendingPathComponent("tp-diff-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func normalize(_ text: String, home: URL) -> String {
    var out = text.replacingOccurrences(of: home.path, with: "<home>")
    out = out.replacingOccurrences(of: "\\d{8}-\\d{6}", with: "<stamp>", options: .regularExpression)
    out = out.replacingOccurrences(
        of: "\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\]",
        with: "[<ts>]",
        options: .regularExpression
    )
    out = out.replacingOccurrences(of: "pid=\\d+", with: "pid=<pid>", options: .regularExpression)
    return out
}

private func executorErrorEvent(_ error: Error) -> [String: Any] {
    if case let ExecutorError.commandFailed(operation, exitCode, stderr) = error {
        return [
            "kind": "commandFailed",
            "operation": operation,
            "exitCode": NSNumber(value: exitCode),
            "stderr": stderr,
        ]
    }
    return ["kind": "spawn", "message": String(describing: error)]
}

private func normalizeStatusDict(_ dict: [String: Any]) -> [String: Any] {
    var out = dict
    if (out["case"] as? String) == "running", !(out["pid"] is NSNull) {
        out["pid"] = "<pid>"
    }
    return out
}

private func decodeTunnel(_ spec: [String: Any]) throws -> TunnelConfig {
    let data = try JSONSerialization.data(withJSONObject: spec)
    return try JSONDecoder().decode(TunnelConfig.self, from: data)
}

private func sortedFiles(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
}

private func normalizeArtifactNames(_ names: [String]) -> [String] {
    names.map {
        $0.replacingOccurrences(of: "\\d{8}-\\d{6}", with: "<stamp>", options: .regularExpression)
    }
}

private func demoSnapshot(paths: TunnelPaths) -> [String: Any] {
    let config = ConfigStore(paths: paths).load().config
    return [
        "op": "fs-snapshot",
        "configIds": config.tunnels.map(\.id),
        "launchdFiles": sortedFiles(in: paths.launchdDirectory),
        "logFiles": sortedFiles(in: paths.logsDirectory),
        "backupFiles": normalizeArtifactNames(sortedFiles(in: paths.migrationBackupDirectory)),
    ]
}

private func demoLifecycleOutcome(
    _ op: String,
    tunnel: TunnelConfig,
    paths: TunnelPaths,
    launchd: LaunchCtlExecutor
) -> [String: Any] {
    do {
        switch op {
        case "start":
            if case .running = launchd.status(label: tunnel.launchdLabel) {
                return ["op": op, "result": "noop"]
            }
            let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
            try launchd.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
        case "stop":
            try launchd.bootout(label: tunnel.launchdLabel)
        case "restart":
            _ = try? launchd.bootout(label: tunnel.launchdLabel)
            let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
            try launchd.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
        default:
            throw HarnessSpawnError(message: "不支持的生命周期操作：\(op)")
        }
        return ["op": op, "result": "ok"]
    } catch {
        let verb = ["start": "启动", "stop": "停止", "restart": "重启"][op] ?? op
        return ["op": op, "error": "\(verb)「\(tunnel.name)」失败：\(error)"]
    }
}

private func removeDemoTunnel(
    _ id: String,
    paths: TunnelPaths,
    launchd: LaunchCtlExecutor
) throws -> Bool {
    let store = ConfigStore(paths: paths)
    guard let tunnel = store.load().config.tunnels.first(where: { $0.id == id }) else {
        return false
    }

    if launchd.status(label: tunnel.launchdLabel) != .notLoaded {
        _ = try launchd.bootout(label: tunnel.launchdLabel)
        if launchd.status(label: tunnel.launchdLabel) != .notLoaded {
            throw HarnessSpawnError(message: "实例未成功停止")
        }
    }
    let plistURL = paths.launchdPlistURL(for: tunnel)
    if FileManager.default.fileExists(atPath: plistURL.path) {
        try FileManager.default.removeItem(at: plistURL)
    }

    let logURL = paths.logURL(for: tunnel)
    var logWarning = false
    if FileManager.default.fileExists(atPath: logURL.path) {
        try? FileManager.default.removeItem(at: logURL)
        logWarning = FileManager.default.fileExists(atPath: logURL.path)
    }

    var config = store.load().config
    guard let index = config.tunnels.firstIndex(where: { $0.id == id }) else {
        return false
    }
    let removed = config.tunnels.remove(at: index)
    do {
        try store.save(config)
    } catch {
        config.tunnels.insert(removed, at: min(index, config.tunnels.count))
        throw error
    }
    return logWarning
}

private func stopAllDemoTunnels(paths: TunnelPaths, launchd: LaunchCtlExecutor) -> Int {
    let config = ConfigStore(paths: paths).load().config
    var stopped = 0
    for tunnel in config.tunnels {
        if (try? launchd.bootout(label: tunnel.launchdLabel)) == true {
            stopped += 1
        }
    }
    return stopped
}

private func runDemoLifecycle(_ fixture: [String: Any], home: URL) throws -> [[String: Any]] {
    let specs = fixture["tunnels"] as? [[String: Any]] ?? []
    let tunnels = try specs.map(decodeTunnel)
    guard let firstTunnel = tunnels.first else {
        throw HarnessSpawnError(message: "demo-lifecycle fixture 缺 tunnels")
    }

    let scriptEntries = fixture["runnerScript"] as? [[String: Any]] ?? []
    var script: [ScriptedRunner.Call] = []
    for entry in scriptEntries {
        let repeatCount = (entry["repeat"] as? Int) ?? 1
        for _ in 0..<repeatCount {
            script.append(scriptCall(entry))
        }
    }

    let paths = TunnelPaths(homeDirectory: home)
    let runner = ScriptedRunner(script: script)
    let launchd = LaunchCtlExecutor(runner: runner, uid: uid_t(getuid()))
    let store = ConfigStore(paths: paths)

    var events: [[String: Any]] = []
    let operations = fixture["ops"] as? [[String: Any]] ?? []
    for operation in operations {
        guard let op = operation["op"] as? String else {
            throw HarnessSpawnError(message: "demo-lifecycle fixture 缺 op")
        }
        let tunnel: TunnelConfig
        if let id = operation["id"] as? String {
            guard let selected = tunnels.first(where: { $0.id == id }) else {
                throw HarnessSpawnError(message: "demo-lifecycle fixture 缺隧道 \(id)")
            }
            tunnel = selected
        } else {
            tunnel = firstTunnel
        }

        switch op {
        case "install":
            try store.save(AppConfig(version: 1, tunnels: tunnels))
            for item in tunnels where item.executor == .launchd {
                _ = try LaunchdPlistRenderer.writePlist(for: item, paths: paths)
            }
            events.append(["op": "install", "ids": tunnels.map(\.id)])
        case "snapshot":
            events.append(demoSnapshot(paths: paths))
        case "plist":
            let url = paths.launchdPlistURL(for: tunnel)
            let content = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
            events.append([
                "op": "plist",
                "content": content.map { normalize($0, home: home) } ?? NSNull(),
            ])
        case "start":
            events.append(demoLifecycleOutcome(op, tunnel: tunnel, paths: paths, launchd: launchd))
        case "stop":
            events.append(demoLifecycleOutcome(op, tunnel: tunnel, paths: paths, launchd: launchd))
        case "restart":
            events.append(demoLifecycleOutcome(op, tunnel: tunnel, paths: paths, launchd: launchd))
        case "status":
            let status = launchd.status(label: tunnel.launchdLabel)
            events.append(["op": "status", "status": normalizeStatusDict(TunnelStatusEvent.dict(status))])
        case "remove":
            let logWarning = try removeDemoTunnel(tunnel.id, paths: paths, launchd: launchd)
            events.append(["op": "remove", "result": "ok", "logWarning": logWarning])
        case "takeover":
            guard let legacy = fixture["legacy"] as? [String: Any],
                  let label = legacy["agentLabel"] as? String,
                  let plistXML = legacy["agentPlist"] as? String else {
                throw HarnessSpawnError(message: "demo takeover fixture 缺 legacy")
            }
            try FileManager.default.createDirectory(at: paths.launchAgentsDirectory, withIntermediateDirectories: true)
            let agentURL = paths.launchAgentsDirectory.appendingPathComponent("\(label).plist")
            try Data(plistXML.utf8).write(to: agentURL)
            let agent = try LegacyImporter.parsePlist(at: agentURL)
            guard let candidate = LegacyImporter.tunnelConfig(from: agent), candidate.id.hasPrefix("demo-") else {
                events.append(["op": "takeover", "errorCase": "invalidDemoID"])
                continue
            }
            let service = MigrationService(paths: paths, executor: launchd, pollDelay: {})
            let outcome = try service.takeover(agent: agent)
            guard outcome.tunnel.id == candidate.id else {
                throw HarnessSpawnError(message: "demo takeover 越过 ID 边界")
            }
            var config = store.load().config
            config.tunnels.append(outcome.tunnel)
            try store.save(config)
            events.append([
                "op": "takeover",
                "result": "ok",
                "rolledBack": outcome.rolledBack,
                "tunnelId": outcome.tunnel.id,
                "label": outcome.tunnel.launchdLabel,
            ])
        case "shutdown-all":
            let stopped = stopAllDemoTunnels(paths: paths, launchd: launchd)
            events.append(["op": "shutdown-all", "stopped": stopped])
        default:
            throw HarnessSpawnError(message: "demo-lifecycle 不支持操作 \(op)")
        }
    }

    guard runner.remainingCount == 0 else {
        throw HarnessSpawnError(message: "demo-lifecycle runnerScript 未完全消费：剩余 \(runner.remainingCount) 项")
    }
    events.append([
        "op": "runner",
        "invocations": runner.invocations.map { invocation in
            let args = (invocation["args"] as? [String] ?? []).map { normalize($0, home: home) }
            return ["args": args] as [String: Any]
        },
        "remaining": runner.remainingCount,
    ])
    return events
}

private func runComponent(_ component: String, fixture: [String: Any], home: URL) async throws -> [[String: Any]] {
    let fileManager = FileManager.default

    switch component {
    case "demo-lifecycle":
        return try runDemoLifecycle(fixture, home: home)

    case "config-store":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        var events: [[String: Any]] = []
        for testCase in cases {
            guard let name = testCase["name"] as? String else { continue }
            let caseHome = makeTempHome("cfg-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: caseHome) }
            let store = ConfigStore(paths: TunnelPaths(homeDirectory: caseHome))
            if let content = testCase["fileContent"] as? String {
                try fileManager.createDirectory(at: store.paths.supportDirectory, withIntermediateDirectories: true)
                try content.data(using: .utf8)!.write(to: store.paths.configURL)
            }
            let loaded = store.load()
            try store.save(loaded.config)
            let saved = (try? Data(contentsOf: store.paths.configURL))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            events.append([
                "name": name,
                "recoveredFrom": loaded.recoveredFrom.map { normalize($0.path, home: caseHome) } ?? NSNull(),
                "tunnelIds": loaded.config.tunnels.map(\.id),
                "saveContent": normalize(saved, home: caseHome),
            ])
        }
        return events

    case "tunnel-id":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.compactMap { testCase in
            guard let name = testCase["name"] as? String,
                  let existing = testCase["existing"] as? [String] else { return nil }
            return [
                "name": name,
                "existing": existing,
                "id": TunnelID.generate(from: name, existing: Set(existing)),
            ]
        }

    case "ssh-command":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.compactMap { testCase in
            guard let command = testCase["command"] as? [String] else { return nil }
            return [
                "command": command,
                "isSSH": SSHCommand.isSSH(command),
                "hasVerbose": SSHCommand.hasVerboseFlag(command),
                "added": SSHCommand.addingVerboseFlag(command),
                "removed": SSHCommand.removingVerboseFlag(command),
            ]
        }

    case "plist-render":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.compactMap { testCase in
            guard let tunnelSpec = testCase["tunnel"] as? [String: Any],
                  let id = tunnelSpec["id"] as? String,
                  let name = tunnelSpec["name"] as? String,
                  let command = tunnelSpec["command"] as? [String],
                  let keepAlive = tunnelSpec["keepAlive"] as? Bool,
                  let throttleInterval = tunnelSpec["throttleInterval"] as? Int,
                  let logPath = testCase["logPath"] as? String else { return nil }
            let tunnel = TunnelConfig(
                id: id, name: name, command: command,
                executor: .launchd, keepAlive: keepAlive,
                throttleInterval: throttleInterval, probe: nil
            )
            let data = try? LaunchdPlistRenderer.plistXMLData(
                for: tunnel, logURL: URL(fileURLWithPath: logPath)
            )
            return [
                "label": tunnel.launchdLabel,
                "content": data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            ]
        }

    case "launchctl-status":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.compactMap { testCase in
            guard let label = testCase["label"] as? String,
                  let output = testCase["printOutput"] as? String else { return nil }
            let runner = ScriptedRunner(script: [ScriptedRunner.Call(
                result: ScriptedRunner.result(0, output, ""), spawnError: nil
            )])
            let executor = LaunchCtlExecutor(runner: runner, uid: uid_t(getuid()))
            return [
                "label": label,
                "status": normalizeStatusDict(TunnelStatusEvent.dict(executor.status(label: label))),
            ]
        }

    case "launchctl-bootout":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.map { testCase in
            guard let label = testCase["label"] as? String else {
                return ["label": NSNull(), "outcome": ["error": ["kind": "spawn", "message": "fixture 缺 label"]]]
            }
            let runner = ScriptedRunner(script: [scriptCall(testCase)])
            let executor = LaunchCtlExecutor(runner: runner, uid: uid_t(getuid()))
            let outcome: [String: Any]
            do {
                let unloaded = try executor.bootout(label: label)
                outcome = ["ok": unloaded]
            } catch {
                outcome = ["error": executorErrorEvent(error)]
            }
            return ["label": label, "outcome": outcome]
        }

    case "launchctl-bootstrap":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.map { testCase in
            guard let label = testCase["label"] as? String else {
                return ["label": NSNull(), "outcome": ["error": ["kind": "spawn", "message": "fixture 缺 label"]]]
            }
            let runner = ScriptedRunner(script: [scriptCall(testCase)])
            let executor = LaunchCtlExecutor(runner: runner, uid: uid_t(getuid()))
            let plistPath = home.appendingPathComponent("plist-\(label).plist")
            let outcome: [String: Any]
            do {
                try executor.bootstrap(label: label, plistURL: plistPath)
                outcome = ["ok": true]
            } catch {
                outcome = ["error": executorErrorEvent(error)]
            }
            return ["label": label, "outcome": outcome]
        }

    case "probe":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        var events: [[String: Any]] = []
        for testCase in cases {
            guard let url = testCase["url"] as? String,
                  let expected = testCase["expectedStatuses"] as? [Int] else { continue }
            let performSpec = testCase["perform"] as? [String: Any] ?? [:]
            // 提前提取为 Sendable 局部量，避免捕获 [String: Any]
            let performError = performSpec["error"] as? String
            let performStatus = performSpec["status"] as? Int
            let probe = ProbeConfig(url: url, expectedStatuses: expected)
            let service = ProbeService(timeout: 3) { _ in
                if let performError {
                    throw HarnessSpawnError(message: performError)
                }
                if let performStatus {
                    return performStatus
                }
                throw URLError(.badURL)
            }
            let result = await service.check(probe)
            let event: [String: Any]
            switch result {
            case .satisfied(let status):
                event = ["case": "satisfied", "status": status]
            case .unexpected(let status):
                event = ["case": "unexpected", "status": status]
            case .failed(let reason):
                event = ["case": "failed", "reason": reason]
            }
            events.append(event)
        }
        return events

    case "log-tail":
        let cases = fixture["cases"] as? [[String: Any]] ?? []
        return cases.map { testCase in
            let maxLines = (testCase["maxLines"] as? Int) ?? 500
            var result: Any = NSNull()
            let url = home.appendingPathComponent("log-\(UUID().uuidString).txt")
            defer { try? fileManager.removeItem(at: url) }
            if testCase["missing"] as? Bool == true {
                // 不创建文件
            } else if let content = testCase["content"] as? String {
                try? content.data(using: .utf8)!.write(to: url)
            }
            if let value = LogTail.lastLines(of: url, maxLines: maxLines) {
                result = value
            }
            return ["result": result]
        }

    case "legacy-scan":
        let files = fixture["files"] as? [String: String] ?? [:]
        let scanDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)
        for (name, content) in files {
            try? content.data(using: .utf8)!.write(to: scanDir.appendingPathComponent(name))
        }
        let agents = LegacyImporter.scan(in: scanDir)
        return [
            [
                "agents": agents.map { agent in
                    [
                        "label": agent.label,
                        "programArguments": agent.programArguments,
                        "keepAlive": agent.keepAlive,
                        "runAtLoad": agent.runAtLoad,
                        "throttleInterval": agent.throttleInterval.map { NSNumber(value: $0) } ?? NSNull(),
                    ] as [String: Any]
                }
            ] as [String: Any]
        ]

    case "legacy-derive":
        let labels = fixture["labels"] as? [String] ?? []
        let agentsSpec = fixture["agents"] as? [[String: Any]] ?? []
        let ids: [Any] = labels.map { label in
            LegacyImporter.tunnelID(for: label).map { $0 as Any } ?? NSNull()
        }
        let configs: [Any] = agentsSpec.map { spec in
            guard let label = spec["label"] as? String,
                  let arguments = spec["programArguments"] as? [String],
                  let keepAlive = spec["keepAlive"] as? Bool,
                  let runAtLoad = spec["runAtLoad"] as? Bool else { return NSNull() }
            let agent = LegacyAgent(
                label: label,
                plistURL: URL(fileURLWithPath: "/tmp/unused.plist"),
                programArguments: arguments,
                keepAlive: keepAlive,
                runAtLoad: runAtLoad,
                throttleInterval: spec["throttleInterval"] as? Int
            )
            guard let config = LegacyImporter.tunnelConfig(from: agent) else { return NSNull() }
            return [
                "id": config.id,
                "name": config.name,
                "command": config.command,
                "executor": config.executor.rawValue,
                "keepAlive": config.keepAlive,
                "throttleInterval": NSNumber(value: config.throttleInterval),
            ] as [String: Any]
        }
        return [["ids": ids, "configs": configs]]

    case "migration":
        let scenarios = fixture["scenarios"] as? [[String: Any]] ?? []
        var events: [[String: Any]] = []
        for scenario in scenarios {
            guard let name = scenario["name"] as? String,
                  let label = scenario["agentLabel"] as? String,
                  let plistXML = scenario["agentPlist"] as? String else { continue }
            let scenarioHome = makeTempHome("mig-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: scenarioHome) }
            let scenarioPaths = TunnelPaths(homeDirectory: scenarioHome)
            let launchAgents = scenarioHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try? fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            let agentPlistURL = launchAgents.appendingPathComponent("\(label).plist")
            try? plistXML.data(using: .utf8)!.write(to: agentPlistURL)

            let entries = scenario["runnerScript"] as? [[String: Any]] ?? []
            var expanded: [ScriptedRunner.Call] = []
            for entry in entries {
                let repeatCount = (entry["repeat"] as? Int) ?? 1
                expanded.append(contentsOf: Array(repeating: scriptCall(entry), count: repeatCount))
            }
            let runner = ScriptedRunner(script: expanded)
            let executor = LaunchCtlExecutor(runner: runner, uid: uid_t(getuid()))
            let service = MigrationService(paths: scenarioPaths, executor: executor, pollDelay: {})

            let parsed = try? LegacyImporter.parsePlist(at: agentPlistURL)
            let agent = LegacyAgent(
                label: label,
                plistURL: agentPlistURL,
                programArguments: parsed?.programArguments ?? [],
                keepAlive: parsed?.keepAlive ?? false,
                runAtLoad: parsed?.runAtLoad ?? false,
                throttleInterval: parsed?.throttleInterval
            )

            var event: [String: Any] = ["scenario": name]
            let takeoverResult = Result<[String: Any], Error> {
                let outcome = try service.takeover(agent: agent)
                return [
                    "rolledBack": outcome.rolledBack,
                    "tunnelId": outcome.tunnel.id,
                    "label": outcome.tunnel.launchdLabel,
                ]
            }
            switch takeoverResult {
            case .success(let outcomeDict):
                event["outcome"] = outcomeDict
            case .failure(let error):
                switch error {
                case MigrationError.invalidAgent(let errorLabel, _):
                    event["errorCase"] = "invalidAgent"
                    event["errorLabel"] = errorLabel
                case MigrationError.backupFailed(let errorLabel, _):
                    event["errorCase"] = "backupFailed"
                    event["errorLabel"] = errorLabel
                case MigrationError.verifyFailed(let errorLabel):
                    event["errorCase"] = "verifyFailed"
                    event["errorLabel"] = errorLabel
                case MigrationError.rollbackFailed(let errorLabel, _):
                    event["errorCase"] = "rollbackFailed"
                    event["errorLabel"] = errorLabel
                default:
                    event["errorCase"] = "executor"
                }
            }
            event["invocations"] = runner.invocations.map { invocation in
                let args = (invocation["args"] as? [String] ?? []).map { normalize($0, home: scenarioHome) }
                return ["args": args] as [String: Any]
            }
            let launchAgentsFiles = (try? fileManager.contentsOfDirectory(atPath: launchAgents.path))?.sorted() ?? []
            let backupFiles = (try? fileManager.contentsOfDirectory(atPath: scenarioPaths.migrationBackupDirectory.path))?.sorted() ?? []
            event["launchAgentsFiles"] = launchAgentsFiles.map { normalize($0, home: scenarioHome) }
            event["backupFiles"] = backupFiles.map { normalize($0, home: scenarioHome) }
            events.append(event)
        }
        return events

    default:
        return [["unsupported": component]]
    }
}

final class DifferentialHarnessTests: XCTestCase {
    func testProduceSwiftEvents() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/TunnelPadCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let fixturesDir = repoRoot.appendingPathComponent("rust/differential/fixtures", isDirectory: true)
        let outputDir = repoRoot.appendingPathComponent("rust/target/differential", isDirectory: true)

        let fixtureFiles = try FileManager.default
            .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var allEvents: [String: Any] = [:]
        for fixtureURL in fixtureFiles {
            let fixtureData = try Data(contentsOf: fixtureURL)
            guard let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
                  let component = fixture["component"] as? String else { continue }
            let home = makeTempHome(component)
            defer { try? FileManager.default.removeItem(at: home) }
            allEvents[fixtureURL.lastPathComponent] = try await runComponent(component, fixture: fixture, home: home)
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: allEvents, options: [.sortedKeys])
        try data.write(to: outputDir.appendingPathComponent("swift-events.json"))
    }
}
