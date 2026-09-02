# TunnelPad 稳定性计划阶段 0 独立准入复核：契约 fixture

- 日期：2026-09-01
- 阶段：阶段 0
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 复核范围：当前仓库内容、阶段 0 基线证据、12 行样本矩阵、4 项 Swift 现状基线、6 项 Swift 契约 fixture、Rust `bootout` 基线、共享影响面，以及日志计划完成后的串行边界。
- 结论：达到“待实施标准”。

## 逐条核对

| 准入条件 | 核对结果 | 证据与判断 |
|---|---|---|
| 当前阶段目标、范围和非目标 | 通过 | 阶段 0 限定为现状基线、隔离 fixture、行为契约和实施门禁；不修改稳定性生产实现、不修改 Schema、不操作真实隧道，app 执行器留待未来计划。 |
| Step 0 基线类型和证据 | 通过 | 已固定为“缺陷修复与架构探索结合的现状快照”，并记录探针/刷新、配置异常、launchd owner、退出清理和 ECS 启动前置边界；使用临时目录、fake lifecycle 和脚本化 launchd。 |
| 12 行样本矩阵 | 通过 | 专项计划的矩阵逐行包含输入/基线、可执行命令或操作、预期结果、失败判定和输出位置，覆盖现状、假死、状态机、launchd、配置、退出清理、代次、ECS 和治理检查。 |
| fixture 输入、预期和失败判定 | 通过 | `StabilityStage0ContractTests` 固定三次失败阈值、10/30/60/300 秒退避、第 10 次失败停止并继续监测、成功清零、`keepAlive=false`、单隧道隔离、手动停止、代次取消、配置 fail-closed 和 ECS 双端点 fail-closed。 |
| 验证方式 | 通过 | 已定义只读源码核对、Swift/Rust 隔离测试、fake launchd、临时配置和治理检查；本轮独立重跑现状基线 4/4、契约 fixture 6/6、Rust `bootout` 基线 1/1，均通过。 |
| 完成条件、失败策略和回滚边界 | 通过 | 计划明确状态机计数/退避/熔断、配置保留、代次取消、单隧道隔离、fail-closed、独立提交回滚和禁止真实外部副作用；全量生产恢复行为不被契约 fixture 冒充。 |
| 当前阶段阻塞项 | 通过 | 之前唯一的阶段 0 阻塞是新的独立准入复核；本文件完成该复核后，阶段 0 无剩余准入阻塞。生产恢复实现、launchd 错误收敛和 ECS 运行中同步接入属于阶段 1–2，不是阶段 0 的未完成项。 |
| 日志计划完成后的共享边界 | 通过 | 日志计划阶段 0–3 已在 `08d2ac5` 完成；稳定性阶段 1 修改 `TunnelManager`、`TunnelRuntimeState`、主面板或共享测试目录时，仍须单一编辑窗口、串行合入，不覆盖日志计划已验收行为。 |
| 治理与图谱 | 通过 | `plan-governance-cli check . --strict-readiness`、`plan-governance-cli graph validate .` 和 `git diff --check` 均通过；严格治理只作结构门禁，本结论另基于当前代码、fixture 和反向边界核对。 |

## 测试证据

| 范围 | 命令 | 结果 |
|---|---|---|
| 现状基线 | `xcodebuildmcp swift-package test --package-path . --filter StabilityStage0BaselineTests` | 4/4 通过；覆盖三次探针失败、探针失败不触发生命周期恢复、损坏配置和半写入配置。 |
| 后续实现契约 | `xcodebuildmcp swift-package test --package-path . --filter StabilityStage0ContractTests` | 6/6 通过；仅冻结阶段 1–2 的实现契约，不表示生产恢复逻辑已接入。 |
| Rust launchd 基线 | `cargo test --manifest-path rust/Cargo.toml owner::tests::stage0_baseline_restart_continues_after_bootout_error -- --exact` | 1/1 通过；脚本化 runner 复现 `bootout` 错误后继续 `bootstrap`，未调用真实 `launchctl`。 |

## 共享影响复核

- `TunnelManager` upstream impact：CRITICAL，84 个影响符号，其中 70 个直接影响，涉及 `TunnelPadCoreTests`。
- `RustLifecycleOwner` upstream impact：CRITICAL，至少 77 个影响符号；接口动态分派使该结果为下界。
- `MainPanelView` upstream impact：LOW，1 个直接影响。
- `TunnelRuntimeState` upstream impact：LOW，16 个影响符号，涉及 Core 与测试模块。

该影响面不阻塞阶段 0 准入，但确认阶段 1 实现必须保留共享模块串行边界，并在修改任何共享符号前重新执行 upstream impact。

## 准入结论与后续边界

本复核确认阶段 0 已达到“待实施标准”。本次委托明确限制为只新增本文件，因此未修改专项计划正文或 `PLAN_MAP`；实际开始阶段 1 前，实施者必须将本文件登记为最新独立复核证据并同步状态链接。

阶段 1 仍必须独立完成自身 Step 0、样本矩阵、验证方式、失败/回滚边界和独立准入复核；不得以本阶段 0 的契约 fixture、全量测试通过或本文件直接替代阶段 1 的准入。

本次复核只执行临时目录/fake runner 测试和只读治理检查，没有修改源代码、没有启动真实隧道、没有调用真实 `launchctl`、SSH 或 ECS。
