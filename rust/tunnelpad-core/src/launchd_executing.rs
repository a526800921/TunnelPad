//! launchd 执行能力边界（Swift `LaunchdExecuting` 协议对等）。

use std::path::Path;

use crate::launchctl::{
    CancellationToken, ExecutorError, LaunchCtlExecutor, ProcessRunning, TunnelStatus,
};

pub trait LaunchdExecuting: Send + Sync {
    fn bootstrap(&self, label: &str, plist_path: &Path) -> Result<(), ExecutorError>;
    fn bootout(&self, label: &str) -> Result<bool, ExecutorError>;
    fn status(&self, label: &str) -> TunnelStatus;

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
}
