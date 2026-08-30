# TunnelPad 代码质量重构：阶段 1 实施证据（含跨阶段兼容切片，2026-08-30）

## 范围

本轮实现以用户确认的“外部使用功能保持正常”为硬约束，涉及 Core 内部边界、异步生命周期和 UI 表单/轮询实现；未修改 `config.json` schema、launchd 标签、日志路径、菜单栏批量入口、迁移语义或现有同步门面方法。阶段 2–4 的追加硬化和 AX 冒烟见[阶段 2–4 实施证据](tunnelpad-code-quality-refactor-stage2-4-20260830.md)。

当前工作树中 `AGENTS.md`、ECS 计划、ECS fixtures/脚本等既有改动不属于本轮重构，未纳入本证据的实现范围。

## 实施内容

1. Core 边界
   - 新增内部 `TunnelConfigRepository`，`TunnelManager` 不再绑定 `ConfigStore` 具体实现。
   - 新增 `LaunchdExecuting`、`AppExecuting` 能力协议；保留 `LaunchCtlExecutor`、`AppProcessExecutor` 公共类型和调用方式。
   - 新增 `TunnelRuntimeState` 聚合状态，`statuses`、`probeResults`、`busyIDs` 仍由原有 `@Published` 属性投影。
   - 新增 `TunnelLifecycleCoordinator`，同步入口和异步入口共享同一套启停结果/错误文案。
2. 异步与竞态
   - `startAsync`、`stopAsync`、`restartAsync`、`removeTunnelAsync`、`updateTunnelAsync` 和 `refreshAsync` 将系统调用移出主线程；原有同步入口保留。
   - `ProbeCoordinator` 使用 actor + generation 丢弃迟到探针结果；状态刷新也使用 generation 防止旧快照回写。
   - app keepAlive 维护独立代际计数；手动停止/退出会使延迟重启失效。
3. UI 组合与轮询
   - 新增 `TunnelFormState`，新建/编辑共用命令解析、探针校验、默认值和 SSH `-v` 操作。
   - 主面板启动、停止、重启、删除和菜单栏切换使用异步兼容入口。
   - 主窗口隐藏时停止 5 秒状态轮询和 2 秒日志轮询；重新显示后自动恢复。

## 验证矩阵

| # | 输入/命令 | 预期 | 结果 |
|---|---|---|---|
| 1 | `swift test` | Core 与可执行目标构建；全部既有和新增用例通过 | 通过：73 个测试，0 失败 |
| 2 | `swift test --filter RefactorBoundaryTests` | 状态聚合、配置 repository、探针取消、异步启停/删除兼容和保存回滚测试通过 | 通过：7 个测试，0 失败 |
| 3 | `swift build` | `TunnelPadCore` 和 `tunnelpad` 可构建 | 通过 |
| 4 | `git diff --check` | 无空白错误 | 通过 |
| 5 | `plan-governance-cli check . --strict-readiness` | 计划结构和索引无 ERROR | 通过；仅保留既有 ECS 重复目标 WARNING |
| 6 | GitNexus `detect_changes(scope=all, worktree=...)` | 识别本轮改动影响的 Core/UI 流程，供回归复核 | 已完成；变更影响范围被标记为 critical，需按现有 73 项测试和用户可控实机回归继续观察 |

## 兼容性核对

- `TunnelManager` 原有公开初始化器、`start/stop/restart/removeTunnel/refresh` 等同步入口仍存在。
- 菜单栏仍只有单条隧道切换、打开主面板和退出；未恢复批量启动/停止。
- 原有启停成功/失败文案、状态枚举、配置字段与文件路径保持不变。
- 取消和 generation 只抑制迟到结果或失效的 keepAlive 重启，不改变有效操作的最终状态。

## 未覆盖与下一步

- 当前没有在真实 launchd 隧道上进行手动启停/删除；阶段 4 已完成只读应用 AX 冒烟，真实实例操作仍需用户指定安全样本。
- 本证据代表阶段 1 实施验证，不替代阶段 4 的真实 UI/隧道业务验收；阶段 1 已完成，计划状态由阶段 4 专项计划收口。
