//! demo 生命周期编排（阶段 3）：对隔离 demo 配置（`demo-` 前缀 ID、独立 home）
//! 执行完整生命周期序列。编排以 Swift 事实源为准：
//! - start/stop/restart：`TunnelLifecycleCoordinator` 同步入口语义
//! - remove：`TunnelManager.removeTunnel` 序列（停实例 → 清 plist → 删日志尽力 →
//!   配置移除与落盘失败回滚）
//! - shutdown-all：`Shutdown.stopAllManagedTunnels`（launchd bootout + killByPidfile）
//!
//! 并发所有权在 Swift（契约冻结章节）：本模块只提供同步编排，供差分与测试驱动。

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;

use crate::app_executor::AppProcessExecutor;
use crate::config_store::system_timestamp;
use crate::config_store::ConfigStore;
use crate::launchctl::TunnelStatus;
use crate::launchd_executing::LaunchdExecuting;
use crate::legacy::{self, LegacyAgent};
use crate::migration::{MigrationOutcome, TakeoverError};
use crate::paths::TunnelPaths;
use crate::plist_render::{plist_xml, write_plist};
use crate::shutdown;
use crate::{AppConfig, TunnelConfig};

/// 编排错误：只保留错误类别（错误文案文本不作跨语言等价判定）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DemoOpError {
    /// launchd 实例停止失败（removeTunnel：停止实例出错）
    StopFailed,
    /// removeTunnel：实例未成功停止
    StillRunning,
    /// removeTunnel：清理 plist 出错
    PlistCleanupFailed,
    /// 配置写入失败（removeTunnel：写入配置出错；内容已回滚）
    ConfigSaveFailed,
    /// 找不到隧道
    TunnelNotFound,
    /// demo 前缀校验失败（安全边界：拒绝非 demo- 前缀 ID）
    InvalidDemoID,
}

pub struct DemoLifecycle<L: LaunchdExecuting> {
    pub paths: TunnelPaths,
    pub launchd: L,
    pub app: AppProcessExecutor,
}

impl<L: LaunchdExecuting> DemoLifecycle<L> {
    pub fn new(paths: TunnelPaths, launchd: L) -> Self {
        let app = AppProcessExecutor::new(paths.clone());
        DemoLifecycle { paths, launchd, app }
    }

    fn validate_demo_id(&self, id: &str) -> Result<(), DemoOpError> {
        if id.starts_with("demo-") && TunnelConfig::is_valid_id(id) {
            Ok(())
        } else {
            Err(DemoOpError::InvalidDemoID)
        }
    }

    pub fn store(&self) -> ConfigStore {
        ConfigStore::new(self.paths.clone())
    }

    /// install：写入包含 demo 隧道的完整配置；launchd 隧道渲染 plist。
    pub fn install(&self, tunnels: &[TunnelConfig]) -> Result<Vec<String>, DemoOpError> {
        for tunnel in tunnels {
            self.validate_demo_id(&tunnel.id)?;
        }
        let config = AppConfig { version: 1, tunnels: tunnels.to_vec() };
        self.store().save(&config).map_err(|_| DemoOpError::ConfigSaveFailed)?;
        for tunnel in tunnels {
            if tunnel.executor == crate::ExecutorKind::Launchd {
                write_plist(tunnel, &self.paths).map_err(|_| DemoOpError::PlistCleanupFailed)?;
            }
        }
        Ok(tunnels.iter().map(|t| t.id.clone()).collect())
    }

    fn load_tunnel(&self, id: &str) -> Result<TunnelConfig, DemoOpError> {
        self.validate_demo_id(id)?;
        let config = self.store().load().config;
        config
            .tunnels
            .into_iter()
            .find(|t| t.id == id)
            .ok_or(DemoOpError::TunnelNotFound)
    }

