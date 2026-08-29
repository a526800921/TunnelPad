import Foundation

/// 由 TunnelConfig 生成 launchd plist（XML）。
/// plist 只写入 TunnelPad 自己的 Application Support 目录（保证退出即停、重启不自启）。
public enum LaunchdPlistRenderer {
    public static func plistDictionary(for tunnel: TunnelConfig, logURL: URL) -> [String: Any] {
        [
            "Label": tunnel.launchdLabel,
            "ProgramArguments": tunnel.command,
            "RunAtLoad": true,
            "KeepAlive": tunnel.keepAlive,
            "ProcessType": "Background",
            "ThrottleInterval": tunnel.throttleInterval,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }

    public static func plistXMLData(for tunnel: TunnelConfig, logURL: URL) throws -> Data {
        let dict = plistDictionary(for: tunnel, logURL: logURL)
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @discardableResult
    public static func writePlist(for tunnel: TunnelConfig, paths: TunnelPaths) throws -> URL {
        let url = paths.launchdPlistURL(for: tunnel)
        try FileManager.default.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
        let data = try plistXMLData(for: tunnel, logURL: paths.logURL(for: tunnel))
        try data.write(to: url, options: .atomic)
        return url
    }
}
