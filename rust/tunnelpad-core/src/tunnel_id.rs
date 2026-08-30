//! 隧道 id 生成规则（Swift `TunnelID` 对等）：由显示名派生 `[a-z0-9-]+` 的 id。

use std::collections::BTreeSet;

/// 小写化；字母数字之外的字符折叠为单个连字符并去除首尾；结果为空回退 `tunnel`；
/// 与 existing 冲突时追加 `-2`、`-3`… 直到可用。
pub fn generate(name: &str, existing: &BTreeSet<String>) -> String {
    let mut slug = String::new();
    let mut last_was_dash = true;
    for ch in name.to_lowercase().chars() {
        if ch.is_ascii() && (ch.is_ascii_alphabetic() || ch.is_ascii_digit()) {
            slug.push(ch);
            last_was_dash = false;
        } else if !last_was_dash {
            slug.push('-');
            last_was_dash = true;
        }
    }
    while slug.starts_with('-') {
        slug.remove(0);
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        slug = "tunnel".to_string();
    }

    if !existing.contains(&slug) {
        return slug;
    }
    let mut n = 2;
    while existing.contains(&format!("{slug}-{n}")) {
        n += 1;
    }
    format!("{slug}-{n}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn slug_rules_match_swift() {
        assert_eq!(generate("Web Server", &set(&[])), "web-server");
        assert_eq!(generate("管理 隧道", &set(&[])), "tunnel");
        assert_eq!(generate("管理A隧道", &set(&[])), "a");
        assert_eq!(generate("  --Web--  ", &set(&[])), "web");
        assert_eq!(generate("a  b", &set(&[])), "a-b");
        assert_eq!(generate("a_b", &set(&[])), "a-b");
        assert_eq!(generate("!!!", &set(&[])), "tunnel");
        assert_eq!(generate("Web", &set(&["web"])), "web-2");
        assert_eq!(generate("Web", &set(&["web", "web-2", "web-3"])), "web-4");
        assert_eq!(generate("中文ABC123", &set(&[])), "abc123");
    }
}
