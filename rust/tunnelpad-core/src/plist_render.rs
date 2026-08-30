//! launchd plist 渲染（Swift `LaunchdPlistRenderer` 对等）。
//! XML 字节级对齐 2026-08-30 实证探针：键按字母序、TAB 缩进、`<true/>`、
//! `<integer>`，字符串不做 `/` 转义，输出以 `</plist>\n` 结尾。

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::paths::TunnelPaths;
use crate::TunnelConfig;

fn escape_xml(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
    out
}

/// 由 TunnelConfig 生成 launchd plist XML（与 PropertyListSerialization .xml 输出对齐）。
pub fn plist_xml(tunnel: &TunnelConfig, log_path: &str) -> String {
    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str(
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
    );
    out.push_str("<plist version=\"1.0\">\n");
    out.push_str("<dict>\n");
    // 键按字母序：KeepAlive, Label, ProcessType, ProgramArguments, RunAtLoad,
    // StandardErrorPath, StandardOutPath, ThrottleInterval
    out.push_str(&format!(
        "\t<key>KeepAlive</key>\n\t<{}/>\n",
        if tunnel.keep_alive { "true" } else { "false" }
    ));
    out.push_str(&format!(
        "\t<key>Label</key>\n\t<string>{}</string>\n",
        escape_xml(&tunnel.launchd_label())
    ));
    out.push_str("\t<key>ProcessType</key>\n\t<string>Background</string>\n");
    out.push_str("\t<key>ProgramArguments</key>\n\t<array>\n");
    for arg in &tunnel.command {
        out.push_str(&format!("\t\t<string>{}</string>\n", escape_xml(arg)));
    }
    out.push_str("\t</array>\n");
    out.push_str("\t<key>RunAtLoad</key>\n\t<true/>\n");
    out.push_str(&format!(
        "\t<key>StandardErrorPath</key>\n\t<string>{}</string>\n",
        escape_xml(log_path)
    ));
    out.push_str(&format!(
        "\t<key>StandardOutPath</key>\n\t<string>{}</string>\n",
        escape_xml(log_path)
    ));
    out.push_str(&format!(
        "\t<key>ThrottleInterval</key>\n\t<integer>{}</integer>\n",
        tunnel.throttle_interval
    ));
    out.push_str("</dict>\n");
    out.push_str("</plist>\n");
    out
}

/// 生成并原子写入 plist，返回写入位置（Swift `writePlist` 对等）。
pub fn write_plist(tunnel: &TunnelConfig, paths: &TunnelPaths) -> io::Result<PathBuf> {
    let url = paths.launchd_plist_url(tunnel);
    fs::create_dir_all(paths.launchd_directory())?;
    let data = plist_xml(tunnel, &path_to_string(&paths.log_url(tunnel)));
    write_atomic(&url, data.as_bytes())?;
    Ok(url)
}

/// Swift `.atomic` 写入语义对齐：写临时文件后 rename。
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp-atomic");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

pub fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_matches_probe_format() {
        let tunnel: TunnelConfig = serde_json::from_value(serde_json::json!({
            "id": "web", "name": "web", "command": ["/usr/bin/ssh", "-N"],
            "executor": "launchd", "keepAlive": true, "throttleInterval": 10
        }))
        .unwrap();
        let xml = plist_xml(&tunnel, "/tmp/x.log");
        assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"));
        assert!(xml.contains("\t<key>KeepAlive</key>\n\t<true/>"));
        assert!(xml.contains("\t<key>Label</key>\n\t<string>com.jafish.tunnelpad.web</string>"));
        assert!(xml.contains("\t<string>/usr/bin/ssh</string>"));
        assert!(xml.contains("\t<key>ThrottleInterval</key>\n\t<integer>10</integer>"));
        assert!(xml.ends_with("</dict>\n</plist>\n"));
    }
}
