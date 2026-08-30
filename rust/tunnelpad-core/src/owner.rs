//! 阶段 5 Rust Core owner。
//!
//! 该模块先隔离验证最终 owner 的边界：一个长期存在的 Rust handle 持有
//! 配置、launchd 执行器和每条隧道的串行锁；跨边界只传 UTF-8 JSON。它不
//! Swift 通过 C ABI 使用该 owner；当前生产范围只启用 launchd。

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::config_store::ConfigStore;
use crate::launchctl::{ExecutorError, TunnelStatus};
use crate::launchd_executing::LaunchdExecuting;
use crate::paths::TunnelPaths;
use crate::plist_render::write_plist;
use crate::{error_code, AppConfig, ExecutorKind, TpError, TunnelConfig};

/// 阶段 5 owner 的 JSON 命令。字段采用 camelCase，命令本身不携带 Swift
/// 对象或指针；handle 只在 C ABI 层存在。
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum CoreCommand {
    LoadConfig,
    SaveConfig { config: AppConfig },
    Begin { id: String },
    Cancel { id: String, generation: u64 },
    Snapshot,
    Status { id: String },
    Start {
        id: String,
        #[serde(default)]
        generation: Option<u64>,
    },
    Stop {
        id: String,
        #[serde(default)]
        generation: Option<u64>,
    },
    Restart {
        id: String,
        #[serde(default)]
        generation: Option<u64>,
    },
    Remove {
        id: String,
        #[serde(default)]
        generation: Option<u64>,
    },
    Shutdown,
}

/// C ABI 之外的 owner 结果。错误会被包装为 `{"ok":false,...}`，使操作级
/// 失败也保持 JSON 通道；只有无效句柄/非法输入等传输错误才返回 NULL。
#[derive(Debug, Clone, Serialize)]
pub struct CoreResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<TpError>,
}

impl CoreResponse {
    fn success(result: Value) -> Self {
        Self {
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    fn failure(error: TpError) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(error),
        }
    }
}

/// Rust Core 的长期 owner。`launchd` 依赖可注入，生产 C ABI 使用系统执行器，
/// fixture 使用 fake 执行器。
pub struct CoreOwner<L: LaunchdExecuting> {
    paths: TunnelPaths,
    pub(crate) launchd: L,
    config: Mutex<AppConfig>,
    tunnel_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    generations: Mutex<HashMap<String, u64>>,
    closed: AtomicBool,
}

impl<L: LaunchdExecuting> CoreOwner<L> {
    /// 读取并校验 Rust owner 的初始配置。现阶段遇到 `app` 配置直接拒绝，
    /// 不自动转换为 `launchd`。
    pub fn new(paths: TunnelPaths, launchd: L) -> Result<Self, TpError> {
        let config = ConfigStore::new(paths.clone()).load().config;
        validate_launchd_config(&config)?;
        Ok(Self {
            paths,
            launchd,
            config: Mutex::new(config),
            tunnel_locks: Mutex::new(HashMap::new()),
            generations: Mutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
        })
    }

    pub fn paths(&self) -> &TunnelPaths {
        &self.paths
    }

    /// 直接提供给 Rust fixture 的命令入口；C ABI 再负责 JSON 字符串分配。
    pub fn execute(&self, command: CoreCommand) -> CoreResponse {
        let outcome = match command {
            CoreCommand::LoadConfig => self.load_config().map(|config| json!({ "config": config })),
            CoreCommand::SaveConfig { config } => {
                self.save_config(config).map(|()| json!({ "saved": true }))
            }
            CoreCommand::Begin { id } => self.begin(&id),
            CoreCommand::Cancel { id, generation } => self.cancel(&id, generation),
            CoreCommand::Snapshot => self.snapshot().map(|snapshot| json!(snapshot)),
            CoreCommand::Status { id } => self.status_result(&id),
            CoreCommand::Start { id, generation } => self.start_with_generation(&id, generation),
            CoreCommand::Stop { id, generation } => self.stop_with_generation(&id, generation),
            CoreCommand::Restart { id, generation } => {
                self.restart_with_generation(&id, generation)
            }
            CoreCommand::Remove { id, generation } => self.remove_with_generation(&id, generation),
            CoreCommand::Shutdown => self.shutdown(),
        };
        match outcome {
            Ok(result) => CoreResponse::success(result),
            Err(error) => CoreResponse::failure(error),
        }
    }

