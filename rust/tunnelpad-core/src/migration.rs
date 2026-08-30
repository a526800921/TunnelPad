//! 迁移接管编排（Swift `MigrationService` 对等）：
//! 备份（移动）→ bootout 旧 → bootstrap 新 → 验证运行。
//! 备份先行是硬约束：备份完成前绝不触碰 launchd；bootstrap 失败立即回滚。
//! 错误语义与 Swift `throws` 对齐：bootout/bootstrap 失败原样重抛执行器错误；
//! 只有回滚失败才包装为 RollbackFailed。错误文案文本不作跨语言字节等价判定。

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use serde::Serialize;

use crate::config_store::TimestampFn;
use crate::launchctl::{ExecutorError, TunnelStatus};
use crate::launchd_executing::LaunchdExecuting;
use crate::legacy::{self, LegacyAgent};
use crate::paths::TunnelPaths;
use crate::plist_render::write_plist;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MigrationOutcome {
    pub tunnel: crate::TunnelConfig,
    pub backup_path: PathBuf,
    pub rolled_back: bool,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "case", rename_all = "camelCase")]
pub enum TakeoverError {
    #[serde(rename_all = "camelCase")]
    InvalidAgent { label: String, reason: String },
    #[serde(rename_all = "camelCase")]
    BackupFailed { label: String, underlying: String },
    #[serde(rename_all = "camelCase")]
    Executor { error: ExecutorError },
    #[serde(rename_all = "camelCase")]
    Io { underlying: String },
    #[serde(rename_all = "camelCase")]
    VerifyFailed { label: String },
    #[serde(rename_all = "camelCase")]
    RollbackFailed { label: String, reason: String },
}

pub struct MigrationService<L: LaunchdExecuting> {
    pub paths: TunnelPaths,
    pub executor: L,
    /// 轮询间隔（测试注入 no-op 免等待）。
    pub poll_delay: Arc<dyn Fn() + Send + Sync>,
    pub timestamp: TimestampFn,
}

impl<L: LaunchdExecuting> MigrationService<L> {
    pub fn new(
        paths: TunnelPaths,
        executor: L,
        poll_delay: Arc<dyn Fn() + Send + Sync>,
        timestamp: TimestampFn,
    ) -> Self {
        MigrationService {
            paths,
            executor,
            poll_delay,
            timestamp,
        }
    }

    /// 接管单个旧 agent。任一步失败即回滚该条（恢复备份 plist 并 bootstrap 旧 agent）。
    pub fn takeover(&self, agent: &LegacyAgent) -> Result<MigrationOutcome, TakeoverError> {
        let tunnel = legacy::tunnel_config(agent)
            .filter(|t| !t.command.is_empty())
            .ok_or_else(|| TakeoverError::InvalidAgent {
                label: agent.label.clone(),
                reason: "无法从 Label 派生合法隧道 id，或 ProgramArguments 为空".into(),
            })?;

        // 备份先行；备份失败直接抛出，不进入回滚分支。
        let backup_path = self
            .backup(agent)
            .map_err(|e| TakeoverError::BackupFailed {
                label: agent.label.clone(),
                underlying: e,
            })?;

        let new_label = tunnel.launchd_label();
        let tunnel_name = tunnel.name.clone();
        match self.takeover_steps(agent, &tunnel, &new_label) {
            Ok(()) => Ok(MigrationOutcome {
                tunnel,
                backup_path,
                rolled_back: false,
                message: format!("接管完成：{} 已由 {} 接管并运行", tunnel_name, new_label),
            }),
            Err(step_error) => match self.rollback(agent, &backup_path, &new_label) {
                Ok(()) => Err(step_error),
                Err(rollback_reason) => Err(TakeoverError::RollbackFailed {
                    label: agent.label.clone(),
                    reason: format!(
                        "回滚失败（需人工恢复备份 {}）：{}；原始错误：{}",
                        backup_path.display(),
                        rollback_reason,
                        describe(&step_error)
                    ),
                }),
            },
        }
    }

    fn takeover_steps(
        &self,
        agent: &LegacyAgent,
        tunnel: &crate::TunnelConfig,
        new_label: &str,
    ) -> Result<(), TakeoverError> {
        // 旧 plist 已移走；bootout 只卸载已加载实例，未加载不算错误。
        self.executor
            .bootout(&agent.label)
            .map_err(|error| TakeoverError::Executor { error })?;
        let new_plist = write_plist(tunnel, &self.paths).map_err(|e| TakeoverError::Io {
            underlying: e.to_string(),
        })?;
        self.executor
            .bootstrap(new_label, &new_plist)
            .map_err(|error| TakeoverError::Executor { error })?;
        self.verify_running(new_label)
    }

    /// 备份 = 把旧 plist 移动到 migration-backup（移动而非复制）。
    fn backup(&self, agent: &LegacyAgent) -> Result<PathBuf, String> {
        fs::create_dir_all(self.paths.migration_backup_directory()).map_err(|e| e.to_string())?;
        let stamp = (self.timestamp)();
        let mut candidate = self
            .paths
            .migration_backup_directory()
            .join(format!("{stamp}-{}.plist", agent.label));
        let mut counter = 1;
        while candidate.exists() {
            candidate = self
                .paths
                .migration_backup_directory()
                .join(format!("{stamp}-{counter}-{}.plist", agent.label));
            counter += 1;
        }
        fs::rename(&agent.plist_path, &candidate).map_err(|e| e.to_string())?;
        Ok(candidate)
    }

    /// 验证新 agent 真正进入 running（bootstrap + RunAtLoad 后给 launchd 一点启动时间）。
    fn verify_running(&self, label: &str) -> Result<(), TakeoverError> {
        for _ in 0..20 {
            if matches!(self.executor.status(label), TunnelStatus::Running { .. }) {
                return Ok(());
            }
            (self.poll_delay)();
        }
        Err(TakeoverError::VerifyFailed {
            label: label.to_string(),
        })
    }

    fn rollback(
        &self,
        agent: &LegacyAgent,
        backup_path: &PathBuf,
        new_label: &str,
    ) -> Result<(), String> {
        let _ = self.executor.bootout(new_label);
        // 若旧实例此前 bootout 失败仍在运行，这里补一次；已卸载则 not-found 不算错误。
        let _ = self.executor.bootout(&agent.label);
        fs::rename(backup_path, &agent.plist_path).map_err(|e| e.to_string())?;
        self.executor
            .bootstrap(&agent.label, &agent.plist_path)
            .map_err(|e| format!("{e:?}"))?;
        Ok(())
    }
}

/// 人类可读的错误描述（对应 Swift `String(describing:)`，仅用于文案，不参与差分判定）。
fn describe(error: &TakeoverError) -> String {
    match error {
        TakeoverError::InvalidAgent { label, reason } => {
            format!("invalidAgent(label: {label}, reason: {reason})")
        }
        TakeoverError::BackupFailed { label, underlying } => {
            format!("backupFailed(label: {label}, underlying: {underlying})")
        }
        TakeoverError::Executor { error } => format!("{error:?}"),
        TakeoverError::Io { underlying } => format!("io error: {underlying}"),
        TakeoverError::VerifyFailed { label } => format!("verifyFailed(label: {label})"),
        TakeoverError::RollbackFailed { label, reason } => {
            format!("rollbackFailed(label: {label}, reason: {reason})")
        }
    }
}
