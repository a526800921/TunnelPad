//! launchd plist 渲染（Swift `LaunchdPlistRenderer` 对等）。
//! XML 字节级对齐 2026-08-30 实证探针：键按字母序、TAB 缩进、`<true/>`、
//! `<integer>`，字符串不做 `/` 转义，输出以 `</plist>\n` 结尾。

use std::fs;
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
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
    plist_xml_with_log_proxy(tunnel, log_path, None)
}

/// 生成带可选日志代理的 launchd plist XML。
///
/// 保留 `plist_xml` 的直写形式用于历史差分 fixture；真实 App 通过
/// `write_plist` 在 bundle 里找到代理时使用此路径。
pub fn plist_xml_with_log_proxy(
    tunnel: &TunnelConfig,
    log_path: &str,
    log_proxy_path: Option<&str>,
) -> String {
    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str(
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
    );
    out.push_str("<plist version=\"1.0\">\n");
    out.push_str("<dict>\n");
    // 键按字母序：AbandonProcessGroup（代理模式）, KeepAlive, Label,
    // ProcessType, ProgramArguments, RunAtLoad, StandardErrorPath,
    // StandardOutPath, ThrottleInterval
    if log_proxy_path.is_some() {
        out.push_str("\t<key>AbandonProcessGroup</key>\n\t<false/>\n");
    }
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
    let mut program_arguments = Vec::with_capacity(tunnel.command.len() + 4);
    if let Some(log_proxy_path) = log_proxy_path {
        program_arguments.push(log_proxy_path.to_string());
        program_arguments.push("--log".to_string());
        program_arguments.push(log_path.to_string());
        program_arguments.push("--".to_string());
    }
    program_arguments.extend(tunnel.command.iter().cloned());
    for arg in &program_arguments {
        out.push_str(&format!("\t\t<string>{}</string>\n", escape_xml(arg)));
    }
    out.push_str("\t</array>\n");
    out.push_str("\t<key>RunAtLoad</key>\n\t<true/>\n");
    let output_path = if log_proxy_path.is_some() {
        "/dev/null"
    } else {
        log_path
    };
    out.push_str(&format!(
        "\t<key>StandardErrorPath</key>\n\t<string>{}</string>\n",
        escape_xml(output_path)
    ));
    out.push_str(&format!(
        "\t<key>StandardOutPath</key>\n\t<string>{}</string>\n",
        escape_xml(output_path)
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
    let log_path = path_to_string(&paths.log_url(tunnel));
    let log_proxy_path = install_log_proxy(paths)?.map(|path| path_to_string(&path));
    let data = plist_xml_with_log_proxy(tunnel, &log_path, log_proxy_path.as_deref());
    write_atomic(&url, data.as_bytes())?;
    Ok(url)
}

fn bundled_log_proxy_path() -> io::Result<Option<PathBuf>> {
    let executable = match std::env::current_exe() {
        Ok(path) => path,
        Err(_) => return Ok(None),
    };
    if !is_app_bundle_executable(&executable) {
        return Ok(None);
    }
    let resources = executable
        .parent()
        .and_then(Path::parent)
        .map(|contents| contents.join("Resources/tunnelpad-log-proxy"))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "TunnelPad Bundle 资源路径缺失"))?;
    let metadata = fs::metadata(&resources).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("TunnelPad 日志代理资源不可用：{error}"),
        )
    })?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "TunnelPad 日志代理资源不可执行",
        ));
    }
    Ok(Some(resources))
}

fn install_log_proxy(paths: &TunnelPaths) -> io::Result<Option<PathBuf>> {
    let Some(source) = bundled_log_proxy_path()? else {
        return Ok(None);
    };
    let destination = paths.support_directory().join("bin/tunnelpad-log-proxy");
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "日志代理目标路径无父目录"))?;
    fs::create_dir_all(parent)?;
    let data = fs::read(&source)?;
    let temporary = destination.with_extension("tmp-atomic");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true).mode(0o755);
    let mut file = options.open(&temporary)?;
    use std::io::Write;
    file.write_all(&data)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, &destination)?;
    Ok(Some(destination))
}

fn is_app_bundle_executable(executable: &Path) -> bool {
    executable.parent().and_then(Path::file_name) == Some("MacOS".as_ref())
        && executable
            .parent()
            .and_then(Path::parent)
            .and_then(Path::file_name)
            == Some("Contents".as_ref())
        && executable
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .and_then(Path::extension)
            == Some("app".as_ref())
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

    #[test]
    fn xml_with_log_proxy_preserves_original_command_after_proxy_arguments() {
        let tunnel: TunnelConfig = serde_json::from_value(serde_json::json!({
            "id": "web", "name": "web", "command": ["/usr/bin/ssh", "-N", "host"],
            "executor": "launchd", "keepAlive": true, "throttleInterval": 10
        }))
        .unwrap();
        let xml = plist_xml_with_log_proxy(
            &tunnel,
            "/tmp/web.log",
            Some("/Applications/TunnelPad.app/Contents/Resources/tunnelpad-log-proxy"),
        );
        let expected = [
            "/Applications/TunnelPad.app/Contents/Resources/tunnelpad-log-proxy",
            "--log",
            "/tmp/web.log",
            "--",
            "/usr/bin/ssh",
            "-N",
            "host",
        ];
        for arg in expected {
            assert!(xml.contains(&format!("<string>{arg}</string>")));
        }
        assert!(xml.contains("<key>StandardErrorPath</key>\n\t<string>/dev/null</string>"));
        assert!(xml.contains("<key>StandardOutPath</key>\n\t<string>/dev/null</string>"));
        assert!(xml.contains("<key>AbandonProcessGroup</key>\n\t<false/>"));
    }
}
