import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat

/// TunnelPad 本机 HTTP API Server。
///
/// 生产实例固定由 AppDelegate 以 127.0.0.1:9998 启动；业务操作只能经过
/// TunnelAPIBackend，避免 HTTP handler 绕过 TunnelManager/Rust Core owner。
public final class TunnelAPIServer: @unchecked Sendable {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 9998
    public static let defaultOperationTimeoutNanoseconds: UInt64 = 60_000_000_000

    private let host: String
    private let port: Int
    private let backend: any TunnelAPIBackend
    private let operationTimeoutNanoseconds: UInt64
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?

    public init(
        host: String = "127.0.0.1",
        port: Int = 9998,
        operationTimeoutNanoseconds: UInt64 = 60_000_000_000,
        backend: any TunnelAPIBackend
    ) {
        self.host = host
        self.port = port
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.backend = backend
    }

    /// 测试 fixture 可使用 port=0，并在绑定后读取实际端口。
    public var localPort: Int? { channel?.localAddress?.port }

    public var isRunning: Bool { channel != nil }

    /// 绑定失败直接抛出，由 AppDelegate 记录错误并继续启动 App；不自动换端口或重试。
    public func start() throws {
        guard channel == nil else { return }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let backend = self.backend
            let timeout = self.operationTimeoutNanoseconds
            let bootstrap = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    let handler = TunnelAPIHandler(
                        backend: backend,
                        operationTimeoutNanoseconds: timeout
                    )
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
            let option = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR)
            let channel = try bootstrap
                .serverChannelOption(option, value: 1)
                .bind(host: host, port: port)
                .wait()
            self.group = group
            self.channel = channel
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func stop() throws {
        let channel = self.channel
        let group = self.group
        self.channel = nil
        self.group = nil
        try channel?.close().wait()
        try group?.syncShutdownGracefully()
    }
}

private struct TunnelAPIResponse: Sendable {
    let statusCode: Int
    let body: Data
    let contentType: String
}

private struct TunnelAPIRequest: Sendable {
    let method: HTTPMethod
    let uri: String
    let body: Data
}

private final class TunnelAPIHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let backend: any TunnelAPIBackend
    private let operationTimeoutNanoseconds: UInt64
    private var method: HTTPMethod = .GET
    private var uri = "/"
    private var body = Data()

    init(backend: any TunnelAPIBackend, operationTimeoutNanoseconds: UInt64) {
        self.backend = backend
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            method = head.method
            uri = head.uri
            body.removeAll(keepingCapacity: true)
            if method != .POST {
                respond(context: context)
            }
        case .body(let buffer):
            if let chunk = buffer.getData(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ) {
                body.append(chunk)
            }
        case .end:
            if method == .POST {
                respond(context: context)
            }
        }
    }

    private func respond(context: ChannelHandlerContext) {
        let request = TunnelAPIRequest(method: method, uri: uri, body: body)
        let backend = self.backend
        let timeout = self.operationTimeoutNanoseconds
        let channel = context.channel
        let handler = self

        Task.detached(priority: .userInitiated) {
            let response = await TunnelAPIRouter.route(
                request,
                backend: backend,
                operationTimeoutNanoseconds: timeout
            )
            channel.eventLoop.execute {
                handler.send(response: response, on: channel)
            }
        }
    }

    private func send(response: TunnelAPIResponse, on channel: Channel) {
        let status: HTTPResponseStatus
        switch response.statusCode {
        case 200: status = .ok
        case 400: status = .badRequest
        case 404: status = .notFound
        case 409: status = .conflict
        case 500: status = .internalServerError
        case 504: status = .gatewayTimeout
        default: status = .internalServerError
        }

        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        let head = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: HTTPHeaders([
                ("Content-Type", response.contentType),
                ("Content-Length", "\(response.body.count)"),
                ("Connection", "close")
            ])
        )
        _ = channel.write(HTTPServerResponsePart.head(head))
        _ = channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        _ = channel.writeAndFlush(HTTPServerResponsePart.end(nil as HTTPHeaders?))
        _ = channel.close(mode: .all)
    }
}

private enum TunnelAPIRouter {
    private enum OperationRace: Sendable {
        case result(TunnelAPIBackendOperationResult)
        case timeout
    }

    private struct HealthResponse: Encodable {
        let ok = true
    }

    private struct ListResponse: Encodable {
        let ok = true
        let tunnels: [TunnelAPISummary]
    }

    private struct DetailResponse: Encodable {
        let ok = true
        let tunnel: TunnelAPISummary
    }

    private struct OperationResponse: Encodable {
        let ok = true
        let operation: String
        let tunnel: TunnelAPISummary
    }

    private struct LogResponse: Encodable {
        let ok = true
        let tunnelId: String
        let version: UInt64
        let status: String
        let text: String
    }

    private struct ErrorResponse: Encodable {
        let ok = false
        let error: APIError
    }

