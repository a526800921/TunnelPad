//! launchd 执行器（Swift `LaunchCtlExecutor` + `ProcessRunner` 对等）。
//! bootstrap / bootout / status，标签 `com.jafish.tunnelpad.<id>`。

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

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
    CommandFailed {
        operation: String,
        exit_code: i32,
        stderr: String,
    },
    #[serde(rename_all = "camelCase")]
    Spawn {
        message: String,
    },
    #[serde(rename_all = "camelCase")]
    ManagedProcessIdentityUnknown {
        stage: String,
    },
    #[serde(rename_all = "camelCase")]
    ManagedProcessSignalFailed {
        signal: String,
    },
    ManagedProcessStillLoaded,
    Cancelled,
}

/// 受管进程的最小身份票据。完整 argv 不属于运行时身份条件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: i32,
    pub uid: u32,
    pub start_time_micros: u128,
    pub executable_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessIdentityError {
    NotFound,
    PermissionDenied,
    Unavailable,
}

/// 读取系统进程身份；测试用 fake 注入，不调用真实进程。
pub trait ProcessIdentityReading: Send + Sync {
    fn read(&self, pid: i32) -> Result<ProcessIdentity, ProcessIdentityError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SystemProcessIdentityReader;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessSignalError {
    NotFound,
    PermissionDenied,
    Unavailable,
}

/// 向已完成身份核验的 PID 发信号；测试用 fake 注入。
pub trait ProcessSignaling: Send + Sync {
    fn send(&self, pid: i32, signal: i32) -> Result<(), ProcessSignalError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SystemProcessSignaler;

pub const SIGCONT_SIGNAL: i32 = libc::SIGCONT;
pub const SIGTERM_SIGNAL: i32 = libc::SIGTERM;
pub const SIGKILL_SIGNAL: i32 = libc::SIGKILL;

#[cfg(test)]
const MANAGED_STOP_INITIAL_WAIT_MS: u64 = 0;
#[cfg(not(test))]
const MANAGED_STOP_INITIAL_WAIT_MS: u64 = 3_000;
#[cfg(test)]
const MANAGED_STOP_CONT_WAIT_MS: u64 = 0;
#[cfg(not(test))]
const MANAGED_STOP_CONT_WAIT_MS: u64 = 1_000;
#[cfg(test)]
const MANAGED_STOP_TERM_WAIT_MS: u64 = 0;
#[cfg(not(test))]
const MANAGED_STOP_TERM_WAIT_MS: u64 = 2_000;
#[cfg(test)]
const MANAGED_STOP_KILL_WAIT_MS: u64 = 0;
#[cfg(not(test))]
const MANAGED_STOP_KILL_WAIT_MS: u64 = 1_000;
#[cfg(test)]
const MANAGED_STOP_POLL_MS: u64 = 1;
#[cfg(not(test))]
const MANAGED_STOP_POLL_MS: u64 = 100;

#[cfg(target_os = "macos")]
#[repr(C)]
struct ProcBsdInfo {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [u8; 16],
    pbi_name: [u8; 32],
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
}

#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
    fn proc_pidpath(pid: libc::c_int, buffer: *mut libc::c_void, buffersize: u32) -> libc::c_int;
}

fn map_process_error() -> ProcessIdentityError {
    match std::io::Error::last_os_error().raw_os_error() {
        Some(code) if code == libc::ESRCH => ProcessIdentityError::NotFound,
        Some(code) if code == libc::EPERM || code == libc::EACCES => {
            ProcessIdentityError::PermissionDenied
        }
        _ => ProcessIdentityError::Unavailable,
    }
}

impl ProcessIdentityReading for SystemProcessIdentityReader {
    fn read(&self, pid: i32) -> Result<ProcessIdentity, ProcessIdentityError> {
        if pid <= 0 {
            return Err(ProcessIdentityError::Unavailable);
        }

        #[cfg(target_os = "macos")]
        {
            let mut info = std::mem::MaybeUninit::<ProcBsdInfo>::uninit();
            // # Safety: buffer is valid for the exact SDK struct size and the
            // call writes only to this out-parameter.
            let result = unsafe {
                proc_pidinfo(
                    pid,
                    3,
                    0,
                    info.as_mut_ptr().cast(),
                    std::mem::size_of::<ProcBsdInfo>() as libc::c_int,
                )
            };
            if result != std::mem::size_of::<ProcBsdInfo>() as libc::c_int {
                return Err(map_process_error());
            }
            // # Safety: proc_pidinfo reported that the complete struct was written.
            let info = unsafe { info.assume_init() };
            let mut path = vec![0_u8; 4096];
            // # Safety: path is writable and its size matches the requested buffer.
            let path_length =
                unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
            if path_length <= 0 || path_length as usize > path.len() {
                return Err(map_process_error());
            }
            // `proc_pidpath` 返回的是有效路径字节数，不包含结尾 NUL；不能
            // 把这个长度直接交给 `CStr::from_bytes_until_nul`，否则正常
            // 的 macOS 进程也会被错误判定为身份未知。
            let executable_path = std::str::from_utf8(&path[..path_length as usize])
                .map_err(|_| ProcessIdentityError::Unavailable)?;
            return Ok(ProcessIdentity {
                pid: info.pbi_pid as i32,
                uid: info.pbi_uid,
                start_time_micros: (info.pbi_start_tvsec as u128)
                    .saturating_mul(1_000_000)
                    .saturating_add(info.pbi_start_tvusec as u128),
                executable_path: PathBuf::from(executable_path),
            });
        }

        #[cfg(not(target_os = "macos"))]
        {
            let _ = pid;
            Err(ProcessIdentityError::Unavailable)
        }
    }
}

impl ProcessSignaling for SystemProcessSignaler {
    fn send(&self, pid: i32, signal: i32) -> Result<(), ProcessSignalError> {
        if pid <= 1 {
            return Err(ProcessSignalError::Unavailable);
        }
        // # Safety: libc::kill is called with a validated positive process id
        // and one of the private signal constants used by the state machine.
        let result = unsafe { libc::kill(pid, signal) };
        if result == 0 {
            return Ok(());
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(code) if code == libc::ESRCH => Err(ProcessSignalError::NotFound),
            Some(code) if code == libc::EPERM || code == libc::EACCES => {
                Err(ProcessSignalError::PermissionDenied)
            }
            _ => Err(ProcessSignalError::Unavailable),
        }
    }
}

/// Rust owner 与外部命令之间共享的取消信号。取消是幂等的，已经启动的
/// `launchctl` 子进程由系统执行器负责终止；fake runner 可用同一信号验证边界。
#[derive(Clone, Debug, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessRunError {
    Spawn { message: String },
    Cancelled,
    TimedOut,
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