    /// start（TunnelLifecycleCoordinator.startSync 语义）。
    pub fn start(&self, id: &str) -> Result<&'static str, DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        match tunnel.executor {
            crate::ExecutorKind::Launchd => {
                // startSync：已运行则 no-op（不重写 plist）
                if matches!(
                    self.launchd.status(&tunnel.launchd_label()),
                    TunnelStatus::Running { .. }
                ) {
                    return Ok("noop");
                }
                let plist = write_plist(&tunnel, &self.paths).map_err(|_| DemoOpError::PlistCleanupFailed)?;
                self.launchd
                    .bootstrap(&tunnel.launchd_label(), &plist)
                    .map_err(|_| DemoOpError::StopFailed)?;
                Ok("ok")
            }
            crate::ExecutorKind::App => {
                self.app.start(&tunnel).map_err(|_| DemoOpError::StopFailed)?;
                Ok("ok")
            }
        }
    }

    /// stop（TunnelLifecycleCoordinator.stopSync 语义）。
    pub fn stop(&self, id: &str) -> Result<&'static str, DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        match tunnel.executor {
            crate::ExecutorKind::Launchd => {
                self.launchd
                    .bootout(&tunnel.launchd_label())
                    .map_err(|_| DemoOpError::StopFailed)?;
                Ok("ok")
            }
            crate::ExecutorKind::App => {
                self.app.stop(&tunnel);
                Ok("ok")
            }
        }
    }

    /// restart（TunnelLifecycleCoordinator.restartSync 语义）。
    pub fn restart(&self, id: &str) -> Result<&'static str, DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        match tunnel.executor {
            crate::ExecutorKind::Launchd => {
                // restartSync：try? bootout（未加载不算错误）→ 重写 plist → bootstrap
                let _ = self.launchd.bootout(&tunnel.launchd_label());
                let plist = write_plist(&tunnel, &self.paths).map_err(|_| DemoOpError::PlistCleanupFailed)?;
                self.launchd
                    .bootstrap(&tunnel.launchd_label(), &plist)
                    .map_err(|_| DemoOpError::StopFailed)?;
                Ok("ok")
            }
            crate::ExecutorKind::App => {
                self.app.restart(&tunnel).map_err(|_| DemoOpError::StopFailed)?;
                Ok("ok")
            }
        }
    }

    pub fn status(&self, id: &str) -> Result<TunnelStatus, DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        Ok(match tunnel.executor {
            crate::ExecutorKind::Launchd => self.launchd.status(&tunnel.launchd_label()),
            crate::ExecutorKind::App => self.app.status(&tunnel.id),
        })
    }

    /// takeover：复用 MigrationService 的备份→bootout→bootstrap→验证语义，
    /// 但只允许接管到 `demo-` 配置；配置落盘由外层 demo 编排在成功后完成。
    pub fn takeover(&self, agent: &LegacyAgent) -> Result<MigrationOutcome, TakeoverError> {
        if let Some(tunnel) = legacy::tunnel_config(agent) {
            if !tunnel.id.starts_with("demo-") {
                return Err(TakeoverError::InvalidAgent {
                    label: agent.label.clone(),
                    reason: "demo 生命周期只允许接管 demo- 前缀隧道".into(),
                });
            }
        }
        let service = crate::migration::MigrationService::new(
            self.paths.clone(),
            BorrowedLaunchd(&self.launchd),
            Arc::new(|| {}),
            Arc::new(system_timestamp),
        );
        service.takeover(agent)
    }

    /// remove（TunnelManager.removeTunnel 序列）。
    /// 返回 ("ok", logWarning?)；日志清理失败仅告警不中断。
    pub fn remove(&self, id: &str) -> Result<(&'static str, bool), DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        match tunnel.executor {
            crate::ExecutorKind::Launchd => {
                if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
                    self.launchd
                        .bootout(&tunnel.launchd_label())
                        .map_err(|_| DemoOpError::StopFailed)?;
                    if self.launchd.status(&tunnel.launchd_label()) != TunnelStatus::NotLoaded {
                        return Err(DemoOpError::StillRunning);
                    }
                }
                let plist = self.paths.launchd_plist_url(&tunnel);
                if plist.exists() {
                    fs::remove_file(&plist).map_err(|_| DemoOpError::PlistCleanupFailed)?;
                }
            }
            crate::ExecutorKind::App => {
                self.app.stop(&tunnel);
            }
        }

        // 日志清理：尽力而为，失败仅告警
        let log_url = self.paths.log_url(&tunnel);
        let mut log_warning = false;
        if log_url.exists() {
            fs::remove_file(&log_url).ok();
            log_warning = log_url.exists();
        }

        // 配置移除；落盘失败回滚
        let mut config = self.store().load().config;
        let Some(index) = config.tunnels.iter().position(|t| t.id == id) else {
            return Ok(("ok", log_warning));
        };
        let removed = config.tunnels.remove(index);
        match self.store().save(&config) {
            Ok(()) => Ok(("ok", log_warning)),
            Err(_) => {
                config.tunnels.insert(index.min(config.tunnels.len()), removed);
                Err(DemoOpError::ConfigSaveFailed)
            }
        }
    }

    /// shutdown-all（Shutdown.stopAllManagedTunnels 语义）：launchd bootout +
    /// app executor 正常退出；未被当前 owner 管理的 pidfile 才走 fallback。
    pub fn shutdown_all(&self) -> usize {
        let config = self.store().load().config;
        let mut stopped = 0;
        let managed_app_ids = self.app.managed_ids();
        // 先走 app executor 的正常退出路径：除终止子进程外，它还会推进
        // generation，使已排队的 keepAlive 重启计划失效。
        self.app.shutdown_all();
        for tunnel in &config.tunnels {
            match tunnel.executor {
                crate::ExecutorKind::Launchd => {
                    if self.launchd.bootout(&tunnel.launchd_label()).unwrap_or(false) {
                        stopped += 1;
                    }
                }
                crate::ExecutorKind::App => {
                    if managed_app_ids.iter().any(|id| id == &tunnel.id) {
                        stopped += 1;
                    } else if shutdown::kill_by_pidfile(&self.paths.pidfile_url(tunnel), libc::SIGTERM) {
                        // 兼容 demo owner 之外留下的 pidfile；没有对应 app
                        // context 时不存在可推进的 generation。
                        stopped += 1;
                    }
                }
            }
        }
        stopped
    }

    /// 文件系统快照（差分事件）：各产物目录的存在性与配置条目。
    pub fn fs_snapshot(&self) -> Value {
        let config = self.store().load().config;
        json!({
            "op": "fs-snapshot",
            "configIds": config.tunnels.iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
            "launchdFiles": sorted_files(&self.paths.launchd_directory()),
            "runFiles": sorted_files(&self.paths.run_directory()),
            "logFiles": sorted_files(&self.paths.logs_directory()),
            "backupFiles": sorted_files(&self.paths.migration_backup_directory()),
        })
    }

    /// plist 内容（install 后差分用）。
    pub fn plist_content(&self, id: &str) -> Option<String> {
        let tunnel = self.load_tunnel(id).ok()?;
        let path: PathBuf = self.paths.launchd_plist_url(&tunnel);
        fs::read_to_string(path).ok()
    }

    /// 渲染（不落盘）的 plist 内容。
    pub fn rendered_plist(&self, id: &str) -> Result<String, DemoOpError> {
        let tunnel = self.load_tunnel(id)?;
        Ok(plist_xml(&tunnel, &path_string(&self.paths.log_url(&tunnel))))
    }
}

