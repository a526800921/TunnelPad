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
        XCTAssertEqual((spec["servers"] as? [[String: Any]])?.first?["url"] as? String, "/")
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

    func testDeniedBrowserRequestsNeverReachBackend() async throws {
        let backend = APIBackendFixture()
        let server = TunnelAPIServer(port: 0, backend: backend)
        try server.start()
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.localPort)
        for headers in [["Origin": "https://untrusted.example"],
                        ["Sec-Fetch-Site": "cross-site"],
                        ["Host": "untrusted.example:\(port)"]] {
            for path in ["/api/health", "/openapi.json", "/api/tunnels", "/api/tunnels/demo/start", "/api/tunnels/demo/logs/clear"] {
                let response = try await request(port: port, path: path,
                    method: path.hasSuffix("start") || path.hasSuffix("clear") ? "POST" : "GET", headers: headers)
                XCTAssertEqual(response.statusCode, 403, "\(headers) \(path)")
                XCTAssertEqual(try errorCode(response.body), "access_denied")
            }
        }
        XCTAssertEqual(backend.callCount, 0)
    }

    func testUnsafeListenerConfigurationNeverBinds() throws {
        for (host, clients) in [("0.0.0.0", ["10.0.0.30"]), ("10.0.0.2", []),
                                ("::", ["10.0.0.30"]), ("10.0.0.2", ["0.0.0.0/0"])] {
            let server = TunnelAPIServer(host: host, port: 0, allowedClientIPs: clients, backend: APIBackendFixture())
            XCTAssertThrowsError(try server.start())
            XCTAssertFalse(server.isRunning)
        }
    }

    func testPartialBindFailureNeverDispatchesAndReleasesFirstListener() throws {
        let backend = APIBackendFixture()
        let server = TunnelAPIServer(port: 0, backend: backend)
        var firstPort: Int?
        // Binding the same exact address twice deterministically fails the second bind.
        XCTAssertThrowsError(try server.start(listenerHosts: ["127.0.0.1", "127.0.0.1"]) { port in
            firstPort = port
            do {
                let response = try self.curl(host: "127.0.0.1", port: port,
                    path: "/api/tunnels/demo/start", method: "POST")
                XCTAssertEqual(response.status, 503)
            } catch { XCTFail("pre-ready request failed: \(error)") }
        })
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.localPort)
        let replacement = TunnelAPIServer(port: try XCTUnwrap(firstPort), backend: backend)
        try replacement.start()
        defer { try? replacement.stop() }
        XCTAssertEqual(try curl(host: "127.0.0.1", port: XCTUnwrap(firstPort), path: "/api/health").status, 200)
    }

    func testRealSocketDeniesNonAllowlistedLANPeerOnEveryRoute() throws {
        guard let lanIP = ProcessInfo.processInfo.environment["TUNNELPAD_TEST_LAN_IP"] else {
            throw XCTSkip("Set TUNNELPAD_TEST_LAN_IP to a local RFC1918 interface address for real-socket LAN coverage")
        }
        let backend = APIBackendFixture()
        let server = TunnelAPIServer(host: lanIP, port: 0, allowedClientIPs: ["10.255.255.254"], backend: backend)
        XCTAssertNotEqual(lanIP, "10.255.255.254")
        try server.start()
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.localPort)
        let routes = [("GET", "/api/health"), ("GET", "/api/tunnels"), ("GET", "/api/tunnels/demo"),
                      ("POST", "/api/tunnels/demo/start"), ("POST", "/api/tunnels/demo/stop"),
                      ("POST", "/api/tunnels/demo/restart"), ("GET", "/api/tunnels/demo/logs"),
                      ("POST", "/api/tunnels/demo/logs/clear"), ("GET", "/openapi.json")]
        for (method, path) in routes {
            let response = try curl(host: lanIP, port: port, path: path, method: method,
                headers: ["Forwarded: for=10.255.255.254", "X-Forwarded-For: 10.255.255.254"])
            XCTAssertEqual(response.status, 403, path)
            XCTAssertEqual(try errorCode(response.body), "access_denied")
        }
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertEqual(try curl(host: "127.0.0.1", port: port, path: "/api/health").status, 200)
    }

    private func curl(host: String, port: Int, path: String, method: String = "GET",
                      headers: [String] = []) throws -> (status: Int, body: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--noproxy", "*", "--silent", "--show-error", "--max-time", "3",
            "--request", method, "--write-out", "\n%{http_code}"]
            + headers.flatMap { ["--header", $0] } + ["http://\(host):\(port)\(path)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: output, as: UTF8.self)
        let separator = try XCTUnwrap(text.lastIndex(of: "\n"))
        return (try XCTUnwrap(Int(text[text.index(after: separator)...])), Data(text[..<separator].utf8))
    }

    private func request(
        port: Int,
        path: String,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
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
    private let callLock = NSLock()
    private var calls = 0
    var callCount: Int { callLock.withLock { calls } }
    private func recordCall() { callLock.withLock { calls += 1 } }

    init() {
        operationResult = .completed(summary)
    }

    func listTunnels() async -> [TunnelAPISummary] { recordCall(); return [summary] }

    func tunnel(id: String) async -> TunnelAPISummary? {
        recordCall()
        return id == summary.id ? summary : nil
    }

    func operate(id: String, operation _: TunnelAPIOperation) async -> TunnelAPIBackendOperationResult {
        recordCall()
        if operationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
        guard id == summary.id else { return .notFound }
        return operationResult
    }

    func logs(id: String) async -> TunnelAPIBackendLogResult {
        recordCall()
        guard id == summary.id else { return .notFound }
        return .completed(TunnelAPILogSnapshot(tunnelID: id, version: 3, status: "available", text: "safe\n"))
    }

    func clearLogs(id: String) async -> TunnelAPIBackendLogResult {
        recordCall()
        guard id == summary.id else { return .notFound }
        return .completed(TunnelAPILogSnapshot(tunnelID: id, version: 4, status: "available", text: ""))
    }
}
