//! tunnelpad-core：TunnelPadCore 的 Rust 对等模型（阶段 1 契约原型）。
//!
//! 类型形状镜像 Swift `Sources/TunnelPadCore/` 的 `AppConfig`/`TunnelConfig`/
//! `TunnelStatus`/`ProbeResult`；字段顺序与 Swift `CodingKeys` 声明顺序一致
//! （规范形状）。跨语言等价性按解码后语义判定——Swift `JSONEncoder` 无
//! sortedKeys 时键序不确定且转义 `/`，不作字节级参照（2026-08-30 独立
//! 复核实测）；缺省值与可选字段的省略行为与 Swift 解码/编码语义对齐。
//!
//! 契约版本：[`ABI_VERSION`] = 1。演进规则（阶段 1 冻结）：
//! 只允许追加新函数与追加错误码；任何破坏性变化必须递增 ABI 版本。

pub mod app_executor;
pub mod apple_json;
pub mod config_store;
pub mod demo;
pub mod ffi;
pub mod launchctl;
pub mod launchd_executing;
pub mod legacy;
pub mod log_tail;
pub mod migration;
pub mod owner;
pub mod owner_ffi;
pub mod paths;
pub mod plist_render;
pub mod probe;
pub mod shutdown;
pub mod ssh_command;
pub mod tunnel_id;

use serde::{Deserialize, Serialize};

/// C ABI 契约版本。当前为 1（阶段 1 冻结）。
pub const ABI_VERSION: u32 = 1;

pub const CONFIG_SCHEMA_VERSION: i64 = 1;

/// 错误码（阶段 1 冻结；只允许追加）。
pub mod error_code {
    pub const OK: u32 = 0;
    pub const INVALID_JSON: u32 = 1;
    pub const SCHEMA_VERSION: u32 = 2;
    pub const INVALID_ID: u32 = 3;
    pub const INVALID_COMMAND: u32 = 4;
    pub const INVALID_ARGUMENT: u32 = 5;
    pub const OWNER_COMMAND: u32 = 6;
    pub const UNSUPPORTED_EXECUTOR: u32 = 7;
    pub const TUNNEL_NOT_FOUND: u32 = 8;
    pub const OWNER_CLOSED: u32 = 9;
    pub const EXECUTOR: u32 = 10;
    pub const CONFIG_IO: u32 = 11;
    pub const STILL_RUNNING: u32 = 12;
}

/// 跨边界错误：`code` 取 [`error_code`] 常量，`message` 语义对齐 Swift 抛错文案。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TpError {
    pub code: u32,
    pub message: String,
}

impl TpError {
    pub fn new(code: u32, message: impl Into<String>) -> Self {
        TpError { code, message: message.into() }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExecutorKind {
    #[default]
    #[serde(rename = "launchd")]
    Launchd,
    #[serde(rename = "app")]
    App,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeConfig {
    pub url: String,
    #[serde(default = "default_expected_statuses")]
    pub expected_statuses: Vec<i32>,
}

fn default_expected_statuses() -> Vec<i32> {
    vec![200]
}

/// 隧道配置。解码语义对齐 Swift `TunnelConfig.init(from:)`：
/// 允许省略带默认值的字段；`probe` 缺省即不探测；id/command 非法时拒绝。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelConfig {
    pub id: String,
    pub name: String,
    pub command: Vec<String>,
    #[serde(default)]
    pub executor: ExecutorKind,
    #[serde(default = "default_true")]
    pub keep_alive: bool,
    #[serde(default = "default_throttle_interval")]
    pub throttle_interval: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub probe: Option<ProbeConfig>,
}

fn default_true() -> bool {
    true
}

fn default_throttle_interval() -> i64 {
    10
}

impl TunnelConfig {
    /// 与 Swift `TunnelConfig.idPattern` 一致：`^[a-z0-9-]+$`。
    pub fn is_valid_id(id: &str) -> bool {
        !id.is_empty()
            && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    }

    /// 与 Swift `TunnelConfig.launchdLabelPrefix` 一致。
    pub fn launchd_label(&self) -> String {
        format!("com.jafish.tunnelpad.{}", self.id)
    }
}

/// config.json 顶层结构。version 必须等于 1，否则按损坏恢复处理。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppConfig {
    pub version: i64,
    pub tunnels: Vec<TunnelConfig>,
}

/// 解析 config.json 并返回规范序列化（键序 = Swift `CodingKeys` 声明顺序的规范形状）。
///
/// 拒绝语义与 Swift 对齐：JSON 非法或必填字段缺失 → `INVALID_JSON`；
/// version != 1 → `SCHEMA_VERSION`；id 非法 → `INVALID_ID`；
/// command 为空或首元素为空 → `INVALID_COMMAND`。
pub fn parse_app_config(input: &str) -> Result<String, TpError> {
    let config = parse_config_envelope(input)?;
    serde_json::to_string(&config)
        .map_err(|e| TpError::new(error_code::INVALID_JSON, format!("config.json 序列化失败：{e}")))
}

/// 解析 config.json 结构（供 ConfigStore 等复用）：version 检查 + id/command 校验。
pub fn parse_config_envelope(input: &str) -> Result<AppConfig, TpError> {
    let value: serde_json::Value = serde_json::from_str(input)
        .map_err(|e| TpError::new(error_code::INVALID_JSON, format!("config.json 解析失败：{e}")))?;

    let version = value
        .get("version")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| TpError::new(error_code::INVALID_JSON, "config.json 缺少 version 字段"))?;
    if version != CONFIG_SCHEMA_VERSION {
        return Err(TpError::new(
            error_code::SCHEMA_VERSION,
            format!("不支持的 schema version：{version}"),
        ));
    }

