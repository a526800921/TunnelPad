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

/// 与 Swift `ConfigStore.timestamp` 同格式（yyyyMMdd-HHmmss），使用系统本地时区。
pub fn system_timestamp() -> String {
    config_timestamp_at(now_secs())
}

/// 与 Swift `AppProcessExecutor.timestamp` 同格式（yyyy-MM-dd HH:mm:ss），使用系统本地时区。
pub fn local_log_timestamp() -> String {
    log_timestamp_at(now_secs())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn config_timestamp_at(secs: u64) -> String {
    let (year, month, day, h, m, s) = local_or_utc_components(secs);
    format!("{year:04}{month:02}{day:02}-{h:02}{m:02}{s:02}")
}

fn log_timestamp_at(secs: u64) -> String {
    let (year, month, day, h, m, s) = local_or_utc_components(secs);
    format!("{year:04}-{month:02}-{day:02} {h:02}:{m:02}:{s:02}")
}

/// Foundation `DateFormatter` 默认使用系统本地时区；使用 `localtime_r` 保持 Rust
/// 生成的损坏留档、迁移备份和 app 日志与 Swift 的墙上时间一致。
fn local_or_utc_components(secs: u64) -> (i64, u32, u32, u32, u32, u32) {
    local_components(secs).unwrap_or_else(|| utc_components(secs))
}

fn local_components(secs: u64) -> Option<(i64, u32, u32, u32, u32, u32)> {
    let seconds: libc::time_t = secs.try_into().ok()?;
    let mut local = std::mem::MaybeUninit::<libc::tm>::zeroed();
    // SAFETY: `seconds` 是有效的 time_t；`localtime_r` 写入已分配的 tm。
    let result = unsafe { libc::localtime_r(&seconds, local.as_mut_ptr()) };
    if result.is_null() {
        return None;
    }
    // SAFETY: 非空返回值表示 localtime_r 已初始化 tm。
    let local = unsafe { local.assume_init() };
    Some((
        local.tm_year as i64 + 1900,
        local.tm_mon as u32 + 1,
        local.tm_mday as u32,
        local.tm_hour as u32,
        local.tm_min as u32,
        local.tm_sec as u32,
    ))
}

fn utc_components(secs: u64) -> (i64, u32, u32, u32, u32, u32) {
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (year, month, day) = civil_from_days(days as i64);
    (year, month, day, h as u32, m as u32, s as u32)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::sync::{Mutex, MutexGuard};

    unsafe extern "C" {
        fn tzset();
    }

    static TZ_LOCK: Mutex<()> = Mutex::new(());

    struct TimezoneGuard {
        previous: Option<OsString>,
        _lock: MutexGuard<'static, ()>,
    }

    impl TimezoneGuard {
        fn set(value: &str) -> Self {
            let lock = TZ_LOCK.lock().expect("时区测试锁不应中毒");
            let previous = std::env::var_os("TZ");
            std::env::set_var("TZ", value);
            // SAFETY: 测试串行持有 TZ_LOCK，避免并发修改进程时区状态。
            unsafe { tzset() };
            Self { previous, _lock: lock }
        }
    }

    impl Drop for TimezoneGuard {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => std::env::set_var("TZ", value),
                None => std::env::remove_var("TZ"),
            }
            // SAFETY: 恢复动作仍在持有 TZ_LOCK 时执行。
            unsafe { tzset() };
        }
    }

    #[test]
    fn fixed_epoch_uses_local_components_and_swift_formats() {
        let _lock = TZ_LOCK.lock().expect("时区测试锁不应中毒");
        let (year, month, day, hour, minute, second) = local_or_utc_components(0);
        assert_eq!(
            config_timestamp_at(0),
            format!("{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}")
        );
        assert_eq!(
            log_timestamp_at(0),
            format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}")
        );
        assert_eq!(config_timestamp_at(0).len(), 15);
        assert_eq!(log_timestamp_at(0).len(), 19);
        assert!((1..=12).contains(&month));
        assert!((1..=31).contains(&day));
        assert!(hour < 24);
        assert!(minute < 60);
        assert!(second < 60);
    }

    #[test]
    fn public_timestamps_use_local_clock_and_expected_shapes() {
        let _lock = TZ_LOCK.lock().expect("时区测试锁不应中毒");
        let config = system_timestamp();
        let log = local_log_timestamp();
        assert_eq!(config.len(), 15);
        assert_eq!(log.len(), 19);
        assert_eq!(config.as_bytes()[8], b'-');
        assert_eq!(log.as_bytes()[4], b'-');
        assert_eq!(log.as_bytes()[7], b'-');
        assert_eq!(log.as_bytes()[10], b' ');
    }

    #[test]
    fn fixed_epochs_match_known_timezone_and_dst_offsets() {
        let utc = TimezoneGuard::set("UTC0");
        assert_eq!(local_components(0), Some((1970, 1, 1, 0, 0, 0)));
        assert_eq!(config_timestamp_at(0), "19700101-000000");
        assert_eq!(log_timestamp_at(0), "1970-01-01 00:00:00");
        drop(utc);

        let shanghai = TimezoneGuard::set("CST-8");
        assert_eq!(local_components(0), Some((1970, 1, 1, 8, 0, 0)));
        assert_eq!(config_timestamp_at(0), "19700101-080000");
        assert_eq!(log_timestamp_at(0), "1970-01-01 08:00:00");
        drop(shanghai);

        let _pacific = TimezoneGuard::set("PST8PDT,M3.2.0,M11.1.0");
        assert_eq!(
            local_components(1_704_067_200),
            Some((2023, 12, 31, 16, 0, 0))
        );
        assert_eq!(
            local_components(1_719_792_000),
            Some((2024, 6, 30, 17, 0, 0))
        );
    }
}
