//! 旧手工隧道 agent 扫描与解析（Swift `LegacyImporter` 对等）。
//! plist 解析覆盖 XML 子集（dict/string/integer/true/false/array），
//! 二进制 plist 不在差分矩阵内（Swift 事实源由 fixture 固定为 XML）。

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::TunnelConfig;

/// `~/Library/LaunchAgents` 下发现的手工隧道 agent。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LegacyAgent {
    pub label: String,
    pub plist_path: PathBuf,
    #[serde(rename = "programArguments")]
    pub program_arguments: Vec<String>,
    #[serde(rename = "keepAlive")]
    pub keep_alive: bool,
    #[serde(rename = "runAtLoad")]
    pub run_at_load: bool,
    #[serde(rename = "throttleInterval")]
    pub throttle_interval: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum LegacyImporterError {
    #[serde(rename_all = "camelCase")]
    UnreadablePlist { path: String },
    #[serde(rename_all = "camelCase")]
    MissingLabel { path: String },
}

pub const LABEL_PREFIX: &str = "com.jafish.motorcycle-manual.";

/// 扫描目录，返回按 Label 排序的旧 agent。不硬编码清单，发现即列出。
pub fn scan(directory: &Path) -> Vec<LegacyAgent> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(_) => return vec![],
    };
    let mut agents: Vec<LegacyAgent> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().map(|ext| ext == "plist").unwrap_or(false))
        .filter_map(|path| parse_plist_file(&path).ok())
        .filter(|agent| agent.label.starts_with(LABEL_PREFIX))
        .collect();
    agents.sort_by(|a, b| a.label.cmp(&b.label));
    agents
}

