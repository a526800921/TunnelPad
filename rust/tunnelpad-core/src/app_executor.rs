//! app 执行器（Swift `AppProcessExecutor` 对等）：直接托管子进程。
//! - start：spawn `command`（不经 shell），stdout/stderr 写入日志文件，写 pidfile
//! - stop：SIGTERM → 最多 5s → SIGKILL；删除 pidfile
//! - keepAlive：意外退出延迟重启（由 [`AppProcessExecutor::handle_exits`] 驱动，
//!   Swift 侧为 terminationHandler 事件驱动——并发所有权在 Swift，见计划契约冻结）
//! - shutdown_all：退出 app 时终止全部子进程
//!
//! 子进程存活探测用 `waitpid(WNOHANG)`（`status()` 只有共享引用，无法
//! `Child::try_wait`）；stop/shutdown_all 持有上下文所有权后回收。

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::launchctl::{ExecutorError, TunnelStatus};
use crate::paths::TunnelPaths;
use crate::TunnelConfig;

const STOP_TIMEOUT_SECS: u64 = 5;
const POLL_INTERVAL_MS: u64 = 50;

struct AppContext {
    child: Child,
    tunnel: TunnelConfig,
    #[allow(dead_code)] // 保留与 Swift Context 同形；生命周期由 generations 表管理
    generation: u64,
    manual_stop: bool,
    log: File,
}

#[derive(Default)]
struct Inner {
    contexts: HashMap<String, AppContext>,
    generations: HashMap<String, u64>,
}

/// 时间戳函数（注入便于测试；格式 yyyy-MM-dd HH:mm:ss）。
pub type LogTimestampFn = Arc<dyn Fn() -> String + Send + Sync>;

/// keepAlive 意外退出后的重启计划。
///
/// `generation` 必须随计划返回；owner 在延迟窗口结束后调用
/// `restart_if_current`，避免 stop/remove/shutdown-all 之后执行迟到计划。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestartPlan {
    pub tunnel: TunnelConfig,
    pub delay_secs: u64,
    pub generation: u64,
}

pub struct AppProcessExecutor {
    paths: TunnelPaths,
    restart_delay_override: Option<u64>,
    inner: Mutex<Inner>,
    log_timestamp: LogTimestampFn,
}

impl AppProcessExecutor {
    pub fn new(paths: TunnelPaths) -> Self {
        AppProcessExecutor {
            paths,
            restart_delay_override: None,
            inner: Mutex::new(Inner::default()),
            log_timestamp: Arc::new(crate::config_store::local_log_timestamp),
        }
    }

    pub fn with_options(paths: TunnelPaths, restart_delay_override: Option<u64>, log_timestamp: LogTimestampFn) -> Self {
        AppProcessExecutor {
            paths,
            restart_delay_override,
            inner: Mutex::new(Inner::default()),
            log_timestamp,
        }
    }

    pub fn start(&self, tunnel: &TunnelConfig) -> Result<(), ExecutorError> {
        {
            let inner = self.inner.lock().unwrap();
            if let Some(existing) = inner.contexts.get(&tunnel.id) {
                if probe_exit(existing.child.id() as i32).is_running() {
                    return Ok(());
                }
            }
        }

        let mut log = self.open_log(tunnel).map_err(spawn_error)?;
        let generation = {
            let mut inner = self.inner.lock().unwrap();
            let generation = inner.generations.get(&tunnel.id).copied().unwrap_or(0) + 1;
            inner.generations.insert(tunnel.id.clone(), generation);
            generation
        };

        let child = match self.spawn(tunnel, &mut log) {
            Ok(child) => child,
            Err(error) => {
                // spawn 失败时没有回调可以收尾，必须主动关闭日志句柄。
                drop(log);
                return Err(error);
            }
        };

        let pid = child.id() as i32;
        let line = format!("[{}] spawned pid={} (executor=app)\n", (self.log_timestamp)(), pid);
        let _ = log.write_all(line.as_bytes());
        let _ = log.flush();

        self.inner.lock().unwrap().contexts.insert(
            tunnel.id.clone(),
            AppContext { child, tunnel: tunnel.clone(), generation, manual_stop: false, log },
        );

        if let Err(error) = self.write_pidfile(pid, tunnel) {
            // pidfile 写入失败时不能留下无记录的子进程。
            self.stop(tunnel);
            return Err(spawn_error(error));
        }
        Ok(())
    }

