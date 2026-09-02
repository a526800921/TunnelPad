# TunnelPad 稳定性计划阶段 1 独立准入复核

- 日期：2026-09-02
- 阶段：阶段 1
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- Step 0 证据：[阶段 1 Step 0 证据](tunnelpad-stability-stage1-step0-20260902.md)
- 前置证据：[阶段 0 独立准入复核](tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md)
- 结论：未达到“待实施标准”。

## 逐项核对

| 准入条件 | 核对结果 | 证据与判断 |
|---|---|---|
| 阶段 1 目标、范围和非目标明确 | 通过 | 阶段 1 只处理当前 `launchd` 的后台健康监测、状态收敛、配置 fail-closed 和单隧道恢复状态机；继续使用 HTTP 探针，不新增 Schema，不处理 app 执行器，不改变日志事件流，不连接真实隧道、SSH、ECS 或 `launchctl`。 |
| Step 0 基线类型明确 | 通过 | 阶段 1 Step 0 固定为“生产实现现状快照 + 高影响调用图复核 + 隔离故障注入矩阵”，并明确阶段 0 契约 fixture 仅作为策略输入，不能作为生产实现证据。 |
| 4 个高影响 upstream impact | 通过（但要求实施前重跑） | 当前记录并复核了：`TunnelManager` CRITICAL（84 个符号/70 个直接影响）、`RustLifecycleOwner` CRITICAL（77 个/54 个直接影响且为下界）、`ProbeCoordinator` CRITICAL（71 个/55 个直接影响）、`TunnelRuntimeState` LOW（16 个/2 个直接影响）。高风险不阻塞 Step 0，但任何生产符号修改前必须重新执行 impact。 |
| 8 行故障注入矩阵 | 通过（设计准入） | 8 行均包含输入/基线、可执行命令或操作、预期结果、失败判定和输出位置，覆盖后台监测、三次失败与第十次熔断、`keepAlive`/手动操作、配置候选与代次、launchd 生命周期、ECS 运行中同步、启动/退出收敛。 |
| 验证方式 | 通过（设计准入） | 已指定 fake clock/probe、fake `launchd`、隔离配置、ECS 双端点和代次/取消 fixture，并要求专项测试、全量 Swift/Rust 回归、治理检查和提交前 `detect_changes()`。实际生产接入测试尚未执行。 |
| 失败、回滚和安全边界 | 通过 | 失败、来源不确定、代次不一致或跨隧道影响均 fail-closed；实现按独立提交回滚；禁止删除真实 plist、启停真实隧道或使用真实 SSH/ECS。 |
| Rust owner / ADR / migration 约束 | 通过 | [ADR-0001](../adr/0001-rust-core-single-owner.md) 与 [Rust owner 切换迁移](../migrations/tunnelpad-rust-owner-cutover.md)要求 Rust Core 作为配置、生命周期、运行时状态、操作代次和取消的唯一 owner；阶段 1 不得新增 Swift 第二套恢复协调器。 |
| 已完成日志计划的共享边界 | 通过 | 日志计划阶段 0–3 已在 `08d2ac5` 完成；[ADR-0003](../adr/0003-log-event-stream-and-retention.md) 保持日志事件/缓存/UI 订阅边界，阶段 1 修改 `TunnelManager`、`TunnelRuntimeState`、主面板或共享测试目录时必须单一编辑窗口、串行合入。 |
| 严格治理结构 | 通过但不等于准入通过 | `plan-governance-cli check . --strict-readiness`、`plan-governance-cli graph validate .` 和 `git diff --check` 均通过；这些命令只证明结构与格式，不替代当前阶段无阻塞项和独立准入结论。 |
| 当前阶段无未解决阻塞项 | 未通过 | 专项计划阶段 1 的“当前阻塞项”仍明确列出生产状态机、launchd/config 接入测试和阶段 1 独立准入尚未完成；阶段 1 Step 0 只完成设计与基线登记，生产实现尚未修改。 |
| `PLAN_MAP` 与最新阶段证据同步 | 未通过 | `PLAN_MAP` 当前将稳定性计划标为“设计中/阶段 1”，仍只链接阶段 0 证据和阶段 0 独立复核，尚未登记 `tunnelpad-stability-stage1-step0-20260902.md` 或本次阶段 1 复核；本次委托明确禁止修改 `PLAN_MAP`，因此该同步尚未完成。 |
| 最新独立准入复核通过 | 未通过 | 阶段 1 计划当前记录为“等待阶段 1 独立准入复核”；本文件给出独立结论，但结论为未达到“待实施标准”。 |

## 独立验证记录

| 检查 | 结果 | 说明 |
|---|---|---|
| `xcodebuildmcp swift-package test --package-path . --filter StabilityStage0BaselineTests` | 4/4 通过 | 仅证明阶段 0 现状缺口基线，不能证明阶段 1 生产恢复已实现。 |
| `xcodebuildmcp swift-package test --package-path . --filter StabilityStage0ContractTests` | 6/6 通过 | 仅测试契约 oracle，不能替代阶段 1 生产协调路径测试。 |
| `cargo test --manifest-path rust/Cargo.toml owner::tests::stage0_baseline_restart_continues_after_bootout_error -- --exact` | 1/1 通过 | 脚本化 launchd runner 的阶段 0 基线，未调用真实 `launchctl`。 |
| GitNexus upstream impact | 4 个目标已复核 | `TunnelManager`、`RustLifecycleOwner`、`ProbeCoordinator`、`TunnelRuntimeState` 的影响面与 Step 0 记录一致。 |
| `plan-governance-cli check . --strict-readiness` | 通过 | 结构检查通过，不把它解释为阶段 1 业务准入通过。 |
| `plan-governance-cli graph validate .` | 通过 | 功能图谱 schema 与引用校验通过。 |
| `git diff --check` | 通过 | 未发现空白错误。 |

## 剩余阻塞项

1. 阶段 1 当前阻塞项尚未清空：生产后台监测、恢复状态机、launchd/config 接入和取消/代次集成测试尚未实施或验证。
2. `PLAN_MAP` 尚未同步阶段 1 Step 0 和本次独立复核证据；本次按委托不修改该文件，实际实施前必须完成同步。
3. 4 个高影响目标虽已完成 Step 0 复核，但生产实现前仍需针对将要修改的具体符号重新执行 upstream impact，并记录 HIGH/CRITICAL 处理边界。

## 结论与后续门槛

阶段 1 的 Step 0 设计和证据矩阵已经具备，但按严格准入最低条件，当前不能标记为“待实施”：计划仍存在明确阻塞项，且 `PLAN_MAP` 尚未同步最新阶段 1 证据。清空阻塞并完成治理同步后，才可重新申请阶段 1 准入。

即使阶段 1 通过准入，后续阶段 1 生产实现仍必须独立完成其实现前/实现后的 Step 0、专项故障注入、测试覆盖、`detect_changes()` 和独立复核；不能以阶段 0 契约 fixture、全量回归或本文件替代生产行为验收。

本次复核仅读取仓库、执行隔离/fake 测试和只读治理检查；没有修改计划、`PLAN_MAP`、源代码或测试，没有启动真实隧道，没有调用真实 `launchctl`、SSH 或 ECS。
