# TunnelPad 能耗计划完成后回归修复：启动过渡态收敛

- 日期：2026-09-04
- 类型：完成后回归修复与验证记录
- 结论：已修复并通过回归验证
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)

## 问题

`reverse-ssh` 没有 HTTP 探针。点击启动后，`launchd` 可能先返回 `other(xpcproxy)` 这一启动过渡态；能耗优化移除主窗口周期性全量 `refreshAsync()` 后，没有探针的隧道不会再被后台周期重新读取，因此该过渡态可能长期留在 UI 和本机 API 的运行时缓存中。

本次只读核对还观察到：本机 API 的缓存状态可以落后于 `launchctl` 的实际运行状态，符合“启动后状态没有收敛”的故障特征。`xpcproxy` 本身不是启动失败，而是需要等待后再次读取的中间状态。

## 修复方案

- 在 `TunnelManager.startAsync` 和 `restartAsync` 的显式生命周期操作完成后，仅对当前隧道执行状态复核。
- 仅对 `notLoaded`/`other` 状态进入复核；每次间隔 100ms，最多 30 次，读到 `running` 立即更新 UI/API 状态。
- 每次读取都检查当前操作代次和取消状态；旧操作、退出或取消不能回写新状态。
- 复核超时或状态读取失败时保留最后一次真实状态，不猜测为运行中。
- 不恢复后台全量 snapshot，不新增探针，不改变配置、SSH、ECS、Rust Core owner、HTTP API 或 launchd label。

## 验证证据

| 项目 | 命令/输入 | 结果 |
|---|---|---|
| 回归 fixture | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter StabilityStage2Tests.testManualStartSettlesTransientLaunchdStatus --output text` | 1/1 通过；`xpcproxy → running` 被收敛，结果和缓存均为 running |
| Swift 全量回归 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --output text` | 140/140 通过 |
| 格式检查 | `git diff --check` | 通过 |
| 变更影响复核 | GitNexus `impact(startAsync, upstream)` | HIGH；直接调用方为详情页、菜单栏和本机 API，已按该边界保持窄改动 |
| 计划治理 | `plan-governance-cli check .`；`plan-governance-cli check . --strict-readiness` | 通过（文档同步后复核） |

## 边界与后续

本记录是已完成计划的回归修复，不重新打开原阶段，也不把一次性启动复核误报为后台健康监测。若后续仍观察到 `xpcproxy` 在 3 秒有界窗口后持续存在，应按 launchd/目标进程启动失败继续诊断；本修复不会以过期缓存把它强行标记为 running。
