# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 1 实施证据

- 日期：2026-09-04
- 阶段：阶段 1
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- Step 0：[阶段 1 Step 0](tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md)
- 结论：阶段 1 隔离实现与验证完成；不包含真实进程信号、真实 launchd、用户隧道或 ECS/远端验收。

## 实施范围

本阶段只修改 Rust Core 的受管 SSH stop 收敛路径、Swift 健康恢复冷却状态和专项测试。Rust 仍是生命周期与进程信号唯一 owner；Swift 仍编排既有 stop → ECS preflight → start 顺序。未新增配置字段、HTTP API、C ABI、launchd label、SSH 参数或远端资源写入。

## 已实现行为

| 边界 | 实现与反证 |
|---|---|
| 受管身份 | macOS 使用 `proc_pidinfo(PROC_PIDTBSDINFO)` 读取 PID、UID、启动时间，使用 `proc_pidpath` 读取可执行路径；每一级信号前重新核验，读取失败或字段变化均 fail-closed。 |
| 停机收敛 | SSH 隧道先检查 `notLoaded`，否则捕获身份并执行 bootout；先以 100ms 轮询等待最多 3 秒，仍未收敛时按 CONT → TERM → KILL 各自重新核验并有界等待。 |
| 状态查询异常 | 受管路径将非“服务不存在”的 `launchctl print` 失败作为错误，不把未知状态当作未加载；初始 `notLoaded` 不再额外 bootout。 |
| 非 SSH 隔离 | `CoreOwner.stop_with_generation` 只对 SSH 命令进入受管收敛器，非 SSH 保持原 bootout 路径。 |
| 取消与代次 | bootout、等待和每一级信号前均有取消门禁；旧 generation 不会继续信号或解锁 Swift 的 ECS/start。 |
| 自动冷却 | Swift 第 10 次恢复失败后清零快速尝试计数，进入 30 分钟内存冷却；冷却内只读不建恢复任务，冷却到期按 3 次失败阈值重新开始；成功探针、手动 start/stop 清除冷却。 |

## 验证结果

| 检查 | 命令 | 结果 |
|---|---|---|
| Rust 全量与差分 | `cargo test --manifest-path rust/Cargo.toml` | 72 项 Rust 单元测试通过，1 项差分测试通过；无失败、无警告。 |
| Swift 全量 | `swift test` | 139 项通过；新增第 10 次失败冷却、冷却时钟和手动 start 重置测试通过。 |
| Rust 变更文件格式 | `rustfmt --edition 2021 --check rust/tunnelpad-core/src/launchctl.rs`；`rustfmt --edition 2021 --check rust/tunnelpad-core/src/launchd_executing.rs` | 通过。 |
| 差分空白 | `git diff --check` | 通过。 |
| GitNexus 变更影响 | `node .gitnexus/run.cjs detect_changes --scope all --repo TunnelPad --limit 100` | 8 个文件、79 个符号、23 条流程，风险等级 `critical`；与已登记的 `LaunchCtlExecutor`/`TunnelManager` CRITICAL 影响一致，未扩大到配置/API/ABI。 |
| 治理门禁 | `plan-governance-cli check . --strict-readiness` | 通过。 |

## 尚未完成的边界

- 阶段 1 没有发送真实 `SIGCONT`、`SIGTERM` 或 `SIGKILL`，没有调用真实用户 launchd/SSH/ECS。
- 阶段 2 仍需自己的 Step 0、独立准入、Release 产物与兼容性验证。
- 阶段 3 才能在用户明确授权的真实活动隧道上做一次不人工释放 PID 的无人值守验收；本文件不把隔离 fixture 视为生产证明。
