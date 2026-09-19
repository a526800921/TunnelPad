import Foundation

/// SSH 命令参数工具：设置弹窗的「SSH 详细日志」开关据此读取和改写命令参数。
/// 命令是自由格式参数数组（首行为可执行文件路径），只精确增删独立的 `-v`，不碰 `-vv` 等其他参数。
public enum SSHCommand {
    struct RemotePortCleanupTarget: Equatable, Sendable {
        let resource: String
        let port: Int
        let sshArguments: [String]
    }

    enum RemotePortCleanupParseError: Error, Equatable, Sendable {
        case unsupportedExecutable
        case unsupportedArgument
        case invalidValue
        case missingReverseForward
        case multipleReverseForwards
        case missingDestination
        case multipleDestinations
    }

    /// 命令的可执行文件是否为 ssh（按首行路径末段判断，兼容 PATH 上的 `ssh`）。
    public static func isSSH(_ command: [String]) -> Bool {
        guard let first = command.first else { return false }
        return (first as NSString).lastPathComponent == "ssh"
    }

    /// 参数中是否已带独立的 `-v`（`-vv`、`-i` 等不算）。
    public static func hasVerboseFlag(_ command: [String]) -> Bool {
        command.dropFirst().contains("-v")
    }

    /// 在可执行文件行之后插入 `-v`；已有则原样返回。
    public static func addingVerboseFlag(_ command: [String]) -> [String] {
        guard let first = command.first, !hasVerboseFlag(command) else { return command }
        return [first, "-v"] + command.dropFirst()
    }

    /// 移除独立的 `-v` 参数，其余参数保持原顺序。
    public static func removingVerboseFlag(_ command: [String]) -> [String] {
        guard let first = command.first else { return command }
        return [first] + command.dropFirst().filter { $0 != "-v" }
    }

