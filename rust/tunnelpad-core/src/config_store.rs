//! config.json 读写与损坏恢复（Swift `ConfigStore` 对等）。

use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::apple_json::app_config_to_apple_json;
use crate::paths::TunnelPaths;
use crate::plist_render::write_atomic;
use crate::{AppConfig, CONFIG_SCHEMA_VERSION};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigLoadResult {
    pub config: AppConfig,
    /// 因损坏或不兼容被改名留档的原文件位置（无则 None）。
    pub recovered_from: Option<PathBuf>,
}

pub type TimestampFn = Arc<dyn Fn() -> String + Send + Sync>;

/// config.json 持久化：损坏/版本不兼容 → 改名留档 → 重建空配置。
pub struct ConfigStore {
    pub paths: TunnelPaths,
    pub timestamp: TimestampFn,
}

impl ConfigStore {
    pub fn new(paths: TunnelPaths) -> Self {
        ConfigStore { paths, timestamp: Arc::new(system_timestamp) }
    }

    pub fn with_timestamp(paths: TunnelPaths, timestamp: TimestampFn) -> Self {
        ConfigStore { paths, timestamp }
    }

    pub fn load(&self) -> ConfigLoadResult {
        let url = self.paths.config_url();
        if !url.exists() {
            return ConfigLoadResult { config: AppConfig::default_config(), recovered_from: None };
        }
        match fs::read(&url)
            .map_err(|e| e.to_string())
            .and_then(|bytes| parse_config_bytes(&bytes))
        {
            Ok(config) => ConfigLoadResult { config, recovered_from: None },
            Err(_) => {
                let _ = fs::create_dir_all(self.paths.support_directory());
                let archive = self
                    .paths
                    .support_directory()
                    .join(format!("config.json.corrupt-{}", (self.timestamp)()));
                let _ = fs::rename(&url, &archive);
                ConfigLoadResult { config: AppConfig::default_config(), recovered_from: Some(archive) }
            }
        }
    }

    pub fn save(&self, config: &AppConfig) -> io::Result<()> {
        fs::create_dir_all(self.paths.support_directory())?;
        let data = app_config_to_apple_json(config);
        write_atomic(&self.paths.config_url(), data.as_bytes())
    }
}

/// 与 Swift `AppConfig.init(from:)` 同语义的解码入口：
/// 结构解析失败、缺字段、id/command 校验失败、version != 1 都算"损坏"。
pub fn parse_config_bytes(bytes: &[u8]) -> Result<AppConfig, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| e.to_string())?;
    crate::parse_config_envelope(text).map_err(|e| e.message)
}

impl AppConfig {
    pub fn default_config() -> Self {
        AppConfig { version: CONFIG_SCHEMA_VERSION, tunnels: vec![] }
    }
}

/// 与 Swift `ConfigStore.timestamp` 同格式（yyyyMMdd-HHmmss）。
/// 注：Swift 使用本地时区；Rust 默认实现使用 UTC（差分测试归一化时间戳，
/// 不参与行为等价判定）。
pub fn system_timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (year, month, day) = civil_from_days(days as i64);
    format!("{year:04}{month:02}{day:02}-{h:02}{m:02}{s:02}")
}

/// 与 Swift `AppProcessExecutor.timestamp` 同格式（yyyy-MM-dd HH:mm:ss，UTC）。
pub fn utc_log_timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (year, month, day) = civil_from_days(days as i64);
    format!("{year:04}-{month:02}-{day:02} {h:02}:{m:02}:{s:02}")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