    pub fn stop(&self, tunnel: &TunnelConfig) {
        let ctx = {
            let mut inner = self.inner.lock().unwrap();
            let next_generation = inner.generations.get(&tunnel.id).copied().unwrap_or(0) + 1;
            inner.generations.insert(tunnel.id.clone(), next_generation);
            inner.contexts.remove(&tunnel.id).map(|mut ctx| {
                ctx.manual_stop = true;
                ctx
            })
        };
        let Some(mut ctx) = ctx else {
            self.remove_pidfile(tunnel);
            return;
        };
        terminate_and_reap(&mut ctx.child);
        self.remove_pidfile(tunnel);
        // ctx（含日志句柄）在此 drop = closeLogHandle
    }

    pub fn restart(&self, tunnel: &TunnelConfig) -> Result<(), ExecutorError> {
        self.stop(tunnel);
        self.start(tunnel)
    }

    pub fn status(&self, id: &str) -> TunnelStatus {
        let inner = self.inner.lock().unwrap();
        match inner.contexts.get(id) {
            Some(ctx) if probe_exit(ctx.child.id() as i32).is_running() => {
                TunnelStatus::Running { pid: Some(ctx.child.id() as i32) }
            }
            _ => TunnelStatus::NotLoaded,
        }
    }

    /// 退出 app 路径：终止全部子进程（SIGTERM → 最多 5s → SIGKILL）。
    pub fn shutdown_all(&self) {
        let all = {
            let mut inner = self.inner.lock().unwrap();
            let all: Vec<AppContext> = inner.contexts.drain().map(|(_, ctx)| ctx).collect();
            let managed_ids: Vec<String> = inner.generations.keys().cloned().collect();
            for id in managed_ids {
                let generation = inner.generations.get(&id).copied().unwrap_or(0) + 1;
                inner.generations.insert(id, generation);
            }
            all
        };
        for mut ctx in all {
            terminate_and_reap(&mut ctx.child);
            self.remove_pidfile(&ctx.tunnel);
        }
    }

