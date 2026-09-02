# TunnelPad 稳定性计划阶段 0 独立准入复核

- 日期：2026-09-01
- 阶段：阶段 0
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 复核范围：当前仓库内容、阶段 0 基线证据、`PLAN_MAP`、4 项 Swift 基线测试、1 项 Rust `bootout` 基线测试，以及日志计划完成后的共享边界。
- 结论：未达到“待实施”标准。

## 逐项核对

| 准入条件 | 核对结果 | 证据与判断 |
|---|---|---|
| 当前阶段目标、范围和非目标明确 | 通过 | 专项计划阶段 0 明确限定为现状确认、隔离基线、契约与实施门禁；不修改稳定性生产实现、不触碰真实隧道，app 执行器留待未来计划。 |
| Step 0 基线类型和证据存在 | 部分通过 | 阶段 0 证据已记录探针/刷新、配置异常、launchd owner、退出清理和 ECS 启动前置；但这些主要是现状基线，尚未形成健康恢复与 ECS 运行中同步的完整可执行准入证据。 |
| 样本/fixture 矩阵完整可执行 | 未通过 | 计划有 12 行矩阵和 fake 注入边界，但连续失败/退避/第 10 次熔断、迟到任务、配置代次和 ECS 来源同步等关键序列仍标记为未执行。 |
| 验证方式明确 | 部分通过 | 已定义只读源码核对、隔离 fixture、Swift/Rust 测试和治理检查；后续状态机、生命周期失败和 ECS 变化 fixture 尚未冻结并执行。 |
| 完成条件、失败策略、回滚边界明确 | 通过 | 计划明确 fail-closed、单隧道隔离、取消/代次保护、独立回滚和禁止真实隧道故障注入。 |
| Swift 阶段 0 基线测试 | 通过（4/4） | `xcodebuildmcp swift-package test --package-path . --filter StabilityStage0BaselineTests`：4 tests passed；覆盖三次探针失败、探针失败不触发生命周期恢复、损坏配置和半写入配置。测试使用临时目录与 fake owner。 |
| Rust `bootout` 基线测试 | 通过（1/1） | `cargo test --manifest-path rust/Cargo.toml owner::tests::stage0_baseline_restart_continues_after_bootout_error -- --exact`：1 test passed；脚本化 runner 证明当前 restart 会忽略 `bootout` 错误并继续 bootstrap，未调用真实 `launchctl`。 |
| 日志计划完成后的共享边界 | 通过 | 日志计划阶段 0–3 已在 `08d2ac5` 完成；稳定性计划记录了后续修改 `TunnelManager`、`TunnelRuntimeState`、主面板和共享测试目录必须使用单一编辑窗口并串行合入。 |
| 治理结构检查 | 通过但不等于准入通过 | `plan-governance-cli check . --strict-readiness`、`plan-governance-cli graph validate .` 和 `git diff --check` 均通过；治理命令只验证结构，不能替代阶段独立准入和业务 fixture。 |

## 共享影响复核

- `TunnelManager` upstream impact：CRITICAL，84 个影响符号，其中 70 个直接影响，涉及 `TunnelPadCoreTests`。
- `RustLifecycleOwner` upstream impact：CRITICAL，至少 77 个影响符号；接口动态分派使结果为下界。
- `MainPanelView` upstream impact：LOW，1 个直接影响。
- `TunnelRuntimeState` upstream impact：LOW，16 个影响符号，涉及 Core 与测试模块。

该影响面支持计划中“阶段 1 共享实现必须串行”的边界，不构成阶段 0 已通过的依据。

## 未达到准入的阻塞项

1. 健康恢复状态机的失败计数、固定退避、第 10 次熔断停止、成功清零、`keepAlive=false` 和手动恢复 fixture 尚未冻结并执行。
2. 配置/操作代次、取消、手动停止/删除/退出和迟到任务的隔离 fixture 尚未执行。
3. 运行中公网 IPv4 变化、ECS 双端点/规则同步、`launchd` KeepAlive 自动重连以及同步失败 fail-closed 序列尚未执行。
4. 专项计划的阶段 0 “最新独立准入复核”仍需登记本次结论；本次委托明确禁止修改计划正文和 `PLAN_MAP`，因此本文件不替代该同步动作。
5. 阶段路线图将阶段 1 标为“待实施”，但当前阶段 0 仍为“设计中”且存在上述阻塞，需在后续治理同步时修正状态漂移后再考虑进入阶段 1。

## 安全边界

本次复核仅读取仓库、执行临时目录/fake runner 测试和治理检查；没有修改源代码、计划正文或 `PLAN_MAP`，没有启动真实隧道、调用真实 `launchctl`、SSH 或访问 ECS。
