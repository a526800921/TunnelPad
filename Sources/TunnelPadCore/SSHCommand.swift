import Foundation

/// SSH 命令参数工具：设置弹窗的「SSH 详细日志」开关据此读取和改写命令参数。
/// 命令是自由格式参数数组（首行为可执行文件路径），只精确增删独立的 `-v`，不碰 `-vv` 等其他参数。
public enum SSHCommand {
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
}
