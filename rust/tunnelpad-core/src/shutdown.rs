//! 退出清理编排（Swift `Shutdown.stopAllManagedTunnels` 的可注入对等）。
//! 语义：退出 = 停止全部托管隧道（launchd bootout + app 执行器按 pidfile 终止）。
//! 直接读 config.json，不依赖 UI 层对象，可从任意线程调用。
//!
//! 差分说明：Swift 事实源硬编码 SystemProcessRunner（真实 launchctl），
//! 阶段 0–3 禁止真实 launchctl 调用，因此本组件不进入跨语言差分矩阵，
//! 由 Rust 单元测试（fake 执行器）覆盖编排语义。

use std::path::Path;

use crate::config_store::ConfigStore;
use crate::launchd_executing::LaunchdExecuting;
use crate::paths::TunnelPaths;

/// 停止全部托管隧道，返回成功停止的条数。
pub fn stop_all_managed_tunnels(
    paths: &TunnelPaths,
    launchd: &dyn LaunchdExecuting,
    kill_by_pidfile: &dyn Fn(&Path) -> bool,
) -> usize {
    let store = ConfigStore::new(paths.clone());
    let config = store.load().config;
    let mut stopped = 0;
    for tunnel in &config.tunnels {
        match tunnel.executor {
            crate::ExecutorKind::Launchd => {
                if launchd.bootout(&tunnel.launchd_label()).unwrap_or(false) {
                    stopped += 1;
                }
            }
            crate::ExecutorKind::App => {
                if kill_by_pidfile(&paths.pidfile_url(tunnel)) {
                    stopped += 1;
                }
            }
        }
    }
    stopped
}
/// Swift `Shutdown.killByPidfile` 对等：读 pidfile → kill(pid,0) 预检 →
/// 默认 SIGTERM；所有路径都清理 pidfile（进程已不存在/文件不可读也算清理）。
pub fn kill_by_pidfile(at: &Path, signal_number: i32) -> bool {
    let Some(content) = std::fs::read_to_string(at).ok() else {
        let _ = std::fs::remove_file(at);
        return false;
    };
    let Ok(pid) = content.trim().parse::<i32>() else {
        let _ = std::fs::remove_file(at);
        return false;
    };
    // # Safety: kill(pid, 0) 为存在性预检，无副作用。
    unsafe {
        if libc::kill(pid, 0) != 0 {
            let _ = std::fs::remove_file(at);
            return false;
        }
        libc::kill(pid, signal_number);
    }
    let _ = std::fs::remove_file(at);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launchctl::{ExecutorError, TunnelStatus};
    use std::path::{Path, PathBuf};
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
        let config = AppConfigHelper::config_with(vec![
            ("launchd-a", "launchd"),
            ("app-a", "app"),
            ("launchd-b", "launchd"),
        ]);
        std::fs::create_dir_all(paths.support_directory()).unwrap();
        std::fs::write(paths.config_url(), serde_json::to_string(&config).unwrap()).unwrap();

        let launchd = FakeLaunchd {
            bootouts: Mutex::new(vec![]),
            succeed: true,
        };
        let app_kills: Mutex<Vec<PathBuf>> = Mutex::new(vec![]);
        let stopped = stop_all_managed_tunnels(&paths, &launchd, &|pidfile| {
            app_kills.lock().unwrap().push(pidfile.to_path_buf());
            true
        });

        assert_eq!(stopped, 3);
        assert_eq!(
            *launchd.bootouts.lock().unwrap(),
            vec![
                "com.jafish.tunnelpad.launchd-a",
                "com.jafish.tunnelpad.launchd-b"
            ]
        );
        let kills = app_kills.lock().unwrap();
        assert_eq!(kills.len(), 1);
        assert!(kills[0].ends_with("run/app-a.pid"));

        // bootout 失败（未加载 false）不计入
        let launchd = FakeLaunchd {
            bootouts: Mutex::new(vec![]),
            succeed: false,
        };
        let stopped = stop_all_managed_tunnels(&paths, &launchd, &|_| false);
        assert_eq!(stopped, 0);

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn kill_by_pidfile_mirrors_swift_semantics() {
        let home = std::env::temp_dir().join(format!("tp-killpid-test-{}", std::process::id()));
        let paths = TunnelPaths::new(&home);
        std::fs::create_dir_all(paths.run_directory()).unwrap();

        // 存活子进程：SIGTERM 终止 + pidfile 被清理
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("2")
            .spawn()
            .unwrap();
        let live_pidfile = paths.run_directory().join("live.pid");
        std::fs::write(&live_pidfile, format!("{}\n", child.id())).unwrap();
        assert!(kill_by_pidfile(&live_pidfile, libc::SIGTERM));
        assert!(!live_pidfile.exists());
        child.wait().unwrap();

        // 已退出的进程：预检失败 → false + pidfile 清理
        let mut exited = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let exited_pid = exited.id() as i32;
        exited.wait().unwrap();
        let dead_pidfile = paths.run_directory().join("dead.pid");
        std::fs::write(&dead_pidfile, format!("{exited_pid}\n")).unwrap();
        assert!(!kill_by_pidfile(&dead_pidfile, libc::SIGTERM));
        assert!(!dead_pidfile.exists());

        // 内容非法 → false + pidfile 清理
        let garbage = paths.run_directory().join("garbage.pid");
        std::fs::write(&garbage, "not-a-pid").unwrap();
        assert!(!kill_by_pidfile(&garbage, libc::SIGTERM));
        assert!(!garbage.exists());

        // 文件缺失 → false
        assert!(!kill_by_pidfile(
            &paths.run_directory().join("missing.pid"),
            libc::SIGTERM
        ));

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
