import Foundation

struct TunnelOperationOutcome: Sendable, Equatable {
    var message: String?
    var error: String?
    var refresh: Bool = true
}

/// 把 launchd/app 的同步系统调用隔离到后台任务。
///
/// TunnelManager 继续作为 @MainActor 门面，界面可使用 async 入口等待结果；
/// 原有同步入口仍保留给兼容调用方和退出路径。
struct TunnelLifecycleCoordinator: Sendable {
    let paths: TunnelPaths
    let launchd: any LaunchdExecuting
    let app: any AppExecuting

    func start(_ tunnel: TunnelConfig) async -> TunnelOperationOutcome {
        await Task.detached(priority: .userInitiated) { self.startSync(tunnel) }.value
    }

    func startSync(_ tunnel: TunnelConfig) -> TunnelOperationOutcome {
        switch tunnel.executor {
        case .launchd:
            if case .running = launchd.status(label: tunnel.launchdLabel) {
                return TunnelOperationOutcome(message: nil, error: nil, refresh: false)
            }
            do {
                let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
                try launchd.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
                return TunnelOperationOutcome(message: "「\(tunnel.name)」已启动")
            } catch {
                return TunnelOperationOutcome(message: nil, error: "启动「\(tunnel.name)」失败：\(error)")
            }
        case .app:
            do {
                try app.start(tunnel)
                return TunnelOperationOutcome(message: "「\(tunnel.name)」已启动（app 执行器）")
            } catch {
                return TunnelOperationOutcome(message: nil, error: "启动「\(tunnel.name)」失败：\(error)")
            }
        }
    }

    func stop(_ tunnel: TunnelConfig) async -> TunnelOperationOutcome {
        await Task.detached(priority: .userInitiated) { self.stopSync(tunnel) }.value
    }

    func stopSync(_ tunnel: TunnelConfig) -> TunnelOperationOutcome {
        switch tunnel.executor {
        case .launchd:
            do {
                try launchd.bootout(label: tunnel.launchdLabel)
                return TunnelOperationOutcome(message: "「\(tunnel.name)」已停止")
            } catch {
                return TunnelOperationOutcome(message: nil, error: "停止「\(tunnel.name)」失败：\(error)")
            }
        case .app:
            app.stop(tunnel)
            return TunnelOperationOutcome(message: "「\(tunnel.name)」已停止")
        }
    }

    /// 删除流程专用的停止结果，只返回原始错误，便于门面保留“删除失败：停止实例出错”文案。
    func stopForDeletion(_ tunnel: TunnelConfig) async -> String? {
        await Task.detached(priority: .userInitiated) { [launchd, app] in
            switch tunnel.executor {
            case .launchd:
                // 与兼容的同步删除入口保持一致：未加载时不调用 bootout，
                // 避免把“已停止”误报成删除失败。
                guard launchd.status(label: tunnel.launchdLabel) != .notLoaded else {
                    return nil
                }
                do {
                    try launchd.bootout(label: tunnel.launchdLabel)
                    return nil
                } catch {
                    return String(describing: error)
                }
            case .app:
                app.stop(tunnel)
                return nil
            }
        }.value
    }

    func status(for tunnel: TunnelConfig) async -> TunnelStatus {
        await statuses(for: [tunnel])[tunnel.id] ?? .notLoaded
    }

    func restart(_ tunnel: TunnelConfig) async -> TunnelOperationOutcome {
        await Task.detached(priority: .userInitiated) { self.restartSync(tunnel) }.value
    }

    func restartSync(_ tunnel: TunnelConfig) -> TunnelOperationOutcome {
        switch tunnel.executor {
        case .launchd:
            do {
                _ = try? launchd.bootout(label: tunnel.launchdLabel)
                let plistURL = try LaunchdPlistRenderer.writePlist(for: tunnel, paths: paths)
                try launchd.bootstrap(label: tunnel.launchdLabel, plistURL: plistURL)
                return TunnelOperationOutcome(message: "「\(tunnel.name)」已重启")
            } catch {
                return TunnelOperationOutcome(message: nil, error: "重启「\(tunnel.name)」失败：\(error)")
            }
        case .app:
            do {
                try app.restart(tunnel)
                return TunnelOperationOutcome(message: "「\(tunnel.name)」已重启")
            } catch {
                return TunnelOperationOutcome(message: nil, error: "重启「\(tunnel.name)」失败：\(error)")
            }
        }
    }

    func statuses(for tunnels: [TunnelConfig]) async -> [String: TunnelStatus] {
        await Task.detached(priority: .utility) { self.statusesSync(for: tunnels) }.value
    }

    func statusesSync(for tunnels: [TunnelConfig]) -> [String: TunnelStatus] {
        var result: [String: TunnelStatus] = [:]
        for tunnel in tunnels {
            switch tunnel.executor {
            case .launchd:
                result[tunnel.id] = launchd.status(label: tunnel.launchdLabel)
            case .app:
                result[tunnel.id] = app.status(id: tunnel.id)
            }
        }
        return result
    }
}