    pub fn managed_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.inner.lock().unwrap().contexts.keys().cloned().collect();
        ids.sort();
        ids
    }

    /// 轮询意外退出：摘除已退出的上下文；keepAlive 时返回带 generation
    /// 的待重启计划，由调用方在并发所有者侧执行。
    /// 与 Swift terminationHandler 的语义差异已记录在计划契约冻结章节。
    pub fn handle_exits(&self) -> Vec<RestartPlan> {
        let mut exited: Vec<AppContext> = vec![];
        {
            let mut inner = self.inner.lock().unwrap();
            let ids: Vec<String> = inner.contexts.keys().cloned().collect();
            for id in ids {
                let Some(ctx) = inner.contexts.get(&id) else { continue };
                let probe = probe_exit(ctx.child.id() as i32);
                if probe.is_running() {
                    continue;
                }
                let Some(mut ctx) = inner.contexts.remove(&id) else { continue };
                if !ctx.manual_stop {
                    let code = probe.exit_code();
                    let line = format!("[{}] process exited unexpectedly code={}\n", (self.log_timestamp)(), code);
                    let _ = ctx.log.write_all(line.as_bytes());
                    self.remove_pidfile(&ctx.tunnel);
                }
                exited.push(ctx);
            }
        }

        let mut restarts = vec![];
        for ctx in exited {
            if ctx.manual_stop || !ctx.tunnel.keep_alive {
                continue;
            }
            let delay = self.restart_delay_override.unwrap_or(ctx.tunnel.throttle_interval.max(0) as u64);
            restarts.push(RestartPlan { tunnel: ctx.tunnel, delay_secs: delay, generation: ctx.generation });
        }
        restarts
    }

    /// 供并发 owner 在延迟窗口结束后执行重启；generation 失配时静默丢弃计划。
    /// owner 仍应保证同一隧道的生命周期操作串行化，与 Swift 契约一致。
    pub fn restart_if_current(&self, plan: &RestartPlan) -> Result<bool, ExecutorError> {
        if !self.is_current_generation(&plan.tunnel.id, plan.generation) {
            return Ok(false);
        }
        self.start(&plan.tunnel)?;
        Ok(true)
    }

    /// 判断某个生命周期计划是否仍属于当前代。
    pub fn is_current_generation(&self, id: &str, generation: u64) -> bool {
        self.inner.lock().unwrap().generations.get(id).copied() == Some(generation)
    }

    fn open_log(&self, tunnel: &TunnelConfig) -> std::io::Result<File> {
        fs::create_dir_all(self.paths.logs_directory())?;
        let url = self.paths.log_url(tunnel);
        if !url.exists() {
            fs::write(&url, b"")?;
        }
        OpenOptions::new().append(true).open(&url)
    }

    fn spawn(&self, tunnel: &TunnelConfig, log: &mut File) -> Result<Child, ExecutorError> {
        if tunnel.command.is_empty() {
            return Err(ExecutorError::CommandFailed {
                operation: "spawn".into(),
                exit_code: -1,
                stderr: "command 为空".into(),
            });
        }
        let stdout = log.try_clone().map_err(spawn_error)?;
        let stderr = log.try_clone().map_err(spawn_error)?;
        Command::new(&tunnel.command[0])
            .args(&tunnel.command[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
            .map_err(|e| ExecutorError::CommandFailed {
                operation: "spawn".into(),
                exit_code: -1,
                stderr: e.to_string(),
            })
    }

    fn write_pidfile(&self, pid: i32, tunnel: &TunnelConfig) -> std::io::Result<()> {
        fs::create_dir_all(self.paths.run_directory())?;
        write_atomic(&self.paths.pidfile_url(tunnel), format!("{pid}\n").as_bytes())
    }

    fn remove_pidfile(&self, tunnel: &TunnelConfig) {
        let _ = fs::remove_file(self.paths.pidfile_url(tunnel));
    }
}

/// waitpid(WNOHANG) 探测结果。
enum ExitProbe {
    Running,
    Exited { code: i32 },
    /// 已被回收或探测失败：按已退出处理（与 Swift isRunning=false 等价）。
    Unknown,
}

impl ExitProbe {
    fn is_running(&self) -> bool {
        matches!(self, ExitProbe::Running)
    }

    fn exit_code(&self) -> i32 {
        match self {
            ExitProbe::Exited { code } => *code,
            _ => -1,
        }
    }
}

fn probe_exit(pid: i32) -> ExitProbe {
    // # Safety: waitpid 仅探测子进程状态。
    unsafe {
        let mut status: libc::c_int = 0;
        let result = libc::waitpid(pid, &mut status, libc::WNOHANG);
        if result == pid {
            if libc::WIFEXITED(status) {
                ExitProbe::Exited { code: libc::WEXITSTATUS(status) }
            } else if libc::WIFSIGNALED(status) {
                ExitProbe::Exited { code: libc::WTERMSIG(status) }
            } else {
                ExitProbe::Exited { code: -1 }
            }
        } else if result == 0 {
            ExitProbe::Running
        } else {
            ExitProbe::Unknown
        }
    }
}

fn terminate_and_reap(child: &mut Child) {
    // # Safety: kill 作用于本执行器自己 spawn 的子进程。
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_secs(STOP_TIMEOUT_SECS);
    while child.try_wait().map(|s| s.is_none()).unwrap_or(false) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(POLL_INTERVAL_MS));
    }
    if child.try_wait().map(|s| s.is_none()).unwrap_or(false) {
        // # Safety: 同上。
        unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
        let _ = child.wait();
    }
}

fn spawn_error(error: std::io::Error) -> ExecutorError {
    ExecutorError::Spawn { message: error.to_string() }
}

fn write_atomic(path: &PathBuf, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp-atomic");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)?;
    Ok(())
}