    private struct APIError: Encodable {
        let code: String
        let message: String
    }

    static func route(
        _ request: TunnelAPIRequest,
        backend: any TunnelAPIBackend,
        operationTimeoutNanoseconds: UInt64
    ) async -> TunnelAPIResponse {
        guard let components = pathComponents(for: request.uri) else {
            return error(status: 400, code: "invalid_request", message: "请求路径无效")
        }

        if components == ["openapi.json"] {
            guard request.method == .GET else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return TunnelAPIResponse(
                statusCode: 200,
                body: openAPISpec,
                contentType: "application/json"
            )
        }

        if components == ["api", "health"] {
            guard request.method == .GET else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return json(status: 200, value: HealthResponse())
        }

        guard components.count >= 2,
              components[0] == "api",
              components[1] == "tunnels" else {
            return error(status: 404, code: "not_found", message: "接口不存在")
        }

        if components.count == 2 {
            guard request.method == .GET else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return json(status: 200, value: ListResponse(tunnels: await backend.listTunnels()))
        }

        let id = components[2]
        if components.count == 3 {
            guard request.method == .GET else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            guard let tunnel = await backend.tunnel(id: id) else {
                return error(status: 404, code: "tunnel_not_found", message: "隧道不存在")
            }
            return json(status: 200, value: DetailResponse(tunnel: tunnel))
        }

        if components.count == 4,
           let operation = TunnelAPIOperation(rawValue: components[3]) {
            guard request.method == .POST else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return await operate(
                id: id,
                operation: operation,
                backend: backend,
                timeoutNanoseconds: operationTimeoutNanoseconds
            )
        }

        if components.count == 4, components[3] == "logs" {
            guard request.method == .GET else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return logResponse(await backend.logs(id: id))
        }

        if components.count == 5,
           components[3] == "logs",
           components[4] == "clear" {
            guard request.method == .POST else {
                return error(status: 400, code: "invalid_request", message: "请求方法无效")
            }
            return logResponse(await backend.clearLogs(id: id))
        }

        return error(status: 404, code: "not_found", message: "接口不存在")
    }

    private static func operate(
        id: String,
        operation: TunnelAPIOperation,
        backend: any TunnelAPIBackend,
        timeoutNanoseconds: UInt64
    ) async -> TunnelAPIResponse {
        // 底层任务是 detached 的：HTTP 超时只结束当前响应等待，不取消或再次触发
        // TunnelManager 的生命周期操作；调用方应随后查询状态。
        let operationTask = Task.detached(priority: .userInitiated) {
            await backend.operate(id: id, operation: operation)
        }
        let race = await withTaskGroup(of: OperationRace.self) { group in
            group.addTask {
                .result(await operationTask.value)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return .timeout
                }
                return .timeout
            }
            defer { group.cancelAll() }
            return await group.next() ?? .timeout
        }

