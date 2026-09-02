# TunnelPad 稳定性计划阶段 1 独立完成复核

- 日期：2026-09-02
- 阶段：阶段 1
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 实施证据：[阶段 1 实施证据](tunnelpad-stability-stage1-implementation-20260902.md)
- 准入证据：[阶段 1 独立准入复核（r2）](tunnelpad-stability-stage1-independent-review-20260902-r2.md)
- 结论：通过，阶段 1 已完成。

## 复核方法

本复核不以专项计划中的“实施中”或“已完成”文字作为完成依据，而是重新读取当前工作树的生产实现、阶段 1 专项测试、Rust owner 失败注入测试、既有生命周期测试和当前治理文件，再执行可复现命令。复核范围只覆盖阶段 1 的 `launchd` 后台健康恢复、配置 fail-closed、代次/取消和 `bootout` fail-closed；启动/退出收敛、ECS 运行中同步和跨层状态一致性明确留在阶段 2。

## 阶段 1 完成条件逐项核对

| 完成条件 | 当前证据 | 结论 |
|---|---|---|
| 后台监测不依赖窗口可见性，且使用现有 HTTP 探针 | `TunnelManager` 的独立 `healthProbeCoordinator` 与后台 `healthMonitorTask`；`StabilityStage1Tests.testBackgroundMonitoringTriggersRecoveryAfterThreeFailures` | 通过 |
| 连续 3 次失败后恢复，退避固定为 10/30/60/300 秒，最多 10 次 | `HealthRecoveryPolicy`、`HealthRecoveryState`；`testProductionHealthStateUsesFixedPolicyAndStopsAfterTenthFailure` | 通过 |
| 第 10 次仍失败只停止当前隧道，停止自动恢复但保留只读监测 | `HealthRecoveryState.Phase.stoppedAfterRecovery`、`stopAfterRecoveryLimit`；`testTenthFailedRecoveryStopsOnlyCurrentTunnel` | 通过 |
| 成功清零，`keepAlive=false` 不自动恢复，手动停止不被拉起 | `finishRecovery(success:)`、`manualStop()`；`testKeepAliveFalseDoesNotTriggerRecovery`、`testManualStopCancelsPendingRecovery` | 通过 |
| 手动 start/restart 后恢复监测并清零 | `resetHealthRecovery(... .monitoring)` 与 `manualStart()`；`testManualStartReopensRecoveryAfterCircuitBreaker` | 通过 |
| 删除、取消、迟到任务和恢复并发不会产生旧副作用 | `cancelRecovery`、恢复任务登记、代次墓碑和弱引用监测循环；`testRemovingTunnelCancelsPendingRecovery`、`testInFlightRecoveryDoesNotConsumeAdditionalAttempts` | 通过 |
| 无效配置候选不会替换当前有效配置 | `reloadConfig`/`reloadConfigAsync` 的错误保留路径与 `applyEffectiveConfig`；`testInvalidReloadRetainsEffectiveConfig` | 通过 |
| Rust `launchd` `bootout` 非预期失败时 fail-closed | `restart_with_generation` 对 `bootout_cancellable` 错误立即返回；`restart_blocks_bootstrap_after_bootout_error` 与既有 `LaunchCtlExecutor` 错误分类测试 | 通过 |
| 不新增 Schema、不操作真实外部资源，且单隧道故障不传播 | 实现未新增配置字段；所有阶段 1 fixture 使用临时目录、fake owner、fake 探针和脚本化 runner；专项测试覆盖固定单隧道路径 | 通过 |

## 独立执行结果

| 命令 | 结果 |
|---|---|
| `swift test --filter StabilityStage1Tests` | 9/9 通过 |
| `swift test` | 118/118 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 51 个 Rust 单元测试、1 个差分测试通过 |
| `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10` | 均通过 |
| `git diff --check` | 通过 |
| GitNexus `detect_changes()` | 83 个变更符号、26 个受影响符号，风险 `critical`；影响集中在已登记的 `TunnelManager` 生命周期枢纽、Rust `restart_with_generation` 及其测试/治理引用 |

## 范围与剩余工作

阶段 1 已关闭的范围是当前 `launchd` 执行器下的后台健康恢复和配置/代次安全边界。以下工作不是阶段 1 的未完成项，而是阶段 2 的设计内容：

- TunnelPad 启动、正常退出、信号退出后的统一 `launchd` 资源收敛。
- 运行中公网 IPv4 变化的发现、ECS 受管安全组同步和自动重连前置。
- 上述跨层状态一致性及其生产 fixture。

阶段 2 仍必须自行完成需求冻结、Step 0、样本矩阵、验证/回滚边界和独立准入；阶段 1 的证据不能替代阶段 2 的准入。

## 结论

当前工作树已满足阶段 1 自身完成条件，专项和全量回归均通过，且 `bootout` 错误不会再被吞掉后继续 `bootstrap`。因此本复核结论为：**阶段 1 已完成（通过独立完成复核）**。