pub fn parse_plist_file(path: &Path) -> Result<LegacyAgent, LegacyImporterError> {
    let data = fs::read(path).map_err(|_| LegacyImporterError::UnreadablePlist {
        path: path_display(path),
    })?;
    let text = String::from_utf8(data).map_err(|_| LegacyImporterError::UnreadablePlist {
        path: path_display(path),
    })?;
    let dict = parse_plist_xml(&text).ok_or_else(|| LegacyImporterError::UnreadablePlist {
        path: path_display(path),
    })?;
    let label = match dict.get("Label") {
        Some(PlistValue::String(label)) => label.clone(),
        _ => {
            return Err(LegacyImporterError::MissingLabel {
                path: path_display(path),
            })
        }
    };
    let program_arguments = match dict.get("ProgramArguments") {
        Some(PlistValue::Array(items)) => items
            .iter()
            .filter_map(|item| match item {
                PlistValue::String(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => vec![],
    };
    Ok(LegacyAgent {
        label,
        plist_path: path.to_path_buf(),
        keep_alive: matches!(dict.get("KeepAlive"), Some(PlistValue::Boolean(true))),
        run_at_load: matches!(dict.get("RunAtLoad"), Some(PlistValue::Boolean(true))),
        throttle_interval: match dict.get("ThrottleInterval") {
            Some(PlistValue::Integer(n)) => Some(*n),
            _ => None,
        },
        program_arguments,
    })
}

/// `com.jafish.motorcycle-manual.<id>` → `<id>`；后缀不是合法 id 时返回 None。
pub fn tunnel_id(label: &str) -> Option<String> {
    let id = label.strip_prefix(LABEL_PREFIX)?;
    if TunnelConfig::is_valid_id(id) {
        Some(id.to_string())
    } else {
        None
    }
}

/// 旧 agent → 新配置条目；无法派生合法 id 或命令为空时返回 None。
pub fn tunnel_config(agent: &LegacyAgent) -> Option<TunnelConfig> {
    let id = tunnel_id(&agent.label)?;
    if agent.program_arguments.is_empty() {
        return None;
    }
    Some(
        serde_json::from_value(serde_json::json!({
            "id": id,
            "name": id,
            "command": agent.program_arguments,
            "executor": "launchd",
            "keepAlive": agent.keep_alive,
            "throttleInterval": agent.throttle_interval.unwrap_or(10),
        }))
        .expect("字段已保证合法"),
    )
}

// MARK: - 最小 plist XML 解析

#[derive(Debug, Clone, PartialEq)]
pub enum PlistValue {
    String(String),
    Integer(i64),
    Boolean(bool),
    Array(Vec<PlistValue>),
    Dict(Vec<(String, PlistValue)>),
}

impl PlistValue {
    fn get(&self, key: &str) -> Option<&PlistValue> {
        match self {
            PlistValue::Dict(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

struct XmlScanner<'a> {
    bytes: &'a [u8],
    pos: usize,
}

/// 解析 plist XML 子集；任何结构意外都返回 None（对应 Swift 的 unreadable）。
pub fn parse_plist_xml(text: &str) -> Option<PlistValue> {
    let mut scanner = XmlScanner {
        bytes: text.as_bytes(),
        pos: 0,
    };
    scanner.skip_prolog()?;
    let value = scanner.parse_element()?;
    // 尾部允许 </plist> 与空白
    scanner.skip_whitespace_and_tags(&["plist"])?;
    Some(value)
}

impl<'a> XmlScanner<'a> {
    fn skip_prolog(&mut self) -> Option<()> {
        self.skip_whitespace_and_tags(&["?xml", "!DOCTYPE"])?;
        Some(())
    }

    fn skip_whitespace_and_tags(&mut self, allowed_tags: &[&str]) -> Option<()> {
        loop {
            self.skip_whitespace();
            if self.peek() == Some(b'<') {
                let tag = self.peek_tag_name()?;
                if allowed_tags.contains(&tag.as_str()) {
                    self.skip_tag()?;
                } else {
                    return Some(());
                }
            } else {
                return Some(());
            }
        }
    }

    fn skip_whitespace(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_ascii_whitespace() {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn peek_tag_name(&self) -> Option<String> {
        let mut i = self.pos + 1;
        let mut name = String::new();
        while let Some(c) = self.bytes.get(i).copied() {
            // '/' 仅在紧随 '<' 时属于标签名（闭合标签）；自闭合标签的 '/' 不算
            let allowed = c.is_ascii_alphanumeric()
                || c == b'?'
                || c == b'!'
                || c == b'-'
                || c == b':'
                || c == b'_'
                || (c == b'/' && i == self.pos + 1);
            if allowed {
                name.push(c as char);
                i += 1;
            } else {
                break;
            }
        }
        Some(name)
    }

    /// 跳过当前标签（含可能的闭合标签）。
    fn skip_tag(&mut self) -> Option<()> {
        if self.peek()? != b'<' {
            return None;
        }
        let end = self.find(b'>')?;
        self.pos = end + 1;
        Some(())
    }

    fn find(&self, needle: u8) -> Option<usize> {
        self.bytes[self.pos..]
            .iter()
            .position(|c| *c == needle)
            .map(|i| self.pos + i)
    }

    fn parse_element(&mut self) -> Option<PlistValue> {
        self.skip_whitespace();
        if self.peek()? != b'<' {
            return None;
        }
        let name = self.peek_tag_name()?;
        if name.starts_with('!') || name.starts_with('?') {
            self.skip_tag()?;
            return self.parse_element();
        }
        self.skip_tag()?; // 消费开标签
        let value = match name.as_str() {
            "plist" => self.parse_element()?,
            "dict" => self.parse_dict()?,
            "array" => self.parse_array()?,
            "string" => PlistValue::String(self.read_text_until_tag("string")?),
            "integer" => {
                let text = self.read_text_until_tag("integer")?;
                PlistValue::Integer(text.trim().parse().ok()?)
            }
            "true" => PlistValue::Boolean(true),
            "false" => PlistValue::Boolean(false),
            _ => return None,
        };
        Some(value)
    }

    fn parse_dict(&mut self) -> Option<PlistValue> {
        let mut items: Vec<(String, PlistValue)> = vec![];
        loop {
            self.skip_whitespace();
            match self.peek()? {
                b'<' => {
                    let tag = self.peek_tag_name()?;
                    match tag.as_str() {
                        "key" => {
                            self.skip_tag()?;
                            let key = self.read_text_until_tag("key")?;
                            let value = self.parse_element()?;
                            items.push((key, value));
                        }
                        "/dict" => {
                            self.skip_tag()?;
                            return Some(PlistValue::Dict(items));
                        }
                        _ => return None,
                    }
                }
                _ => return None,
            }
        }
    }

    fn parse_array(&mut self) -> Option<PlistValue> {
        let mut items = vec![];
        loop {
            self.skip_whitespace();
            match self.peek()? {
                b'<' => {
                    let tag = self.peek_tag_name()?;
                    if tag == "/array" {
                        self.skip_tag()?;
                        return Some(PlistValue::Array(items));
                    }
                    items.push(self.parse_element()?);
                }
                _ => return None,
            }
        }
    }

    /// 读取文本直到闭合标签 `</name>`，解码 XML 实体。
    fn read_text_until_tag(&mut self, name: &str) -> Option<String> {
        let closing = format!("</{name}>");
        let rest = &self.bytes[self.pos..];
        let end = rest
            .windows(closing.len())
            .position(|w| w == closing.as_bytes())?;
        let raw = std::str::from_utf8(&rest[..end]).ok()?;
        self.pos += end + closing.len();
        Some(decode_entities(raw))
    }
}

fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '&' {
            out.push(c);
            continue;
        }
        let mut entity = String::new();
        while let Some(&n) = chars.peek() {
            if n == ';' {
                chars.next();
                break;
            }
            entity.push(n);
            chars.next();
        }
        match entity.as_str() {
            "amp" => out.push('&'),
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            other => {
                // 未知实体原样保留（plist fixture 不会出现）
                out.push('&');
                out.push_str(other);
                out.push(';');
            }
        }
    }
    out
}

fn path_display(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.jafish.motorcycle-manual.web</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/ssh</string>
		<string>-N</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
"#;

    #[test]
    fn parses_sample_agent() {
        let agent = parse_plist_xml(SAMPLE).expect("应可解析");
        assert_eq!(
            agent.get("Label"),
            Some(&PlistValue::String(
                "com.jafish.motorcycle-manual.web".into()
            ))
        );
        assert!(matches!(
            agent.get("KeepAlive"),
            Some(PlistValue::Boolean(true))
        ));
        assert!(matches!(
            agent.get("ThrottleInterval"),
            Some(PlistValue::Integer(30))
        ));
    }

    #[test]
    fn derive_rules_match_swift() {
        let agent = LegacyAgent {
            label: "com.jafish.motorcycle-manual.web".into(),
            plist_path: PathBuf::from("/tmp/a.plist"),
            program_arguments: vec!["/usr/bin/ssh".into(), "-N".into()],
            keep_alive: true,
            run_at_load: true,
            throttle_interval: Some(30),
        };
        assert_eq!(tunnel_id(&agent.label).as_deref(), Some("web"));
        let config = tunnel_config(&agent).unwrap();
        assert_eq!(config.id, "web");
        assert_eq!(config.throttle_interval, 30);
        assert!(config.keep_alive);

        // 非法 id 后缀
        assert_eq!(tunnel_id("com.jafish.motorcycle-manual.Bad ID"), None);
        // ThrottleInterval 缺省 → 10
        let no_throttle = LegacyAgent {
            throttle_interval: None,
            ..agent
        };
        assert_eq!(tunnel_config(&no_throttle).unwrap().throttle_interval, 10);
        // 空 ProgramArguments
        let empty_args = LegacyAgent {
            program_arguments: vec![],
            ..no_throttle
        };
        assert!(tunnel_config(&empty_args).is_none());
    }
}
