# TunnelPad 界面优化——阶段 4 菜单栏单项启停证据（2026-08-30）

## 基线与实现

- 基线代码：`Sources/tunnelpad/MenuBarController.swift` 的 `rebuildMenu` 原先按 `tunnel.executor == .launchd` 设置菜单项 enabled，app 执行器条目被禁用。
- 实现变更：菜单项现在仅在 `manager.busyIDs` 不包含该隧道 id 时启用；点击仍进入既有 `toggleTunnel(_:)`，按 `TunnelStatus` 分派到 `TunnelManager.start/stop`。
- 未修改：`TunnelManager`、config schema、执行器实现和退出语义。
- 菜单栏调整：移除“启动全部”“停止全部”，仅保留逐条隧道启停、打开主面板和退出入口；主窗口原有批量入口也不恢复。

## 自动验证

| 项目 | 结果 | 证据 |
|---|---|---|
| Debug 构建 | 通过 | `swift build`，Build complete，无编译错误。 |
| Core 回归 | 通过 | `swift test`，63 tests，0 failures。 |
| Release 打包 | 通过 | `./scripts/build_app.sh --skip-tests`；release 构建、Info.plist、ad-hoc 签名、`plutil -lint` 和 `codesign --verify --deep --strict` 均通过。 |
| 真实配置保护 | 通过 | 打包期间 `config.json` 保持两条真实隧道；`admin-tunnel` 探针仍为 401 ✓。 |
| 批量入口移除 | 通过 | `rg -n "启动全部|停止全部|startAll|stopAll" Sources/tunnelpad/MenuBarController.swift` 无匹配；最终 Release 包由该源码构建。 |

## 实机状态

- 用独立 Stage4 App 实例启动并读取主窗口，确认两条真实隧道状态正常、主窗口无异常。
- 用户手动打开状态栏菜单并确认 launchd/app 单项启动与停止正常；busy 禁用规则由 `manager.busyIDs` 代码路径保持。
- 批量入口移除后通过 `MenuBarController` 源码核对和最终 Release 包构建确认，不再由菜单构建代码生成“启动全部”“停止全部”。

## 结论

阶段 4 的代码实现、状态栏单项启停实机验证、批量入口移除、Debug/Release 构建和全量 Core 回归均已通过，计划可关闭。
