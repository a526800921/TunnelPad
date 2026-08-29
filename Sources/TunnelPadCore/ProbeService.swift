import Foundation

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

    public init(timeout: TimeInterval = 3, perform: Performer? = nil) {
        self.timeout = timeout
        if let perform {
            self.perform = perform
        } else {
            // 每次探测创建临时会话：绕过系统代理（回环请求会被系统代理拦截），
            // 并规避跨隔离捕获共享会话。
            self.perform = { request in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                return http.statusCode
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
