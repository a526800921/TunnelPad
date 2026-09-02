# TunnelPad 稳定性阶段 2 跨层状态一致性切片实施证据

- 实施日期：2026-09-02
- 计划：`tunnelpad-stability`
- 阶段：阶段 2
- 切片：探针恢复、Rust 状态快照、生命周期操作与 UI 状态的迟到结果治理
- 实施结论：**已完成本切片实现，待独立完成复核**

## 实施范围

本次只实现已通过独立准入的 Swift `TunnelManager` 结果门禁：统一状态快照请求代次、生命周期/配置失效代次、busy 隧道状态保护和健康探针批次失效。Rust Core 的操作代次、C ABI、配置 Schema、launchd plist、ECS 前置、日志事件流和 UI 布局均未改变。

## 代码变更

| 文件 | 变更 |
|---|---|
| `Sources/TunnelPadCore/TunnelManager.swift` | 将同步刷新、异步刷新和后台健康快照纳入共享状态读取代次；生命周期操作、配置成功变化和退出开始时失效在途读取；快照写回时保留 busy 隧道状态；健康探针结果需通过本轮读取代次和失效门禁。 |
| `Tests/TunnelPadCoreTests/StabilityStage2Tests.swift` | 增加旧健康快照覆盖手动启动、旧健康探针覆盖手动停止、旧快照覆盖新刷新、退出中旧快照写回四类阻塞 gate fixture。 |

## 行为证据

- `testLateHealthSnapshotCannotOverwriteManualStart`：后台快照先读到 `notLoaded`，手动启动写入 `running` 后释放旧快照，最终仍为 `running`。
- `testLateHealthProbeCannotOverwriteManualStop`：健康探针阻塞期间手动停止，释放旧探针后不再写入旧 `probeResults`，最终状态为 `notRunning`。
- `testOlderSnapshotCannotOverrideNewerRefresh`：较早后台快照晚于较新的刷新返回时被丢弃。
- `testShutdownInvalidatesPendingHealthResults`：退出开始后释放在途快照，旧结果不再写入 UI。
- 所有生命周期/配置失效入口复用同一 `invalidateStateReads()`；不能及时取消的底层调用仍允许结束，但其结果不具备提交资格。
- `applyStatusSnapshot` 只让非 busy 隧道接受快照状态，避免系统查询覆盖正在进行中的手动或自动操作。

## 可复现验证

| 验证项 | 命令 | 结果 |
|---|---|---|
| 阶段 2 专项 | `swift test --filter StabilityStage2Tests` | 11/11 通过 |
| Swift 全量 | `swift test` | 129/129 通过 |
| Rust 全量 | `cargo test --manifest-path rust/Cargo.toml` | 53 个 unit + 1 个 differential 通过 |
| 治理检查 | `plan-governance-cli check .` | PASS |
| 严格准入检查 | `plan-governance-cli check . --strict-readiness` | PASS |
| 停滞检查 | `plan-governance-cli check . --stale-days 10` | PASS |
| 补丁格式检查 | `git diff --check` | PASS |

测试使用 fake owner、阻塞快照/探针 gate 和临时目录；没有执行真实 `launchctl`、SSH、ECS、信号或用户隧道操作。

## 安全与未覆盖范围

- 旧结果统一 fail-closed：丢弃，不触发生命周期副作用，不推进健康恢复失败计数。
- 失效代次是 Manager 层结果提交门禁，不替代 Rust owner 在系统副作用前执行的操作代次校验。
- 本切片不改变探针三态、连续 3 次失败、固定退避、10 次熔断、`keepAlive` 或 ECS 同步策略。
- 真实受控应用验收、配置/执行器切换提交顺序和 `app` 执行器孤儿进程仍不在本切片完成范围。
