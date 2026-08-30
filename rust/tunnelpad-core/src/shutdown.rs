//! 退出清理编排（Swift `Shutdown.stopAllManagedTunnels` 的可注入对等）。
//! 语义：退出 = 停止全部托管 launchd 隧道。
//! 直接读 config.json，不依赖 UI 层对象，可从任意线程调用。
//!
//! 差分说明：Swift 事实源硬编码 SystemProcessRunner（真实 launchctl），
//! 阶段 0–3 禁止真实 launchctl 调用，因此本组件不进入跨语言差分矩阵，
//! 由 Rust 单元测试（fake 执行器）覆盖编排语义。

use crate::config_store::ConfigStore;
use crate::launchd_executing::LaunchdExecuting;
use crate::paths::TunnelPaths;

/// 停止全部托管隧道，返回成功停止的条数。
pub fn stop_all_managed_tunnels(paths: &TunnelPaths, launchd: &dyn LaunchdExecuting) -> usize {
    let store = ConfigStore::new(paths.clone());
    let config = store.load().config;
    let mut stopped = 0;
    for tunnel in &config.tunnels {
        if launchd.bootout(&tunnel.launchd_label()).unwrap_or(false) {
            stopped += 1;
        }
    }
    stopped
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launchctl::{ExecutorError, TunnelStatus};
    use std::path::Path;
    use std::sync::Mutex;

    struct FakeLaunchd {
        bootouts: Mutex<Vec<String>>,
        succeed: bool,
    }

    impl LaunchdExecuting for FakeLaunchd {
        fn bootstrap(&self, _label: &str, _plist_path: &Path) -> Result<(), ExecutorError> {
            unimplemented!("stop-all 不调用 bootstrap")
        }
        fn bootout(&self, label: &str) -> Result<bool, ExecutorError> {
            self.bootouts.lock().unwrap().push(label.to_string());
            Ok(self.succeed)
        }
        fn status(&self, _label: &str) -> TunnelStatus {
            TunnelStatus::NotLoaded
        }
    }

    #[test]
    fn counts_only_successful_stops() {
        let home = std::env::temp_dir().join(format!("tp-shutdown-test-{}", std::process::id()));
        let paths = TunnelPaths::new(&home);
        let config =
            AppConfigHelper::config_with(vec![("launchd-a", "launchd"), ("launchd-b", "launchd")]);
        std::fs::create_dir_all(paths.support_directory()).unwrap();
        std::fs::write(paths.config_url(), serde_json::to_string(&config).unwrap()).unwrap();

        let launchd = FakeLaunchd {
            bootouts: Mutex::new(vec![]),
            succeed: true,
        };
        let stopped = stop_all_managed_tunnels(&paths, &launchd);

        assert_eq!(stopped, 2);
        assert_eq!(
            *launchd.bootouts.lock().unwrap(),
            vec![
                "com.jafish.tunnelpad.launchd-a",
                "com.jafish.tunnelpad.launchd-b"
            ]
        );
        // bootout 失败（未加载 false）不计入
        let launchd = FakeLaunchd {
            bootouts: Mutex::new(vec![]),
            succeed: false,
        };
        let stopped = stop_all_managed_tunnels(&paths, &launchd);
        assert_eq!(stopped, 0);

        std::fs::remove_dir_all(&home).ok();
    }

    struct AppConfigHelper;
    impl AppConfigHelper {
        fn config_with(items: Vec<(&str, &str)>) -> crate::AppConfig {
            let tunnels: Vec<crate::TunnelConfig> = items
                .into_iter()
                .map(|(id, executor)| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "name": id, "command": ["/bin/true"], "executor": executor
                    }))
                    .unwrap()
                })
                .collect();
            crate::AppConfig {
                version: 1,
                tunnels,
            }
        }
    }
}
