# TunnelPad 稳定性计划阶段 0 基线证据

- 日期：2026-09-01
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 基线类型：缺陷现状快照 + 隔离 fixture 设计
- 结论：现有探针、配置、launchd 生命周期、退出清理和 ECS 启动前置边界已完成只读核验；现状缺口已通过 4 项 Swift 隔离测试和 1 项 Rust 基线测试复现，后续实现契约又通过 6 项仅测试契约 fixture 固定，未接入生产恢复逻辑；阶段 0 已通过独立准入并关闭，阶段 1 仍需自己的 Step 0 和准入。

## 复核范围

本证据只覆盖稳定性计划阶段 0 的当前代码基线和实现边界。阶段 0 不修改 Swift/Rust 稳定性生产实现、不修改配置、不启停真实隧道、不调用真实 `launchctl` 或 SSH；日志事件流计划阶段 0–3 已完成，但其文档、实现和隔离测试不计入本计划的稳定性准入。

本次复核时工作树基线为：

| 项目 | 命令 | 结果 | 判定 |
|---|---|---|---|
| 基线提交 | `git rev-parse HEAD` | `08d2ac5`（日志事件流计划阶段 0–3 已完成） | 通过 |
| 工作树范围 | `git status --short`、`git diff --stat` | 仅有稳定性计划/证据、稳定性 Swift 基线测试，以及 Rust owner 测试基线改动；未修改稳定性生产逻辑，日志计划实现已在 HEAD | 通过，按重新开始后的串行边界隔离 |
| 空白检查 | `git diff --check` | 无空白错误 | 通过 |

## 当前实现基线

### 探针只读展示，不触发恢复

只读核对 `ProbeService.swift`、`ProbeCoordinator.swift` 和 `TunnelManager.swift`：

- `ProbeService` 只执行 HTTP GET，将结果分为满足、状态码不符合和请求失败三类；源码注释明确其只影响展示、不影响进程管理。
- `TunnelManager.refresh()`/`refreshAsync()` 在刷新完成后调用 `runProbes()`；`runProbes()` 取消上一批任务、执行一次探针并写入 `probeResults`，没有后台周期调度或自动重启调用。
- `ProbeCoordinator` 的 generation 只用于丢弃过期结果；它不是健康恢复计数器，也不拥有隧道生命周期。

证据命令：

```text
rg -n -C 4 'ProbeResult|HTTP GET|runProbes|probeTask|probeGeneration|refreshAsync|restart' \
  Sources/TunnelPadCore/ProbeService.swift \
  Sources/TunnelPadCore/ProbeCoordinator.swift \
  Sources/TunnelPadCore/TunnelManager.swift
```

结论：进程仍存活但 HTTP 探针持续失败时，当前源码没有由探针结果触发恢复的路径；这只是缺口确认，不是故障注入通过证据。

### 主窗口刷新不等于后台健康监测

只读核对 `Sources/tunnelpad/MainPanelView.swift`：主面板在窗口可见时每 5 秒调用 `manager.refreshAsync()`；窗口隐藏后该视图任务退出。该刷新同时查询状态并触发一次探针，但不构成独立于窗口可见性的健康协调器。

证据命令：

```text
rg -n -C 5 'task\(id: appDelegate\.isMainWindowVisible\)|5_000_000_000|refreshAsync' \
  Sources/tunnelpad/MainPanelView.swift
```

### 当前 owner 是 Rust + launchd

只读核对 `RustLifecycleOwner.swift`、`LaunchCtlExecutor.swift`、`rust/tunnelpad-core/src/owner.rs` 和 `AppDelegate.swift`：

- Rust Core 是 `TunnelManager` 的生命周期 owner；Swift 通过最小协议调用 load/save/snapshot/start/stop/restart/remove/shutdown。
- 当前执行器状态由 `launchctl print` 查询；查询失败按 `notLoaded` 处理，`bootout` 只把明确的 not-found 视为未加载，其他错误可抛出。
- Rust restart 当前显式忽略 `bootout` 结果后继续写 plist/bootstrap；该行为已在计划中记录为待修复的失败边界。
- 正常退出和 SIGTERM/SIGINT 都经 Rust owner 停止全部受管 launchd 隧道；当前有效路径不使用 app pidfile。未来 app 执行器及孤儿进程收敛另立计划。

证据命令：

```text
rg -n -C 5 'bootout|bootstrap|status|shutdown|stopAllManagedTunnels|applicationShouldTerminate' \
  Sources/TunnelPadCore/RustLifecycleOwner.swift \
  Sources/TunnelPadCore/LaunchCtlExecutor.swift \
  Sources/TunnelPadCore/Shutdown.swift \
  Sources/tunnelpad/AppDelegate.swift \
  rust/tunnelpad-core/src/owner.rs
```

### 配置损坏仍存在安全收敛待冻结项

当前 `ConfigStore.load()` 在 JSON 解码失败时把原文件改名为 `config.json.corrupt-<timestamp>`，然后返回空配置；`TunnelManager` 在 Rust Core 加载失败时也会用空配置初始化并记录错误。稳定性计划尚未冻结“当前有效运行配置保留、运行时状态不裁剪、错误和留档失败如何处理”的最终契约。

证据命令：

```text
rg -n -C 6 'ConfigLoadResult|corrupt-|AppConfig\(\)|loadConfig|重新加载配置失败' \
  Sources/TunnelPadCore/ConfigStore.swift \
  Sources/TunnelPadCore/TunnelManager.swift \
  rust/tunnelpad-core/src
```

### ECS 动态 SSH 只覆盖显式启动前置