use serde_json::{json, Value};

fn path_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn sorted_files(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// 让 DemoLifecycle 能复用 MigrationService，而不复制一套接管编排；
/// 实际 launchd 所有权仍由外层 DemoLifecycle 持有。
struct BorrowedLaunchd<'a, L: LaunchdExecuting + ?Sized>(&'a L);

impl<L: LaunchdExecuting + ?Sized> LaunchdExecuting for BorrowedLaunchd<'_, L> {
    fn bootstrap(&self, label: &str, plist_path: &Path) -> Result<(), crate::launchctl::ExecutorError> {
        self.0.bootstrap(label, plist_path)
    }

    fn bootout(&self, label: &str) -> Result<bool, crate::launchctl::ExecutorError> {
        self.0.bootout(label)
    }

    fn status(&self, label: &str) -> TunnelStatus {
        self.0.status(label)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct FakeLaunchd {
        bootstraps: Mutex<usize>,
        bootouts: Mutex<usize>,
    }

    impl FakeLaunchd {
        fn new() -> Self {
            FakeLaunchd { bootstraps: Mutex::new(0), bootouts: Mutex::new(0) }
        }
    }

    impl LaunchdExecuting for FakeLaunchd {
        fn bootstrap(&self, _label: &str, _plist_path: &Path) -> Result<(), crate::launchctl::ExecutorError> {
            *self.bootstraps.lock().unwrap() += 1;
            Ok(())
        }

        fn bootout(&self, _label: &str) -> Result<bool, crate::launchctl::ExecutorError> {
            *self.bootouts.lock().unwrap() += 1;
            Ok(true)
        }

        fn status(&self, _label: &str) -> TunnelStatus {
            TunnelStatus::NotLoaded
        }
    }

    fn temp_home() -> PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let home = std::env::temp_dir().join(format!("tp-demo-test-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&home).unwrap();
        home
    }

    fn demo_tunnel() -> TunnelConfig {
        serde_json::from_value(json!({
            "id": "demo-unit",
            "name": "demo-unit",
            "command": ["/usr/bin/ssh", "-N"],
            "executor": "launchd",
            "keepAlive": true,
            "throttleInterval": 10
        }))
        .unwrap()
    }

    #[test]
    fn install_rejects_non_demo_ids() {
        let home = temp_home();
        let lifecycle = DemoLifecycle::new(TunnelPaths::new(&home), FakeLaunchd::new());
        let mut tunnel = demo_tunnel();
        tunnel.id = "admin-tunnel".into();

        assert_eq!(lifecycle.install(&[tunnel]), Err(DemoOpError::InvalidDemoID));
        assert!(!lifecycle.paths.config_url().exists());
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn launchd_lifecycle_cleans_config_and_plist() {
        let home = temp_home();
        let paths = TunnelPaths::new(&home);
        let fake = FakeLaunchd::new();
        let lifecycle = DemoLifecycle::new(paths.clone(), fake);
        let tunnel = demo_tunnel();

        assert_eq!(lifecycle.install(&[tunnel.clone()]).unwrap(), vec![tunnel.id.clone()]);
        assert!(paths.config_url().exists());
        assert!(paths.launchd_plist_url(&tunnel).exists());
        assert_eq!(lifecycle.start(&tunnel.id), Ok("ok"));
        assert_eq!(lifecycle.stop(&tunnel.id), Ok("ok"));
        assert_eq!(lifecycle.remove(&tunnel.id), Ok(("ok", false)));

        assert!(lifecycle.store().load().config.tunnels.is_empty());
        assert!(!paths.launchd_plist_url(&tunnel).exists());
        assert_eq!(lifecycle.fs_snapshot()["runFiles"], json!([]));
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn takeover_rejects_non_demo_before_launchd() {
        let home = temp_home();
        let lifecycle = DemoLifecycle::new(TunnelPaths::new(&home), FakeLaunchd::new());
        let agent = crate::legacy::LegacyAgent {
            label: "com.jafish.motorcycle-manual.admin-tunnel".into(),
            plist_path: home.join("legacy.plist"),
            program_arguments: vec!["/usr/bin/ssh".into()],
            keep_alive: true,
            run_at_load: true,
            throttle_interval: Some(10),
        };

        assert!(matches!(
            lifecycle.takeover(&agent),
            Err(crate::migration::TakeoverError::InvalidAgent { .. })
        ));
        assert!(!lifecycle.paths.migration_backup_directory().exists());
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn shutdown_all_invalidates_app_restart_plan() {
        let home = temp_home();
        let paths = TunnelPaths::new(&home);
        let lifecycle = DemoLifecycle::new(paths, FakeLaunchd::new());
        let tunnel: TunnelConfig = serde_json::from_value(json!({
            "id": "demo-race-unit",
            "name": "demo-race-unit",
            "command": ["/usr/bin/true"],
            "executor": "app",
            "keepAlive": true,
            "throttleInterval": 1
        }))
        .unwrap();
        lifecycle.install(&[tunnel.clone()]).unwrap();
        lifecycle.app.start(&tunnel).unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let plan = loop {
            if let Some(plan) = lifecycle.app.handle_exits().into_iter().next() {
                break plan;
            }
            assert!(std::time::Instant::now() < deadline, "应观察到 app 迟到重启计划");
            std::thread::sleep(std::time::Duration::from_millis(20));
        };

        lifecycle.shutdown_all();
        assert!(!lifecycle.app.restart_if_current(&plan).unwrap());
        assert_eq!(lifecycle.app.status(&tunnel.id), TunnelStatus::NotLoaded);
        fs::remove_dir_all(home).ok();
    }
}
