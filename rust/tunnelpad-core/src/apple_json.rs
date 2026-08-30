//! Apple 风格 JSON 写盘器（Swift `JSONEncoder` `.prettyPrinted + .sortedKeys`
//! 输出的字节级对等实现，2026-08-30 实证探针确定格式）。
//!
//! 格式要点：2 空格缩进；`"key" : value` 分隔；字符串中 `/` 转义为 `\/`；
//! 非 ASCII（中文等）保持 UTF-8 原文；键按字母序；空数组渲染为 `[`、空行、
//! 闭括号（Swift prettyPrinted 的已知行为）；输出不以换行结尾。
//! 键序由各类型的固定字段集决定（与 serde 字段名一致）。

use crate::{AppConfig, TunnelConfig};

pub fn app_config_to_apple_json(config: &AppConfig) -> String {
    let tunnels = render_array(&config.tunnels, 2, render_tunnel);
    format!(
        "{{\n  \"tunnels\" : {tunnels},\n  \"version\" : {}\n}}",
        config.version
    )
}

/// 层级：`{`(0) → 键(2) → tunnel `{`(4) → 键(6) → probe `{`(6→键 8) → 数组项(8→项 10)。
fn render_tunnel(tunnel: &TunnelConfig) -> String {
    // 键按字母序：command, executor, id, keepAlive, name, probe, throttleInterval
    let mut out = String::from("{\n");
    out.push_str(&format!(
        "      \"command\" : {},\n",
        render_string_array(&tunnel.command, 6)
    ));
    out.push_str(&format!(
        "      \"executor\" : {},\n",
        render_string("launchd")
    ));
    out.push_str(&format!("      \"id\" : {},\n", render_string(&tunnel.id)));
    out.push_str(&format!("      \"keepAlive\" : {},\n", tunnel.keep_alive));
    out.push_str(&format!(
        "      \"name\" : {},\n",
        render_string(&tunnel.name)
    ));
    if let Some(probe) = &tunnel.probe {
        out.push_str("      \"probe\" : {\n");
        // 键序：expectedStatuses, url
        out.push_str(&format!(
            "        \"expectedStatuses\" : {},\n",
            render_int_array(&probe.expected_statuses, 8)
        ));
        out.push_str(&format!(
            "        \"url\" : {}\n",
            render_string(&probe.url)
        ));
        out.push_str("      },\n");
    }
    out.push_str(&format!(
        "      \"throttleInterval\" : {}\n",
        tunnel.throttle_interval
    ));
    out.push_str("    }");
    out
}

fn render_string_array(items: &[String], indent: usize) -> String {
    render_array(items, indent, |item| render_string(item))
}

fn render_int_array<T: std::fmt::Display>(items: &[T], indent: usize) -> String {
    render_array(items, indent, |item| item.to_string())
}

fn render_array<T, F: Fn(&T) -> String>(items: &[T], indent: usize, render: F) -> String {
    let pad = " ".repeat(indent);
    if items.is_empty() {
        return format!("[\n\n{pad}]");
    }
    let inner_pad = " ".repeat(indent + 2);
    let rendered: Vec<String> = items
        .iter()
        .map(|item| format!("{inner_pad}{},", render(item)))
        .collect();
    let mut joined = rendered.join("\n");
    if joined.ends_with(',') {
        joined.truncate(joined.len() - 1);
    }
    format!("[\n{joined}\n{pad}]")
}

pub fn render_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '/' => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_tunnels_matches_swift_pretty_printed() {
        let config = AppConfig {
            version: 1,
            tunnels: vec![],
        };
        assert_eq!(
            app_config_to_apple_json(&config),
            "{\n  \"tunnels\" : [\n\n  ],\n  \"version\" : 1\n}"
        );
    }

    #[test]
    fn full_tunnel_matches_probe_bytes() {
        let config: AppConfig = serde_json::from_str(
            r#"{"version":1,"tunnels":[{"id":"admin-tunnel","name":"管理\"引号\"\\反斜杠","command":["/usr/bin/ssh","-N","-L","8080:127.0.0.1:80","host"],"executor":"launchd","keepAlive":true,"throttleInterval":10,"probe":{"url":"http://127.0.0.1:8080/health","expectedStatuses":[200,204]}}]}"#,
        )
        .unwrap();
        let expected = "{\n  \"tunnels\" : [\n    {\n      \"command\" : [\n        \"\\/usr\\/bin\\/ssh\",\n        \"-N\",\n        \"-L\",\n        \"8080:127.0.0.1:80\",\n        \"host\"\n      ],\n      \"executor\" : \"launchd\",\n      \"id\" : \"admin-tunnel\",\n      \"keepAlive\" : true,\n      \"name\" : \"管理\\\"引号\\\"\\\\反斜杠\",\n      \"probe\" : {\n        \"expectedStatuses\" : [\n          200,\n          204\n        ],\n        \"url\" : \"http:\\/\\/127.0.0.1:8080\\/health\"\n      },\n      \"throttleInterval\" : 10\n    }\n  ],\n  \"version\" : 1\n}";
        assert_eq!(app_config_to_apple_json(&config), expected);
    }
}