    let config: AppConfig = serde_json::from_value(value)
        .map_err(|e| TpError::new(error_code::INVALID_JSON, format!("config.json 解析失败：{e}")))?;

    for tunnel in &config.tunnels {
        if !TunnelConfig::is_valid_id(&tunnel.id) {
            return Err(TpError::new(
                error_code::INVALID_ID,
                format!("隧道 id 只允许小写字母、数字与连字符：{}", tunnel.id),
            ));
        }
        if tunnel.command.is_empty() || tunnel.command[0].is_empty() {
            return Err(TpError::new(
                error_code::INVALID_COMMAND,
                "command 不能为空且首元素必须是可执行路径",
            ));
        }
    }
    Ok(config)
}

/// `TunnelStatus` 的规范 JSON（阶段 1 契约）：
/// `{"case":"running","pid":1234}` / `{"case":"notRunning"}` /
/// `{"case":"notLoaded"}` / `{"case":"other","state":"..."}`。
/// `has_pid=false` 时 `running` 编码为 `"pid":null`。
pub fn status_to_json(status_case: u32, has_pid: bool, pid: i32, state: Option<&str>) -> Result<String, TpError> {
    let value = match status_case {
        0 => serde_json::json!({
            "case": "running",
            "pid": if has_pid { serde_json::json!(pid) } else { serde_json::Value::Null },
        }),
        1 => serde_json::json!({ "case": "notRunning" }),
        2 => serde_json::json!({ "case": "notLoaded" }),
        3 => {
            let state = state.ok_or_else(|| {
                TpError::new(error_code::INVALID_ARGUMENT, "other 状态必须携带 state 字符串")
            })?;
            serde_json::json!({ "case": "other", "state": state })
        }
        _ => return Err(TpError::new(error_code::INVALID_ARGUMENT, "未知的 TunnelStatus case")),
    };
    serde_json::to_string(&value).map_err(|e| TpError::new(error_code::INVALID_JSON, e.to_string()))
}

