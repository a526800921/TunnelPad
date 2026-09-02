# TunnelPad 稳定性计划阶段 1 独立准入复核（r2）

- 日期：2026-09-02
- 阶段：阶段 1
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- Step 0 证据：[阶段 1 Step 0 证据](tunnelpad-stability-stage1-step0-20260902.md)
- 上一轮复核：[阶段 1 独立准入复核](tunnelpad-stability-stage1-independent-review-20260902.md)
- 结论：达到“待实施标准”。

## 复核范围

本轮基于当前工作树重新核对，不沿用上一轮结论。复核读取了 `PLAN_MAP.md`、稳定性专项计划、阶段 1 Step 0、上一轮复核，以及其引用的 [ADR-0001](../adr/0001-rust-core-single-owner.md)、[Rust owner 切换迁移](../migrations/tunnelpad-rust-owner-cutover.md) 和 [ADR-0003](../adr/0003-log-event-stream-and-retention.md)。

## 严格准入逐项核对

| 准入条件 | 当前结果 | 证据与判断 |
|---|---|---|
| 阶段 1 目标、范围和非目标 | 通过 | 只实现当前 `launchd` 范围内的后台健康监测、状态收敛、配置 fail-closed 和单隧道恢复状态机；使用现有 HTTP 探针，固定 3 次失败、10/30/60/300 秒退避和第 10 次熔断；不新增 Schema、不处理 app 执行器、不改变日志事件流、不连接真实隧道、SSH、ECS 或真实 `launchctl`。 |
| 阶段 1 自身 Step 0 | 通过 | Step 0 已固定为“生产实现现状快照 + 高影响调用图复核 + 隔离故障注入矩阵”，并明确阶段 0 契约 oracle 不能替代生产接入证据。[Step 0](tunnelpad-stability-stage1-step0-20260902.md:6-13) |
| 4 个高影响 upstream impact | 通过 | `TunnelManager`：CRITICAL，84 个符号/70 个直接影响；`RustLifecycleOwner`：CRITICAL，77 个/54 个直接影响且为下界；`ProbeCoordinator`：CRITICAL，71 个/55 个直接影响；`TunnelRuntimeState`：LOW，16 个/2 个直接影响。影响已转化为实施前重跑和单一编辑窗口约束。 |
| 8 行可执行故障注入矩阵 | 通过 | 8 行均包含输入/基线、命令或操作、预期结果、失败判定和输出位置，覆盖窗口隐藏后台监测、三次失败/第十次熔断、`keepAlive`/手动操作、配置候选/代次、launchd 生命周期、ECS 运行中同步、启动/退出收敛。 |
| 验证方式 | 通过 | 已规定 fake clock/probe、fake `launchd`、隔离配置、ECS 双端点、取消/代次 fixture，以及专项测试、全量 Swift/Rust 回归、治理检查和提交前 `detect_changes()`。生产接入测试属于通过准入后的实施验证，不是 Step 0 的缺失。 |
| 失败/回滚/安全边界 | 通过 | 失败、来源不确定、代次不一致和跨隧道影响均 fail-closed；实现按独立提交回滚；不删除真实 plist、不启停真实隧道、不修改远端安全组或凭证。 |
| Rust owner、ADR 与迁移边界 | 通过 | ADR-0001 与 owner 切换迁移明确 Rust Core 是配置、生命周期、运行时状态、操作代次和取消的唯一 owner；阶段 1 不得新增 Swift 第二套恢复协调器，健康恢复必须复用该边界。 |
| 已完成日志计划的共享边界 | 通过 | 日志计划阶段 0–3 已在 `08d2ac5` 完成；ADR-0003 保持日志采集、缓存和 UI 订阅边界。阶段 1 修改 `TunnelManager`、`TunnelRuntimeState`、主面板或共享测试目录时，必须单一编辑窗口、串行合入，不覆盖日志计划验收行为。 |
| 当前阶段无准入阻塞 | 通过 | 整改后的专项计划明确“当前阻塞项：无”，并把生产状态机、launchd/config 接入测试和完成复核归类为通过准入后的待实施工作。[专项计划](../plans/tunnelpad-stability.md:315-321) |
| `PLAN_MAP` 已同步阶段 1 Step 0 | 通过 | 当前索引已登记阶段 1、Step 0 证据和上一轮复核，状态仍保持“设计中/阶段 1”，与本轮复核前的待审状态一致。[PLAN_MAP](../PLAN_MAP.md:27-30) |
| 严格治理门禁 | 通过 | 当前执行 `plan-governance-cli check . --strict-readiness`、`plan-governance-cli graph validate .` 和 `git diff --check` 均通过；这些检查与本轮代码/文档核对共同构成准入证据。 |

## 当前证据与独立验证

阶段 1 Step 0 及阶段 0 证据记录的隔离基线如下：

- Swift 现状基线 `StabilityStage0BaselineTests`：4/4 通过。
- Swift 契约 fixture `StabilityStage0ContractTests`：6/6 通过；只冻结策略输入，不冒充生产恢复实现。
- Rust `owner::tests::stage0_baseline_restart_continues_after_bootout_error`：1/1 通过；脚本化 runner 复现 `bootout` 错误后继续 `bootstrap`，不调用真实 `launchctl`。
- GitNexus 四个目标的 upstream impact 与 Step 0 表格一致。
- 当前治理命令和图谱校验通过，未发现格式或结构错误。

## 结论与剩余问题

本轮确认：阶段 1 的目标、范围/非目标、Step 0、8 行矩阵、验证方式、失败/回滚边界、共享日志边界和当前阻塞状态均满足严格准入最低条件，达到“待实施标准”。

仍有两个实施前交接动作，但不构成阶段 1 设计准入阻塞：

1. 本次委托禁止修改计划正文和 `PLAN_MAP`；实际开始改代码前，应将本文件登记为最新独立复核并把阶段 1 状态从“设计中”更新为“待实施”。
2. 阶段 1 生产实现开始后，必须按具体修改符号重新执行 upstream impact，完成生产协调路径的 fake 探针/fake `launchd`/隔离配置/ECS fixture，并在完成阶段再做独立复核；不能用阶段 0 契约 fixture、全量测试或本文件替代生产行为验收。

阶段 1 的 Step 0 已独立完成，本结论不把阶段 0 的通过结论当作阶段 1 的 Step 0；后续阶段若进入阶段 2，仍必须为阶段 2 单独建立 Step 0 和准入复核。

本次复核没有修改计划、`PLAN_MAP`、源代码或测试，没有启动真实隧道，没有调用真实 `launchctl`、SSH 或 ECS。
