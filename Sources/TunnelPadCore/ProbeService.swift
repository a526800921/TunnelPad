import Foundation

/// 每个 ProbeService 持有一个独立会话，复用同一探针协调器的连接资源。
/// actor 只负责会话引用和请求串行入口，保持注入 performer 的测试路径不变。
private actor ProbeSession {
    private let session: URLSession

    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    func status(for request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return http.statusCode
    }
}

/// 探针结果三态：满足 / 不满足（有响应但状态码不在期望集）/ 失败（连接错误、超时等）。
public enum ProbeResult: Equatable, Sendable {
    case satisfied(status: Int)
    case unexpected(status: Int)
    case failed(reason: String)
}

/// 状态探针：HTTP GET（绕过系统代理），只影响展示、不影响进程管理。
public struct ProbeService: Sendable {
    /// 返回 HTTP 状态码；抛错视为失败。可注入便于测试。
    public typealias Performer = @Sendable (URLRequest) async throws -> Int

    private let timeout: TimeInterval
    private let perform: Performer
    private let session: ProbeSession?

    public init(timeout: TimeInterval = 3, perform: Performer? = nil) {
        self.timeout = timeout
        if let perform {
            self.perform = perform
            self.session = nil
        } else {
            let session = ProbeSession(timeout: timeout)
            self.session = session
            self.perform = { request in
                try await session.status(for: request)
            }
        }
    }

    public func check(_ probe: ProbeConfig) async -> ProbeResult {
        guard let url = URL(string: probe.url) else {
            return .failed(reason: "非法探针 URL：\(probe.url)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        do {
            let status = try await perform(request)
            if probe.expectedStatuses.contains(status) {
                return .satisfied(status: status)
            }
            return .unexpected(status: status)
        } catch {
            return .failed(reason: String(describing: error))
        }
    }
}
