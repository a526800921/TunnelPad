# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 1 独立准入复核

- 日期：2026-09-04
- 阶段：阶段 1
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- Step 0 证据：[阶段 1 Step 0](tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md)
- 前置：[阶段 0 独立准入复核](tunnelpad-unattended-managed-ssh-recovery-stage0-independent-review-20260904.md)
- 结论：通过，达到“待实施”标准（仅限阶段 1；不代表代码已修改或真实环境已验收）

## 复核范围

本轮只准入 Rust Core 受管进程收敛器和 Swift 内存自动冷却的隔离实现。实际代码修改必须按计划逐符号重新执行 GitNexus impact；阶段 1 只允许使用 fake、临时目录和内存时钟，不允许发送真实进程信号，不允许调用真实 launchd、SSH、ECS 或用户隧道。

## 严格准入逐项核对

| 准入条件 | 当前结果 | 证据与判断 |
|---|---|---|
| 当前阶段目标、范围和非目标 | 通过 | 阶段 1 只实现受管 SSH 的身份核验/信号升级和第 10 次失败后的自动冷却；不新增配置字段、HTTP API、C ABI、launchd label，不处理未知进程或非 SSH 进程。 |
| Step 0 与基线类型 | 通过 | Step 0 已记录 Rust stop/launchd/FFI、Swift 恢复上限和现有取消边界，前置阶段 0 已核对 macOS `libproc` 接口和 CRITICAL 影响。 |
| 身份闭环与失败语义 | 通过 | 冻结为 label、PID、UID、启动时间、可执行路径及 launchd 归属的组合核验；查询失败、PID 复用、路径变化或权限拒绝均为未知、零信号、fail-closed；完整 argv 不作为硬依赖。 |
| 有界信号顺序 | 通过 | 已固定 bootout 后先等待 `notLoaded`，仍未收敛时逐级 CONT → TERM → KILL；每级前重新核验身份，等待受 cancellation/generation 约束，最终同时确认 label 未加载且原 PID 消失。 |
| 自动冷却语义 | 通过 | 第 10 次恢复失败改为当前 Core owner 内存范围内的 30 分钟冷却；冷却内只读、不建恢复任务，成功探针或手动操作清除，重启不持久化。 |
| 可执行样本矩阵 | 通过 | Step 0 具备 10 行矩阵，覆盖正常 bootout、冻结 PID、PID 复用、权限/进程消失、取消、冷却、FFI 顺序和非 SSH/多隧道隔离；每行均有输入、操作、预期、失败判定和输出位置。 |
| 验证和回滚边界 | 通过 | 已锁定 Rust/Swift 专项与全量回归、差分、治理和 `detect_changes()`；失败只回滚阶段 1 独立提交，不改 plist、config、ECS、远端资源或凭证；真实无人值守验收保留到阶段 3。 |
| 高影响范围与共享编辑 | 通过 | `LaunchCtlExecutor` upstream 为 CRITICAL（22 个已知符号、3 条流程、6 个模块）；计划明确 Rust `launchctl.rs`、`launchd_executing.rs`、`owner.rs`、FFI/测试以及 Swift `HealthRecovery.swift`/`TunnelManager.swift` 的共享编辑需串行，并要求编辑前重新 impact。 |
| 当前阶段无阻塞与治理门禁 | 通过 | Rust 66 项单元 + 1 项差分、Swift 139 项通过；`plan-governance-cli check . --strict-readiness` 与 `git diff --check` 已通过；阶段 1 没有未解决的准入阻塞。 |

## 准入结论

阶段 1 的实现契约、身份失败策略、信号状态机、自动冷却、样本矩阵、验证/回滚边界及 CRITICAL 共享编辑边界已明确，达到“待实施”标准。现在可以进入代码修改，但完成前不得宣称无人值守恢复已具备；实现后的专项测试、全量回归、`detect_changes()` 和阶段 1 独立完成复核仍是必需条件。

本次复核未修改代码，未发送任何信号，未调用真实 `launchctl`、SSH、ECS、远端接口或用户隧道。
