# TunnelPad 稳定性阶段 2 跨层状态一致性切片 Step 0

- 日期：2026-09-02
- 计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 阶段：阶段 2
- 切片：探针恢复、Rust 状态快照、生命周期操作与 UI 状态的迟到结果治理
- Step 0 类型：架构探索基线 + 迟到结果故障注入
- 当前结论：**Step 0 已完成，独立准入已通过并完成本切片实现；本文件仍作为实现前基线记录**

## 目标与非目标

本切片只解决 Swift `TunnelManager` 作为 UI/FFI 门面的异步结果准入问题：旧的 Rust `snapshot`、旧的健康探针结果或恢复结果，在手动启停、配置重载、删除和退出之后，不能再写回 `statuses`、`probeResults`、`config` 或触发下一轮恢复。

本切片不修改 Rust Core 的生命周期实现、C ABI、`config.json` Schema、launchd plist、ECS 同步顺序、日志事件流、备注字段或 UI 组件布局；也不重新定义探针三态、3 次失败、10 次恢复和熔断策略。

## 当前基线

### 已确认事实

1. `TunnelManager` 是 `@MainActor` 类，但 `refreshAsync()` 和 `runHealthProbeCycle()` 都把 Rust `snapshot()` 放进 `Task.detached`；两条读取路径没有共用同一套结果代次。
2. `refreshAsync()` 的 `refreshGeneration` 只比较异步刷新之间的顺序，后台健康快照不参与该代次；健康快照返回后直接调用 `applyEffectiveConfig(snapshot.config)` 和 `setStatuses(snapshot.statuses)`。
3. 健康快照没有保护当前 `busyIDs`。手动或自动生命周期操作执行期间，迟到快照可以覆盖刚写入的运行状态。
4. UI 刷新使用 `probeGeneration` 丢弃旧的普通探针批次，但健康协调器的 `runHealthProbeCycle()` 直接调用无代次参数的 `applyProbeResults(results)`；健康探针结果可以在生命周期操作完成后继续写入。
5. `HealthRecoveryState` 和 Rust owner 已有隧道级恢复/操作代次，但 Swift 门面没有把异步快照、探针批次与这些状态变化绑定成同一个结果准入边界。
6. `updateRuntime` 本身在主 actor 上提交完整值，问题不是数据竞争，而是已返回的旧异步结果缺少提交条件。

### 最小故障时序

```text
后台健康快照开始（读到 notLoaded）
        ↓
用户点击启动 → Rust start 成功 → UI 写入 running
        ↓
旧健康快照返回 → 当前实现再次写入 notLoaded  ← 状态倒灌
```

另一条路径是：

```text
健康快照完成 → 健康探针开始且尚未返回
        ↓
用户点击停止 → UI 写入 notRunning
        ↓
旧探针返回 satisfied → 当前实现仍写入旧 probeResults  ← 结果倒灌
```

## 固定方案

1. 在 `TunnelManager` 内增加只服务于结果准入的 Swift 状态读取代次：所有状态快照请求（同步刷新、异步刷新、后台健康快照）共享请求顺序；较旧请求完成后直接丢弃。
2. 增加跨生命周期/配置变化的失效代次。开始或结束隧道操作、配置成功变更、退出清理时，使在途快照和健康探针结果失效；不能取消的底层调用仍允许完成，但不得提交结果。
3. 健康快照提交时保留当前 `busyIDs` 的状态，不让监测读数覆盖正在执行的生命周期操作；操作结束后由操作结果或下一次新快照收敛。
4. 健康探针结果必须同时通过本轮健康读取代次和失效代次，才允许更新展示或调用 `recordHealthResult`；旧结果不能推进失败计数、排队恢复或熔断。
5. 不在 Rust Core 增加第二套代次；Rust 已有的操作代次继续负责系统副作用前的安全校验，Swift 新门禁只负责异步结果是否可以回写 UI 门面。

## 样本/fixture 矩阵