当前 `TunnelManager` 的启动入口调用 `ECSPreStartChecker`，其脚本失败、超时或无法启动会阻断显式启动。阶段 0 尚未实现或验证运行中公网 IPv4 变化、探针失败/SSH 断线与 `launchd KeepAlive` 自动重连之间的协调，因此“自动重连前确认当前来源或 fail-closed”仍是待冻结契约。

证据命令：

```text
rg -n -C 5 'preStartChecker|ECSPreStartChecker|checkAsync|TUNNELPAD_IP_ENDPOINT|keepAlive|KeepAlive' \
  Sources/TunnelPadCore/TunnelManager.swift \
  Sources/TunnelPadCore/ECSPreStart.swift \
  Sources/TunnelPadCore/LaunchdPlistRenderer.swift \
  rust/tunnelpad-core/src
```

## 样本矩阵状态

| 样本 | 当前状态 | 证据或未完成原因 |
|---|---|---|
| 探针/刷新现状 | 已完成（只读） | `ProbeService`、`ProbeCoordinator`、`TunnelManager` 和主面板源码核验；确认探针只写展示结果、刷新依赖显式/窗口可见入口 |
| launchd 状态与 bootout 错误 | 已完成（只读 + 隔离基线） | Swift `LaunchCtlExecutor` 与 Rust owner 核验；`stage0_baseline_restart_continues_after_bootout_error` 通过，确认 restart 当前忽略 bootout 错误并继续 bootstrap；Rust 生产行为未改 |
| 正常退出/信号退出 owner | 已完成（只读） | `Shutdown`、`AppDelegate` 和 Rust owner 核验；确认当前 launchd 统一 owner，app pidfile 不在本阶段 |
| 配置损坏/半写入 | 已完成现状基线 | `swift test --filter StabilityStage0BaselineTests` 中 2 项通过；当前坏 JSON/半写入会被留档并以空配置返回，明确这是待修复的 fail-closed 缺口，不是目标行为 |
| 进程存活但探针连续失败 | 已完成现状基线 | `swift test --filter StabilityStage0BaselineTests` 中 2 项通过；连续三次失败仍为 `ProbeResult.failed`，`TunnelManager` 不调用生命周期恢复；不得据此推断新恢复状态机已实现 |
| 3 次失败、固定退避、第 10 次熔断 | 已完成（仅测试契约） | `swift test --filter StabilityStage0ContractTests` 中 1 项通过；固定 10/30/60/300 秒退避、最多 10 次失败后停止并继续监测，不能据此推断生产状态机已实现 |
| 手动停止/删除/退出与迟到任务 | 已完成（仅测试契约） | 同一命令中 2 项通过；覆盖手动停止取消待恢复、隧道隔离、代次拒绝迟到结果；生产接入留待阶段 1–2 |
| 运行中公网 IPv4 变化与 ECS 同步 | 已完成（仅测试契约） | 同一命令中 1 项通过；覆盖双端点一致、私网/不可用、来源不一致和同步失败的 fail-closed；未访问真实 ECS |
| 治理与反向引用 | 已完成（结构检查；准入未通过） | `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10`、`git diff --check` 与关键词/旧草案反向引用检查均通过；严格检查通过不等于本阶段行为准入通过 |

## 并行边界

- 日志计划阶段 0–3 已完成并通过独立复核；稳定性计划阶段 0 已完成并通过独立复核，当前进入阶段 1 设计，涉及共享模块的改动仍必须单独排队。
- 涉及 `TunnelManager`、`TunnelRuntimeState`、`MainPanelView`、`TunnelDetailComponents` 和共享测试目录的稳定性实现必须使用单一编辑窗口；本证据不把日志实现和日志测试计入稳定性测试覆盖。
- 当前稳定性计划不修改日志采集、内存缓存或 UI 事件订阅；日志计划不修改健康恢复、ECS 自动重连或 launchd 生命周期失败处理。

## 尚未完成与下一步

阶段 0 已完成并通过独立准入；后续转入阶段 1：

1. 阶段 1 先完成自己的 Step 0，冻结生产实现边界、影响面和故障注入矩阵。
2. 阶段 1 通过独立准入后，才开始生产恢复实现。

## 验证记录

| 命令 | 结果 | 判定 |
|---|---|---|
| `swift test --filter StabilityStage0BaselineTests` | 4/4 通过 | 通过 |
| `swift test --filter StabilityStage0ContractTests` | 6/6 通过 | 通过；仅冻结后续实现契约，不代表生产实现已接入 |
| `cargo test --manifest-path rust/Cargo.toml stage0_baseline_restart_continues_after_bootout_error` | 1/1 通过 | 通过 |
| `swift test` | 109/109 通过 | 通过；包含日志计划已提交的回归测试和本计划 6 项契约 fixture |
| `cargo test --manifest-path rust/Cargo.toml` | Rust 单元 51/51、差分 1/1 通过 | 通过 |
| `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10`、`git diff --check` | 全部通过 | 通过；共享目标 WARNING 仍为预期治理提示 |

独立准入复核：[契约 fixture 独立准入复核](tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md)于 2026-09-01 确认阶段 0 达到“待实施标准”；该结论只关闭阶段 0，不替代阶段 1 自身 Step 0 和独立准入。

因此当前结论是：探针、配置异常和 launchd bootout 错误的现状基线已落盘，健康恢复和 ECS 运行中同步契约已冻结；阶段 0 已通过独立准入，阶段 1 仍不可实施，待阶段 1 自身 Step 0 和准入完成后再开始。日志计划已完成，不再构成稳定性阶段 0 的并行依赖。
