# TunnelPad 后台健康监测能耗优化：阶段 1 Step 0

- 日期：2026-09-04
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 前置基线：[阶段 0 基线](tunnelpad-health-monitor-energy-stage0-20260903.md)
- 实施证据：[阶段 1 实施证据](tunnelpad-health-monitor-energy-stage1-implementation-20260904.md)
- 基线类型：性能调用计数 + 健康恢复契约兼容验证
- 结论：候选实现边界已冻结并完成隔离验证；不代表真实 App 能耗验收完成

## 阶段 1 范围

本阶段只优化 `TunnelManager` 的持续健康循环：读取配置代替每轮全量状态快照，启动阶段最多保留一次全量状态发现；健康探针满足时不读取 launchd 状态，探针不满足时只读取目标隧道状态，自动恢复开始前再次复核目标状态。

本阶段不修改 `refreshAsync()`、主窗口刷新、HTTP 探针语义、KeepAlive、ECS fail-closed、Rust ABI、配置 Schema、日志事件流、launchd label、SSH 命令或真实用户资源。单条状态读取通过独立内部 `RustHealthStatusReader` 能力协议提供，不扩大 `RustLifecycleOwner` 接口。

## 契约与安全门禁

- 健康周期仍为 10 秒；连续 3 次非满足结果才计入恢复；退避仍为 10/30/60/300 秒，最多 10 次。
- 配置读取失败、单条状态读取失败、能力缺失、取消或代次不一致时不使用旧状态触发生命周期副作用。
- 恢复前必须读取目标隧道最新状态；非运行状态仅在既有 ECS quiescence 且已有恢复代次时沿用原有受控重试边界。
- 启动初次状态发现最多一次，用于保留无主窗口状态展示；持续健康路径不再重复扫描无探针隧道。

## Step 0 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 结果 |
|---|---|---|---|---|---|
| 1 | 一条启用探针、一条无探针；探针连续满足 | `swift test --filter HealthMonitorEnergyTests/testHealthyCyclesDoNotRescanAllTunnelStatuses` | 全量 snapshot 仅 1 次，状态读取 0 次 | 健康周期重复 snapshot 或读取任一隧道状态 | 通过 |
| 2 | 一条探针异常、一条无探针 | `swift test --filter HealthMonitorEnergyTests/testFailedProbeOnlyReadsTargetTunnelStatus` | 不重复全量 snapshot；只读取异常目标 | 扫描无探针隧道或使用全量 snapshot | 通过 |
| 3 | 目标状态未知 | `swift test --filter HealthMonitorEnergyTests/testUnknownTargetStatusDoesNotTriggerRecovery` | 不使用旧状态触发自动恢复 | 状态异常时仍调用 restart/stop | 通过 |
| 4 | 连续失败、恢复、KeepAlive、手动操作、删除、代次 | `swift test --filter 'StabilityStage1Tests\|StabilityStage2Tests'` | 既有恢复阈值、ECS 顺序、取消和代次边界不变 | 恢复提前/延后、越过手动/退出边界或跨隧道操作 | 20/20 通过 |
| 5 | Swift 全量回归 | `swift test` | 既有 Swift 行为不回归 | 任一测试失败 | 137/137 通过 |
| 6 | Rust owner/ABI/差分 | `cargo test --manifest-path rust/Cargo.toml` | Rust owner 和 ABI 行为不变 | 任一 Rust/差分测试失败 | 66+1 通过 |
| 7 | 治理与工作树 | `plan-governance-cli check . --strict-readiness`；`git diff --check`；GitNexus `detect_changes()` | 治理通过，变更范围落在登记模块 | 治理错误、空白错误或未登记流程变化 | 通过；GitNexus 风险为 high，已复核受影响流程 |

## 失败与回滚边界

所有测试使用临时目录、fake owner、fake probe 和 fake 前置检查，不接触真实 `launchctl`、SSH、ECS、用户隧道或远端规则。若阶段 2 隔离 App 采样不能证明固定周期峰值消失，或发现恢复语义变化，只回滚本阶段代码，不改用户配置、真实 plist 或远端资源。