    /// 为“远端端口强杀”生成一条不继承用户 ssh_config、转发或远端命令的短连接。
    /// 解析采用显式允许列表；未知/合并参数一律拒绝，避免把可执行入口带入清理链。
    static func remotePortCleanupTarget(_ command: [String]) throws -> RemotePortCleanupTarget {
        guard command.first == "/usr/bin/ssh" else {
            throw RemotePortCleanupParseError.unsupportedExecutable
        }

        var identityFile: String?
        var sshPort: Int?
        var explicitUser: String?
        var addressFamily: String?
        var strictHostKeyChecking = "accept-new"
        var seenOptions = Set<String>()
        var remotePort: Int?
        var destination: String?
        var index = 1

        func value(after option: String) throws -> String {
            guard index + 1 < command.count else {
                throw RemotePortCleanupParseError.invalidValue
            }
            let value = command[index + 1]
            guard !value.isEmpty else { throw RemotePortCleanupParseError.invalidValue }
            index += 2
            return value
        }

        while index < command.count {
            let argument = command[index]
            if destination != nil {
                throw RemotePortCleanupParseError.multipleDestinations
            }

            switch argument {
            case "-N", "-T", "-v", "-vv", "-vvv":
                index += 1
            case "-4", "-6":
                guard addressFamily == nil || addressFamily == argument else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                addressFamily = argument
                index += 1
            case "-i":
                let value = try value(after: argument)
                guard identityFile == nil, value.hasPrefix("/"), isSafeScalarValue(value) else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                identityFile = value
            case "-p":
                let value = try value(after: argument)
                guard sshPort == nil, let parsed = decimalPort(value) else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                sshPort = parsed
            case "-l":
                let value = try value(after: argument)
                guard explicitUser == nil, isSafeUser(value) else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                explicitUser = value
            case "-L":
                _ = try value(after: argument)
            case "-R":
                let value = try value(after: argument)
                guard remotePort == nil else {
                    throw RemotePortCleanupParseError.multipleReverseForwards
                }
                guard let parsed = parseLoopbackRemotePort(value) else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                remotePort = parsed
            case "-o":
                let value = try value(after: argument)
                let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { throw RemotePortCleanupParseError.invalidValue }
                let key = pieces[0].lowercased()
                let optionValue = String(pieces[1])
                guard seenOptions.insert(key).inserted else {
                    throw RemotePortCleanupParseError.invalidValue
                }
                switch key {
                case "batchmode", "exitonforwardfailure", "identitiesonly":
                    guard optionValue.lowercased() == "yes" else {
                        throw RemotePortCleanupParseError.invalidValue
                    }
                case "stricthostkeychecking":
                    let normalized = optionValue.lowercased()
                    guard normalized == "yes" || normalized == "accept-new" else {
                        throw RemotePortCleanupParseError.invalidValue
                    }
                    strictHostKeyChecking = normalized
                case "serveraliveinterval":
                    guard let number = Int(optionValue), (0...300).contains(number) else {
                        throw RemotePortCleanupParseError.invalidValue
                    }
                case "serveralivecountmax":
                    guard let number = Int(optionValue), (1...10).contains(number) else {
                        throw RemotePortCleanupParseError.invalidValue
                    }
                default:
                    throw RemotePortCleanupParseError.unsupportedArgument
                }
            default:
                guard !argument.hasPrefix("-"), isSafeDestination(argument) else {
                    throw RemotePortCleanupParseError.unsupportedArgument
                }
                destination = argument
                index += 1
            }
        }

        guard let remotePort else { throw RemotePortCleanupParseError.missingReverseForward }
        guard let destination else { throw RemotePortCleanupParseError.missingDestination }
        let split = splitDestination(destination)
        guard explicitUser == nil || split.user == nil else {
            throw RemotePortCleanupParseError.invalidValue
        }
        let effectiveUser = explicitUser ?? split.user ?? ""
        let effectiveSSHPort = sshPort ?? 22

        var arguments = ["-F", "/dev/null"]
        if let addressFamily { arguments.append(addressFamily) }
        if let identityFile { arguments += ["-i", identityFile] }
        if let sshPort { arguments += ["-p", String(sshPort)] }
        if let explicitUser { arguments += ["-l", explicitUser] }
        arguments += [
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "RequestTTY=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=\(strictHostKeyChecking)",
            "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-T",
            destination,
            "/usr/bin/python3", "-I", "-S", "-", String(remotePort),
        ]

        return RemotePortCleanupTarget(
            resource: "\(effectiveUser)@\(split.host.lowercased()):\(effectiveSSHPort)/tcp/\(remotePort)",
            port: remotePort,
            sshArguments: arguments
        )
    }

    private static func parseLoopbackRemotePort(_ value: String) -> Int? {
        let prefix = "127.0.0.1:"
        guard value.hasPrefix(prefix) else { return nil }
        let remainder = value.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let port = String(remainder[..<separator])
        let target = remainder[remainder.index(after: separator)...]
        guard !target.isEmpty else { return nil }
        return decimalPort(port)
    }

    private static func decimalPort(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = Int(value), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private static func isSafeScalarValue(_ value: String) -> Bool {
        !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    private static func isSafeUser(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    private static func isSafeDestination(_ value: String) -> Bool {
        guard isSafeScalarValue(value), !value.hasPrefix("-") else { return false }
        let split = splitDestination(value)
        guard split.user.map(isSafeUser) ?? true, !split.host.isEmpty else { return false }
        if split.host.hasPrefix("[") && split.host.hasSuffix("]") {
            return split.host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" }
        }
        return split.host.allSatisfy { $0.isLetter || $0.isNumber || ".-".contains($0) }
    }

    private static func splitDestination(_ value: String) -> (user: String?, host: String) {
        guard let separator = value.firstIndex(of: "@") else { return (nil, value) }
        guard value[value.index(after: separator)...].firstIndex(of: "@") == nil else {
            return (nil, "")
        }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }
}
