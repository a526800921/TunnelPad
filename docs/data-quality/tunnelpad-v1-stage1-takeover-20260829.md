# TunnelPad v1 阶段 1 迁移接管与验证记录（2026-08-29）

- 执行时间：2026-08-29 16:38–17:05 CST
- 执行者：ZCode Agent（实施轮次）
- 前置基线：[tunnelpad-v1-stage0-baseline-20260829.md](tunnelpad-v1-stage0-baseline-20260829.md)
- 代码：commit `43f23ff`（阶段 1 全部实现）+ SIGTERM 修复（见下文，收尾提交）

## 验收口径对照（用户 2026-08-29 确认）

| 验收项 | 结果 | 证据 |
|---|---|---|
| 构建 + 全部测试通过 | ✅ | `swift build` 零告警零错误；`swift test` 29 用例全部通过（ConfigStore 4、Renderer 2、Executor 9、Importer 4、Migration 4、TunnelConfig 6） |
| 真实接管两条隧道 | ✅ | 两条均经 UI"导入并接管"完成；新标签 running、旧标签卸载、命令逐字等价、curl/ECS 探测通过 |
| 杀 ssh 进程 → launchd 秒级自动重连 | ✅ | kill 新标签 ssh pid 86516 后 **1 秒**恢复为 pid 86678（state=running），curl 恢复 401 |
| 退出 app → launchctl 里代理消失、隧道断开 | ✅ | 两条路径均验证：菜单"退出 TunnelPad"（applicationShouldTerminate）与 SIGTERM（Shutdown 信号路径）；退出后两标签 `Could not find service`、8081 拒连、ECS 22022 无监听 |
| 重启 app → 一键恢复 | ✅ | 重启 app →"全部启动"一次点击 → 两标签 running，curl 401、ECS `LISTEN 127.0.0.1:22022` |

## 接管过程与证据

### admin-tunnel（16:46）

- UI 迁移区列出 `com.jafish.motorcycle-manual.admin-tunnel`，点击"导入并接管"。
- 结果：`com.jafish.tunnelpad.admin-tunnel` `state=running`（pid 86516）；旧标签 `Could not find service`；`curl --noproxy '*' http://127.0.0.1:8081/admin` → `401`。
- 备份：`~/Library/Application Support/TunnelPad/migration-backup/20260829-164605-com.jafish.motorcycle-manual.admin-tunnel.plist`
- config.json 落盘，`command` 数组与阶段 0 基线的 ProgramArguments **逐字一致**（含 `ConnectTimeout=10`、`ThrottleInterval=10`）。

### reverse-ssh（16:46）

- 同流程。结果：`com.jafish.tunnelpad.reverse-ssh` `state=running`（pid 86593）；旧标签卸载；ECS 侧 `ss -tln | grep 22022` → `LISTEN 127.0.0.1:22022`。
- 备份：`~/Library/Application Support/TunnelPad/migration-backup/20260829-164632-com.jafish.motorcycle-manual.reverse-ssh.plist`

### 收尾状态核查

- `~/Library/LaunchAgents/` 下已无 `com.jafish.motorcycle-manual.*` plist（`ls | grep motorcycle` 为空）。
- 接管期间隧道探测始终等价（401 / LISTEN 22022），未出现不可用窗口（bootout→bootstrap 间隔亚秒级）。

## 杀进程自动重连（16:47）

```
kill 86516（com.jafish.tunnelpad.admin-tunnel 的 ssh pid）
→ 1s 内 launchd 重新拉起：state=running，新 pid 86678
→ curl 8081/admin → 401
```

与阶段 0 观察的 KeepAlive 行为一致；`ThrottleInterval=10` 未造成可感知延迟。

## 退出即停（两条路径）

### 路径 1：SIGTERM（logout/shutdown/kill 场景，16:48 发现缺陷并修复）

- 首次 `kill -TERM` 测试：app 进程退出但**两条 agent 未卸载**。崩溃报告 `~/Library/Logs/DiagnosticReports/tunnelpad-2026-08-29-164820.ips` 显示 `EXC_BREAKPOINT` → `dispatch_assert_queue_fail`：信号处理闭包在 `@MainActor` 的 AppDelegate 内创建，继承了主线程隔离断言，在全局队列触发即崩溃。
- 修复：信号安装移入 `TunnelPadCore.Shutdown.installSignalHandlers()`（nonisolated，直接读 config.json 停全部隧道后 `exit`），AppDelegate 只调用它。
- 复测（16:52，pid 88777）：`kill -TERM` → app 退出 → 两标签 `Could not find service` → 8081 无监听。✅

### 路径 2：正常退出（菜单"退出 TunnelPad"，17:00）

- 通过 System Events AXPress 点击应用菜单"退出 TunnelPad"（触发 `NSApp.terminate` → `applicationShouldTerminate` 后台逐条 bootout → `reply(toApplicationShouldTerminate:)`）。
- 结果：app 退出 → 两标签 `Could not find service` → curl 8081 拒连 → ECS 22022 无监听。✅

## 重启恢复（16:58 与 17:03 各一次）

- 重启 app：配置自动加载（两条隧道列表、"已停止"灰点、无迁移区残留——LaunchAgents 已无旧 agent）。
- 点击"全部启动"：两标签 `state=running`，curl 401、ECS LISTEN 22022。
- 最终状态：TunnelPad 常驻（菜单栏 + 主面板），两条隧道由 `com.jafish.tunnelpad.*` 托管运行。

## 已知边界（如实登记）

1. **SIGTERM 崩溃缺陷**在首次退出验证中发现，已修复并复测通过；崩溃报告 .ips 留存在 `~/Library/Logs/DiagnosticReports/`（本机文件，不入仓库）。
2. 开发期以裸二进制运行（`.build/debug/tunnelpad`），**会显示 Dock 图标**；LSUIElement 菜单栏纯常驻行为随阶段 2 `build_app.sh` 打包落实（计划内）。
3. app 崩溃（无法执行任何清理）时 launchd agent 继续运行——计划已知情接受的边界；下次启动 app 可重新纳管。
4. 回滚演练未实际执行（避免对在线隧道多做两次切换）；回滚命令与备份位置已验证存在（备份文件在 migration-backup，恢复 = 移回 `~/Library/LaunchAgents` + `launchctl bootstrap`）。
5. reverse-ssh 长期高频重拉史（阶段 0 `runs=7126`）为 ECS 侧/网络因素，非本阶段引入；接管后由 launchd 同等 KeepAlive 语义承接。

## 跨仓库同步

- motorcycle-manual-app 仓库 `docs/plans/user-document-processing-admin.md` 阶段证据已追加"admin 隧道托管方变更"记录（commit `e4f2c4b`，2026-08-29）：后台访问方式（SSH 隧道 + 回环 8081 + HTTP Basic）与公网零入口边界不变。
