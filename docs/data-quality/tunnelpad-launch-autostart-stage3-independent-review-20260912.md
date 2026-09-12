# 阶段 3 独立复核：启动自动恢复

- 日期：2026-09-12；复核者：独立只读复核（未参与实现与测试编写，ZCode 子代理）
- 方式/风险：独立 / 高影响（生命周期与共享逻辑）
- 受审范围：`restoreAutoStartTunnels` 实现、AppDelegate 挂接、两个专项测试及 StubLifecycleOwner 扩展

## 逐项结论（R1–R6 及六项清单全部通过）

1. **R1–R6 边界 — 通过**：R1 已运行跳过（自动恢复竞争经 3 次失败 + 10s 退避排除）；R2 busy 经 startAsync `beginOperation` 门禁返回 `.inProgress` 不启动、不误报 lastError（附轻微缺口：无直接专项测试）；R3 ECS fail-closed 失败隔离、循环无条件继续（附轻微观察：失败条居配置末尾，"不阻断后续"未被顺序性证明）；R4 缺省不参与；R5 标志先置位与"单次尝试"决策自洽（成功后置位反而会重放失败尝试）；R6 状态未知 fail-closed 全部跳过，测试诚实不对 lastError 归属作断言。
2. **并发与时序 — 通过**：@MainActor 轮询让出主 actor；恢复轮询读已发布 statuses，不依赖自身 token 幸存，任何竞争者发布全量快照即可满足等待；超时只漏恢复不会误启动；`applyStatusSnapshot` 经 `setStatuses` 全量替换，启动期首个非空 statuses 必为全量快照，无部分填充。
3. **生命周期交互 — 通过（表述修正）**：恢复 Task 不被 shutdownAsync 取消；真正防线在 Rust owner——`shutdown()` 先 `closed=true` + 取消在途 token + 推进代次 + 持锁逐条 bootout，恢复中的启动要么在 shutdown 前完成（随后被统一停掉）要么被 `OWNER_CLOSED`/`STALE_OPERATION` 门禁在写 plist/bootstrap 前中止，无半启动遗留（Rust 测试 `shutdown_cancels_in_flight_lifecycle_commands` 覆盖）。
4. **不变量 — 通过**：新增不自动启动、参数修改不自动重启、退出即停、fail-closed 均保持。观察项：≤5s 发现窗口内新增且 autoStart=true 的隧道可能被本轮拉起（add 路径本身不启动，符合用户标记意图，窗口极小）。
5. **测试质量 — 通过**：桩的锁保护/失败注入正确；启动后状态断言确定性（busy 合并保护 .running 不被快照覆盖）；复核者复跑 5 轮 + 全量 1 次，加实施者 5 次，共 11 次零失败。
6. **回归面 — 通过**：`restoreAutoStartTunnels` 唯一生产调用方为 AppDelegate；API/菜单/面板无间接触发路径。
7. **声明真实性 — 通过**：`swift test` 150/150 复跑通过。

## 总体结论

**PASS**。无必须修复项；3 项轻微观察（R2 无直接测试、R3 顺序性断言偏弱、发现窗口内新增 autoStart 隧道可能被本轮拉起）。

## 范围外发现

工作树含非本阶段声明范围的改动：健康监测路径不再写 `lastError`（进度/冷却/失败）及 `StabilityStage1/2Tests` 配套断言调整、主面板错误栏移除。复核确认不构成阶段 3 缺陷（恢复路径自身失败仍写 lastError，R3 可见性不受影响），建议在验证记录中明确归属——已记录于[阶段 1–3 实施证据](tunnelpad-launch-autostart-stage1-3-implementation-20260912.md)。
