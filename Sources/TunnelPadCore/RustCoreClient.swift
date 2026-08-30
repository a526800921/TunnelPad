import Foundation
import Darwin

/// Rust Core owner 的 Swift FFI 适配层。
///
/// 这里仅负责动态库加载、UTF-8 JSON 编解码和 UI 类型映射；配置、状态、
/// launchd 生命周期和 shutdown 语义都由 Rust handle 持有。动态库不可用时
/// 该对象保持失败状态，调用方不得回退到 Swift Core。
final class RustCoreClient: @unchecked Sendable {
    enum ClientError: LocalizedError, Sendable {
        case unavailable(String)
        case missingSymbol(String)
        case abiMismatch(UInt32)
        case createFailed(String)
        case transport(String)
        case remote(code: UInt32, message: String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Rust Core 不可用：\(reason)"
            case .missingSymbol(let symbol): return "Rust Core 缺少符号：\(symbol)"
            case .abiMismatch(let version): return "Rust Core owner ABI 不匹配：\(version)"
            case .createFailed(let reason): return "Rust Core owner 创建失败：\(reason)"
            case .transport(let reason): return "Rust Core FFI 传输失败：\(reason)"
            case .remote(let code, let message): return "Rust Core 操作失败（\(code)）：\(message)"
            case .invalidResponse(let reason): return "Rust Core 返回无效结果：\(reason)"
            }
        }
    }

    struct Snapshot: Sendable {
        let config: AppConfig
        let statuses: [String: TunnelStatus]
    }

    private typealias CoreVersion = @convention(c) () -> UInt32
    private typealias CoreCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias CoreCommand = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CoreShutdown = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias CoreDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CoreLastError = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias CoreStringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private static let expectedABI: UInt32 = 1

    private let libraryHandle: UnsafeMutableRawPointer?
    private let ownerHandle: UnsafeMutableRawPointer?
    private let commandFunction: CoreCommand?
    private let shutdownFunction: CoreShutdown?
    private let destroyFunction: CoreDestroy?
    private let lastErrorFunction: CoreLastError?
    private let stringFreeFunction: CoreStringFree?
    private let failure: ClientError?

    init(paths: TunnelPaths, libraryURL: URL? = RustCoreClient.defaultLibraryURL()) throws {
        guard let libraryURL else {
            throw ClientError.unavailable("动态库路径不可用")
        }
        guard let libraryHandle = libraryURL.path.withCString({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }) else {
            throw ClientError.unavailable(Self.lastDynamicLoaderError())
        }

        guard let versionSymbol = dlsym(libraryHandle, "tp_core_abi_version") else {
            dlclose(libraryHandle)
            throw ClientError.missingSymbol("tp_core_abi_version")
        }
        let version = unsafeBitCast(versionSymbol, to: CoreVersion.self)()
        guard version == Self.expectedABI else {
            dlclose(libraryHandle)
            throw ClientError.abiMismatch(version)
        }

        guard
            let createSymbol = dlsym(libraryHandle, "tp_core_create"),
            let commandSymbol = dlsym(libraryHandle, "tp_core_command"),
            let shutdownSymbol = dlsym(libraryHandle, "tp_core_shutdown"),
            let destroySymbol = dlsym(libraryHandle, "tp_core_destroy"),
            let lastErrorSymbol = dlsym(libraryHandle, "tp_core_last_error"),
            let stringFreeSymbol = dlsym(libraryHandle, "tp_string_free")
        else {
            dlclose(libraryHandle)
            throw ClientError.missingSymbol("tp_core_create/tp_core_command/tp_core_shutdown/tp_core_destroy/tp_core_last_error/tp_string_free")
        }

        let create = unsafeBitCast(createSymbol, to: CoreCreate.self)
        let ownerHandle = paths.homeDirectory.path.withCString { create($0) }
        guard let ownerHandle else {
            let lastError = unsafeBitCast(lastErrorSymbol, to: CoreLastError.self)
            let free = unsafeBitCast(stringFreeSymbol, to: CoreStringFree.self)
            let reason: String
            if let pointer = lastError() {
                reason = String(cString: pointer)
                free(pointer)
            } else {
                reason = "未知错误"
            }
            dlclose(libraryHandle)
            throw ClientError.createFailed(reason)
        }

        self.libraryHandle = libraryHandle
        self.ownerHandle = ownerHandle
        self.commandFunction = unsafeBitCast(commandSymbol, to: CoreCommand.self)
        self.shutdownFunction = unsafeBitCast(shutdownSymbol, to: CoreShutdown.self)
        self.destroyFunction = unsafeBitCast(destroySymbol, to: CoreDestroy.self)
        self.lastErrorFunction = unsafeBitCast(lastErrorSymbol, to: CoreLastError.self)
        self.stringFreeFunction = unsafeBitCast(stringFreeSymbol, to: CoreStringFree.self)
        self.failure = nil
    }

    /// 仅供 UI 门面在动态库加载失败时持有一个可描述错误的 client；它不
    /// 执行任何 Swift Core fallback。
    init(failure: ClientError) {
        libraryHandle = nil
        ownerHandle = nil
        commandFunction = nil
        shutdownFunction = nil
        destroyFunction = nil
        lastErrorFunction = nil
        stringFreeFunction = nil
        self.failure = failure
    }

    deinit {
        if let ownerHandle, let destroyFunction {
            destroyFunction(ownerHandle)
        }
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    func loadConfig() throws -> AppConfig {
        let result = try send(["op": "loadConfig"])
        return try decode(AppConfig.self, from: result["config"])
    }

    func saveConfig(_ config: AppConfig) throws {
        let configData = try JSONEncoder().encode(config)
        let configObject = try JSONSerialization.jsonObject(with: configData)
        _ = try send(["op": "saveConfig", "config": configObject])
    }

    func snapshot() throws -> Snapshot {
        let result = try send(["op": "snapshot"])
        let config = try decode(AppConfig.self, from: result["config"])
        guard let statusObjects = result["statuses"] as? [String: Any] else {
            throw ClientError.invalidResponse("snapshot 缺少 statuses")
        }
        var statuses: [String: TunnelStatus] = [:]
        for (id, statusObject) in statusObjects {
            statuses[id] = try decodeStatus(statusObject)
        }
        return Snapshot(config: config, statuses: statuses)
    }

    func status(id: String) throws -> TunnelStatus {
        let result = try send(["op": "status", "id": id])
        return try decodeStatus(result["status"])
    }

    func start(id: String) throws -> TunnelStatus {
        try lifecycle(op: "start", id: id)
    }

    func stop(id: String) throws -> TunnelStatus {
        try lifecycle(op: "stop", id: id)
    }

    func restart(id: String) throws -> TunnelStatus {
        try lifecycle(op: "restart", id: id)
    }

    func remove(id: String) throws {
        _ = try send(["op": "remove", "id": id])
    }

    func shutdown() throws -> Int {
        let result = try invokeShutdown()
        guard let stopped = result["stopped"] as? NSNumber, stopped.intValue >= 0 else {
            throw ClientError.invalidResponse("shutdown 缺少合法 stopped 数量")
        }
        return stopped.intValue
    }

    private func lifecycle(op: String, id: String) throws -> TunnelStatus {
        let result = try send(["op": op, "id": id])
        return try decodeStatus(result["status"])
    }

    private func send(_ command: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: command, options: [])
        guard let commandString = String(data: data, encoding: .utf8) else {
            throw ClientError.transport("命令不是合法 UTF-8")
        }
        guard let handle = ownerHandle, let commandFunction, let stringFreeFunction else {
            throw failure ?? ClientError.unavailable("owner handle 未创建")
        }

        var output: UnsafeMutablePointer<CChar>?
        commandString.withCString { input in
            output = commandFunction(handle, input)
        }
        guard let output else {
            throw ClientError.transport(lastErrorMessage() ?? "owner command 返回 NULL")
        }
        defer { stringFreeFunction(output) }
        return try parseResponse(String(cString: output))
    }

    private func invokeShutdown() throws -> [String: Any] {
        guard let handle = ownerHandle, let shutdownFunction, let stringFreeFunction else {
            throw failure ?? ClientError.unavailable("owner handle 未创建")
        }
        guard let output = shutdownFunction(handle) else {
            throw ClientError.transport(lastErrorMessage() ?? "owner shutdown 返回 NULL")
        }
        defer { stringFreeFunction(output) }
        return try parseResponse(String(cString: output))
    }

    private func parseResponse(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = response["ok"] as? Bool else {
            throw ClientError.invalidResponse("不是合法 owner response")
        }
        if !ok {
            let error = response["error"] as? [String: Any]
            let code = (error?["code"] as? NSNumber)?.uint32Value ?? 0
            let message = error?["message"] as? String ?? "未知错误"
            throw ClientError.remote(code: code, message: message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw ClientError.invalidResponse("成功响应缺少 result")
        }
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: Any?) throws -> T {
        guard let object else {
            throw ClientError.invalidResponse("缺少可解码字段")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.invalidResponse("字段解码失败：\(error)")
        }
    }

    private func decodeStatus(_ object: Any?) throws -> TunnelStatus {
        guard let object = object as? [String: Any], let kind = object["case"] as? String else {
            throw ClientError.invalidResponse("状态快照格式错误")
        }
        switch kind {
        case "running":
            let pid = (object["pid"] as? NSNumber).map { Int32(truncating: $0) }
            return .running(pid: pid)
        case "notRunning":
            return .notRunning
        case "notLoaded":
            return .notLoaded
        case "other":
            guard let state = object["state"] as? String else {
                throw ClientError.invalidResponse("other 状态缺少 state")
            }
            return .other(state: state)
        default:
            throw ClientError.invalidResponse("未知状态 case：\(kind)")
        }
    }

    private func lastErrorMessage() -> String? {
        guard let lastErrorFunction, let stringFreeFunction, let pointer = lastErrorFunction() else {
            return nil
        }
        defer { stringFreeFunction(pointer) }
        return String(cString: pointer)
    }

    private static func lastDynamicLoaderError() -> String {
        guard let error = dlerror() else { return "未知加载错误" }
        return String(cString: error)
    }

    /// 正式 app 只从自己的 PrivateFrameworks 加载 Rust Core。SwiftPM 测试没有
    /// app bundle，因此测试 bundle 额外允许从仓库的 release 产物加载同一份 dylib；
    /// 这不是 Swift Core fallback，测试仍然走真实 Rust owner。
    private static func defaultLibraryURL() -> URL? {
        let bundled = RustCoreShadow.defaultLibraryURL()
        guard isTestBundle else { return bundled }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("rust/target/release/libtunnelpad_core.dylib")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return bundled
    }

    private static var isTestBundle: Bool {
        Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || CommandLine.arguments.first?.contains("xctest") == true
    }
}
