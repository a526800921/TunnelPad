import Foundation

/// 日志尾部读取。日志文件量级小（launchd 直写），
/// 采用整文件读入后取尾部。
public enum LogTail {
    /// 返回文件末 `maxLines` 行；文件不存在或不可读返回 nil。
    public static func lastLines(of url: URL, maxLines: Int = 500) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // 文件以换行结尾时 split 会多出一个空元素，去掉以免挤掉一行真实日志
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