| 编号 | 场景与输入 | 可执行命令 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| C1 | 后台首个 snapshot 固定返回 `notLoaded`，期间手动 `start` 返回 `running`，再释放旧 snapshot | `swift test --filter StabilityStage2Tests.testLateHealthSnapshotCannotOverwriteManualStart` | 最终状态为 `running`，旧 snapshot 不得回写 | 状态回到 `notLoaded` 或产生额外生命周期调用 | Swift XCTest 输出 |
| C2 | 健康探针请求阻塞，期间手动 `stop` 返回 `notRunning`，再释放旧探针 | `swift test --filter StabilityStage2Tests.testLateHealthProbeCannotOverwriteManualStop` | 旧探针结果不写入、不推进恢复状态；最终状态为 `notRunning` | 出现旧 `probeResults`、恢复调用或状态倒灌 | Swift XCTest 输出 |
| C3 | 两个状态 snapshot 反序返回，先发请求的结果晚于后发请求 | `swift test --filter StabilityStage2Tests.testOlderSnapshotCannotOverrideNewerRefresh` | 只接受最新请求结果 | UI 状态采用旧请求内容 | Swift XCTest 输出 |
| C4 | snapshot/探针在异步操作开始前发出，操作期间配置或状态变化 | `swift test --filter StabilityStage2Tests.testOperationInvalidatesPendingHealthResults` | 旧结果丢弃；`busyIDs` 不被卡住 | 旧结果写回或 busy 集合残留 | Swift XCTest 输出 |
| C5 | 单条隧道操作期间另一条隧道 snapshot/探针正常返回 | `swift test --filter StabilityStage2Tests.testCrossLayerInvalidationKeepsOtherTunnelIndependent` | 只失效目标隧道相关结果，其他隧道继续展示和监测 | 其他隧道状态/探针被清空或改变 | Swift XCTest 输出 |
| C6 | 自动恢复成功后，之前发出的健康 snapshot/探针才返回 | `swift test --filter StabilityStage2Tests.testRecoveryResultCannotBeOverwrittenByOlderHealthRead` | 成功状态和恢复计数保持；旧读取不触发再次恢复 | 状态回退、重复恢复或失败计数增加 | Swift XCTest 输出 |
| C7 | 退出开始后健康快照、探针和恢复任务仍有迟到返回 | `swift test --filter StabilityStage2Tests.testShutdownInvalidatesPendingHealthResults` | 不再向 UI 写入结果、不再发起新的隧道生命周期操作 | 退出后仍更新状态或启动隧道 | Swift XCTest 输出 |
| C8 | 正常刷新、后台监测、手动启停和配置重载混合执行 | `swift test --filter StabilityStage2Tests` 与 `swift test` | 专项及全量回归通过，Schema/ABI/plist/ECS 行为不变 | 任一既有回归失败或出现计划外文件 | XCTest、Cargo、治理输出 |

## 验证、失败与回滚边界

- 先运行 C1/C2 的故障注入，确认当前基线能暴露状态倒灌，再实现统一结果门禁；C3–C7 在同一切片补齐。
- 所有 fake owner、fake probe 和阻塞 gate 使用临时目录、固定隧道 ID 和内存记录，不触碰真实 `launchctl`、SSH、ECS、用户配置或真实信号。
- 任何异常、取消、旧代次或配置不匹配都采用 fail-closed：丢弃结果，不触发生命周期副作用，不清空当前有效 UI 状态。
- 回滚只撤销本切片的 Swift 门面和 fixture 变更，保留 Rust owner、ECS 自动恢复、启动/退出资源收敛及日志计划已验收改动；不使用配置重写或真实 plist 删除作为回滚手段。
- 实施前必须完成本切片独立准入；实施后必须执行 Swift/Rust 回归、治理检查、`git diff --check` 和 GitNexus `detect_changes()`。

## 影响与共享边界

- `TunnelManager` upstream impact：`CRITICAL`，影响 103 个上游符号，其中 74 个直接引用，覆盖菜单栏、主面板、设置、启动/停止/重启/删除、配置重载和健康恢复。
- `refreshAsync` upstream impact：`CRITICAL`，影响 15 个符号、6 条执行流；`beginOperation` upstream impact：`CRITICAL`，影响 34 个符号、13 条执行流。
- `runHealthProbeCycle`、`recordHealthResult` 和 `performAutomaticRecovery` 当前 impact 为 `LOW`，但它们位于上述核心调用链中，必须用专项回归保护。
- `TunnelRuntimeState` upstream impact 为 `LOW`，本切片优先不改变其字段结构；如需修改，必须重新执行该符号 impact 并更新边界。
- 与已完成日志事件流计划共享 `TunnelManager` 和测试目录，采用单一编辑窗口；不回写日志计划行为。

## 当前准入状态

本 Step 0 已固定目标、范围、非目标、最小故障时序、结果门禁方案、样本矩阵、验证方式、失败/回滚边界和共享影响；独立准入复核已通过，C1–C3、C7 已形成专项反证，其余边界由统一门禁和全量回归覆盖，详细结果见[实施证据](tunnelpad-stability-stage2-cross-layer-consistency-implementation-20260902.md)。
