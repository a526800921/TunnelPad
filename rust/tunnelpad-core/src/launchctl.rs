//! launchd 执行器（Swift `LaunchCtlExecutor` + `ProcessRunner` 对等）。
//! bootstrap / bootout / status，标签 `com.jafish.tunnelpad.<id>`。

use std::path::Path;
use std::process::{Command, Stdio};

use serde::Serialize;

/// launchctl 查询到的隧道状态。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "case", rename_all = "camelCase")]
pub enum TunnelStatus {
    Running { pid: Option<i32> },
    NotRunning,
    NotLoaded,
    Other { state: String },
}

/// 执行器错误。Swift 端 runner 抛出的 spawn 错误会原样重抛（不包装为
/// commandFailed），因此用 `kind` 区分两类；serde 形状即差分事件形状。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ExecutorError {
    #[serde(rename_all = "camelCase")]
    CommandFailed { operation: String, exit_code: i32, stderr: String },
    #[serde(rename_all = "camelCase")]
    Spawn { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// 同步执行外部命令（launchctl 等），测试可注入 fake。
pub trait ProcessRunning: Send + Sync {
    fn run(&self, executable_path: &str, arguments: &[String]) -> Result<ProcessResult, String>;
}

/// 真实系统执行器：同步执行、读全量 stdout/stderr、等退出。
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemProcessRunner;

impl ProcessRunning for SystemProcessRunner {
    fn run(&self, executable_path: &str, arguments: &[String]) -> Result<ProcessResult, String> {
        let output = Command::new(executable_path)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| e.to_string())?;
        Ok(ProcessResult {
            exit_code: output.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        })
    }
}

/// launchd 执行器。
pub struct LaunchCtlExecutor<R: ProcessRunning> {
    pub runner: R,
    pub uid: u32,
}

impl Default for LaunchCtlExecutor<SystemProcessRunner> {
    fn default() -> Self {
        LaunchCtlExecutor { runner: SystemProcessRunner, uid: current_uid() }
    }
}

pub fn current_uid() -> u32 {
    // # Safety: getuid 无失败路径。
    unsafe { libc::getuid() }
}

impl<R: ProcessRunning> LaunchCtlExecutor<R> {
    pub fn new(runner: R, uid: u32) -> Self {
        LaunchCtlExecutor { runner, uid }
    }

    pub const LAUNCHCTL_PATH: &'static str = "/bin/launchctl";

    pub fn domain(&self) -> String {
        format!("gui/{}", self.uid)
    }

    /// 加载并立即启动（生成 plist 固定 RunAtLoad=true）。
    /// `label` 仅用于调用方语义；launchctl bootstrap 以 plist 路径定位。
    pub fn bootstrap(&self, _label: &str, plist_path: &Path) -> Result<(), ExecutorError> {
        let result = self
            .runner
            .run(Self::LAUNCHCTL_PATH, &["bootstrap".into(), self.domain(), path_display(plist_path)])
            .map_err(|message| ExecutorError::Spawn { message })?;
        if result.exit_code == 0 {
            Ok(())
        } else {
            Err(ExecutorError::CommandFailed {
                operation: "bootstrap".into(),
                exit_code: result.exit_code,
                stderr: result.stderr,
            })
        }
    }

    /// 卸载。返回是否确实卸载了已加载实例；"未加载"不算错误。
    pub fn bootout(&self, label: &str) -> Result<bool, ExecutorError> {
        let result = self
            .runner
            .run(
                Self::LAUNCHCTL_PATH,
                &["bootout".into(), format!("{}/{}", self.domain(), label)],
            )
            .map_err(|message| ExecutorError::Spawn { message })?;
        if result.exit_code == 0 {
            return Ok(true);
        }
        if is_not_found_message(&result.stderr, &result.stdout) {
            return Ok(false);
        }
        Err(ExecutorError::CommandFailed {
            operation: "bootout".into(),
            exit_code: result.exit_code,
            stderr: result.stderr,
        })
    }

    /// 查询状态；命令失败（未加载/不可执行）一律按 notLoaded 处理。
    pub fn status(&self, label: &str) -> TunnelStatus {
        match self.runner.run(
            Self::LAUNCHCTL_PATH,
            &["print".into(), format!("{}/{}", self.domain(), label)],
        ) {
            Ok(result) if result.exit_code == 0 => parse_status(&result.stdout),
            _ => TunnelStatus::NotLoaded,
        }
    }
}

