# TunnelPad 后台健康监测能耗优化：阶段 0 基线

- 日期：2026-09-03
- 类型：性能缺陷现状快照 + 恢复语义兼容探索
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 结论：已复现固定约 10 秒 CPU 峰值，并与后台健康循环的完整状态快照调用链对应；本文件不是阶段准入或实施完成结论。

## 观察边界

本次只读检查本机 TunnelPad 的非敏感运行状态和源代码。当前有两条由 `launchd` 管理的 SSH 隧道，均稳定运行且没有重复重启；其中一条启用本机 HTTP 探针并接受 `200`/`401`，另一条未启用探针。未读取或记录 SSH 命令参数、探针地址、凭证、私钥、远端资源或 ECS 配置。

## 运行采样

活动监视器显示 TunnelPad 约每 10 秒出现 300 以上的瞬时“能耗影响”，并伴随数十个百分点 CPU 峰值。为排除历史平均值干扰，执行了 25 秒只读采样：

```bash
top -l 25 -pid <TunnelPad PID> -stats pid,cpu,threads,time -s 1
```

| 采样时间 | TunnelPad CPU | 线程数 | 结论 |
|---|---:|---:|---|
| 21:11:21 | 31.7% | 10 | 峰值 |
| 21:11:31 | 29.7% | 8 | 与前一峰相隔 10 秒 |
| 21:11:41 | 11.2% | 8/1 | 下一轮开始信号 |

非峰值样本中 TunnelPad CPU 为 0%；两个受管 SSH 进程也为 0% CPU，且各自 `launchctl print` 显示 `runs = 1`。没有证据表明 SSH 流量或 KeepAlive 重启循环是固定峰值的主因。

## 代码调用链

| 层级 | 当前行为 | 能耗关联 |
|---|---|---|
| `HealthRecoveryPolicy` | `monitorIntervalNanoseconds = 10_000_000_000` | 与峰值周期一致 |
| `TunnelManager.startHealthMonitoring()` | 常驻任务每轮运行 `runHealthProbeCycle()` 后 sleep 10 秒 | 主窗口隐藏后仍会运行 |
| `TunnelManager.runHealthProbeCycle()` | 每轮先 `rustCore.snapshot()`，再运行全部已配置 HTTP 探针 | 完整状态读取与健康检查耦合 |
| Rust `CoreOwner.snapshot()` | 遍历 `config.tunnels`，逐条调用 `launchd.status()` | 无探针隧道同样被扫描 |
| Rust `LaunchCtlExecutor.status()` | 同步启动 `/bin/launchctl print gui/<uid>/<label>` 并读全量输出 | 当前配置每轮两次子进程启动 |
| `ProbeCoordinator` / `ProbeService` | 对启用探针的隧道顺序执行 HTTP GET | 当前每轮还有一次本机 HTTP 请求 |

因此稳定健康循环至少包含“两次同步 `launchctl print` + 一次 HTTP 探针”。采样已证明这条循环与 CPU 峰值精确同周期；本次未做内核级 profiler，不能精确拆分单个子进程和 HTTP 会话各自的 CPU 占比。

## GitNexus 影响基线

| 候选符号 | upstream impact | 计划处理 |
|---|---|---|
| `TunnelManager.runHealthProbeCycle` | LOW；2 个受影响符号 | 阶段 1 候选修改点 |
| `ProbeCoordinator.run` | LOW；4 个受影响符号 | 既有边界，默认不改 |
| `ProbeService.check` | MEDIUM；9 个受影响符号 | 默认不改，保留 HTTP/代理/超时语义 |
| `TunnelManager.refreshAsync` | CRITICAL；17 个受影响符号、9 条流程 | 明确排除，另立需求才可处理 |

## 阶段 0 冻结边界

1. 保留 10 秒后台监测和 HTTP-only 信号；不通过关闭探针、KeepAlive 或拉长周期规避功耗。
2. 阶段 1 只探索“健康时不做全量状态快照；失败计数、状态未知或恢复前才针对目标隧道复核状态”。
3. 任何恢复仍保留连续 3 次失败、10/30/60/300 秒退避、最多 10 次、ECS fail-closed 与既有 generation/取消语义。
4. 不触及 `refreshAsync`、UI 刷新、Rust ABI、配置 Schema、日志事件流或真实用户资源。

## 后续样本与失败判定

阶段 0 基线建立时尚缺 fake Rust owner/fake probe 的调用计数 fixture；当前补充证据见[阶段 1 Step 0](tunnelpad-health-monitor-energy-stage1-step0-20260904.md)和[阶段 1 实施证据](tunnelpad-health-monitor-energy-stage1-implementation-20260904.md)。它必须证明：

- 健康探针连续满足时，不读取无探针隧道状态，也不发起全量 Rust snapshot；
- `[fail, fail, fail]`、成功清零、手动 start/restart/stop、删除、配置变化、退出和迟到结果继续遵守既有恢复状态机；
- 恢复前读取目标隧道的有效状态；状态未知、非运行、取消或失败时不发起错误生命周期操作；
- 任一反证、恢复时效变化、跨隧道操作或真实外部副作用均判定为失败，停止阶段 1 实施并保留当前实现。

## 安全与回滚

本阶段没有改动生产代码或运行配置，不需要运行时回滚。后续任何实现若无法证明恢复契约等价或更保守，应回滚该实现提交；不得通过改写 `config.json`、删除真实 plist、终止无关进程或操作 ECS/SSH 规避失败。