    /// 启动后允许真实 runner 在 launchd 短暂过渡态中重读状态；fake 默认
    /// 为零次，保持既有脚本化调用序列不变。
    fn startup_status_retry_limit(&self) -> u8 {
        0
    }

    /// 可取消执行的默认实现保持 fake/旧实现兼容；真实系统 runner 会在
    /// 子进程运行期间轮询 token 并终止 launchctl。
    fn run_cancellable(
        &self,
        executable_path: &str,
        arguments: &[String],
        cancellation: &CancellationToken,
    ) -> Result<ProcessResult, ProcessRunError> {
        if cancellation.is_cancelled() {
            return Err(ProcessRunError::Cancelled);
        }
        self.run(executable_path, arguments)
            .map_err(|message| ProcessRunError::Spawn { message })
    }

    /// 在有界时间内执行外部命令。默认实现保持 fake/旧实现兼容；真实
    /// 系统 runner 覆盖此方法，避免 `launchctl print` 把健康监测线程卡死。
    fn run_with_timeout(
        &self,
        executable_path: &str,
        arguments: &[String],
        _timeout: Duration,
    ) -> Result<ProcessResult, ProcessRunError> {
        self.run(executable_path, arguments)
            .map_err(|message| ProcessRunError::Spawn { message })
    }

    /// 在同时受取消和超时约束的边界内执行外部命令。默认实现复用
    /// `run_with_timeout`，真实系统 runner 覆盖此方法以同时轮询两者。
    fn run_cancellable_with_timeout(
        &self,
        executable_path: &str,
        arguments: &[String],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> Result<ProcessResult, ProcessRunError> {
        if cancellation.is_cancelled() {
            return Err(ProcessRunError::Cancelled);
        }
        self.run_with_timeout(executable_path, arguments, timeout)
    }
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

    fn startup_status_retry_limit(&self) -> u8 {
        20
    }

    fn run_cancellable(
        &self,
        executable_path: &str,
        arguments: &[String],
        cancellation: &CancellationToken,
    ) -> Result<ProcessResult, ProcessRunError> {
        self.run_spawned(executable_path, arguments, Some(cancellation), None)
    }

    fn run_with_timeout(
        &self,
        executable_path: &str,
        arguments: &[String],
        timeout: Duration,
    ) -> Result<ProcessResult, ProcessRunError> {
        self.run_spawned(executable_path, arguments, None, Some(timeout))
    }

    fn run_cancellable_with_timeout(
        &self,
        executable_path: &str,
        arguments: &[String],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> Result<ProcessResult, ProcessRunError> {
        self.run_spawned(
            executable_path,
            arguments,
            Some(cancellation),
            Some(timeout),
        )
    }
}

impl SystemProcessRunner {
    fn run_spawned(
        &self,
        executable_path: &str,
        arguments: &[String],
        cancellation: Option<&CancellationToken>,
        timeout: Option<Duration>,
    ) -> Result<ProcessResult, ProcessRunError> {
        if cancellation
            .map(CancellationToken::is_cancelled)
            .unwrap_or(false)
        {
            return Err(ProcessRunError::Cancelled);
        }
        let mut child = Command::new(executable_path)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| ProcessRunError::Spawn {
                message: error.to_string(),
            })?;

        let started = std::time::Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None)
                    if cancellation
                        .map(CancellationToken::is_cancelled)
                        .unwrap_or(false) =>
                {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ProcessRunError::Cancelled);
                }
                Ok(None)
                    if timeout
                        .map(|limit| started.elapsed() >= limit)
                        .unwrap_or(false) =>
                {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ProcessRunError::TimedOut);
                }
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ProcessRunError::Spawn {
                        message: error.to_string(),
                    });
                }
            }
        };

        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        if let Some(mut pipe) = child.stdout.take() {
            pipe.read_to_end(&mut stdout)
                .map_err(|error| ProcessRunError::Spawn {
                    message: error.to_string(),
                })?;
        }
        if let Some(mut pipe) = child.stderr.take() {
            pipe.read_to_end(&mut stderr)
                .map_err(|error| ProcessRunError::Spawn {
                    message: error.to_string(),
                })?;
        }
        Ok(ProcessResult {
            exit_code: status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&stdout).to_string(),
            stderr: String::from_utf8_lossy(&stderr).to_string(),
        })
    }
}

