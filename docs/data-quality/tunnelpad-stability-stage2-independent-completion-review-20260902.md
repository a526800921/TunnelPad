# TunnelPad 稳定性阶段 2 整体独立完成复核

- 日期：2026-09-02
- 阶段：阶段 2
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 阶段证据：[阶段 2 真实 App 受控验收](tunnelpad-stability-stage2-real-app-acceptance-20260902.md)
- 结论：通过，阶段 2 已完成；阶段 3 保持设计中

## 复核方法

本复核重新读取当前工作树的阶段 2 实现、四个切片的 Step 0/准入/实施/完成证据、真实 App 受控验收、当前治理文件和关键测试结果，不以实施文档中的状态文字单独作为完成依据。复核边界为当前已确认的 `launchd` 执行器；未来 `app` 执行器、pidfile 身份校验和孤儿进程收敛不属于阶段 2。

## 阶段 2 完成条件逐项核对

| 完成条件 | 当前证据 | 结论 |
|---|---|---|
| ECS 自动恢复采用停止、前置同步、启动的安全顺序 | [ECS 切片实施证据](tunnelpad-stability-stage2-ecs-recovery-implementation-20260902.md)、[ECS 切片独立准入复核](tunnelpad-stability-stage2-ecs-recovery-independent-review-20260902.md)；fake owner 和前置失败矩阵覆盖 `notLoaded` 门禁与 fail-closed | 通过 |
| 启动、退出和崩溃后重新启动时资源状态能够收敛 | [启动/退出切片独立完成复核](tunnelpad-stability-stage2-lifecycle-reconciliation-independent-completion-review-20260902.md)；真实 App 启动发现、正常退出清理和 App 崩溃后重启发现已验收 | 通过 |
| 异步快照、探针和恢复结果不会被迟到任务倒灌 | [跨层一致性切片独立完成复核](tunnelpad-stability-stage2-cross-layer-consistency-independent-completion-review-20260902.md)；C1–C3/C7 迟到结果、busy 状态和代次门禁反证通过 | 通过 |
| 配置重载不会先提交候选配置再处理旧资源 | [配置重载切片独立完成复核](tunnelpad-stability-stage2-config-reload-reconciliation-independent-completion-review-20260902.md)；候选校验、删除 label 停止/复核/提交顺序和失败保留旧配置通过 | 通过 |
| 真实运行中的受管隧道可被 `KeepAlive` 重拉起、被正常 bootout，并在 App 崩溃后被重新发现 | [真实 App 受控验收追加记录](tunnelpad-stability-stage2-real-app-acceptance-20260902.md#追加验收真实运行中受管隧道与-app-崩溃恢复)；真实 `admin-tunnel` 的 HTTP `401`、PID 变化/保持、label 和端口收敛均已记录 | 通过 |
| 真实 HTTP 探针假死能够触发 ECS 自动恢复业务闭环 | [真实探针假死验收](tunnelpad-stability-stage2-real-app-acceptance-20260902.md#追加验收http-探针假死触发-ecs-自动恢复)；身份校验后的 `SIGSTOP` 造成连续 3 次失败，实际观察到 `stop → ECSPreStartChecker.checkAsync → start`、同步日志、新 PID 和 HTTP `401` | 通过 |
| 单隧道故障、清理和恢复不会扩散到其他隧道，且不新增 Schema 或操作计划外真实资源 | 阶段 2 专项测试、Rust owner 测试、真实验收均只使用受管 `admin-tunnel`；`reverse-ssh` 未加载；当前配置字段和执行器枚举未改变 | 通过 |

## 独立执行结果

| 命令/检查 | 结果 |
|---|---|
| `swift test` | 129/129 通过；其中 `StabilityStage2Tests` 11/11 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 62 个 Rust 单元测试、1 个差分测试通过 |
| `scripts/update-ecs-ssh-ip --check` | 双端点探测和受管安全组读取成功，未执行写操作 |
| `codesign --verify --deep --strict dist/TunnelPad.app` | 通过 |
| 真实环境清理复查 | `admin-tunnel` label 不存在/未加载，App/隧道 PID 不存在，8081 无监听 |
| `plan-governance-cli check . --strict-readiness` | 通过 |
| `plan-governance-cli check . --stale-days 10` | 通过 |
| `git diff --check` | 通过 |

阶段 2 各切片实施前的 upstream impact、实施后的 GitNexus 变更范围和各自独立完成复核已分别登记在对应证据；本次复核没有修改生产代码，也没有重新执行真实隧道故障注入。

## 范围与后续

阶段 2 关闭当前四个稳定性切片、`launchd` 生命周期收敛、跨层结果门禁、配置重载收敛和真实 `admin-tunnel` 业务闭环。阶段 3 只负责隔离 demo、受控应用/发布门禁和文档收口；未来 `app` 执行器仍需另立计划并重新冻结 pidfile 身份校验、停止失败和孤儿进程边界。

## 结论

阶段 2 的实现、专项反证、全量回归、真实 App/launchd 生命周期和真实 HTTP 探针触发 ECS 自动恢复均已独立核对通过。因此本复核结论为：**阶段 2 已完成；阶段 3 保持设计中，不因本复核自动获得实施准入。**
