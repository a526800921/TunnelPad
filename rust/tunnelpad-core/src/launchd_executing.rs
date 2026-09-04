//! launchd 执行能力边界（Swift `LaunchdExecuting` 协议对等）。

use std::path::Path;

use crate::launchctl::{
    CancellationToken, ExecutorError, LaunchCtlExecutor, ProcessRunning, TunnelStatus,
};

pub trait LaunchdExecuting: Send + Sync {
    fn bootstrap(&self, label: &str, plist_path: &Path) -> Result<(), ExecutorError>;
    fn bootout(&self, label: &str) -> Result<bool, ExecutorError>;
    fn status(&self, label: &str) -> TunnelStatus;

    /// 保留 launchctl 状态读取错误，供健康恢复区分“状态未知”和普通状态。
    /// 旧 fake 默认沿用兼容的非 checked status。
    fn status_checked(&self, label: &str) -> Result<TunnelStatus, ExecutorError> {
        Ok(self.status(label))
    }

    /// 启动后读取稳定状态；旧 fake 默认复用一次 status，真实执行器可在
    /// launchd 过渡态内做有界重读。
    fn status_after_bootstrap(&self, label: &str) -> TunnelStatus {
        self.status(label)
    }

    fn bootstrap_cancellable(
        &self,
        label: &str,
        plist_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<(), ExecutorError> {
        if cancellation.is_cancelled() {
            return Err(ExecutorError::Cancelled);
        }
        self.bootstrap(label, plist_path)
    }

    fn bootout_cancellable(
        &self,
        label: &str,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        if cancellation.is_cancelled() {
            return Err(ExecutorError::Cancelled);
        }
        self.bootout(label)
    }

    /// 受管 SSH 的 bootout 后收敛能力。旧 fake 默认保持原有
    /// bootout/status 语义；真实执行器覆盖此方法实现身份核验和信号升级。
    fn stop_managed_cancellable(
        &self,
        label: &str,
        _executable_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        let stopped = self.bootout_cancellable(label, cancellation)?;
        if self.status(label) == TunnelStatus::NotLoaded {
            Ok(stopped)
        } else {
            Err(ExecutorError::ManagedProcessStillLoaded)
        }
    }
}

impl<R: ProcessRunning> LaunchdExecuting for LaunchCtlExecutor<R> {
    fn bootstrap(&self, label: &str, plist_path: &Path) -> Result<(), ExecutorError> {
        LaunchCtlExecutor::bootstrap(self, label, plist_path)
    }

    fn bootout(&self, label: &str) -> Result<bool, ExecutorError> {
        LaunchCtlExecutor::bootout(self, label)
    }

    fn status(&self, label: &str) -> TunnelStatus {
        LaunchCtlExecutor::status(self, label)
    }

    fn status_checked(&self, label: &str) -> Result<TunnelStatus, ExecutorError> {
        LaunchCtlExecutor::status_checked(self, label)
    }

    fn status_after_bootstrap(&self, label: &str) -> TunnelStatus {
        LaunchCtlExecutor::status_after_bootstrap(self, label)
    }

    fn bootstrap_cancellable(
        &self,
        label: &str,
        plist_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<(), ExecutorError> {
        LaunchCtlExecutor::bootstrap_cancellable(self, label, plist_path, cancellation)
    }

    fn bootout_cancellable(
        &self,
        label: &str,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        LaunchCtlExecutor::bootout_cancellable(self, label, cancellation)
    }

    fn stop_managed_cancellable(
        &self,
        label: &str,
        executable_path: &Path,
        cancellation: &CancellationToken,
    ) -> Result<bool, ExecutorError> {
        LaunchCtlExecutor::stop_managed_cancellable(self, label, executable_path, cancellation)
    }
}
