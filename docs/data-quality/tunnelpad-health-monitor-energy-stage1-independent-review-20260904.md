# TunnelPad 后台健康监测能耗优化：阶段 1 独立只读复核

- 日期：2026-09-04
- 阶段：阶段 1
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 复核性质：基于当前工作树的独立只读复核，不是用户真实环境能耗验收

## 复核结论

隔离实现满足当前阶段的调用计数和恢复安全门禁，可以继续进行阶段 2 的隔离 App 采样；本复核不宣称真实 Activity Monitor 峰值已经消失，也不关闭阶段 2 的真实环境授权门槛。

## 反向核对

- `runHealthProbeCycle` 不再每轮调用 `snapshot()`；仅在启动状态发现阶段最多调用一次。
- 健康探针满足时不调用 `RustHealthStatusReader.status(id:)`；异常结果只按目标 id 读取状态。
- `performAutomaticRecovery` 在 ECS 前置或 restart 前读取目标隧道新鲜状态，状态读取失败直接返回，不使用缓存启动。
- `refreshAsync()`、Rust ABI、配置 Schema、HTTP 探针、KeepAlive、ECS checker、日志路径和真实外部资源均未被本切片修改。
- GitNexus `detect_changes()` 报告 20 个变更符号、10 个受影响符号、10 条受影响流程，风险 `high`；受影响流程集中在已登记的健康探测、失败记录和自动恢复路径，未发现 `refreshAsync()` 被修改。

## 可复现证据

- `swift test --filter 'HealthMonitorEnergyTests|StabilityStage1Tests|StabilityStage2Tests'`：22/22 通过。
- `swift test`：136/136 通过。
- `cargo test --manifest-path rust/Cargo.toml`：66 个 Rust 单元测试和 1 个差分测试通过。
- `plan-governance-cli check . --strict-readiness`：通过。
- `git diff --check`：通过。

## 剩余边界

阶段 2 仍需使用隔离 App 做 30 秒采样，确认健康循环不再造成固定约 10 秒峰值；随后如需验证当前 `admin-tunnel`，必须另行取得用户授权，并确认非目标隧道与远端资源未变化。
