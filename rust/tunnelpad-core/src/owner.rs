//! 阶段 5 Rust Core owner 原型。
//!
//! 该模块先隔离验证最终 owner 的边界：一个长期存在的 Rust handle 持有
//! 配置、launchd 执行器和每条隧道的串行锁；跨边界只传 UTF-8 JSON。它不
//! 改写现有 Swift 门面，也不启用真实 App 路径，供阶段 5 Step 0 fixture
//! 与 C ABI smoke 使用。

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
    Snapshot,
    Status { id: String },
    Start { id: String },
    Stop { id: String },
    Restart { id: String },
    Remove { id: String },
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
            CoreCommand::Snapshot => self.snapshot().map(|snapshot| json!(snapshot)),
            CoreCommand::Status { id } => self.status_result(&id),
            CoreCommand::Start { id } => self.start(&id),
            CoreCommand::Stop { id } => self.stop(&id),
            CoreCommand::Restart { id } => self.restart(&id),
            CoreCommand::Remove { id } => self.remove(&id),
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
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        let tunnel = self.tunnel(id)?;
        if matches!(
            self.launchd.status(&tunnel.launchd_label()),
            TunnelStatus::Running { .. }
        ) {
            return Ok(
                json!({ "id": id, "operation": "noop", "status": self.launchd.status(&tunnel.launchd_label()) }),
            );
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
        Ok(
            json!({ "id": id, "operation": "start", "status": self.launchd.status(&tunnel.launchd_label()) }),
        )
    }

    pub fn stop(&self, id: &str) -> Result<Value, TpError> {
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        let tunnel = self.tunnel(id)?;
        let stopped = self
            .launchd
            .bootout(&tunnel.launchd_label())
            .map_err(|error| executor_error("停止", error))?;
        Ok(
            json!({ "id": id, "operation": "stop", "stopped": stopped, "status": self.launchd.status(&tunnel.launchd_label()) }),
        )
    }

    pub fn restart(&self, id: &str) -> Result<Value, TpError> {
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        let tunnel = self.tunnel(id)?;
        // 保持现有 Swift restartSync 的兼容语义：未加载或 bootout 失败
        // 不阻断后续 plist 重写/bootstrap，bootstrap 失败仍返回错误。
        let _ = self.launchd.bootout(&tunnel.launchd_label());
        let plist = write_plist(&tunnel, &self.paths).map_err(|error| {
            TpError::new(
                error_code::CONFIG_IO,
                format!("写入 launchd plist 失败：{error}"),
            )
        })?;
        self.launchd
            .bootstrap(&tunnel.launchd_label(), &plist)
            .map_err(|error| executor_error("重启", error))?;
        Ok(
            json!({ "id": id, "operation": "restart", "status": self.launchd.status(&tunnel.launchd_label()) }),
        )
    }

    pub fn remove(&self, id: &str) -> Result<Value, TpError> {
        self.ensure_open()?;
        let lock = self.lock_for(id);
        let _guard = lock.lock().expect("owner tunnel mutex 不应中毒");
        let tunnel = self.tunnel(id)?;
        if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
            self.launchd
                .bootout(&tunnel.launchd_label())
                .map_err(|error| executor_error("删除时停止", error))?;
            if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
                return Err(TpError::new(error_code::STILL_RUNNING, "实例未成功停止"));
            }
        }

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
