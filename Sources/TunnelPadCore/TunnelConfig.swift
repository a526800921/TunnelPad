import Foundation

/// 执行器类型。v1 阶段仅实现 launchd；app 执行器在阶段 2 落地。
public enum ExecutorKind: String, Codable, Sendable, CaseIterable {
    case launchd
    case app
}

/// 单条隧道配置（config.json 的 tunnels 条目）。
public struct TunnelConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 等价于 launchd plist 的 ProgramArguments，原样保存、不规范化。
    public var command: [String]
    public var executor: ExecutorKind
    public var keepAlive: Bool
    /// 秒。写入生成 plist 的 ThrottleInterval。
    public var throttleInterval: Int

    public static let idPattern = "^[a-z0-9-]+$"
    public static let launchdLabelPrefix = "com.jafish.tunnelpad."

    public init(
        id: String,
        name: String,
        command: [String],
        executor: ExecutorKind = .launchd,
        keepAlive: Bool = true,
        throttleInterval: Int = 10
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.executor = executor
        self.keepAlive = keepAlive
        self.throttleInterval = throttleInterval
    }

    public var launchdLabel: String { Self.launchdLabelPrefix + id }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.range(of: idPattern, options: .regularExpression) != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, executor, keepAlive, throttleInterval
    }

    /// 手写配置允许省略带默认值的字段。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode([String].self, forKey: .command)
        executor = try container.decodeIfPresent(ExecutorKind.self, forKey: .executor) ?? .launchd
        keepAlive = try container.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? true
        throttleInterval = try container.decodeIfPresent(Int.self, forKey: .throttleInterval) ?? 10

        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "隧道 id 只允许小写字母、数字与连字符：\(id)"
            )
        }
        guard !command.isEmpty, !command[0].isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container,
                debugDescription: "command 不能为空且首元素必须是可执行路径"
            )
        }
    }
}
