# TunnelPad 稳定性计划阶段 1 实施证据

- 日期：2026-09-02
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 准入：[阶段 1 独立准入复核（r2）](tunnelpad-stability-stage1-independent-review-20260902-r2.md)
- 完成复核：[阶段 1 独立完成复核](tunnelpad-stability-stage1-independent-completion-review-20260902.md)
- 实施范围：后台健康监测、单隧道健康恢复状态机、配置有效候选保留、手动操作取消/清零、第 10 次失败后的停止和 Rust `launchd` `bootout` fail-closed
- 当前状态：阶段 1 已完成；本证据只覆盖本阶段的 Core slice，启动/退出收敛、ECS 运行时同步和真实应用验收留待后续阶段

## 已实施内容

- 新增固定策略 `HealthRecoveryPolicy`：后台监测周期固定 10 秒，不增加配置字段；连续 3 次非满足探针结果触发恢复，退避固定为 10/30/60/300 秒，最多 10 次。
- 新增单隧道 `HealthRecoveryState`：成功清零，`keepAlive=false` 不进入自动恢复，手动停止进入人工停止态，手动启动/重启恢复监测并清零，第 10 次恢复失败后进入熔断停止态。
- `TunnelManager` 在初始化后启动与窗口可见性无关的后台监测；UI 一次性探针和后台探针使用两个独立 `ProbeCoordinator`，避免面板刷新取消健康监测。
- 自动恢复通过既有 `RustLifecycleOwner` 和 `ECSPreStartChecking`，没有新增 Swift 生命周期 owner；恢复任务按隧道保存，手动操作、配置变更、移除和退出会取消旧任务。恢复等待或执行期间保持任务登记，后续探针只观察，不推进失败计数或创建重复恢复链。
- 后台监测循环使用弱引用调度，不把 `TunnelManager` 与常驻任务形成保留环；删除隧道后保留恢复代次墓碑，防止旧任务在同 ID 重建后复活。
- 自动恢复成功前要求返回 `running`；第 10 次仍失败后执行当前隧道 stop，停止后保留只读监测，不再自动拉起，提示用户手动启动或重启。
- 配置重载只接受 Rust owner 已成功解析的候选；解析失败保留当前有效配置和运行态，不进行空配置裁剪。
- Rust owner 的 `restart` 对 `bootout` 明确区分“未加载可继续”和其他错误；非预期停止失败立即返回，不写 plist、不执行 `bootstrap`。

## 隔离验证矩阵

| # | 场景 | 输入 | 预期 | 结果 |
|---|---|---|---|---|
| 1 | 后台监测 | fake owner 返回 running；fake HTTP 探针连续失败 | 不依赖窗口，至少 3 次失败后调用一次 restart | 通过 |
| 2 | `keepAlive=false` | fake owner 返回 running；探针连续失败 | 只更新探针结果，不调用 restart | 通过 |
| 3 | 手动停止/人工重开 | 第 1 次恢复任务等待中调用 stop；熔断后调用 start | 手动 stop 取消待恢复任务；手动 start/restart 清零并重新允许自动恢复 | 通过 |
| 4 | 上限熔断 | fake restart 连续 10 次失败 | 第 10 次后只 stop 当前隧道，保留只读监测，不再自动恢复 | 通过 |
| 5 | 策略状态 | 生产 `HealthRecoveryState` 输入失败/成功序列 | 3 次阈值、10/30/60/300 秒、成功清零和第 10 次 stop 均固定 | 通过 |
| 6 | 配置 fail-closed | 当前有效配置；reload owner 返回错误 | 保留当前 config，不裁剪当前运行态并提示错误 | 通过 |
| 7 | 恢复并发保护 | 恢复调用执行较慢期间继续注入探针失败 | 同一隧道不创建重复恢复链，不提前推进 10 次额度；当前恢复结束后再处理后续结果 | 通过 |
| 8 | `launchd` 停止失败 | fake `bootout` 返回非未加载错误 | `restart` 返回可诊断 executor 错误，不执行后续 `bootstrap` | 通过 |
| 9 | 删除与迟到任务 | 恢复任务等待期间删除当前隧道 | 已排队恢复任务被取消，不在删除后执行 restart | 通过 |

## 可复现命令与输出

| 命令 | 结果 |
|---|---|
| `swift test --filter StabilityStage1Tests` | 9/9 通过 |
| `swift test` | 118/118 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 51 个 Rust 单元测试 + 1 个差分测试通过 |
| `cargo test --manifest-path rust/Cargo.toml restart_blocks_bootstrap_after_bootout_error` | 1/1 通过 |
| `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10` | 均通过 |
| `git diff --check` | 通过 |
| GitNexus `detect_changes()` | 83 个变更符号、26 个受影响符号，风险 `critical`；`TunnelManager` 与 Rust `restart_with_generation` 均为预期高影响 |

测试使用临时目录、fake Rust owner、fake 探针、fake 前置检查和脚本化 `launchd` runner；没有调用真实 `launchctl`、SSH、ECS 或用户隧道。启动/退出收敛与 ECS 运行中同步属于阶段 2，不是阶段 1 的未完成项；阶段 1 完成前仍需登记最终全量回归和独立完成复核。

## 安全与回滚边界

- 自动恢复只处理配置中的当前 `launchd` 隧道，并按 id 隔离计数、代次和任务。
- 监测状态读取失败时不使用旧状态触发生命周期副作用。
- 任何失败、取消、代次不一致或状态不是 running 都不伪造成功；第 10 次后的 stop 失败也停止后续自动恢复并保留诊断。
- 回滚只回滚本阶段代码提交，不删除真实 plist、不改写配置、不操作远端规则。