/// launchd 执行器。
pub struct LaunchCtlExecutor<R: ProcessRunning> {
    pub runner: R,
    pub uid: u32,
    identity_reader: Arc<dyn ProcessIdentityReading>,
    signaler: Arc<dyn ProcessSignaling>,
    status_cache: Arc<Mutex<HashMap<String, (TunnelStatus, Option<i32>)>>>,
}

impl Default for LaunchCtlExecutor<SystemProcessRunner> {
    fn default() -> Self {
        LaunchCtlExecutor {
            runner: SystemProcessRunner,
            uid: current_uid(),
            identity_reader: Arc::new(SystemProcessIdentityReader),
            signaler: Arc::new(SystemProcessSignaler),
            status_cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

pub fn current_uid() -> u32 {
    // # Safety: getuid 无失败路径。
    unsafe { libc::getuid() }
}

impl<R: ProcessRunning> LaunchCtlExecutor<R> {
    pub fn new(runner: R, uid: u32) -> Self {
        Self::with_process_control(
            runner,
            uid,
            Arc::new(SystemProcessIdentityReader),
            Arc::new(SystemProcessSignaler),
        )
    }

    pub fn with_process_control(
        runner: R,
        uid: u32,
        identity_reader: Arc<dyn ProcessIdentityReading>,
        signaler: Arc<dyn ProcessSignaling>,
    ) -> Self {
        LaunchCtlExecutor {
            runner,
            uid,
            identity_reader,
            signaler,
            status_cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub const LAUNCHCTL_PATH: &'static str = "/bin/launchctl";

    pub(crate) fn recovery_command(
        &self,
        args: &[String],
        cancel: &CancellationToken,
        timeout: Duration,
    ) -> Result<ProcessResult, ExecutorError> {
        if timeout.is_zero() {
            return Err(status_query_timeout_error());
        }
        let result = self
            .runner
            .run_cancellable_with_timeout(Self::LAUNCHCTL_PATH, args, cancel, timeout)
            .map_err(|error| match error {
                ProcessRunError::Cancelled => ExecutorError::Cancelled,
                ProcessRunError::TimedOut => status_query_timeout_error(),
                ProcessRunError::Spawn { message } => ExecutorError::Spawn { message },
            })?;
        if result.exit_code != 0
            && !(args[0] == "print" && is_not_found_message(&result.stderr, &result.stdout))
        {
            return Err(ExecutorError::CommandFailed {
                operation: args[0].clone(),
                exit_code: result.exit_code,
                stderr: "自动恢复命令失败".into(),
            });
        }
        Ok(result)
    }

    pub(crate) fn recovery_status_checked(
        &self,
        label: &str,
        cancel: &CancellationToken,
        timeout: Duration,
    ) -> Result<TunnelStatus, ExecutorError> {
        let result = self.recovery_command(
            &["print".into(), format!("{}/{}", self.domain(), label)],
            cancel,
            timeout.min(Duration::from_secs(2)),
        )?;
        let details = if result.exit_code != 0 {
            (TunnelStatus::NotLoaded, None)
        } else {
            let details = parse_status_details(&result.stdout);
            if details.0 == TunnelStatus::NotLoaded {
                return Err(ExecutorError::CommandFailed {
                    operation: "status".into(),
                    exit_code: 0,
                    stderr: "无法解析 launchctl 状态".into(),
                });
            }
            details
        };
        self.remember_status(label, details.clone());
        Ok(details.0)
    }

    pub fn domain(&self) -> String {
        format!("gui/{}", self.uid)
    }

    /// 加载并立即启动（生成 plist 固定 RunAtLoad=true）。
    /// `label` 仅用于调用方语义；launchctl bootstrap 以 plist 路径定位。
    pub fn bootstrap(&self, _label: &str, plist_path: &Path) -> Result<(), ExecutorError> {
        let result = self.run_process(
            &["bootstrap".into(), self.domain(), path_display(plist_path)],
            None,
        )?;
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

    pub fn bootstrap_cancellable(
        &self,
        _label: &str,
        plist_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<(), ExecutorError> {
        let result = self.run_process(
            &["bootstrap".into(), self.domain(), path_display(plist_path)],
            Some(cancellation),
        )?;
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
        let result = self.run_process(
            &["bootout".into(), format!("{}/{}", self.domain(), label)],
            None,
        )?;
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

    pub fn bootout_cancellable(
        &self,
        label: &str,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        let result = self.run_process(
            &["bootout".into(), format!("{}/{}", self.domain(), label)],
            Some(cancellation),
        )?;
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

    /// 查询状态；供旧的非 checked 内部调用保持历史 fallback 语义。
    pub fn status(&self, label: &str) -> TunnelStatus {
        match self.status_details_checked(label) {
            Ok((status, _)) => status,
            Err(error) if is_status_query_timeout(&error) => self
                .cached_status(label)
                .map(|(status, _)| status)
                .unwrap_or(TunnelStatus::Other {
                    state: "status query timeout".into(),
                }),
            Err(_) => TunnelStatus::NotLoaded,
        }
    }

    /// 查询状态并保留错误边界。健康恢复必须使用这个 checked 路径，不能
    /// 把 launchctl 超时折叠为普通状态。
    pub(crate) fn status_checked(&self, label: &str) -> Result<TunnelStatus, ExecutorError> {
        self.status_details_checked(label).map(|(status, _)| status)
    }

    /// 启动后的稳定状态读取。真实 launchd 允许短暂的 notLoaded/other
    /// 过渡态；只有稳定读到 running 才把 PID 写入状态缓存，供冻结故障
    /// 的后续身份核验使用。fake runner 默认不重试。
    pub fn status_after_bootstrap(&self, label: &str) -> TunnelStatus {
        let mut status = self.status(label);
        for _ in 0..self.runner.startup_status_retry_limit() {
            if matches!(status, TunnelStatus::Running { .. }) {
                break;
            }
            thread::sleep(Duration::from_millis(50));
            status = self.status(label);
        }
        status
    }

    fn status_details_checked(
        &self,
        label: &str,
    ) -> Result<(TunnelStatus, Option<i32>), ExecutorError> {
        match self.runner.run_with_timeout(
            Self::LAUNCHCTL_PATH,
            &["print".into(), format!("{}/{}", self.domain(), label)],
            Duration::from_secs(2),
        ) {
            Ok(result) if result.exit_code == 0 => {
                let details = parse_status_details(&result.stdout);
                if details.0 == TunnelStatus::NotLoaded {
                    return Err(ExecutorError::CommandFailed {
                        operation: "status".into(),
                        exit_code: 0,
                        stderr: "无法解析 launchctl 状态".into(),
                    });
                }
                self.remember_status(label, details.clone());
                Ok(details)
            }
            Ok(result) if is_not_found_message(&result.stderr, &result.stdout) => {
                let details = (TunnelStatus::NotLoaded, None);
                self.remember_status(label, details.clone());
                Ok(details)
            }
            Ok(result) => Err(ExecutorError::CommandFailed {
                operation: "status".into(),
                exit_code: result.exit_code,
                stderr: result.stderr,
            }),
            Err(ProcessRunError::Spawn { message }) => Err(ExecutorError::Spawn { message }),
            Err(ProcessRunError::Cancelled) => Err(ExecutorError::Cancelled),
            Err(ProcessRunError::TimedOut) => Err(status_query_timeout_error()),
        }
    }

    fn remember_status(&self, label: &str, details: (TunnelStatus, Option<i32>)) {
        self.status_cache
            .lock()
            .expect("launchctl status cache mutex 不应中毒")
            .insert(label.to_string(), details);
    }

    fn cached_status(&self, label: &str) -> Option<(TunnelStatus, Option<i32>)> {
        self.status_cache
            .lock()
            .expect("launchctl status cache mutex 不应中毒")
            .get(label)
            .cloned()
    }

    /// 对已核验的受管 SSH 执行 bootout 后的有界收敛。
    pub fn stop_managed_cancellable(
        &self,
        label: &str,
        executable_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        if cancellation.is_cancelled() {
            return Err(ExecutorError::Cancelled);
        }
        let (initial_status, pid) = match self.status_details_checked(label) {
            Ok(details) => details,
            Err(error) if is_status_query_timeout(&error) => {
                self.cached_status(label).ok_or(error)?
            }
            Err(error) => return Err(error),
        };
        if initial_status == TunnelStatus::NotLoaded {
            return Ok(false);
        }
        let expected = match pid {
            Some(pid) => Some(self.capture_identity(pid, executable_path)?),
            None => None,
        };
        // launchctl bootout 可能等待一个已被 SIGSTOP 的 job 退出；这里必须
        // 有界，否则永远到不了下方按身份核验保护的 CONT/TERM/KILL 阶段。
        let stopped = self.bootout_managed_cancellable(label, cancellation)?;

        if self.wait_for_convergence(
            label,
            expected.as_ref(),
            MANAGED_STOP_INITIAL_WAIT_MS,
            cancellation,
        )? {
            return Ok(stopped);
        }

        let Some(expected) = expected.as_ref() else {
            return Err(ExecutorError::ManagedProcessIdentityUnknown {
                stage: "bootout 后未取得受管 PID".into(),
            });
        };

        for (signal, wait_ms) in [
            (SIGCONT_SIGNAL, MANAGED_STOP_CONT_WAIT_MS),
            (SIGTERM_SIGNAL, MANAGED_STOP_TERM_WAIT_MS),
            (SIGKILL_SIGNAL, MANAGED_STOP_KILL_WAIT_MS),
        ] {
            self.verify_identity(label, expected, executable_path, cancellation)?;
            match self.signaler.send(expected.pid, signal) {
                Ok(()) | Err(ProcessSignalError::NotFound) => {}
                Err(ProcessSignalError::PermissionDenied | ProcessSignalError::Unavailable) => {
                    return Err(ExecutorError::ManagedProcessSignalFailed {
                        signal: signal_name(signal).into(),
                    });
                }
            }
            if self.wait_for_convergence(label, Some(expected), wait_ms, cancellation)? {
                return Ok(stopped);
            }
        }

        Err(ExecutorError::ManagedProcessStillLoaded)
    }

    fn bootout_managed_cancellable(
        &self,
        label: &str,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        let arguments = &["bootout".into(), format!("{}/{}", self.domain(), label)];
        let result = match self.runner.run_cancellable_with_timeout(
            Self::LAUNCHCTL_PATH,
            arguments,
            cancellation,
            Duration::from_secs(2),
        ) {
            Ok(result) => result,
            Err(ProcessRunError::TimedOut) => return Ok(false),
            Err(ProcessRunError::Spawn { message }) => {
                return Err(ExecutorError::Spawn { message })
            }
            Err(ProcessRunError::Cancelled) => return Err(ExecutorError::Cancelled),
        };
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

    fn capture_identity(
        &self,
        pid: i32,
        executable_path: &Path,
    ) -> Result<ProcessIdentity, ExecutorError> {
        let identity = self.identity_reader.read(pid).map_err(|_| {
            ExecutorError::ManagedProcessIdentityUnknown {
                stage: "捕获受管身份".into(),
            }
        })?;
        if identity.pid != pid
            || identity.uid != self.uid
            || identity.executable_path != executable_path
        {
            return Err(ExecutorError::ManagedProcessIdentityUnknown {
                stage: "捕获受管身份不匹配".into(),
            });
        }
        Ok(identity)
    }

    fn verify_identity(
        &self,
        label: &str,
        expected: &ProcessIdentity,
        executable_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<(), ExecutorError> {
        if cancellation.is_cancelled() {
            return Err(ExecutorError::Cancelled);
        }
        match self.status_details_checked(label) {
            Ok((status, pid)) => {
                if matches!(status, TunnelStatus::NotLoaded) || pid != Some(expected.pid) {
                    return Err(ExecutorError::ManagedProcessIdentityUnknown {
                        stage: "信号前 launchd 身份变化".into(),
                    });
                }
            }
            Err(error) if is_status_query_timeout(&error) => {
                // 状态未知时仍必须通过下方完整的进程身份票据核验；不以
                // timeout 本身推断 PID 所属关系，也不向其他 PID 发信号。
            }
            Err(error) => return Err(error),
        }
        let current = self.identity_reader.read(expected.pid).map_err(|_| {
            ExecutorError::ManagedProcessIdentityUnknown {
                stage: "信号前读取受管身份".into(),
            }
        })?;
        if current != *expected
            || current.uid != self.uid
            || current.executable_path != executable_path
        {
            return Err(ExecutorError::ManagedProcessIdentityUnknown {
                stage: "信号前受管身份变化".into(),
            });
        }
        Ok(())
    }

    fn wait_for_convergence(
        &self,
        label: &str,
        expected: Option<&ProcessIdentity>,
        timeout_ms: u64,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        let deadline = std::time::Instant::now() + Duration::from_millis(timeout_ms);
        loop {
            if cancellation.is_cancelled() {
                return Err(ExecutorError::Cancelled);
            }
            match self.status_details_checked(label) {
                Ok((status, pid)) => {
                    if status == TunnelStatus::NotLoaded {
                        let Some(expected) = expected else {
                            return Ok(true);
                        };
                        match self.identity_reader.read(expected.pid) {
                            Err(ProcessIdentityError::NotFound) => return Ok(true),
                            Ok(current) if current != *expected => return Ok(true),
                            Ok(_) => {}
                            Err(
                                ProcessIdentityError::PermissionDenied
                                | ProcessIdentityError::Unavailable,
                            ) => {
                                return Err(ExecutorError::ManagedProcessIdentityUnknown {
                                    stage: "确认原 PID 消失".into(),
                                });
                            }
                        }
                    } else if let Some(expected) = expected {
                        if pid != Some(expected.pid) {
                            return Err(ExecutorError::ManagedProcessIdentityUnknown {
                                stage: "等待收敛时 launchd PID 变化".into(),
                            });
                        }
                    }
                }
                Err(error) if is_status_query_timeout(&error) => {
                    let Some(expected) = expected else {
                        return Err(error);
                    };
                    match self.identity_reader.read(expected.pid) {
                        Err(ProcessIdentityError::NotFound) => return Ok(true),
                        Ok(current) if current != *expected => return Ok(true),
                        Ok(_) => {}
                        Err(
                            ProcessIdentityError::PermissionDenied
                            | ProcessIdentityError::Unavailable,
                        ) => {
                            return Err(ExecutorError::ManagedProcessIdentityUnknown {
                                stage: "超时后确认原 PID 消失".into(),
                            });
                        }
                    }
                }
                Err(error) => return Err(error),
            }
            if std::time::Instant::now() >= deadline {
                return Ok(false);
            }
            thread::sleep(Duration::from_millis(MANAGED_STOP_POLL_MS));
        }
    }

    fn run_process(
        &self,
        arguments: &[String],
        cancellation: Option<&CancellationToken>,
    ) -> Result<ProcessResult, ExecutorError> {
        match cancellation {
            Some(cancellation) => {
                self.runner
                    .run_cancellable(Self::LAUNCHCTL_PATH, arguments, cancellation)
            }
            None => self
                .runner
                .run(Self::LAUNCHCTL_PATH, arguments)
                .map_err(|message| ProcessRunError::Spawn { message }),
        }
        .map_err(|error| match error {
            ProcessRunError::Spawn { message } => ExecutorError::Spawn { message },
            ProcessRunError::Cancelled => ExecutorError::Cancelled,
            ProcessRunError::TimedOut => ExecutorError::CommandFailed {
                operation: "command".into(),
                exit_code: -1,
                stderr: "外部命令执行超时".into(),
            },
        })
    }
}

fn path_display(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

/// 解析 `launchctl print` 输出。只看顶层字段（单制表符缩进），忽略嵌套块。
pub fn parse_status(stdout: &str) -> TunnelStatus {
    parse_status_details(stdout).0
}

fn parse_status_details(stdout: &str) -> (TunnelStatus, Option<i32>) {
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

    let status = match state.as_deref() {
        Some("running") => TunnelStatus::Running { pid },
        Some("not running") => TunnelStatus::NotRunning,
        Some(other) => TunnelStatus::Other {
            state: other.to_string(),
        },
        None => TunnelStatus::NotLoaded,
    };
    (status, pid)
}

fn signal_name(signal: i32) -> &'static str {
    match signal {
        SIGCONT_SIGNAL => "SIGCONT",
        SIGTERM_SIGNAL => "SIGTERM",
        SIGKILL_SIGNAL => "SIGKILL",
        _ => "unknown",
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

fn status_query_timeout_error() -> ExecutorError {
    ExecutorError::CommandFailed {
        operation: "status".into(),
        exit_code: -1,
        stderr: "launchctl 状态查询超时".into(),
    }
}

fn is_status_query_timeout(error: &ExecutorError) -> bool {
    matches!(
        error,
        ExecutorError::CommandFailed {
            operation,
            exit_code: -1,
            stderr,
        } if operation == "status" && stderr == "launchctl 状态查询超时"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::thread;
    use std::time::{Duration, Instant};

    struct FakeRunner {
        outputs: Mutex<VecDeque<Result<ProcessResult, String>>>,
    }

    impl FakeRunner {
        fn new(outputs: Vec<Result<ProcessResult, String>>) -> Self {
            FakeRunner {
                outputs: Mutex::new(outputs.into()),
            }
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

    #[derive(Clone)]
    struct IdentityReader {
        script: Arc<Mutex<VecDeque<Result<ProcessIdentity, ProcessIdentityError>>>>,
    }

    impl IdentityReader {
        fn new(script: Vec<Result<ProcessIdentity, ProcessIdentityError>>) -> Self {
            Self {
                script: Arc::new(Mutex::new(script.into())),
            }
        }
    }

    impl ProcessIdentityReading for IdentityReader {
        fn read(&self, _pid: i32) -> Result<ProcessIdentity, ProcessIdentityError> {
            self.script
                .lock()
                .unwrap()
                .pop_front()
                .expect("身份 fixture 调用超出脚本")
        }
    }

    #[derive(Clone, Default)]
    struct Signaler {
        signals: Arc<Mutex<Vec<(i32, i32)>>>,
    }

    impl ProcessSignaling for Signaler {
        fn send(&self, pid: i32, signal: i32) -> Result<(), ProcessSignalError> {
            self.signals.lock().unwrap().push((pid, signal));
            Ok(())
        }
    }

    fn process_output(exit_code: i32, stdout: &str, stderr: &str) -> Result<ProcessResult, String> {
        Ok(ProcessResult {
            exit_code,
            stdout: stdout.into(),
            stderr: stderr.into(),
        })
    }

    fn running_output(pid: i32) -> Result<ProcessResult, String> {
        process_output(0, &format!("\tstate = running\n\tpid = {pid}\n"), "")
    }

    fn other_output(pid: i32) -> Result<ProcessResult, String> {
        process_output(0, &format!("\tstate = SIGTERMed\n\tpid = {pid}\n"), "")
    }

    fn not_loaded_output() -> Result<ProcessResult, String> {
        process_output(3, "", "Could not find service")
    }

    fn identity(pid: i32) -> ProcessIdentity {
        ProcessIdentity {
            pid,
            uid: 501,
            start_time_micros: 123,
            executable_path: PathBuf::from("/usr/bin/ssh"),
        }
    }

    #[test]
    fn parse_status_matches_swift() {
        // 无顶层 state（0 缩进的行被忽略）→ notLoaded
        assert_eq!(
            parse_status("state = running\npid = 5"),
            TunnelStatus::NotLoaded
        );
        // 嵌套块（2 缩进）里的 state = active 被忽略
        assert_eq!(
            parse_status("\tstate = running\n\tpid = 1234\n\t\tstate = active"),
            TunnelStatus::Running { pid: Some(1234) }
        );
        assert_eq!(
            parse_status("\tstate = running\n\tpid = 1234"),
            TunnelStatus::Running { pid: Some(1234) }
        );
        assert_eq!(
            parse_status("\tstate = not running"),
            TunnelStatus::NotRunning
        );
        assert_eq!(
            parse_status("\tstate = weird-state"),
            TunnelStatus::Other {
                state: "weird-state".into()
            }
        );
        assert_eq!(parse_status(""), TunnelStatus::NotLoaded);
        assert_eq!(
            parse_status("\tstate = running"),
            TunnelStatus::Running { pid: None }
        );
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
            Err(ExecutorError::CommandFailed {
                operation,
                exit_code,
                stderr,
            }) => {
                assert_eq!(operation, "bootout");
                assert_eq!(exit_code, 1);
                assert_eq!(stderr, "Bootstrap failed: 5");
            }
            other => panic!("期望 CommandFailed，实际 {other:?}"),
        }
    }

    #[test]
    fn system_runner_terminates_cancelled_child() {
        let runner = SystemProcessRunner;
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let started = Instant::now();
        let worker = thread::spawn(move || {
            runner.run_cancellable("/bin/sleep", &["30".into()], &worker_cancellation)
        });

        thread::sleep(Duration::from_millis(25));
        cancellation.cancel();
        assert_eq!(worker.join().unwrap(), Err(ProcessRunError::Cancelled));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "取消后的子进程退出过慢：{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn system_runner_times_out_hung_child() {
        let runner = SystemProcessRunner;
        let started = Instant::now();
        let result =
            runner.run_with_timeout("/bin/sleep", &["30".into()], Duration::from_millis(25));
        assert_eq!(result, Err(ProcessRunError::TimedOut));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "超时后的子进程退出过慢：{:?}",
            started.elapsed()
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn system_identity_reader_reads_current_process() {
        let reader = SystemProcessIdentityReader;
        let identity = reader
            .read(std::process::id() as i32)
            .expect("当前测试进程的身份票据应可读取");
        assert_eq!(identity.pid, std::process::id() as i32);
        assert_eq!(identity.uid, current_uid());
        assert!(!identity.executable_path.as_os_str().is_empty());
        assert!(identity.start_time_micros > 0);
    }

    struct TimedOutRunner;

    impl ProcessRunning for TimedOutRunner {
        fn run(&self, _exe: &str, _args: &[String]) -> Result<ProcessResult, String> {
            Err("不应调用无界 runner".into())
        }

        fn run_with_timeout(
            &self,
            _exe: &str,
            _args: &[String],
            _timeout: Duration,
        ) -> Result<ProcessResult, ProcessRunError> {
            Err(ProcessRunError::TimedOut)
        }
    }

    #[test]
    fn status_timeout_keeps_last_known_running_state() {
        let executor = LaunchCtlExecutor::new(TimedOutRunner, 501);
        executor.remember_status("managed", (TunnelStatus::Running { pid: Some(7) }, Some(7)));
        assert_eq!(
            executor.status("managed"),
            TunnelStatus::Running { pid: Some(7) }
        );

        let uncached = LaunchCtlExecutor::new(TimedOutRunner, 501);
        assert_eq!(
            uncached.status("managed"),
            TunnelStatus::Other {
                state: "status query timeout".into()
            }
        );
    }

    struct ManagedStopBootoutTimeoutRunner {
        outputs: Mutex<VecDeque<Result<ProcessResult, ProcessRunError>>>,
    }

    impl ProcessRunning for ManagedStopBootoutTimeoutRunner {
        fn run(&self, _exe: &str, _args: &[String]) -> Result<ProcessResult, String> {
            Err("不应调用无界 runner".into())
        }

        fn run_with_timeout(
            &self,
            _exe: &str,
            _args: &[String],
            _timeout: Duration,
        ) -> Result<ProcessResult, ProcessRunError> {
            self.outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("有界 runner 输出已耗尽")
        }
    }

    #[test]
    fn managed_stop_continues_after_bounded_bootout_timeout() {
        let reader =
            IdentityReader::new(vec![Ok(identity(7)), Err(ProcessIdentityError::NotFound)]);
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            ManagedStopBootoutTimeoutRunner {
                outputs: Mutex::new(
                    vec![
                        running_output(7).map_err(|message| ProcessRunError::Spawn { message }),
                        Err(ProcessRunError::TimedOut),
                        not_loaded_output().map_err(|message| ProcessRunError::Spawn { message }),
                    ]
                    .into(),
                ),
            },
            501,
            Arc::new(reader),
            Arc::new(signaler.clone()),
        );

        assert_eq!(
            executor.stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            ),
            Ok(false)
        );
        assert!(signaler.signals.lock().unwrap().is_empty());
    }

    #[test]
    fn managed_stop_does_not_signal_when_bootout_converges() {
        let reader =
            IdentityReader::new(vec![Ok(identity(7)), Err(ProcessIdentityError::NotFound)]);
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            FakeRunner::new(vec![
                running_output(7),
                process_output(0, "", ""),
                not_loaded_output(),
            ]),
            501,
            Arc::new(reader),
            Arc::new(signaler.clone()),
        );

        let stopped = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap();
        assert!(stopped);
        assert!(signaler.signals.lock().unwrap().is_empty());
    }

    #[test]
    fn managed_stop_returns_without_bootout_when_unloaded() {
        let signaler = Signaler::default();
        let runner = FakeRunner::new(vec![not_loaded_output()]);
        let executor = LaunchCtlExecutor::with_process_control(
            runner,
            501,
            Arc::new(IdentityReader::new(vec![])),
            Arc::new(signaler.clone()),
        );

        let stopped = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap();
        assert!(!stopped);
        assert!(signaler.signals.lock().unwrap().is_empty());
    }

    #[test]
    fn managed_stop_refuses_unexpected_status_failure() {
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            FakeRunner::new(vec![process_output(1, "", "Operation not permitted")]),
            501,
            Arc::new(IdentityReader::new(vec![])),
            Arc::new(signaler.clone()),
        );

        let error = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap_err();
        assert!(matches!(
            error,
            ExecutorError::CommandFailed { operation, .. } if operation == "status"
        ));
        assert!(signaler.signals.lock().unwrap().is_empty());
    }

    #[test]
    fn managed_stop_refuses_unparseable_success_status() {
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            FakeRunner::new(vec![process_output(0, "\tpid = 7\n", "")]),
            501,
            Arc::new(IdentityReader::new(vec![])),
            Arc::new(signaler.clone()),
        );

        let error = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap_err();
        assert!(matches!(
            error,
            ExecutorError::CommandFailed { operation, exit_code: 0, .. }
                if operation == "status"
        ));
        assert!(signaler.signals.lock().unwrap().is_empty());
    }

    #[test]
    fn managed_stop_escalates_only_after_identity_rechecks() {
        let outputs = vec![
            running_output(7),
            process_output(0, "", ""),
            other_output(7),
            other_output(7),
            other_output(7),
            other_output(7),
            other_output(7),
            other_output(7),
            not_loaded_output(),
        ];
        let reader = IdentityReader::new(vec![
            Ok(identity(7)),
            Ok(identity(7)),
            Ok(identity(7)),
            Ok(identity(7)),
            Err(ProcessIdentityError::NotFound),
        ]);
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            FakeRunner::new(outputs),
            501,
            Arc::new(reader),
            Arc::new(signaler.clone()),
        );

        let stopped = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap();
        assert!(stopped);
        assert_eq!(
            signaler.signals.lock().unwrap().as_slice(),
            &[
                (7, SIGCONT_SIGNAL),
                (7, SIGTERM_SIGNAL),
                (7, SIGKILL_SIGNAL),
            ]
        );
    }

    #[test]
    fn managed_stop_refuses_signal_when_launchd_pid_changes() {
        let reader = IdentityReader::new(vec![Ok(identity(7))]);
        let signaler = Signaler::default();
        let executor = LaunchCtlExecutor::with_process_control(
            FakeRunner::new(vec![
                running_output(7),
                process_output(0, "", ""),
                other_output(8),
            ]),
            501,
            Arc::new(reader),
            Arc::new(signaler.clone()),
        );

        let error = executor
            .stop_managed_cancellable(
                "managed",
                Path::new("/usr/bin/ssh"),
                &CancellationToken::new(),
            )
            .unwrap_err();
        assert!(matches!(
            error,
            ExecutorError::ManagedProcessIdentityUnknown { .. }
        ));
        assert!(signaler.signals.lock().unwrap().is_empty());
    }
}
