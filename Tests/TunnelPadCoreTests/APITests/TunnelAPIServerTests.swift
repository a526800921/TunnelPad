import Foundation
import XCTest
@testable import TunnelPadCore

final class TunnelAPIServerTests: XCTestCase {

    func testRoutesReturnSafeJSONAndOpenAPI() async throws {
        let backend = APIBackendFixture()
        let server = TunnelAPIServer(port: 0, backend: backend)
        try server.start()
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.localPort)

        let health = try await request(port: port, path: "/api/health")
        XCTAssertEqual(health.statusCode, 200)
        XCTAssertEqual(try jsonObject(health.body)["ok"] as? Bool, true)

        let list = try await request(port: port, path: "/api/tunnels")
        XCTAssertEqual(list.statusCode, 200)
        let listObject = try jsonObject(list.body)
        XCTAssertEqual((listObject["tunnels"] as? [[String: Any]])?.count, 1)
        let listText = String(decoding: list.body, as: UTF8.self)
        XCTAssertFalse(listText.contains("/usr/bin/ssh"))
        XCTAssertFalse(listText.contains("http://private.example"))

        let logs = try await request(port: port, path: "/api/tunnels/demo/logs")
        XCTAssertEqual(logs.statusCode, 200)
        XCTAssertEqual(try jsonObject(logs.body)["tunnelId"] as? String, "demo")

        let clear = try await request(port: port, path: "/api/tunnels/demo/logs/clear", method: "POST")
        XCTAssertEqual(clear.statusCode, 200)

        let openAPI = try await request(port: port, path: "/openapi.json")
        XCTAssertEqual(openAPI.statusCode, 200)
        let spec = try jsonObject(openAPI.body)
        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])
        XCTAssertEqual(paths.count, 9)
        XCTAssertNotNil(paths["/api/tunnels/{id}/restart"])
        XCTAssertEqual((spec["servers"] as? [[String: Any]])?.first?["url"] as? String, "http://127.0.0.1:9998")
    }

    func testOperationErrorsAndTimeoutAreStable() async throws {
        let backend = APIBackendFixture()
        let server = TunnelAPIServer(
            port: 0,
            operationTimeoutNanoseconds: 20_000_000,
            backend: backend
        )
        try server.start()
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.localPort)

        let success = try await request(port: port, path: "/api/tunnels/demo/start", method: "POST")
        XCTAssertEqual(success.statusCode, 200)
        XCTAssertEqual(try jsonObject(success.body)["operation"] as? String, "start")

        backend.operationResult = .inProgress
        let conflict = try await request(port: port, path: "/api/tunnels/demo/stop", method: "POST")
        XCTAssertEqual(conflict.statusCode, 409)
        XCTAssertEqual(try errorCode(conflict.body), "operation_in_progress")

        let unknown = try await request(port: port, path: "/api/tunnels/ghost")
        XCTAssertEqual(unknown.statusCode, 404)
        XCTAssertEqual(try errorCode(unknown.body), "tunnel_not_found")

        backend.operationResult = .completed(backend.summary)
        backend.operationDelayNanoseconds = 100_000_000
        let timeout = try await request(port: port, path: "/api/tunnels/demo/restart", method: "POST")
        XCTAssertEqual(timeout.statusCode, 504)
        XCTAssertEqual(try errorCode(timeout.body), "operation_timeout")
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func testKnownRouteWithWrongMethodReturnsInvalidRequest() async throws {
        let server = TunnelAPIServer(port: 0, backend: APIBackendFixture())
        try server.start()
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.localPort)

        let response = try await request(port: port, path: "/api/health", method: "POST")
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(try errorCode(response.body), "invalid_request")
    }

    func testBindingConflictThrowsWithoutFallbackPort() throws {
        let first = TunnelAPIServer(port: 0, backend: APIBackendFixture())
        try first.start()
        defer { try? first.stop() }
        let occupiedPort = try XCTUnwrap(first.localPort)

        let second = TunnelAPIServer(port: occupiedPort, backend: APIBackendFixture())
        XCTAssertThrowsError(try second.start())
        XCTAssertFalse(second.isRunning)
        XCTAssertEqual(first.localPort, occupiedPort)
    }

    private func request(
        port: Int,
        path: String,
        method: String = "GET"
    ) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (httpResponse.statusCode, body)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ data: Data) throws -> String {
        let object = try jsonObject(data)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? String)
    }
}

private final class APIBackendFixture: TunnelAPIBackend, @unchecked Sendable {
    let summary = TunnelAPISummary(
        id: "demo",
        name: "Demo",
        remark: "本地测试",
        executor: "launchd",
        keepAlive: true,
        throttleInterval: 10,
        status: "not_loaded",
        pid: nil,
        busy: false,
        probe: TunnelAPIProbeSummary(enabled: true, status: "failed")
    )

    var operationResult: TunnelAPIBackendOperationResult
    var operationDelayNanoseconds: UInt64 = 0

    init() {
        operationResult = .completed(summary)
    }

    func listTunnels() async -> [TunnelAPISummary] { [summary] }

    func tunnel(id: String) async -> TunnelAPISummary? {
        id == summary.id ? summary : nil
    }

    func operate(id: String, operation _: TunnelAPIOperation) async -> TunnelAPIBackendOperationResult {
        if operationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
        guard id == summary.id else { return .notFound }
        return operationResult
    }

    func logs(id: String) async -> TunnelAPIBackendLogResult {
        guard id == summary.id else { return .notFound }
        return .completed(TunnelAPILogSnapshot(tunnelID: id, version: 3, status: "available", text: "safe\n"))
    }

    func clearLogs(id: String) async -> TunnelAPIBackendLogResult {
        guard id == summary.id else { return .notFound }
        return .completed(TunnelAPILogSnapshot(tunnelID: id, version: 4, status: "available", text: ""))
    }
}