    pub fn execute_json(&self, input: &str) -> Result<String, TpError> {
        let command: CoreCommand = serde_json::from_str(input).map_err(|error| {
            TpError::new(
                error_code::OWNER_COMMAND,
                format!("owner 命令 JSON 解析失败：{error}"),
            )
        })?;
        serde_json::to_string(&self.execute(command)).map_err(|error| {
            TpError::new(
                error_code::INVALID_JSON,
                format!("owner 结果序列化失败：{error}"),
            )
        })
    }

    fn ensure_open(&self) -> Result<(), TpError> {
        if self.closed.load(Ordering::Acquire) {
            Err(TpError::new(error_code::OWNER_CLOSED, "Rust Core 已关闭"))
        } else {
            Ok(())
        }
    }

    fn load_config(&self) -> Result<AppConfig, TpError> {
        self.ensure_open()?;
        let config = ConfigStore::new(self.paths.clone()).load().config;
        validate_launchd_config(&config)?;
        *self.config.lock().expect("owner config mutex 不应中毒") = config.clone();
        Ok(config)
    }

    fn save_config(&self, config: AppConfig) -> Result<(), TpError> {
        self.ensure_open()?;
        validate_launchd_config(&config)?;
        ConfigStore::new(self.paths.clone())
            .save(&config)
            .map_err(|error| {
                TpError::new(
                    error_code::CONFIG_IO,
                    format!("保存 config.json 失败：{error}"),
                )
            })?;
        *self.config.lock().expect("owner config mutex 不应中毒") = config;
        Ok(())
    }

    fn lock_for(&self, id: &str) -> Arc<Mutex<()>> {
        let mut locks = self
            .tunnel_locks
            .lock()
            .expect("owner tunnel lock mutex 不应中毒");
        locks
            .entry(id.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    fn tunnel(&self, id: &str) -> Result<TunnelConfig, TpError> {
        self.config
            .lock()
            .expect("owner config mutex 不应中毒")
            .tunnels
            .iter()
            .find(|tunnel| tunnel.id == id)
            .cloned()
            .ok_or_else(|| TpError::new(error_code::TUNNEL_NOT_FOUND, format!("找不到隧道：{id}")))
    }

    fn next_generation(&self, id: &str) -> u64 {
        let mut generations = self
            .generations
            .lock()
            .expect("owner generation mutex 不应中毒");
        let generation = generations.entry(id.to_string()).or_insert(0);
        *generation = generation.wrapping_add(1).max(1);
        *generation
    }

    fn ensure_generation(&self, id: &str, expected: Option<u64>) -> Result<(), TpError> {
        let Some(expected) = expected else { return Ok(()) };
        let current = self
            .generations
            .lock()
            .expect("owner generation mutex 不应中毒")
            .get(id)
            .copied();
        if current != Some(expected) {
            return Err(TpError::new(
                error_code::STALE_OPERATION,
                format!("隧道操作代次已过期：{id}（expected={expected}, current={current:?}）"),
            ));
        }
        Ok(())
    }

    pub fn begin(&self, id: &str) -> Result<Value, TpError> {
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.tunnel(id)?;
        let generation = self.next_generation(id);
        Ok(json!({ "id": id, "operation": "begin", "generation": generation }))
    }

    pub fn cancel(&self, id: &str, generation: u64) -> Result<Value, TpError> {
        self.ensure_open()?;
        // 取消必须和同隧道生命周期命令共用串行锁；否则它可能在生命周期
        // 通过 generation 检查后、触发 launchd/plist 副作用前插入，形成竞态。
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.tunnel(id)?;
        let current = self
            .generations
            .lock()
            .expect("owner generation mutex 不应中毒")
            .get(id)
            .copied();
        if current == Some(generation) {
            let next = self.next_generation(id);
            return Ok(json!({ "id": id, "operation": "cancel", "generation": next }));
        }
        Ok(json!({ "id": id, "operation": "stale", "generation": current }))
    }

    fn status_result(&self, id: &str) -> Result<Value, TpError> {
        let status = self.status(id)?;
        Ok(json!({ "id": id, "status": status }))
    }

    /// 状态读取和生命周期命令共享同一条隧道锁，避免同一隧道的状态查询
    /// 与启停交叉；不同 id 不共享锁，可以并行调用 launchctl。
    pub fn status(&self, id: &str) -> Result<TunnelStatus, TpError> {
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        let tunnel = self.tunnel(id)?;
        Ok(self.launchd.status(&tunnel.launchd_label()))
    }

    pub fn start(&self, id: &str) -> Result<Value, TpError> {
        self.start_with_generation(id, None)
    }

    fn start_with_generation(&self, id: &str, generation: Option<u64>) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let tunnel = self.tunnel(id)?;
        let current_status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        if matches!(current_status, TunnelStatus::Running { .. }) {
            return Ok(json!({ "id": id, "operation": "noop", "status": current_status }));
        }
        let plist = write_plist(&tunnel, &self.paths).map_err(|error| {
            TpError::new(
                error_code::CONFIG_IO,
                format!("写入 launchd plist 失败：{error}"),
            )
        })?;
        self.launchd
            .bootstrap(&tunnel.launchd_label(), &plist)
            .map_err(|error| executor_error("启动", error))?;
        self.ensure_generation(id, generation)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        Ok(json!({ "id": id, "operation": "start", "status": status }))
    }

    pub fn stop(&self, id: &str) -> Result<Value, TpError> {
        self.stop_with_generation(id, None)
    }

    fn stop_with_generation(&self, id: &str, generation: Option<u64>) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let tunnel = self.tunnel(id)?;
        let stopped = self
            .launchd
            .bootout(&tunnel.launchd_label())
            .map_err(|error| executor_error("停止", error))?;
        self.ensure_generation(id, generation)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        Ok(json!({ "id": id, "operation": "stop", "stopped": stopped, "status": status }))
    }