fn path_display(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

/// 解析 `launchctl print` 输出。只看顶层字段（单制表符缩进），忽略嵌套块。
pub fn parse_status(stdout: &str) -> TunnelStatus {
    let mut state: Option<String> = None;
    let mut pid: Option<i32> = None;

    for line in stdout.split('\n').filter(|l| !l.is_empty()) {
        if leading_tab_count(line) != 1 {
            continue;
        }
        let trimmed = line.trim_matches(|c: char| c == ' ' || c == '\t');
        if state.is_none() {
            if let Some(value) = top_level_value("state", trimmed) {
                state = Some(value.to_string());
                continue;
            }
        }
        if pid.is_none() {
            if let Some(value) = top_level_value("pid", trimmed) {
                if let Ok(number) = value.parse::<i32>() {
                    pid = Some(number);
                }
            }
        }
    }

    match state.as_deref() {
        Some("running") => TunnelStatus::Running { pid },
        Some("not running") => TunnelStatus::NotRunning,
        Some(other) => TunnelStatus::Other { state: other.to_string() },
        None => TunnelStatus::NotLoaded,
    }
}

fn leading_tab_count(line: &str) -> usize {
    line.chars().take_while(|c| *c == '\t').count()
}

fn top_level_value<'a>(key: &str, trimmed_line: &'a str) -> Option<&'a str> {
    if !trimmed_line.starts_with(&format!("{key} =")) {
        return None;
    }
    let equals = trimmed_line.find('=')?;
    let value = trimmed_line[equals + 1..].trim_matches(|c: char| c == ' ' || c == '\t');
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn is_not_found_message(stderr: &str, stdout: &str) -> bool {
    let combined = format!("{stderr}{stdout}");
    combined.contains("Could not find service") || combined.contains("No such file or directory")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    struct FakeRunner {
        outputs: Mutex<VecDeque<Result<ProcessResult, String>>>,
    }

    impl FakeRunner {
        fn new(outputs: Vec<Result<ProcessResult, String>>) -> Self {
            FakeRunner { outputs: Mutex::new(outputs.into()) }
        }
    }

    impl ProcessRunning for FakeRunner {
        fn run(&self, _exe: &str, _args: &[String]) -> Result<ProcessResult, String> {
            self.outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("脚本输出已耗尽")
        }
    }

    #[test]
    fn parse_status_matches_swift() {
        // 无顶层 state（0 缩进的行被忽略）→ notLoaded
        assert_eq!(parse_status("state = running\npid = 5"), TunnelStatus::NotLoaded);
        // 嵌套块（2 缩进）里的 state = active 被忽略
        assert_eq!(
            parse_status("\tstate = running\n\tpid = 1234\n\t\tstate = active"),
            TunnelStatus::Running { pid: Some(1234) }
        );
        assert_eq!(
            parse_status("\tstate = running\n\tpid = 1234"),
            TunnelStatus::Running { pid: Some(1234) }
        );
        assert_eq!(parse_status("\tstate = not running"), TunnelStatus::NotRunning);
        assert_eq!(
            parse_status("\tstate = weird-state"),
            TunnelStatus::Other { state: "weird-state".into() }
        );
        assert_eq!(parse_status(""), TunnelStatus::NotLoaded);
        assert_eq!(parse_status("\tstate = running"), TunnelStatus::Running { pid: None });
        // 非法 pid 忽略
        assert_eq!(
            parse_status("\tstate = running\n\tpid = 99999999999"),
            TunnelStatus::Running { pid: None }
        );
    }

    #[test]
    fn bootout_not_found_is_not_error() {
        let executor = LaunchCtlExecutor::new(
            FakeRunner::new(vec![Ok(ProcessResult {
                exit_code: 3,
                stdout: "".to_string(),
                stderr: "Could not find service \"gui/501/x\" in domain".into(),
            })]),
            501,
        );
        assert_eq!(executor.bootout("x").unwrap(), false);
        assert_eq!(executor.domain(), "gui/501");
    }

    #[test]
    fn bootout_other_failure_is_error() {
        let executor = LaunchCtlExecutor::new(
            FakeRunner::new(vec![Ok(ProcessResult {
                exit_code: 1,
                stdout: "".to_string(),
                stderr: "Bootstrap failed: 5".into(),
            })]),
            501,
        );
        match executor.bootout("x") {
            Err(ExecutorError::CommandFailed { operation, exit_code, stderr }) => {
                assert_eq!(operation, "bootout");
                assert_eq!(exit_code, 1);
                assert_eq!(stderr, "Bootstrap failed: 5");
            }
            other => panic!("期望 CommandFailed，实际 {other:?}"),
        }
    }
}
