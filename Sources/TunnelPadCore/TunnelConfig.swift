import Foundation

/// 执行器类型。阶段 5 当前只支持 launchd；app 执行器另立计划。
public enum ExecutorKind: String, Codable, Sendable, CaseIterable {
    case launchd
}

/// 可选状态探针配置（schema v1 追加的可选字段，向后兼容）。
public struct ProbeConfig: Codable, Equatable, Sendable {
    public var url: String
    public var expectedStatuses: [Int]

    public init(url: String, expectedStatuses: [Int] = [200]) {
        self.url = url
        self.expectedStatuses = expectedStatuses
    }

    enum CodingKeys: String, CodingKey {
        case url, expectedStatuses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        expectedStatuses = try container.decodeIfPresent([Int].self, forKey: .expectedStatuses) ?? [200]
    }
}

/// 单条隧道配置（config.json 的 tunnels 条目）。
public struct TunnelConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 用于管理展示的备注；缺失于旧配置时为空字符串。
    public var remark: String
    /// 等价于 launchd plist 的 ProgramArguments，原样保存、不规范化。
    public var command: [String]
    public var executor: ExecutorKind
    public var keepAlive: Bool
    /// 秒。写入生成 plist 的 ThrottleInterval。
    public var throttleInterval: Int
    /// 可选状态探针；缺省不探测。
    public var probe: ProbeConfig?

    public static let idPattern = "^[a-z0-9-]+$"
    public static let launchdLabelPrefix = "com.jafish.tunnelpad."

    public init(
        id: String,
        name: String,
        remark: String = "",
        command: [String],
        executor: ExecutorKind = .launchd,
        keepAlive: Bool = true,
        throttleInterval: Int = 10,
        probe: ProbeConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.remark = remark
        self.command = command
        self.executor = executor
        self.keepAlive = keepAlive
        self.throttleInterval = throttleInterval
        self.probe = probe
    }

    public var launchdLabel: String { Self.launchdLabelPrefix + id }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.range(of: idPattern, options: .regularExpression) != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, remark, command, executor, keepAlive, throttleInterval, probe
    }

    /// 手写配置允许省略带默认值的字段；缺 `remark` 时为空字符串，缺 `probe` 即不探测。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
        command = try container.decode([String].self, forKey: .command)
        executor = try container.decodeIfPresent(ExecutorKind.self, forKey: .executor) ?? .launchd
        keepAlive = try container.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? true
        throttleInterval = try container.decodeIfPresent(Int.self, forKey: .throttleInterval) ?? 10
        probe = try container.decodeIfPresent(ProbeConfig.self, forKey: .probe)

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