    pub fn restart(&self, id: &str) -> Result<Value, TpError> {
        self.restart_with_generation(id, None)
    }

    fn restart_with_generation(
        &self,
        id: &str,
        generation: Option<u64>,
    ) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let tunnel = self.tunnel(id)?;
        // 保持现有 Swift restartSync 的兼容语义：未加载或 bootout 失败
        // 不阻断后续 plist 重写/bootstrap，bootstrap 失败仍返回错误。
        let _ = self.launchd.bootout(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        let plist = write_plist(&tunnel, &self.paths).map_err(|error| {
            TpError::new(
                error_code::CONFIG_IO,
                format!("写入 launchd plist 失败：{error}"),
            )
        })?;
        self.launchd
            .bootstrap(&tunnel.launchd_label(), &plist)
            .map_err(|error| executor_error("重启", error))?;
        self.ensure_generation(id, generation)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        Ok(json!({ "id": id, "operation": "restart", "status": status }))
    }

    pub fn remove(&self, id: &str) -> Result<Value, TpError> {
        self.remove_with_generation(id, None)
    }

    fn remove_with_generation(
        &self,
        id: &str,
        generation: Option<u64>,
    ) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let tunnel = self.tunnel(id)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        if status != TunnelStatus::NotLoaded {
            self.launchd
                .bootout(&tunnel.launchd_label())
                .map_err(|error| executor_error("删除时停止", error))?;
            self.ensure_generation(id, generation)?;
            if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
                return Err(TpError::new(error_code::STILL_RUNNING, "实例未成功停止"));
            }
        }

        self.ensure_generation(id, generation)?;
        let plist = self.paths.launchd_plist_url(&tunnel);
        if plist.exists() {
            fs::remove_file(&plist).map_err(|error| {
                TpError::new(
                    error_code::CONFIG_IO,
                    format!("清理 launchd plist 失败：{error}"),
                )
            })?;
        }
        let log = self.paths.log_url(&tunnel);
        let mut log_warning = false;
        if log.exists() {
            let _ = fs::remove_file(&log);
            log_warning = log.exists();
        }

        self.ensure_generation(id, generation)?;

        let mut config = self
            .config
            .lock()
            .expect("owner config mutex 不应中毒")
            .clone();
        let Some(index) = config
            .tunnels
            .iter()
            .position(|candidate| candidate.id == id)
        else {
            return Err(TpError::new(
                error_code::TUNNEL_NOT_FOUND,
                format!("找不到隧道：{id}"),
            ));
        };
        let removed = config.tunnels.remove(index);
        if let Err(error) = ConfigStore::new(self.paths.clone()).save(&config) {
            config.tunnels.insert(index, removed);
            return Err(TpError::new(
                error_code::CONFIG_IO,
                format!("删除后保存 config.json 失败：{error}"),
            ));
        }
        *self.config.lock().expect("owner config mutex 不应中毒") = config;
        Ok(json!({ "id": id, "operation": "remove", "logWarning": log_warning }))
    }

    pub fn snapshot(&self) -> Result<OwnerSnapshot, TpError> {
        self.ensure_open()?;
        let config = self
            .config
            .lock()
            .expect("owner config mutex 不应中毒")
            .clone();
        let mut statuses = BTreeMap::new();
        for tunnel in &config.tunnels {
            let lock = self.lock_for(&tunnel.id);
            let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
            statuses.insert(
                tunnel.id.clone(),
                self.launchd.status(&tunnel.launchd_label()),
            );
        }
        Ok(OwnerSnapshot {
            config,
            statuses,
            closed: false,
        })
    }

    /// 退出时先把所有隧道锁按稳定顺序持有，再关门并逐条 bootout；这样不会
    /// 让新生命周期操作在 shutdown 之后进入。
    pub fn shutdown(&self) -> Result<Value, TpError> {
        self.ensure_open()?;
        let ids = {
            let mut ids: Vec<String> = self
                .config
                .lock()
                .expect("owner config mutex 不应中毒")
                .tunnels
                .iter()
                .map(|tunnel| tunnel.id.clone())
                .collect();
            ids.sort();
            ids
        };
        let locks: Vec<_> = ids.iter().map(|id| self.lock_for(id)).collect();
        let _guards: Vec<_> = locks
            .iter()
            .map(|lock| lock.lock().expect("owner tunnel mutex 不应中毒"))
            .collect();
        self.closed.store(true, Ordering::Release);

        let mut stopped = 0;
        for id in ids {
            let tunnel = self.tunnel(&id)?;
            if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
                if self
                    .launchd
                    .bootout(&tunnel.launchd_label())
                    .map_err(|error| executor_error("退出清理", error))?
                {
                    stopped += 1;
                }
            }
        }
        Ok(json!({ "operation": "shutdown", "stopped": stopped }))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OwnerSnapshot {
    pub config: AppConfig,
    pub statuses: BTreeMap<String, TunnelStatus>,
    pub closed: bool,
}

