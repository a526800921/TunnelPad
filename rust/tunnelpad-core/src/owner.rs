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
use crate::launchctl::{CancellationToken, ExecutorError, TunnelStatus};
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
    SaveConfig {
        config: AppConfig,
    },
    Begin {
        id: String,
    },
    Cancel {
        id: String,
        generation: u64,
    },
    Snapshot,
    Status {
        id: String,
    },
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

#[derive(Clone)]
struct OperationState {
    generation: u64,
    cancellation: CancellationToken,
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
    operations: Mutex<HashMap<String, OperationState>>,
    closed: AtomicBool,
}

impl<L: LaunchdExecuting> CoreOwner<L> {
    /// 读取并校验 Rust owner 的初始配置。现阶段遇到 `app` 配置直接拒绝，
    /// 不自动转换为 `launchd`。
    pub fn new(paths: TunnelPaths, launchd: L) -> Result<Self, TpError> {
        let config = load_owner_config(&paths)?;
        validate_launchd_config(&config)?;
        Ok(Self {
            paths,
            launchd,
            config: Mutex::new(config),
            tunnel_locks: Mutex::new(HashMap::new()),
            operations: Mutex::new(HashMap::new()),
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
        let config = load_owner_config(&self.paths)?;
        validate_launchd_config(&config)?;

        // 配置重载不能先丢失旧配置再处理已删除的 label。否则仍在运行的
        // launchd 服务会脱离 owner，之后 shutdown/status 都无法再找到它。
        // 先复制旧配置并按稳定顺序持有待删除隧道锁，避免与同一隧道的启停
        // 交错；全部删除项收敛后才替换 owner 配置。
        let previous = self
            .config
            .lock()
            .expect("owner config mutex 不应中毒")
            .clone();
        let next_ids: std::collections::HashSet<_> =
            config.tunnels.iter().map(|tunnel| tunnel.id.as_str()).collect();
        let mut removed: Vec<_> = previous
            .tunnels
            .iter()
            .filter(|tunnel| !next_ids.contains(tunnel.id.as_str()))
            .cloned()
            .collect();
        removed.sort_by(|left, right| left.id.cmp(&right.id));
        let locks: Vec<_> = removed.iter().map(|tunnel| self.lock_for(&tunnel.id)).collect();
        let _guards: Vec<_> = locks
            .iter()
            .map(|lock| lock.lock().expect("owner tunnel mutex 不应中毒"))
            .collect();

        let mut first_error = None;
        for tunnel in &removed {
            let label = tunnel.launchd_label();
            if self.launchd.status(&label) == TunnelStatus::NotLoaded {
                continue;
            }
            if let Err(error) = self.launchd.bootout(&label) {
                if first_error.is_none() {
                    let mut failure = executor_error("配置刷新前停止", error);
                    failure.message = format!("{}（label={label}）", failure.message);
                    first_error = Some(failure);
                }
                continue;
            }
            if self.launchd.status(&label) != TunnelStatus::NotLoaded && first_error.is_none() {
                first_error = Some(TpError::new(
                    error_code::EXECUTOR,
                    format!("配置刷新前停止后仍加载 launchd 服务：{label}"),
                ));
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }

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

    fn next_generation(&self, id: &str) -> (u64, CancellationToken) {
        let mut operations = self
            .operations
            .lock()
            .expect("owner operation mutex 不应中毒");
        let state = operations
            .entry(id.to_string())
            .or_insert_with(|| OperationState {
                generation: 0,
                cancellation: CancellationToken::new(),
            });
        state.generation = state.generation.wrapping_add(1).max(1);
        state.cancellation = CancellationToken::new();
        (state.generation, state.cancellation.clone())
    }

    fn advance_generation(state: &mut OperationState) -> u64 {
        state.generation = state.generation.wrapping_add(1).max(1);
        state.cancellation = CancellationToken::new();
        state.generation
    }

    fn ensure_generation(&self, id: &str, expected: Option<u64>) -> Result<(), TpError> {
        let Some(expected) = expected else {
            return Ok(());
        };
        let current = self
            .operations
            .lock()
            .expect("owner operation mutex 不应中毒")
            .get(id)
            .map(|state| state.generation);
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
        self.ensure_open()?;
        self.tunnel(id)?;
        let (generation, _) = self.next_generation(id);
        Ok(json!({ "id": id, "operation": "begin", "generation": generation }))
    }

    pub fn cancel(&self, id: &str, generation: u64) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.tunnel(id)?;
        // 取消不能等待生命周期锁：它必须能在 launchctl 正在运行时立即发出
        // 信号。生命周期仍在每个副作用边界检查 generation，系统 runner 还
        // 会终止正在运行的 launchctl 子进程。
        let mut operations = self
            .operations
            .lock()
            .expect("owner operation mutex 不应中毒");
        let Some(state) = operations.get_mut(id) else {
            return Ok(json!({ "id": id, "operation": "stale", "generation": null }));
        };
        if state.generation == generation {
            state.cancellation.cancel();
            let next = Self::advance_generation(state);
            return Ok(json!({ "id": id, "operation": "cancel", "generation": next }));
        }
        Ok(json!({ "id": id, "operation": "stale", "generation": state.generation }))
    }

    fn cancellation_for(&self, id: &str, generation: Option<u64>) -> CancellationToken {
        generation
            .and_then(|expected| {
                self.operations
                    .lock()
                    .expect("owner operation mutex 不应中毒")
                    .get(id)
                    .filter(|state| state.generation == expected)
                    .map(|state| state.cancellation.clone())
            })
            .unwrap_or_else(CancellationToken::new)
    }

    fn cancel_all_operations(&self) {
        let mut operations = self
            .operations
            .lock()
            .expect("owner operation mutex 不应中毒");
        for state in operations.values_mut() {
            state.cancellation.cancel();
            Self::advance_generation(state);
        }
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
        let cancellation = self.cancellation_for(id, generation);
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
            .bootstrap_cancellable(&tunnel.launchd_label(), &plist, &cancellation)
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
        let cancellation = self.cancellation_for(id, generation);
        let tunnel = self.tunnel(id)?;
        let stopped = self
            .launchd
            .bootout_cancellable(&tunnel.launchd_label(), &cancellation)
            .map_err(|error| executor_error("停止", error))?;
        self.ensure_generation(id, generation)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        Ok(json!({ "id": id, "operation": "stop", "stopped": stopped, "status": status }))
    }

    pub fn restart(&self, id: &str) -> Result<Value, TpError> {
        self.restart_with_generation(id, None)
    }

    fn restart_with_generation(&self, id: &str, generation: Option<u64>) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let cancellation = self.cancellation_for(id, generation);
        let tunnel = self.tunnel(id)?;
        // 未加载由 executor 明确归类为可继续；其他 bootout 失败必须
        // fail-closed，不能在旧实例未收敛时继续写 plist/bootstrap。
        self
            .launchd
            .bootout_cancellable(&tunnel.launchd_label(), &cancellation)
            .map_err(|error| executor_error("重启前停止", error))?;
        self.ensure_generation(id, generation)?;
        let plist = write_plist(&tunnel, &self.paths).map_err(|error| {
            TpError::new(
                error_code::CONFIG_IO,
                format!("写入 launchd plist 失败：{error}"),
            )
        })?;
        self.launchd
            .bootstrap_cancellable(&tunnel.launchd_label(), &plist, &cancellation)
            .map_err(|error| executor_error("重启", error))?;
        self.ensure_generation(id, generation)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        Ok(json!({ "id": id, "operation": "restart", "status": status }))
    }

    pub fn remove(&self, id: &str) -> Result<Value, TpError> {
        self.remove_with_generation(id, None)
    }

    fn remove_with_generation(&self, id: &str, generation: Option<u64>) -> Result<Value, TpError> {
        self.ensure_open()?;
        self.ensure_generation(id, generation)?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        self.ensure_generation(id, generation)?;
        let cancellation = self.cancellation_for(id, generation);
        let tunnel = self.tunnel(id)?;
        let status = self.launchd.status(&tunnel.launchd_label());
        self.ensure_generation(id, generation)?;
        if status != TunnelStatus::NotLoaded {
            self.launchd
                .bootout_cancellable(&tunnel.launchd_label(), &cancellation)
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

    /// 退出时先原子地关闭 owner、取消在途操作，再把所有隧道锁按稳定顺序
    /// 持有并逐条 bootout；单条清理失败不会截断后续 label。清理失败时
    /// 释放 closed 门闩，允许调用方再次尝试收敛未完成的服务；成功后重复
    /// shutdown 仍不会再次产生 launchd 副作用。
    pub fn shutdown(&self) -> Result<Value, TpError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Err(TpError::new(error_code::OWNER_CLOSED, "Rust Core 已关闭"));
        }
        let outcome = (|| {
            self.cancel_all_operations();
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
            let mut stopped = 0;
            let mut first_error = None;
            for id in ids {
                let tunnel = self.tunnel(&id)?;
                let label = tunnel.launchd_label();
                if self.launchd.status(&label) != TunnelStatus::NotLoaded {
                    match self.launchd.bootout(&label) {
                        Ok(_) => {
                            if self.launchd.status(&label) == TunnelStatus::NotLoaded {
                                stopped += 1;
                            } else if first_error.is_none() {
                                first_error = Some(TpError::new(
                                    error_code::EXECUTOR,
                                    format!("退出清理后仍加载 launchd 服务：{label}"),
                                ));
                            }
                        }
                        Err(error) => {
                            if first_error.is_none() {
                                let mut failure = executor_error("退出清理", error);
                                failure.message = format!("{}（label={label}）", failure.message);
                                first_error = Some(failure);
                            }
                            // 即使当前 label 失败，也继续处理剩余配置中的受管服务。
                            // 失败结果在所有 label 尝试完成后统一返回。
                        }
                    }
                }
            }
            if let Some(error) = first_error {
                return Err(error);
            }
            Ok(json!({ "operation": "shutdown", "stopped": stopped }))
        })();

        if outcome.is_err() {
            // 本次清理未收敛，保留重试入口；closed=true 只代表成功完成
            // shutdown，不能把一次可恢复的 launchd 错误变成永久状态。
            self.closed.store(false, Ordering::Release);
        }
        outcome
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

/// owner 读取必须 fail-closed：`ConfigStore` 的历史损坏恢复语义会把非法
/// config 改名后返回空配置，适合旧 UI 启动恢复，但不适合作为唯一 owner 的
/// 初始状态。这里直接读取并解析，保留 schema/id/command 的具体错误码。
fn load_owner_config(paths: &TunnelPaths) -> Result<AppConfig, TpError> {
    let url = paths.config_url();
    if !url.exists() {
        return Ok(AppConfig::default_config());
    }
    let bytes = fs::read(&url).map_err(|error| {
        TpError::new(
            error_code::CONFIG_IO,
            format!("读取 config.json 失败：{error}"),
        )
    })?;
    let input = std::str::from_utf8(&bytes).map_err(|error| {
        TpError::new(
            error_code::INVALID_JSON,
            format!("config.json 不是合法 UTF-8：{error}"),
        )
    })?;
    crate::parse_config_envelope(input)
}

fn executor_error(operation: &str, error: ExecutorError) -> TpError {
    let cancelled = matches!(&error, ExecutorError::Cancelled);
    let message = match error {
        ExecutorError::CommandFailed {
            exit_code, stderr, ..
        } => {
            format!("{operation} launchd 失败（exit={exit_code}）：{stderr}")
        }
        ExecutorError::Spawn { message } => format!("{operation} launchd 无法启动：{message}"),
        ExecutorError::Cancelled => format!("{operation} launchd 操作已取消"),
    };
    let code = if cancelled {
        error_code::STALE_OPERATION
    } else {
        error_code::EXECUTOR
    };
    TpError::new(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launchctl::{
        CancellationToken, LaunchCtlExecutor, ProcessResult, ProcessRunError, ProcessRunning,
    };
    use std::collections::VecDeque;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Receiver, Sender};
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
            assert!(
                self.script.lock().unwrap().is_empty(),
                "launchd fixture 仍有未消费的调用"
            )
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
    }

    impl BlockingRunner {
        fn new() -> (Self, Receiver<()>) {
            let (entered_tx, entered_rx) = mpsc::channel();
            (
                Self {
                    entered: Arc::new(Mutex::new(Some(entered_tx))),
                },
                entered_rx,
            )
        }
    }

    impl ProcessRunning for BlockingRunner {
        fn run(
            &self,
            _executable_path: &str,
            _arguments: &[String],
        ) -> Result<ProcessResult, String> {
            Ok(ProcessResult {
                exit_code: 3,
                stdout: String::new(),
                stderr: "Could not find service".into(),
            })
        }

        fn run_cancellable(
            &self,
            _executable_path: &str,
            _arguments: &[String],
            cancellation: &CancellationToken,
        ) -> Result<ProcessResult, ProcessRunError> {
            if let Some(entered) = self.entered.lock().unwrap().take() {
                entered.send(()).unwrap();
            }
            while !cancellation.is_cancelled() {
                thread::sleep(Duration::from_millis(5));
            }
            Err(ProcessRunError::Cancelled)
        }
    }

    #[derive(Clone)]
    struct RestartBlockingRunner {
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        bootstrap_entered: Arc<Mutex<Option<Sender<()>>>>,
    }

    impl RestartBlockingRunner {
        fn new() -> (Self, Receiver<()>) {
            let (entered_tx, entered_rx) = mpsc::channel();
            (
                Self {
                    calls: Arc::new(Mutex::new(vec![])),
                    bootstrap_entered: Arc::new(Mutex::new(Some(entered_tx))),
                },
                entered_rx,
            )
        }

        fn calls(&self) -> Vec<Vec<String>> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl ProcessRunning for RestartBlockingRunner {
        fn run(
            &self,
            _executable_path: &str,
            arguments: &[String],
        ) -> Result<ProcessResult, String> {
            self.calls.lock().unwrap().push(arguments.to_vec());
            Err("restart 使用了不可取消 launchctl 路径".into())
        }

        fn run_cancellable(
            &self,
            _executable_path: &str,
            arguments: &[String],
            cancellation: &CancellationToken,
        ) -> Result<ProcessResult, ProcessRunError> {
            self.calls.lock().unwrap().push(arguments.to_vec());
            match arguments.first().map(String::as_str) {
                Some("bootout") => Ok(ProcessResult {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                }),
                Some("bootstrap") => {
                    if let Some(entered) = self.bootstrap_entered.lock().unwrap().take() {
                        entered.send(()).unwrap();
                    }
                    while !cancellation.is_cancelled() {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(ProcessRunError::Cancelled)
                }
                other => panic!("unexpected launchctl operation: {other:?}"),
            }
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
                    remark: String::new(),
                    command: vec!["/usr/bin/true".into()],
                    executor: ExecutorKind::Launchd,
                    keep_alive: true,
                    throttle_interval: 10,
                    probe: None,
                })
                .collect(),
        }
    }

    fn config_with_tunnels(tunnels: Vec<TunnelConfig>) -> AppConfig {
        AppConfig { version: 1, tunnels }
    }

    fn tunnel(id: &str, command: &str) -> TunnelConfig {
        TunnelConfig {
            id: id.into(),
            name: id.into(),
            remark: String::new(),
            command: vec![command.into()],
            executor: ExecutorKind::Launchd,
            keep_alive: true,
            throttle_interval: 10,
            probe: None,
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
    fn config_owner_reads_and_rejects_app_executor_json() {
        let home = temp_home("config");
        let owner = owner(&home, &["admin-tunnel"]);
        let response = owner.execute_json(r#"{"op":"loadConfig"}"#).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap()["ok"],
            true
        );

        let error = crate::parse_config_envelope(
            r#"{"version":1,"tunnels":[{"id":"bad-app","name":"bad-app","command":["/bin/true"],"executor":"app"}]}"#,
        )
        .unwrap_err();
        assert_eq!(error.code, error_code::INVALID_JSON);
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_stops_removed_loaded_label_before_commit() {
        let home = temp_home("reload-removed-success");
        let runner = ScriptedRunner::new(vec![running(100), process(0, "", ""), not_loaded()]);
        let owner = scripted_owner(&home, &["keep", "remove"], runner.clone());
        let candidate = config_with_tunnels(vec![tunnel("keep", "/usr/bin/true")]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let loaded = owner.load_config().unwrap();

        assert_eq!(loaded.tunnels.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), vec!["keep"]);
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["print", "bootout", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_commits_new_tunnels_without_starting_them() {
        let home = temp_home("reload-added");
        let runner = ScriptedRunner::new(vec![]);
        let owner = scripted_owner(&home, &["keep"], runner.clone());
        let candidate = config_with_tunnels(vec![
            tunnel("keep", "/usr/bin/true"),
            tunnel("added", "/usr/bin/added"),
        ]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let loaded = owner.load_config().unwrap();

        assert_eq!(loaded.tunnels.len(), 2);
        assert_eq!(owner.config.lock().unwrap().tunnels.len(), 2);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_stops_unloaded_removed_label_without_bootout() {
        let home = temp_home("reload-removed-unloaded");
        let runner = ScriptedRunner::new(vec![not_loaded()]);
        let owner = scripted_owner(&home, &["remove"], runner.clone());
        let candidate = config_with_tunnels(vec![]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let loaded = owner.load_config().unwrap();

        assert!(loaded.tunnels.is_empty());
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_rejects_stop_failure_and_retains_old_owner_config() {
        let home = temp_home("reload-removed-error");
        let runner = ScriptedRunner::new(vec![
            running(101),
            process(8, "", "Operation not permitted"),
        ]);
        let owner = scripted_owner(&home, &["keep", "remove"], runner.clone());
        let candidate = config_with_tunnels(vec![tunnel("keep", "/usr/bin/true")]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let error = owner.load_config().unwrap_err();

        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("配置刷新前停止"));
        assert_eq!(
            owner
                .config
                .lock()
                .unwrap()
                .tunnels
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec!["keep", "remove"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_rejects_label_that_remains_loaded_after_bootout() {
        let home = temp_home("reload-removed-still-loaded");
        let runner = ScriptedRunner::new(vec![running(102), process(0, "", ""), running(103)]);
        let owner = scripted_owner(&home, &["remove"], runner.clone());
        let candidate = config_with_tunnels(vec![]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let error = owner.load_config().unwrap_err();

        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("仍加载"));
        assert_eq!(owner.config.lock().unwrap().tunnels.len(), 1);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_attempts_all_removed_labels_before_rejecting_candidate() {
        let home = temp_home("reload-removed-partial");
        let runner = ScriptedRunner::new(vec![
            running(201),
            process(0, "", ""),
            not_loaded(),
            running(202),
            process(9, "", "Operation not permitted"),
        ]);
        let owner = scripted_owner(&home, &["first", "second"], runner.clone());
        let candidate = config_with_tunnels(vec![]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();

        let error = owner.load_config().unwrap_err();

        assert_eq!(error.code, error_code::EXECUTOR);
        assert_eq!(owner.config.lock().unwrap().tunnels.len(), 2);
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["print", "bootout", "print", "print", "bootout"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_keeps_same_loaded_label_without_automatic_restart() {
        let home = temp_home("reload-same-id-change");
        let old = tunnel("same", "/usr/bin/old");
        let runner = ScriptedRunner::new(vec![]);
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone())
            .save(&config_with_tunnels(vec![old]))
            .unwrap();
        let owner = CoreOwner::new(paths, LaunchCtlExecutor::new(runner.clone(), 501)).unwrap();

        let candidate = config_with_tunnels(vec![tunnel("same", "/usr/bin/new")]);
        ConfigStore::new(owner.paths().clone())
            .save(&candidate)
            .unwrap();
        let loaded = owner.load_config().unwrap();

        assert_eq!(loaded.tunnels[0].command, vec!["/usr/bin/new"]);
        assert_eq!(owner.config.lock().unwrap().tunnels[0].command, vec!["/usr/bin/new"]);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_rejects_invalid_candidate_without_lifecycle_side_effects() {
        let home = temp_home("reload-invalid");
        let runner = ScriptedRunner::new(vec![]);
        let owner = scripted_owner(&home, &["keep"], runner.clone());
        fs::write(
            owner.paths().config_url(),
            br#"{"version":2,"tunnels":[]}"#,
        )
        .unwrap();

        let error = owner.load_config().unwrap_err();

        assert_eq!(error.code, error_code::SCHEMA_VERSION);
        assert_eq!(owner.config.lock().unwrap().tunnels.len(), 1);
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reload_config_waits_for_same_tunnel_lifecycle_lock() {
        let home = temp_home("reload-lock");
        let paths = TunnelPaths::new(&home);
        let initial = config_with_tunnels(vec![tunnel("same", "/usr/bin/true")]);
        ConfigStore::new(paths.clone()).save(&initial).unwrap();
        let (runner, entered_rx) = BlockingRunner::new();
        let owner = Arc::new(CoreOwner::new(
            paths,
            LaunchCtlExecutor::new(runner, 501),
        ).unwrap());
        let generation = owner.begin("same").unwrap()["generation"]
            .as_u64()
            .unwrap();
        let lifecycle_owner = owner.clone();
        let lifecycle = thread::spawn(move || {
            lifecycle_owner.execute(CoreCommand::Start {
                id: "same".into(),
                generation: Some(generation),
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        ConfigStore::new(owner.paths().clone())
            .save(&config_with_tunnels(vec![]))
            .unwrap();
        let reload_owner = owner.clone();
        let reload = thread::spawn(move || reload_owner.load_config());
        thread::sleep(Duration::from_millis(20));
        owner.cancel("same", generation).unwrap();

        let lifecycle = lifecycle.join().unwrap();
        assert!(!lifecycle.ok);
        let loaded = reload.join().unwrap().unwrap();
        assert!(loaded.tunnels.is_empty());
        assert!(owner.config.lock().unwrap().tunnels.is_empty());
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn lifecycle_and_shutdown_are_json_owned() {
        let home = temp_home("lifecycle");
        let runner = ScriptedRunner::new(vec![
            not_loaded(),
            process(0, "", ""),
            running(123),
            running(456),
            running(789),
            running(321),
            process(0, "", ""),
            not_loaded(),
            running(654),
            process(0, "", ""),
            not_loaded(),
        ]);
        let owner = scripted_owner(&home, &["admin-tunnel", "reverse-ssh"], runner.clone());
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
        assert_eq!(
            serde_json::from_str::<Value>(&shutdown).unwrap()["result"]["stopped"],
            2
        );
        runner.assert_exhausted();
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
    fn shutdown_attempts_all_loaded_services() {
        let home = temp_home("shutdown-continues-after-error");
        let runner = ScriptedRunner::new(vec![
            running(101),
            process(8, "", "Operation not permitted"),
            running(202),
            process(0, "", ""),
            not_loaded(),
        ]);
        let owner = scripted_owner(&home, &["first", "second"], runner.clone());

        let error = owner.shutdown().unwrap_err();

        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("label=com.jafish.tunnelpad.first"));
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["print", "bootout", "print", "bootout", "print"],
            "第一条 bootout 失败后仍必须继续清理后续服务"
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn shutdown_failure_allows_retry_of_unconverged_services() {
        let home = temp_home("shutdown-retry-after-error");
        let runner = ScriptedRunner::new(vec![
            running(101),
            process(8, "", "Operation not permitted"),
            running(202),
            process(0, "", ""),
            not_loaded(),
            running(101),
            process(0, "", ""),
            not_loaded(),
            not_loaded(),
        ]);
        let owner = scripted_owner(&home, &["first", "second"], runner.clone());

        let first_error = owner.shutdown().unwrap_err();
        assert_eq!(first_error.code, error_code::EXECUTOR);

        let second = owner
            .shutdown()
            .expect("清理失败后应允许下一次 shutdown 重试");
        assert_eq!(second["operation"], "shutdown");
        assert_eq!(second["stopped"], 1);
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec![
                "print", "bootout", "print", "bootout", "print", "print", "bootout", "print",
                "print"
            ]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn shutdown_is_single_entry() {
        let home = temp_home("shutdown-single-entry");
        let runner = ScriptedRunner::new(vec![running(303), process(0, "", ""), not_loaded()]);
        let owner = scripted_owner(&home, &["single"], runner.clone());

        owner.shutdown().unwrap();
        let error = owner.shutdown().unwrap_err();

        assert_eq!(error.code, error_code::OWNER_CLOSED);
        assert_eq!(runner.calls().len(), 3, "重复 shutdown 不得重复查询或 bootout");
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn lifecycle_success_matrix_preserves_command_order() {
        let home = temp_home("matrix-start");
        let runner = ScriptedRunner::new(vec![not_loaded(), process(0, "", ""), running(123)]);
        let owner = scripted_owner(&home, &["matrix-start"], runner.clone());
        let result = owner.start("matrix-start").unwrap();
        assert_eq!(result["operation"], "start");
        assert_eq!(result["status"]["case"], "running");
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
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
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
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
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
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
        assert_eq!(
            owner.status("matrix-status").unwrap(),
            TunnelStatus::Running { pid: Some(2468) }
        );
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
    fn cancel_interrupts_in_flight_lifecycle_commands() {
        let home = temp_home("cancel-lock");
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone())
            .save(&config(&["cancel-lock"]))
            .unwrap();
        let (runner, entered_rx) = BlockingRunner::new();
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

        let (cancel_done_tx, cancel_done_rx) = mpsc::channel();
        let cancel_owner = owner.clone();
        let cancel = thread::spawn(move || {
            let response = cancel_owner.cancel("cancel-lock", generation).unwrap();
            cancel_done_tx.send(response).unwrap();
        });
        let response = cancel_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(response["operation"], "cancel");
        cancel.join().unwrap();
        let lifecycle = lifecycle.join().unwrap();
        assert!(!lifecycle.ok);
        assert_eq!(lifecycle.error.unwrap().code, error_code::STALE_OPERATION);
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn shutdown_cancels_in_flight_lifecycle_commands() {
        let home = temp_home("shutdown-cancel");
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone())
            .save(&config(&["shutdown-cancel"]))
            .unwrap();
        let (runner, entered_rx) = BlockingRunner::new();
        let owner = Arc::new(CoreOwner::new(paths, LaunchCtlExecutor::new(runner, 501)).unwrap());
        let generation = owner.begin("shutdown-cancel").unwrap()["generation"]
            .as_u64()
            .unwrap();

        let lifecycle_owner = owner.clone();
        let lifecycle = thread::spawn(move || {
            lifecycle_owner.execute(CoreCommand::Start {
                id: "shutdown-cancel".into(),
                generation: Some(generation),
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let shutdown = owner.shutdown().unwrap();
        assert_eq!(shutdown["operation"], "shutdown");
        let lifecycle = lifecycle.join().unwrap();
        assert!(!lifecycle.ok);
        assert_eq!(lifecycle.error.unwrap().code, error_code::STALE_OPERATION);
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn restart_cancels_in_flight_bootstrap() {
        let home = temp_home("restart-cancel-bootstrap");
        let paths = TunnelPaths::new(&home);
        ConfigStore::new(paths.clone())
            .save(&config(&["restart-cancel-bootstrap"]))
            .unwrap();
        let (runner, entered_rx) = RestartBlockingRunner::new();
        let owner =
            Arc::new(CoreOwner::new(paths, LaunchCtlExecutor::new(runner.clone(), 501)).unwrap());
        let generation = owner.begin("restart-cancel-bootstrap").unwrap()["generation"]
            .as_u64()
            .unwrap();

        let lifecycle_owner = owner.clone();
        let lifecycle = thread::spawn(move || {
            lifecycle_owner.execute(CoreCommand::Restart {
                id: "restart-cancel-bootstrap".into(),
                generation: Some(generation),
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let cancel = owner
            .cancel("restart-cancel-bootstrap", generation)
            .unwrap();
        assert_eq!(cancel["operation"], "cancel");
        let lifecycle = lifecycle.join().unwrap();
        assert!(!lifecycle.ok);
        assert_eq!(lifecycle.error.unwrap().code, error_code::STALE_OPERATION);
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["bootout", "bootstrap"]
        );
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
    fn restart_blocks_bootstrap_after_bootout_error() {
        let home = temp_home("stage0-restart-bootout-error");
        let runner = ScriptedRunner::new(vec![process(9, "", "Operation not permitted")]);
        let owner = scripted_owner(&home, &["stage0-restart-bootout-error"], runner.clone());

        let error = owner
            .restart("stage0-restart-bootout-error")
            .unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert!(error.message.contains("重启前停止 launchd 失败"));
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["bootout"],
            "bootout 失败后不得继续 bootstrap"
        );
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
        let runner = ScriptedRunner::new(vec![
            running(654),
            process(0, "", ""),
            not_loaded(),
            not_loaded(),
        ]);
        let owner = scripted_owner(&home, &["loaded", "unloaded"], runner.clone());
        let result = owner.shutdown().unwrap();
        assert_eq!(result["operation"], "shutdown");
        assert_eq!(result["stopped"], 1);
        assert_eq!(
            runner
                .calls()
                .iter()
                .map(|call| call[0].as_str())
                .collect::<Vec<_>>(),
            vec!["print", "bootout", "print", "print"]
        );
        runner.assert_exhausted();
        let _ = fs::remove_dir_all(home);

        let home = temp_home("matrix-shutdown-error");
        let runner = ScriptedRunner::new(vec![
            running(987),
            process(8, "", "Operation not permitted"),
            running(987),
        ]);
        let owner = scripted_owner(&home, &["matrix-shutdown-error"], runner.clone());
        let error = owner.shutdown().unwrap_err();
        assert_eq!(error.code, error_code::EXECUTOR);
        assert_eq!(
            owner.status("matrix-shutdown-error").unwrap(),
            TunnelStatus::Running { pid: Some(987) }
        );
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