        switch race {
        case .timeout:
            return error(
                status: 504,
                code: "operation_timeout",
                message: "隧道操作超时，当前结果未知"
            )
        case .result(let result):
            switch result {
            case .completed(let tunnel):
                return json(
                    status: 200,
                    value: OperationResponse(operation: operation.rawValue, tunnel: tunnel)
                )
            case .notFound:
                return error(status: 404, code: "tunnel_not_found", message: "隧道不存在")
            case .inProgress:
                return error(status: 409, code: "operation_in_progress", message: "隧道当前正在执行其他操作")
            case .failed:
                return error(status: 500, code: "operation_failed", message: "隧道操作失败")
            }
        }
    }

    private static func logResponse(_ result: TunnelAPIBackendLogResult) -> TunnelAPIResponse {
        switch result {
        case .completed(let snapshot):
            return json(
                    status: 200,
                    value: LogResponse(
                    tunnelId: snapshot.tunnelID,
                    version: snapshot.version,
                    status: snapshot.status,
                    text: snapshot.text
                )
            )
        case .notFound:
            return error(status: 404, code: "tunnel_not_found", message: "隧道不存在")
        case .failed:
            return error(status: 500, code: "log_failed", message: "日志操作失败")
        }
    }

    private static func pathComponents(for uri: String) -> [String]? {
        let rawPath = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? uri
        let rawComponents = rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var components: [String] = []
        for component in rawComponents {
            guard let decoded = component.removingPercentEncoding else { return nil }
            components.append(decoded)
        }
        return components
    }

    private static func json<T: Encodable>(status: Int, value: T) -> TunnelAPIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return TunnelAPIResponse(
            statusCode: status,
            body: body,
            contentType: "application/json"
        )
    }

    private static func error(status: Int, code: String, message: String) -> TunnelAPIResponse {
        json(status: status, value: ErrorResponse(error: APIError(code: code, message: message)))
    }

    private static let openAPISpec: Data = {
        let idParameter: [[String: Any]] = [[
            "name": "id",
            "in": "path",
            "required": true,
            "schema": ["type": "string"]
        ]]
        let summarySchema: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "name": ["type": "string"],
                "remark": ["type": "string"],
                "executor": ["type": "string", "enum": ["launchd"]],
                "keepAlive": ["type": "boolean"],
                "throttleInterval": ["type": "integer"],
                "status": ["type": "string"],
                "pid": ["type": "integer", "nullable": true],
                "busy": ["type": "boolean"],
                "probe": ["$ref": "#/components/schemas/ProbeSummary"]
            ],
            "required": ["id", "name", "remark", "executor", "keepAlive", "throttleInterval", "status", "busy", "probe"]
        ]
        let errorResponse: [String: Any] = ["$ref": "#/components/schemas/ErrorResponse"]
        func operation(
            _ summary: String,
            response: [String: Any],
            parameters: [[String: Any]] = [],
            statusCodes: [String] = []
        ) -> [String: Any] {
            var responses: [String: Any] = [
                "200": [
                    "description": "成功",
                    "content": ["application/json": ["schema": response]]
                ]
            ]
            for code in statusCodes {
                responses[code] = [
                    "description": "失败",
                    "content": ["application/json": ["schema": errorResponse]]
                ]
            }
            var result: [String: Any] = ["summary": summary, "responses": responses]
            if !parameters.isEmpty { result["parameters"] = parameters }
            return result
        }

        let summaryRef: [String: Any] = ["$ref": "#/components/schemas/TunnelSummary"]
        let logRef: [String: Any] = ["$ref": "#/components/schemas/LogSnapshot"]
        let spec: [String: Any] = [
            "openapi": "3.1.0",
            "info": [
                "title": "TunnelPad 本机 API",
                "version": "1.0.0",
                "description": "TunnelPad 本机隧道状态、启停和日志 API。"
            ],
            "servers": [["url": "http://127.0.0.1:9998", "description": "本机回环服务"]],
            "paths": [
                "/api/health": ["get": operation("健康检查", response: ["type": "object", "properties": ["ok": ["type": "boolean"]]])],
                "/api/tunnels": ["get": operation("隧道列表", response: ["type": "object", "properties": ["ok": ["type": "boolean"], "tunnels": ["type": "array", "items": summaryRef]]])],
                "/api/tunnels/{id}": ["get": operation("隧道详情", response: ["type": "object", "properties": ["ok": ["type": "boolean"], "tunnel": summaryRef]], parameters: idParameter, statusCodes: ["404"])],
                "/api/tunnels/{id}/start": ["post": operation("启动隧道", response: ["type": "object", "properties": ["ok": ["type": "boolean"], "operation": ["type": "string"], "tunnel": summaryRef]], parameters: idParameter, statusCodes: ["404", "409", "500", "504"])],
                "/api/tunnels/{id}/stop": ["post": operation("停止隧道", response: ["type": "object", "properties": ["ok": ["type": "boolean"], "operation": ["type": "string"], "tunnel": summaryRef]], parameters: idParameter, statusCodes: ["404", "409", "500", "504"])],
                "/api/tunnels/{id}/restart": ["post": operation("重启隧道", response: ["type": "object", "properties": ["ok": ["type": "boolean"], "operation": ["type": "string"], "tunnel": summaryRef]], parameters: idParameter, statusCodes: ["404", "409", "500", "504"])],
                "/api/tunnels/{id}/logs": ["get": operation("读取日志", response: logRef, parameters: idParameter, statusCodes: ["404", "500"])],
                "/api/tunnels/{id}/logs/clear": ["post": operation("清空日志", response: logRef, parameters: idParameter, statusCodes: ["404", "500"])],
                "/openapi.json": ["get": operation("OpenAPI 描述", response: ["type": "object"])],
            ],
            "components": [
                "schemas": [
                    "TunnelSummary": summarySchema,
                    "ProbeSummary": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "status": ["type": "string", "enum": ["disabled", "unknown", "satisfied", "unexpected", "failed"]],
                            "httpStatus": ["type": "integer"]
                        ],
                        "required": ["enabled", "status"]
                    ],
                    "LogSnapshot": [
                        "type": "object",
                        "properties": [
                            "ok": ["type": "boolean"],
                            "tunnelId": ["type": "string"],
                            "version": ["type": "integer"],
                            "status": ["type": "string", "enum": ["available", "missing", "error"]],
                            "text": ["type": "string"]
                        ],
                        "required": ["ok", "tunnelId", "version", "status", "text"]
                    ],
                    "ErrorResponse": [
                        "type": "object",
                        "properties": [
                            "ok": ["type": "boolean", "const": false],
                            "error": [
                                "type": "object",
                                "properties": ["code": ["type": "string"], "message": ["type": "string"]],
                                "required": ["code", "message"]
                            ]
                        ],
                        "required": ["ok", "error"]
                    ]
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }()
}
