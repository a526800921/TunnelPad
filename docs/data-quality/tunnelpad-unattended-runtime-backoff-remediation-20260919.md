# TunnelPad 无人值守运行期退避修复证据（2026-09-19）

## 现场反例

真实运行日志显示：SSH 因 ECS 远端 `18080` 仍被旧会话占用而快速退出，launchd 状态监控每秒发现一次状态变化；恢复任务只看到短暂 `running` 就结束，下一轮监控又将其当作新的首次故障并以 0 秒调度。单次偶发健康结果还会清空恢复计数，因此日志形成约 2 秒一次的同步、重启与失败循环。

该现象证明此前“每次监控事件都立即恢复”和“单次成功即清零”的组合不满足长时无人值守要求。它不改变 bootout-first、ECS 前置同步、身份核验和 fail-closed 边界。

## 本次决策

- 启动期与运行期采用同一恢复节奏：`0、5、10、30、60、60……` 秒。
- 第一次 0 秒由状态机第 1 次尝试自然产生，调用方不再传入“首次立即”的特殊覆盖值。
- 任何结构化前置错误都不得覆盖恢复状态机的序列；共享认证结果可以缓存 60 秒以避免重复访问云端，无效配置复查和 helper 提示也以 60 秒为上限，不再保留 300 秒恢复等待。
- 恢复后至少连续两次健康采样才清空运行期恢复计数；一次短暂成功不再把下一次失败重置为 0 秒。
- 重试仍然永久保留恢复意图；60 秒是封顶间隔，不是停止阈值。

## 实现范围

- `HealthRecoveryPolicy` 固定统一退避序列和 60 秒上限；`HealthRecoveryState` 增加连续恢复确认计数。
- `TunnelManager` 的 launchd/IP 漂移入口取消 0 秒调用方特判；运行期 ECS 错误分类不再覆盖状态机退避，无效配置复查封顶 60 秒。
- `LaunchRecoveryCoordinator` 的启动恢复与共享 ECS 认证冷却复用同一上限。
- Swift 解码兜底、打包脚本和 Rust preflight 的认证/本地/未知错误提示及认证冷却均由 300 秒改为 60 秒。
- 隔离测试固定完整序列、短暂 `running` 后进入 5 秒退避、60 秒封顶以及连续两次健康确认契约。

## 验证结果

- Swift 全量：197 项通过，0 失败。
- Rust 全量：111 项通过，0 失败。
- ECS fixture：18 项通过；监督与恢复测试：9 项通过。
- Release 编译：XcodeBuildMCP Swift Package `release` 构建通过。
- 静态门禁：`git diff --check`、Rust `cargo fmt --check`、脚本 `bash -n` 均通过；生产源码/脚本/Rust helper 已无 300 秒 retry hint、sleep 或纳秒退避常量。
- 影响与治理：GitNexus `detect-changes --scope all` 报告 45 条受影响流程、总体 `critical`，与共享恢复链预期一致；`plan-governance-cli check . --strict-readiness` 通过。
- 代码自验阶段没有打包、替换或重启当时运行的 App，没有创建 App 备份，也没有写入真实 ECS；随后按下节记录部署同一提交的新包。

## 新版部署与启动

- 提交：`8502ecd`（`fix: cap unattended recovery backoff`）。
- 使用项目 `scripts/build_app.sh --skip-tests` 在临时目录构建新包；深度签名、Info.plist、资源脚本一致性和包内 300 秒残留扫描通过。新主程序 SHA-256 为 `901f9cf6572697fc5eb178c5682805918b06984bd1d3158733af01c10f02af37`。
- 旧 App 先通过 XcodeBuildMCP 优雅停止；App、受管代理、SSH 和 launchd label 均退出后才原位替换 `dist/TunnelPad.app`。旧包随后从临时目录删除，未保留备份 App。
- 新 App 由 XcodeBuildMCP 启动成功，Bundle ID 为 `com.jafish.tunnelpad.app`；观察时 App PID `85781`、代理 PID `86245`、SSH PID `86285`，launchd 为 `running`、`runs = 1`、`last exit code = (never exited)`。
- 本地 `127.0.0.1:9998` 和 `127.0.0.1:10080` 均由预期进程监听。Workbench 当前未列出实例，因此按项目回退边界使用目标 SSH 做只读 `ss` 核对；ECS `127.0.0.1:18080` 只有一个 `sshd` listener。
- `app.log` 在本地 21:32:08 建立 1 条启动恢复候选并记录一次 `transient`，21:32:14 确认运行，符合首次失败后约 5 秒重试；持续观察超过 1 分钟 PID 未变化。隧道日志最后一条旧错误仍为 21:07:44，新版启动后没有新增 `18080` 转发失败。

## 剩余验收

当前运行实例已经替换为新 build，但本次只验证了启动期一次 `transient → 5 秒后成功` 和稳定运行，没有主动制造连续端口冲突。后续仍需受控复现一次远端端口冲突或等价快速退出，确认完整日志节奏为首次立即、随后 5/10/30/60 秒封顶，并同时核对单实例 SSH、`18080` listener 和孤儿进程。该真实验收失败时保持计划“实施中”，不得以本证据关闭计划。