fn validate_launchd_config(config: &AppConfig) -> Result<(), TpError> {
    for tunnel in &config.tunnels {
        if tunnel.executor != ExecutorKind::Launchd {
            return Err(TpError::new(
                error_code::UNSUPPORTED_EXECUTOR,
                format!("阶段 5 仅支持 launchd 执行器：{}", tunnel.id),
            ));
        }
        if !TunnelConfig::is_valid_id(&tunnel.id) {
            return Err(TpError::new(
                error_code::INVALID_ID,
                format!("隧道 id 只允许小写字母、数字与连字符：{}", tunnel.id),
            ));
        }
        if tunnel.command.is_empty() || tunnel.command[0].is_empty() {
            return Err(TpError::new(
                error_code::INVALID_COMMAND,
                "command 不能为空且首元素必须是可执行路径",
            ));
        }
    }
    Ok(())
}

fn executor_error(operation: &str, error: ExecutorError) -> TpError {
    let message = match error {
        ExecutorError::CommandFailed {
            exit_code, stderr, ..
        } => {
            format!("{operation} launchd 失败（exit={exit_code}）：{stderr}")
        }
        ExecutorError::Spawn { message } => format!("{operation} launchd 无法启动：{message}"),
    };
    TpError::new(error_code::EXECUTOR, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launchctl::{LaunchCtlExecutor, ProcessResult, ProcessRunning};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::collections::VecDeque;
    use std::thread;
    use std::time::Duration;

    #[derive(Clone)]
    struct FakeRunner {
        active: Arc<AtomicUsize>,
        max_active: Arc<AtomicUsize>,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        delay: Duration,
    }

    impl FakeRunner {
        fn new(delay: Duration) -> Self {
            Self {
                active: Arc::new(AtomicUsize::new(0)),
                max_active: Arc::new(AtomicUsize::new(0)),
                calls: Arc::new(Mutex::new(vec![])),
                delay,
            }
        }

        fn update_max(&self, active: usize) {
            let mut current = self.max_active.load(Ordering::Relaxed);
            while active > current {
                match self.max_active.compare_exchange(
                    current,
                    active,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => break,
                    Err(next) => current = next,
                }
            }
        }
    }

    impl ProcessRunning for FakeRunner {
        fn run(
            &self,
            _executable_path: &str,
            arguments: &[String],
        ) -> Result<ProcessResult, String> {
            self.calls.lock().unwrap().push(arguments.to_vec());
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.update_max(active);
            thread::sleep(self.delay);
            self.active.fetch_sub(1, Ordering::SeqCst);
            Ok(ProcessResult {
                exit_code: 0,
                stdout: "\tstate = not running\n".into(),
                stderr: String::new(),
            })
        }
    }

    #[derive(Clone)]
    struct ScriptedRunner {
        script: Arc<Mutex<VecDeque<Result<ProcessResult, String>>>>,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
    }

    impl ScriptedRunner {
        fn new(script: Vec<Result<ProcessResult, String>>) -> Self {
            Self {
                script: Arc::new(Mutex::new(script.into())),
                calls: Arc::new(Mutex::new(vec![])),
            }
        }

        fn calls(&self) -> Vec<Vec<String>> {
            self.calls.lock().unwrap().clone()
        }

        fn assert_exhausted(&self) {
            assert!(self.script.lock().unwrap().is_empty(), "launchd fixture 仍有未消费的调用")
        }
    }

    impl ProcessRunning for ScriptedRunner {
        fn run(
            &self,
            _executable_path: &str,
            arguments: &[String],
        ) -> Result<ProcessResult, String> {
            self.calls.lock().unwrap().push(arguments.to_vec());
            self.script
                .lock()
                .unwrap()
                .pop_front()
                .expect("launchd fixture 调用超出脚本")
        }
    }

    #[derive(Clone)]
    struct BlockingRunner {
        entered: Arc<Mutex<Option<Sender<()>>>>,
        release: Arc<Mutex<Receiver<()>>>,
    }

    impl BlockingRunner {
        fn new() -> (Self, Receiver<()>, Sender<()>) {
            let (entered_tx, entered_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            (
                Self {
                    entered: Arc::new(Mutex::new(Some(entered_tx))),
                    release: Arc::new(Mutex::new(release_rx)),
                },
                entered_rx,
                release_tx,
            )
        }
    }

    impl ProcessRunning for BlockingRunner {
        fn run(
            &self,
            _executable_path: &str,
            _arguments: &[String],
        ) -> Result<ProcessResult, String> {
            if let Some(entered) = self.entered.lock().unwrap().take() {
                entered.send(()).unwrap();
                self.release.lock().unwrap().recv().unwrap();
            }
            Ok(ProcessResult {
                exit_code: 0,
                stdout: "\tstate = not running\n".into(),
                stderr: String::new(),
            })
        }
    }

    fn process(exit_code: i32, stdout: &str, stderr: &str) -> Result<ProcessResult, String> {
        Ok(ProcessResult {
            exit_code,
            stdout: stdout.into(),
            stderr: stderr.into(),
        })
    }

    fn spawn_error(message: &str) -> Result<ProcessResult, String> {
        Err(message.into())
    }

    fn not_loaded() -> Result<ProcessResult, String> {
        process(3, "", "Could not find service")
    }

    fn running(pid: i32) -> Result<ProcessResult, String> {
        process(0, &format!("\tstate = running\n\tpid = {pid}\n"), "")
    }

    fn not_running() -> Result<ProcessResult, String> {
        process(0, "\tstate = not running\n", "")
    }

    fn temp_home(label: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("tp-owner-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&home).unwrap();
        home
    }

    fn config(ids: &[&str]) -> AppConfig {
        AppConfig {
            version: 1,
            tunnels: ids
                .iter()
                .map(|id| TunnelConfig {
                    id: (*id).into(),
                    name: (*id).into(),
                    command: vec!["/usr/bin/true".into()],
                    executor: ExecutorKind::Launchd,
                    keep_alive: true,
                    throttle_interval: 10,
                    probe: None,
                })
                .collect(),
        }
    }

    fn owner(home: &Path, ids: &[&str]) -> CoreOwner<LaunchCtlExecutor<FakeRunner>> {
        let paths = TunnelPaths::new(home);
        ConfigStore::new(paths.clone()).save(&config(ids)).unwrap();
        CoreOwner::new(
            paths,
            LaunchCtlExecutor::new(FakeRunner::new(Duration::from_millis(10)), 501),
        )
        .unwrap()
    }

    fn scripted_owner(
        home: &Path,
        ids: &[&str],
        runner: ScriptedRunner,
    ) -> CoreOwner<LaunchCtlExecutor<ScriptedRunner>> {
        let paths = TunnelPaths::new(home);
        ConfigStore::new(paths.clone()).save(&config(ids)).unwrap();
        CoreOwner::new(paths, LaunchCtlExecutor::new(runner, 501)).unwrap()
    }

    #[test]
    fn config_owner_reads_writes_and_rejects_app() {
        let home = temp_home("config");
        let owner = owner(&home, &["admin-tunnel"]);
        let response = owner.execute_json(r#"{"op":"loadConfig"}"#).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap()["ok"],
            true
        );

        let mut app_config = config(&["bad-app"]);
        app_config.tunnels[0].executor = ExecutorKind::App;
        let error = owner.save_config(app_config).unwrap_err();
        assert_eq!(error.code, error_code::UNSUPPORTED_EXECUTOR);
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn lifecycle_and_shutdown_are_json_owned() {
        let home = temp_home("lifecycle");
        let owner = owner(&home, &["admin-tunnel", "reverse-ssh"]);
        let start = owner
            .execute_json(r#"{"op":"start","id":"admin-tunnel"}"#)
            .unwrap();
        assert_eq!(serde_json::from_str::<Value>(&start).unwrap()["ok"], true);
        let snapshot = owner.execute_json(r#"{"op":"snapshot"}"#).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&snapshot).unwrap()["result"]["config"]["tunnels"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let shutdown = owner.execute_json(r#"{"op":"shutdown"}"#).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&shutdown).unwrap()["result"]["operation"],
            "shutdown"
        );
        let after = owner
            .execute_json(r#"{"op":"status","id":"admin-tunnel"}"#)
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&after).unwrap()["error"]["code"],
            error_code::OWNER_CLOSED
        );
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn shutdown_skips_unloaded_services() {
        #[derive(Clone)]
        struct UnloadedRunner {
            calls: Arc<Mutex<Vec<Vec<String>>>>,
        }

        impl ProcessRunning for UnloadedRunner {
            fn run(
                &self,
                _executable_path: &str,
                arguments: &[String],
            ) -> Result<ProcessResult, String> {
                self.calls.lock().unwrap().push(arguments.to_vec());
                if arguments.first().map(String::as_str) == Some("print") {
                    return Ok(ProcessResult {
                        exit_code: 3,
                        stdout: String::new(),
                        stderr: "Could not find service".into(),
                    });
                }
                Ok(ProcessResult {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            }
        }

        let home = temp_home("shutdown-unloaded");
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone())
            .save(&config(&["admin-tunnel", "reverse-ssh"]))
            .unwrap();
        let calls = Arc::new(Mutex::new(vec![]));
        let owner = CoreOwner::new(
            paths,
            LaunchCtlExecutor::new(
                UnloadedRunner {
                    calls: calls.clone(),
                },
                501,
            ),
        )
        .unwrap();

        let response = owner.shutdown().unwrap();

        assert_eq!(response["stopped"], 0);
        let calls = calls.lock().unwrap();
        assert_eq!(
            calls
                .iter()
                .filter(|arguments| arguments.first().map(String::as_str) == Some("print"))
                .count(),
            2
        );
        assert!(!calls
            .iter()
            .any(|arguments| arguments.first().map(String::as_str) == Some("bootout")));
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn lifecycle_success_matrix_preserves_command_order() {
        let home = temp_home("matrix-start");
        let runner = ScriptedRunner::new(vec![
            not_loaded(),
            process(0, "", ""),
            running(123),
        ]);
        let owner = scripted_owner(&home, &["matrix-start"], runner.clone());
        let result = owner.start("matrix-start").unwrap();
        assert_eq!(result["operation"], "start");
        assert_eq!(result["status"]["case"], "running");
        assert_eq!(
            runner.calls().iter().map(|call| call[0].as_str()).collect::<Vec<_>>(),
            vec!["print", "bootstrap", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-stop");
        let runner = ScriptedRunner::new(vec![process(0, "", ""), not_running()]);
        let owner = scripted_owner(&home, &["matrix-stop"], runner.clone());
        let result = owner.stop("matrix-stop").unwrap();
        assert_eq!(result["operation"], "stop");
        assert_eq!(result["stopped"], true);
        assert_eq!(
            runner.calls().iter().map(|call| call[0].as_str()).collect::<Vec<_>>(),
            vec!["bootout", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-restart");
        let runner = ScriptedRunner::new(vec![
            process(3, "", "Could not find service"),
            process(0, "", ""),
            running(456),
        ]);
        let owner = scripted_owner(&home, &["matrix-restart"], runner.clone());
        let result = owner.restart("matrix-restart").unwrap();
        assert_eq!(result["operation"], "restart");
        assert_eq!(result["status"]["case"], "running");
        assert_eq!(
            runner.calls().iter().map(|call| call[0].as_str()).collect::<Vec<_>>(),
            vec!["bootout", "bootstrap", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn status_matrix_returns_launchd_state_and_rejects_unknown_id() {
        let home = temp_home("matrix-status");
        let runner = ScriptedRunner::new(vec![running(2468)]);
        let owner = scripted_owner(&home, &["matrix-status"], runner.clone());
        assert_eq!(owner.status("matrix-status").unwrap(), TunnelStatus::Running { pid: Some(2468) });
        assert_eq!(runner.calls()[0][0], "print");
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-status-unknown");
        let runner = ScriptedRunner::new(vec![]);
        let owner = scripted_owner(&home, &["matrix-status-unknown"], runner.clone());
        let error = owner.status("missing").unwrap_err();
        assert_eq!(error.code, error_code::TUNNEL_NOT_FOUND);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn stale_generation_is_rejected_before_any_launchd_call() {
        let home = temp_home("generation");
        let runner = ScriptedRunner::new(vec![]);
        let owner = scripted_owner(&home, &["generation"], runner.clone());
        let first = owner.begin("generation").unwrap()["generation"]
            .as_u64()
            .unwrap();
        let second = owner.begin("generation").unwrap()["generation"]
            .as_u64()
            .unwrap();
        assert!(second > first);

        let stale = owner.execute(CoreCommand::Start {
            id: "generation".into(),
            generation: Some(first),
        });
        assert!(!stale.ok);
        assert_eq!(stale.error.unwrap().code, error_code::STALE_OPERATION);
        runner.assert_exhausted();

        let cancel = owner.cancel("generation", second).unwrap();
        assert_eq!(cancel["operation"], "cancel");
        let cancelled = owner.execute(CoreCommand::Stop {
            id: "generation".into(),
            generation: Some(second),
        });
        assert!(!cancelled.ok);
        assert_eq!(cancelled.error.unwrap().code, error_code::STALE_OPERATION);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn cancel_serializes_with_lifecycle_commands() {
        let home = temp_home("cancel-lock");
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone()).save(&config(&["cancel-lock"])).unwrap();
        let (runner, entered_rx, release_tx) = BlockingRunner::new();
        let owner = Arc::new(CoreOwner::new(paths, LaunchCtlExecutor::new(runner, 501)).unwrap());
        let generation = owner.begin("cancel-lock").unwrap()["generation"]
            .as_u64()
            .unwrap();

        let lifecycle_owner = owner.clone();
        let lifecycle = thread::spawn(move || {
            lifecycle_owner.execute(CoreCommand::Start {
                id: "cancel-lock".into(),
                generation: Some(generation),
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (cancel_started_tx, cancel_started_rx) = mpsc::channel();
        let (cancel_done_tx, cancel_done_rx) = mpsc::channel();
        let cancel_owner = owner.clone();
        let cancel = thread::spawn(move || {
            cancel_started_tx.send(()).unwrap();
            let response = cancel_owner.cancel("cancel-lock", generation).unwrap();
            cancel_done_tx.send(response).unwrap();
        });
        cancel_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            cancel_done_rx.recv_timeout(Duration::from_millis(25)).is_err(),
            "cancel 不应在同隧道生命周期持锁时完成"
        );

        release_tx.send(()).unwrap();
        assert!(lifecycle.join().unwrap().ok);
        let response = cancel_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(response["operation"], "cancel");
        cancel.join().unwrap();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn lifecycle_failure_matrix_returns_executor_errors_without_swallowing_failures() {
        let home = temp_home("matrix-start-error");
        let runner = ScriptedRunner::new(vec![
            not_loaded(),
            process(9, "", "Operation not permitted"),
        ]);
        let owner = scripted_owner(&home, &["matrix-start-error"], runner.clone());
        let error = owner.start("matrix-start-error").unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("启动 launchd 失败"));
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-stop-error");
        let runner = ScriptedRunner::new(vec![spawn_error("launchctl missing")]);
        let owner = scripted_owner(&home, &["matrix-stop-error"], runner.clone());
        let error = owner.stop("matrix-stop-error").unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("无法启动"));
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-restart-error");
        let runner = ScriptedRunner::new(vec![
            process(3, "", "Could not find service"),
            process(7, "", "Bootstrap failed"),
        ]);
        let owner = scripted_owner(&home, &["matrix-restart-error"], runner.clone());
        let error = owner.restart("matrix-restart-error").unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("重启 launchd 失败"));
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-remove-error");
        let runner = ScriptedRunner::new(vec![
            running(789),
            process(5, "", "Operation not permitted"),
            not_loaded(),
        ]);
        let owner = scripted_owner(&home, &["matrix-remove-error"], runner.clone());
        let error = owner.remove("matrix-remove-error").unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("删除时停止 launchd 失败"));
        assert_eq!(owner.snapshot().unwrap().config.tunnels.len(), 1);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn remove_and_shutdown_matrix_updates_config_and_counts_loaded_services() {
        let home = temp_home("matrix-remove-success");
        let runner = ScriptedRunner::new(vec![running(321), process(0, "", ""), not_loaded()]);
        let owner = scripted_owner(&home, &["matrix-remove-success"], runner.clone());
        owner.remove("matrix-remove-success").unwrap();
        assert!(owner.snapshot().unwrap().config.tunnels.is_empty());
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-shutdown");
        let runner = ScriptedRunner::new(vec![running(654), process(0, "", ""), not_loaded()]);
        let owner = scripted_owner(&home, &["loaded", "unloaded"], runner.clone());
        let result = owner.shutdown().unwrap();
        assert_eq!(result["operation"], "shutdown");
        assert_eq!(result["stopped"], 1);
        assert_eq!(
            runner.calls().iter().map(|call| call[0].as_str()).collect::<Vec<_>>(),
            vec!["print", "bootout", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-shutdown-error");
        let runner = ScriptedRunner::new(vec![running(987), process(8, "", "Operation not permitted")]);
        let owner = scripted_owner(&home, &["matrix-shutdown-error"], runner.clone());
        let error = owner.shutdown().unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(owner.status("matrix-shutdown-error").is_err());
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn same_tunnel_serializes_but_different_tunnels_can_overlap() {
        let home = temp_home("concurrency");
        let owner = Arc::new(owner(&home, &["one", "two"]));
        let same_handles: Vec<_> = (0..2)
            .map(|_| {
                let owner = owner.clone();
                thread::spawn(move || owner.status("one").unwrap())
            })
            .collect();
        for handle in same_handles {
            handle.join().unwrap();
        }
        let runner = &owner.launchd.runner;
        assert_eq!(runner.max_active.load(Ordering::SeqCst), 1);

        let different_handles: Vec<_> = ["one", "two"]
            .into_iter()
            .map(|id| {
                let owner = owner.clone();
                thread::spawn(move || owner.status(id).unwrap())
            })
            .collect();
        for handle in different_handles {
            handle.join().unwrap();
        }
        assert!(runner.max_active.load(Ordering::SeqCst) >= 2);
        let _ = fs::remove_dir_all(home);
    }
}
