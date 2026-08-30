//! 集中管理 TunnelPad 的全部磁盘路径（Swift `TunnelPaths` 对等）。
//! 测试可注入 home 目录。

use std::path::{Path, PathBuf};

use crate::TunnelConfig;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelPaths {
    pub home_directory: PathBuf,
}

impl TunnelPaths {
    pub fn new(home_directory: impl Into<PathBuf>) -> Self {
        TunnelPaths {
            home_directory: home_directory.into(),
        }
    }

    /// TunnelPad 自己的 Application Support 目录（生成的 launchd plist 存这里）。
    pub fn support_directory(&self) -> PathBuf {
        self.home_directory
            .join("Library/Application Support/TunnelPad")
    }

    pub fn config_url(&self) -> PathBuf {
        self.support_directory().join("config.json")
    }

    pub fn launchd_directory(&self) -> PathBuf {
        self.support_directory().join("launchd")
    }

    pub fn migration_backup_directory(&self) -> PathBuf {
        self.support_directory().join("migration-backup")
    }

    /// app 执行器子进程的 pidfile 目录。
    pub fn run_directory(&self) -> PathBuf {
        self.support_directory().join("run")
    }

    pub fn pidfile_url(&self, tunnel: &TunnelConfig) -> PathBuf {
        self.run_directory().join(format!("{}.pid", tunnel.id))
    }

    /// 日志放 `~/Library/Logs/TunnelPad`。
    pub fn logs_directory(&self) -> PathBuf {
        self.home_directory.join("Library/Logs/TunnelPad")
    }

    pub fn launch_agents_directory(&self) -> PathBuf {
        self.home_directory.join("Library/LaunchAgents")
    }

    pub fn launchd_plist_url(&self, tunnel: &TunnelConfig) -> PathBuf {
        self.launchd_directory()
            .join(format!("{}.plist", tunnel.launchd_label()))
    }

    pub fn log_url(&self, tunnel: &TunnelConfig) -> PathBuf {
        self.logs_directory().join(format!("{}.log", tunnel.id))
    }
}

/// `Path` 展示用的可携带分隔符字符串（Swift `URL.path` 语义：绝对路径字符串）。
pub fn path_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}
