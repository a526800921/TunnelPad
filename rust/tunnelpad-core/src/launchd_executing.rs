//! launchd 执行能力边界（Swift `LaunchdExecuting` 协议对等）。

use std::path::Path;

use crate::launchctl::{ExecutorError, LaunchCtlExecutor, ProcessRunning, TunnelStatus};

pub trait LaunchdExecuting: Send + Sync {
    fn bootstrap(&self, label: &str, plist_path: &Path) -> Result<(), ExecutorError>;
    fn bootout(&self, label: &str) -> Result<bool, ExecutorError>;
    fn status(&self, label: &str) -> TunnelStatus;
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
}
