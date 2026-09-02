import Foundation

/// 受控生命周期操作的请求级结果；UI 兼容入口也可以忽略返回值，API 适配器不能依赖全局 lastError 猜测结果。
public enum TunnelOperationResult: Equatable, Sendable {
    case completed(status: TunnelStatus)
    case notFound
    case inProgress
    case failed
}

/// API 可执行的生命周期操作。
public enum TunnelAPIOperation: String, Codable, Sendable {
    case start
    case stop
    case restart
}

/// 对外返回的隧道安全摘要；不包含 command、探针 URL、本地路径、环境变量或原始错误。
public struct TunnelAPISummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let remark: String
    public let executor: String
    public let keepAlive: Bool
    public let throttleInterval: Int
    public let status: String
    public let pid: Int32?
    public let busy: Bool
    public let probe: TunnelAPIProbeSummary

    public init(
        id: String,
        name: String,
        remark: String,
        executor: String,
        keepAlive: Bool,
        throttleInterval: Int,
        status: String,
        pid: Int32?,
        busy: Bool,
        probe: TunnelAPIProbeSummary
    ) {
        self.id = id
        self.name = name
        self.remark = remark
        self.executor = executor
        self.keepAlive = keepAlive
        self.throttleInterval = throttleInterval
        self.status = status
        self.pid = pid
        self.busy = busy
        self.probe = probe
    }
}

/// 探针安全摘要；失败只返回分类，不返回 URL 或系统错误详情。
public struct TunnelAPIProbeSummary: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: String
    public let httpStatus: Int?

    public init(enabled: Bool, status: String, httpStatus: Int? = nil) {
        self.enabled = enabled
        self.status = status
        self.httpStatus = httpStatus
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, status, httpStatus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(status, forKey: .status)
        if let httpStatus {
            try container.encode(httpStatus, forKey: .httpStatus)
        }
    }
}

/// API 返回的日志纯文本快照。
public struct TunnelAPILogSnapshot: Codable, Equatable, Sendable {
    public let tunnelID: String
    public let version: UInt64
    public let status: String
    public let text: String

    public init(tunnelID: String, version: UInt64, status: String, text: String) {
        self.tunnelID = tunnelID
        self.version = version
        self.status = status
        self.text = text
    }
}

/// TunnelManager 到 HTTP 层的受控操作结果。
public enum TunnelAPIBackendOperationResult: Sendable {
    case completed(TunnelAPISummary)
    case notFound
    case inProgress
    case failed
}

/// TunnelManager 到 HTTP 层的受控日志结果。
public enum TunnelAPIBackendLogResult: Sendable {
    case completed(TunnelAPILogSnapshot)
    case notFound
    case failed
}

/// API Server 唯一依赖的业务适配边界。
public protocol TunnelAPIBackend: Sendable {
    func listTunnels() async -> [TunnelAPISummary]
    func tunnel(id: String) async -> TunnelAPISummary?
    func operate(id: String, operation: TunnelAPIOperation) async -> TunnelAPIBackendOperationResult
    func logs(id: String) async -> TunnelAPIBackendLogResult
    func clearLogs(id: String) async -> TunnelAPIBackendLogResult
}
