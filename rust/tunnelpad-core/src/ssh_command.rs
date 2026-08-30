//! SSH 命令参数工具（Swift `SSHCommand` 对等）。
//! 命令是自由格式参数数组（首行为可执行文件路径），只精确增删独立的 `-v`。

use std::path::Path;

/// 命令的可执行文件是否为 ssh（按首行路径末段判断，兼容 PATH 上的 `ssh`）。
pub fn is_ssh(command: &[String]) -> bool {
    match command.first() {
        Some(first) => Path::new(first).file_name().map(|f| f == "ssh").unwrap_or(false),
        None => false,
    }
}

/// 参数中是否已带独立的 `-v`（`-vv`、`-i` 等不算）。
pub fn has_verbose_flag(command: &[String]) -> bool {
    command.iter().skip(1).any(|arg| arg == "-v")
}

/// 在可执行文件行之后插入 `-v`；已有则原样返回。
pub fn adding_verbose_flag(command: &[String]) -> Vec<String> {
    match command.first() {
        Some(first) if !has_verbose_flag(command) => {
            let mut out = vec![first.clone(), "-v".to_string()];
            out.extend_from_slice(&command[1..]);
            out
        }
        _ => command.to_vec(),
    }
}

/// 移除独立的 `-v` 参数，其余参数保持原顺序。
pub fn removing_verbose_flag(command: &[String]) -> Vec<String> {
    match command.first() {
        Some(first) => {
            let mut out = vec![first.clone()];
            out.extend(command.iter().skip(1).filter(|arg| arg.as_str() != "-v").cloned());
            out
        }
        None => command.to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn matches_swift_semantics() {
        assert!(is_ssh(&cmd(&["/usr/bin/ssh", "-N"])));
        assert!(is_ssh(&cmd(&["ssh", "-N"])));
        assert!(!is_ssh(&cmd(&["/usr/bin/sshx", "-N"])));
        assert!(!is_ssh(&cmd(&["-N"])));
        assert!(!is_ssh(&[]));

        assert!(!has_verbose_flag(&cmd(&["ssh", "-N"])));
        assert!(has_verbose_flag(&cmd(&["ssh", "-N", "-v"])));
        assert!(!has_verbose_flag(&cmd(&["ssh", "-vv"])));
        assert!(!has_verbose_flag(&cmd(&["ssh"])));

        assert_eq!(adding_verbose_flag(&cmd(&["ssh", "-N"])), cmd(&["ssh", "-v", "-N"]));
        assert_eq!(adding_verbose_flag(&cmd(&["ssh", "-v", "-N"])), cmd(&["ssh", "-v", "-N"]));
        assert_eq!(removing_verbose_flag(&cmd(&["ssh", "-N", "-v", "-L", "a:b"])), cmd(&["ssh", "-N", "-L", "a:b"]));
        assert_eq!(removing_verbose_flag(&cmd(&["ssh", "-vv"])), cmd(&["ssh", "-vv"]));
    }
}
