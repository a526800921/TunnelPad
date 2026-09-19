import Foundation

/// 由 TunnelConfig 生成 launchd plist（XML）。
/// plist 只写入 TunnelPad 自己的 Application Support 目录（保证退出即停、重启不自启）。
public enum LaunchdPlistRenderer {
    public static func plistDictionary(
        for tunnel: TunnelConfig,
        logURL: URL,
        logProxyURL: URL? = nil
    ) -> [String: Any] {
        let command = logProxyURL.map { proxyURL in
            [proxyURL.path, "--log", logURL.path, "--"] + tunnel.command
        } ?? tunnel.command
        let outputPath = logProxyURL == nil ? logURL.path : "/dev/null"
        // 无人值守 SSH 由 TunnelManager 统一执行“停止→ECS 同步→启动”。
        // 禁止 launchd 在 ECS 预检之前自行 KeepAlive 重启，避免双重所有者。
        let launchdKeepAlive = tunnel.keepAlive
            && !(tunnel.autoStart && SSHCommand.isSSH(tunnel.command))
        var dictionary: [String: Any] = [
            "Label": tunnel.launchdLabel,
            "ProgramArguments": command,
            "RunAtLoad": true,
            "KeepAlive": launchdKeepAlive,
            "ProcessType": "Background",
            "ThrottleInterval": tunnel.throttleInterval,
            "StandardOutPath": outputPath,
            "StandardErrorPath": outputPath,
        ]
        if logProxyURL != nil {
            // 代理和 SSH 共享 launchd 作业进程组；代理被强制终止时，
            // launchd 仍能清理同组的受管 SSH/后代。
            dictionary["AbandonProcessGroup"] = false
        }
        return dictionary
    }

    public static func plistXMLData(
        for tunnel: TunnelConfig,
        logURL: URL,
        logProxyURL: URL? = nil
    ) throws -> Data {
        let dict = plistDictionary(for: tunnel, logURL: logURL, logProxyURL: logProxyURL)
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @discardableResult
    public static func writePlist(for tunnel: TunnelConfig, paths: TunnelPaths) throws -> URL {
        let url = paths.launchdPlistURL(for: tunnel)
        try FileManager.default.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
        let data = try plistXMLData(
            for: tunnel,
            logURL: paths.logURL(for: tunnel),
            logProxyURL: try installedLogProxyURL(paths: paths)
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func installedLogProxyURL(paths: TunnelPaths) throws -> URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            // SwiftPM/XCTest 直接调用 renderer 时没有 App Bundle；保留旧的
            // 直写 fixture，不让测试运行时伪造发布资源。
            return nil
        }
        guard let resourceURL = Bundle.main.resourceURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "TunnelPad Resources"])
        }
        let source = resourceURL.appendingPathComponent("tunnelpad-log-proxy")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }

        let destinationDirectory = paths.supportDirectory
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = destinationDirectory.appendingPathComponent("tunnelpad-log-proxy")
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        return destination
    }
}
