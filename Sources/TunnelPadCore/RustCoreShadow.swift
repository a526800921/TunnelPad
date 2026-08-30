import Foundation
import Darwin

/// 可选的 Rust Core 影子校验器。
///
/// Rust 只验证 Swift 生成的配置 JSON，不拥有任何生命周期操作。动态库缺失、ABI
/// 不匹配或校验失败时，该对象保持不可用，调用方继续使用 Swift Core。
final class RustCoreShadow: @unchecked Sendable {
    private typealias ABIVersion = @convention(c) () -> UInt32
    private typealias ConfigParse = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias StringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private enum State {
        case unavailable(String)
        case dynamic(ABIVersion, ConfigParse, StringFree)
        case test(abiVersion: UInt32, configParses: Bool)
    }

    static let expectedABIVersion: UInt32 = 1

    private let handle: UnsafeMutableRawPointer?
    private var state: State

    var isAvailable: Bool {
        switch state {
        case .dynamic:
            return true
        case .test(let abiVersion, _):
            return abiVersion == Self.expectedABIVersion
        case .unavailable:
            return false
        }
    }

    var failureReason: String? {
        if case .unavailable(let reason) = state {
            return reason
        }
        return nil
    }

    init(libraryURL: URL? = RustCoreShadow.defaultLibraryURL()) {
        guard let libraryURL else {
            self.handle = nil
            self.state = .unavailable("Rust 动态库路径不可用")
            return
        }
        guard let handle = libraryURL.path.withCString({
            dlopen($0, RTLD_NOW | RTLD_LOCAL)
        }) else {
            self.handle = nil
            self.state = .unavailable("无法加载 Rust 动态库：\(Self.lastDynamicLoaderError())")
            return
        }

        guard let abiSymbol = dlsym(handle, "tp_abi_version") else {
            dlclose(handle)
            self.handle = nil
            self.state = .unavailable("Rust 动态库缺少 ABI v1 必需符号")
            return
        }

        let abiVersion = unsafeBitCast(abiSymbol, to: ABIVersion.self)
        guard abiVersion() == Self.expectedABIVersion else {
            dlclose(handle)
            self.handle = nil
            self.state = .unavailable("Rust ABI 版本不匹配")
            return
        }

        guard
            let configParseSymbol = dlsym(handle, "tp_config_parse"),
            let stringFreeSymbol = dlsym(handle, "tp_string_free")
        else {
            dlclose(handle)
            self.handle = nil
            self.state = .unavailable("Rust 动态库缺少 ABI v1 必需符号")
            return
        }

        self.handle = handle
        self.state = .dynamic(
            abiVersion,
            unsafeBitCast(configParseSymbol, to: ConfigParse.self),
            unsafeBitCast(stringFreeSymbol, to: StringFree.self)
        )
    }

    /// 测试用后端，覆盖缺失/ABI 不匹配/解析失败而不依赖动态库文件。
    init(testABI: UInt32, configParses: Bool) {
        self.handle = nil
        self.state = .test(abiVersion: testABI, configParses: configParses)
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    /// 对配置做非权威 Rust 校验；返回 false 时调用方必须继续使用 Swift 结果。
    @discardableResult
    func validateConfig(_ config: AppConfig) -> Bool {
        switch state {
        case .unavailable:
            return false
        case .test(let abiVersion, let configParses):
            guard abiVersion == Self.expectedABIVersion, configParses else {
                state = .unavailable("Rust 配置影子校验失败")
                return false
            }
            return true
        case .dynamic(_, let configParse, let stringFree):
            guard
                let data = try? JSONEncoder().encode(config),
                let json = String(data: data, encoding: .utf8)
            else {
                state = .unavailable("Swift 配置无法编码为 Rust 校验输入")
                return false
            }

            var output: UnsafeMutablePointer<CChar>?
            json.withCString { input in
                output = configParse(input)
            }
            guard let output else {
                state = .unavailable("Rust 配置影子校验失败")
                return false
            }
            stringFree(output)
            return true
        }
    }

    static func defaultLibraryURL() -> URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("libtunnelpad_core.dylib")
    }

    private static func lastDynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "未知加载错误"
        }
        return String(cString: error)
    }
}
