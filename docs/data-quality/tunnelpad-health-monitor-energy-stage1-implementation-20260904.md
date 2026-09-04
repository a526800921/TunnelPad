# TunnelPad 后台健康监测能耗优化：阶段 1 实施证据

- 日期：2026-09-04
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 前置基线：[阶段 0 基线](tunnelpad-health-monitor-energy-stage0-20260903.md)
- 当前状态：阶段 1 候选实现已完成隔离验证；阶段 2 真实能耗验收和全计划独立完成复核仍未完成

## 实施范围

- `TunnelManager` 的持续健康循环先读取有效配置；启动阶段最多执行一次全量 `snapshot()`，保留无主窗口时的初始状态发现。
- 健康探针满足时不读取单条 launchd 状态；探针不满足时只通过独立的 `RustHealthStatusReader` 能力读取目标隧道状态。
- 自动恢复动作开始前再次读取目标隧道最新状态；读取失败、能力不可用或代次过期均 fail-closed。
- 没有扩大 `RustLifecycleOwner` 接口，没有修改 Rust ABI、配置 Schema、HTTP 探针、KeepAlive、ECS 前置、日志事件流或 `refreshAsync()`。

## 隔离验证矩阵

| # | 场景 | 预期 | 结果 |
|---|---|---|---|
| 1 | 一条启用探针、一条无探针，连续健康周期 | 全量 snapshot 仅启动时 1 次；健康周期不调用单条状态读取；无探针隧道不被扫描 | 通过 |
| 2 | 启用探针连续失败 | 不重新执行全量 snapshot；仅读取失败探针对应隧道的状态 | 通过 |
| 3 | 目标状态未知 | 不使用旧状态触发自动恢复 | 通过 |
| 4 | 连续 3 次失败与恢复 | 仍按现有阈值进入恢复，恢复前复核状态 | 通过 |
| 5 | KeepAlive、手动停止、删除、迟到结果、ECS 前置和非 SSH 恢复 | 保持既有 fail-closed、取消、代次、顺序和恢复边界 | 通过 |
| 6 | Rust/Swift 全量回归 | 既有行为无回归 | 通过 |

## 可复现命令与输出

| 命令 | 结果 |
|---|---|
| `swift test --filter 'HealthMonitorEnergyTests\|StabilityStage1Tests\|StabilityStage2Tests'` | 23/23 通过 |
| `swift test` | 137/137 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 66 个 Rust 单元测试 + 1 个差分测试通过 |
| `plan-governance-cli check . --strict-readiness` | 通过 |
| `git diff --check` | 通过 |

测试只使用临时目录、fake owner、fake 探针和 fake 前置检查；没有调用真实 `launchctl`、SSH、ECS、用户隧道或远端资源。尚未将新代码部署到当前运行中的 TunnelPad，也未宣称真实 Activity Monitor 峰值已经消失。

## 回滚和剩余验收

- 代码回滚仅限本阶段改动；不删除真实 plist、不改写用户配置、不操作 ECS 或 SSH 资源。
- 若隔离测试发现恢复提前/延后、状态倒灌、跨隧道读取或 ECS 顺序变化，停止合入并恢复阶段 1 代码。
- 阶段 2 仍需在隔离 App 中做 30 秒采样，再决定是否进入用户授权的真实 `admin-tunnel` 受控验收。
