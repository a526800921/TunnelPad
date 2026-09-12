import Foundation
import TunnelPadCore

enum TunnelFormValidationError: LocalizedError {
    case emptyName
    case emptyCommand
    case invalidThrottle
    case invalidProbeURL
    case invalidProbeStatuses

    var errorDescription: String? {
        switch self {
        case .emptyName: return "名称不能为空"
        case .emptyCommand: return "命令至少需要一行可执行文件路径"
        case .invalidThrottle: return "重启间隔至少为 1 秒"
        case .invalidProbeURL: return "探针 URL 无效"
        case .invalidProbeStatuses: return "期望状态码无效（示例：200 或 200,301）"
        }
    }
}

/// 新建/编辑共用的表单状态、命令解析和配置校验。
/// UI 只负责绑定字段与呈现错误，避免两套弹窗的规则逐渐漂移。
struct TunnelFormState: Equatable {
    var name = ""
    var remark = ""
    var commandText = ""
    var executor: ExecutorKind = .launchd
    var keepAlive = true
    var throttleInterval = 10
    var probeEnabled = false
    var probeURL = ""
    var probeStatuses = "200"
    var autoStart = false

    init() {}

    init(tunnel: TunnelConfig) {
        name = tunnel.name
        remark = tunnel.remark
        commandText = tunnel.command.joined(separator: "\n")
        // 阶段 5 当前只允许 launchd；旧 app 配置不会进入生产 owner。
        executor = .launchd
        keepAlive = tunnel.keepAlive
        throttleInterval = tunnel.throttleInterval
        probeEnabled = tunnel.probe != nil
        probeURL = tunnel.probe?.url ?? ""
        probeStatuses = tunnel.probe.map { $0.expectedStatuses.map(String.init).joined(separator: ", ") } ?? "200"
        autoStart = tunnel.autoStart
    }

    var parsedCommand: [String] {
        commandText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var hasSSHVerboseFlag: Bool {
        SSHCommand.hasVerboseFlag(parsedCommand)
    }

    mutating func setSSHVerbose(_ enabled: Bool) {
        let updated = enabled
            ? SSHCommand.addingVerboseFlag(parsedCommand)
            : SSHCommand.removingVerboseFlag(parsedCommand)
        commandText = updated.joined(separator: "\n")
    }

    func makeTunnel(id: String) throws -> TunnelConfig {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw TunnelFormValidationError.emptyName }
        guard !parsedCommand.isEmpty else { throw TunnelFormValidationError.emptyCommand }
        guard throttleInterval >= 1 else { throw TunnelFormValidationError.invalidThrottle }

        let probe = try makeProbe()
        return TunnelConfig(
            id: id,
            name: trimmedName,
            remark: trimmedRemark,
            command: parsedCommand,
            executor: executor,
            keepAlive: keepAlive,
            throttleInterval: throttleInterval,
            probe: probe,
            autoStart: autoStart
        )
    }

    private func makeProbe() throws -> ProbeConfig? {
        guard probeEnabled else { return nil }
        let trimmedURL = probeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else {
            throw TunnelFormValidationError.invalidProbeURL
        }
        let statuses = probeStatuses
            .split(whereSeparator: { ",， ".contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (100...599).contains($0) }
        guard !statuses.isEmpty else { throw TunnelFormValidationError.invalidProbeStatuses }
        return ProbeConfig(url: trimmedURL, expectedStatuses: statuses)
    }
}
