//! 日志尾部读取（Swift `LogTail` 对等）。
//! 日志文件量级小，采用整文件读入后取尾部。

use std::fs;
use std::path::Path;

/// 返回文件末 `max_lines` 行；文件不存在或不可读（含非法 UTF-8）返回 None。
pub fn last_lines(path: &Path, max_lines: usize) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let text = String::from_utf8(bytes).ok()?;
    Some(last_lines_of_text(&text, max_lines))
}

/// 纯文本变体（差分与测试复用）。
pub fn last_lines_of_text(text: &str, max_lines: usize) -> String {
    let mut lines: Vec<&str> = text.split('\n').collect();
    // 文件以换行结尾时 split 会多出一个空元素，去掉以免挤掉一行真实日志
    if lines.last().map(|l| l.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    let start = lines.len().saturating_sub(max_lines);
    lines[start..].join("\n")
}

pub const DEFAULT_MAX_LINES: usize = 500;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_swift_semantics() {
        assert_eq!(last_lines_of_text("a\nb\nc", 500), "a\nb\nc");
        assert_eq!(last_lines_of_text("a\nb\nc\n", 500), "a\nb\nc");
        assert_eq!(last_lines_of_text("a\nb\nc", 2), "b\nc");
        assert_eq!(last_lines_of_text("", 500), "");
        assert_eq!(last_lines_of_text("\n\n", 500), "\n");
        assert_eq!(last_lines_of_text("a\n\nb", 500), "a\n\nb");
        assert_eq!(last_lines_of_text("中文\n日志", 1), "日志");
    }
}