/// `ProbeResult` 的规范 JSON（阶段 1 契约）：
/// `{"case":"satisfied","status":200}` / `{"case":"unexpected","status":502}` /
/// `{"case":"failed","reason":"..."}`。
pub fn probe_result_to_json(kind: u32, status: i32, reason: Option<&str>) -> Result<String, TpError> {
    let value = match kind {
        0 => serde_json::json!({ "case": "satisfied", "status": status }),
        1 => serde_json::json!({ "case": "unexpected", "status": status }),
        2 => {
            let reason = reason.ok_or_else(|| {
                TpError::new(error_code::INVALID_ARGUMENT, "failed 结果必须携带 reason 字符串")
            })?;
            serde_json::json!({ "case": "failed", "reason": reason })
        }
        _ => return Err(TpError::new(error_code::INVALID_ARGUMENT, "未知的 ProbeResult kind")),
    };
    serde_json::to_string(&value).map_err(|e| TpError::new(error_code::INVALID_JSON, e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 规范形状 fixture：按 Swift `CodingKeys` 声明顺序书写。
    /// 跨语言等价性按解码后语义判定（Swift JSONEncoder 无 sortKeys 时键序不确定）。
    const FULL: &str = r#"{"version":1,"tunnels":[{"id":"admin-tunnel","name":"管理隧道","command":["/usr/bin/ssh","-N","-L","8080:127.0.0.1:80","host"],"executor":"launchd","keepAlive":true,"throttleInterval":10,"probe":{"url":"http://127.0.0.1:8080/health","expectedStatuses":[200,204]}}]}"#;

    /// Swift 手写配置允许省略默认字段；编码时补全为默认值。
    const MINIMAL_INPUT: &str = r#"{"version":1,"tunnels":[{"id":"web","name":"web","command":["/usr/bin/ssh","-N"]}]}"#;
    const MINIMAL_CANONICAL: &str = r#"{"version":1,"tunnels":[{"id":"web","name":"web","command":["/usr/bin/ssh","-N"],"executor":"launchd","keepAlive":true,"throttleInterval":10}]}"#;

    fn canon(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("fixture 必须是合法 JSON")
    }

    #[test]
    fn full_config_roundtrip_matches_swift_shape() {
        let out = parse_app_config(FULL).expect("完整配置应可解析");
        assert_eq!(canon(&out), canon(FULL));
        // 键序与 Swift CodingKeys 一致（字节级对齐）。
        assert_eq!(out, FULL);
    }

    #[test]
    fn minimal_config_fills_swift_defaults() {
        let out = parse_app_config(MINIMAL_INPUT).expect("最小配置应可解析");
        assert_eq!(canon(&out), canon(MINIMAL_CANONICAL));
        assert_eq!(out, MINIMAL_CANONICAL);
    }

    #[test]
    fn rejects_unsupported_schema_version() {
        let bad = r#"{"version":2,"tunnels":[]}"#;
        let err = parse_app_config(bad).unwrap_err();
        assert_eq!(err.code, error_code::SCHEMA_VERSION);
        assert!(err.message.contains("2"));
    }

    #[test]
    fn rejects_invalid_id() {
        let bad = r#"{"version":1,"tunnels":[{"id":"Admin Tunnel!","name":"x","command":["/bin/true"]}]}"#;
        let err = parse_app_config(bad).unwrap_err();
        assert_eq!(err.code, error_code::INVALID_ID);
    }

    #[test]
    fn rejects_empty_command_and_empty_first_element() {
        let empty = r#"{"version":1,"tunnels":[{"id":"a","name":"a","command":[]}]}"#;
        assert_eq!(parse_app_config(empty).unwrap_err().code, error_code::INVALID_COMMAND);

        let blank_first = r#"{"version":1,"tunnels":[{"id":"a","name":"a","command":["","x"]}]}"#;
        assert_eq!(parse_app_config(blank_first).unwrap_err().code, error_code::INVALID_COMMAND);
    }

    #[test]
    fn rejects_malformed_json_and_missing_required_fields() {
        assert_eq!(parse_app_config("{not json").unwrap_err().code, error_code::INVALID_JSON);
        let missing = r#"{"version":1,"tunnels":[{"id":"a","name":"a"}]}"#;
        assert_eq!(parse_app_config(missing).unwrap_err().code, error_code::INVALID_JSON);
    }

    #[test]
    fn id_rules_match_swift_pattern() {
        assert!(TunnelConfig::is_valid_id("admin-tunnel"));
        assert!(TunnelConfig::is_valid_id("web-1"));
        assert!(!TunnelConfig::is_valid_id(""));
        assert!(!TunnelConfig::is_valid_id("Web"));
        assert!(!TunnelConfig::is_valid_id("a b"));
        assert!(!TunnelConfig::is_valid_id("中文"));
    }

    #[test]
    fn launchd_label_matches_swift_prefix() {
        let mut config: TunnelConfig =
            serde_json::from_value(serde_json::json!({"id":"a1","name":"n","command":["/bin/true"]})).unwrap();
        assert_eq!(config.launchd_label(), "com.jafish.tunnelpad.a1");
        config.executor = ExecutorKind::App;
        assert_eq!(config.launchd_label(), "com.jafish.tunnelpad.a1");
    }

    #[test]
    fn status_json_covers_all_cases() {
        assert_eq!(
            status_to_json(0, true, 1234, None).unwrap(),
            r#"{"case":"running","pid":1234}"#
        );
        assert_eq!(
            status_to_json(0, false, 0, None).unwrap(),
            r#"{"case":"running","pid":null}"#
        );
        assert_eq!(status_to_json(1, false, 0, None).unwrap(), r#"{"case":"notRunning"}"#);
        assert_eq!(status_to_json(2, false, 0, None).unwrap(), r#"{"case":"notLoaded"}"#);
        assert_eq!(
            status_to_json(3, false, 0, Some("weird-state")).unwrap(),
            r#"{"case":"other","state":"weird-state"}"#
        );
        assert_eq!(status_to_json(9, false, 0, None).unwrap_err().code, error_code::INVALID_ARGUMENT);
        assert_eq!(status_to_json(3, false, 0, None).unwrap_err().code, error_code::INVALID_ARGUMENT);
    }

    #[test]
    fn probe_result_json_covers_all_cases() {
        assert_eq!(
            probe_result_to_json(0, 200, None).unwrap(),
            r#"{"case":"satisfied","status":200}"#
        );
        assert_eq!(
            probe_result_to_json(1, 502, None).unwrap(),
            r#"{"case":"unexpected","status":502}"#
        );
        assert_eq!(
            probe_result_to_json(2, 0, Some("连接被拒绝")).unwrap(),
            r#"{"case":"failed","reason":"连接被拒绝"}"#
        );
        assert_eq!(probe_result_to_json(2, 0, None).unwrap_err().code, error_code::INVALID_ARGUMENT);
        assert_eq!(probe_result_to_json(9, 0, None).unwrap_err().code, error_code::INVALID_ARGUMENT);
    }
}
