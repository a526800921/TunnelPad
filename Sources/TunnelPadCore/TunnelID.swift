import Foundation

/// 隧道 id 生成规则：由显示名派生 `[a-z0-9-]+` 的 id，供新建隧道使用。
public enum TunnelID {
    /// 小写化；字母数字之外的字符折叠为单个连字符并去除首尾；结果为空回退 `tunnel`；
    /// 与 existing 冲突时追加 `-2`、`-3`… 直到可用。
    public static func generate(from name: String, existing: Set<String>) -> String {
        var slug = ""
        var lastWasDash = true
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "tunnel" }

        guard existing.contains(slug) else { return slug }
        var n = 2
        while existing.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }
}
