# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 0 独立准入复核

- 日期：2026-09-04
- 阶段：阶段 0
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- Step 0 证据：[阶段 0 Step 0](tunnelpad-unattended-managed-ssh-recovery-stage0-step0-20260904.md)
- 结论：通过，达到“待实施”标准（仅限阶段 0；阶段 1 仍须自己的 Step 0 与独立准入）

## 复核范围

本轮只复核阶段 0 是否已经把无人值守目标、受管进程身份、信号升级边界、自动冷却语义、失败策略、验证矩阵和回滚边界固定到可以进入下一阶段的程度。不把计划、Step 0 或既有真实故障注入误计为信号升级已经实现，也不准许本轮执行真实 `SIGCONT`、`SIGTERM`、`SIGKILL`、launchd、ECS 或远端操作。

## 严格准入逐项核对

| 准入条件 | 当前结果 | 证据与判断 |
|---|---|---|
| 当前阶段目标、范围和非目标 | 通过 | 专项计划明确只在 Rust Core 内设计受管 SSH 的收敛恢复；不修改配置 Schema、C ABI、HTTP API、launchd label、SSH 参数或 ECS 契约，不处理未知进程。 |
| Step 0 与基线类型 | 通过 | Step 0 明确记录了当前 `TunnelStatus`、`LaunchCtlExecutor`、`CoreOwner.stop`、健康恢复上限、现有信号入口和真实故障背景；真实故障仅作为问题定位证据。 |
| macOS 身份接口与失败语义 | 通过 | 当前 SDK 查证了 `proc_pidinfo(PROC_PIDTBSDINFO)` 的 UID/启动时间字段和 `proc_pidpath`；阶段 1 固定为 label、PID、UID、启动时间、可执行路径及 launchd 归属的组合核验，任一字段读取失败即视为未知并禁止发信号。完整 argv 不作为硬依赖。 |
| 可执行样本矩阵 | 通过 | Step 0 具备 8 行矩阵，覆盖正常 bootout、冻结 PID、逐级信号、PID 复用、取消、10 次快速失败冷却、FFI 顺序和启动过渡态；每行包含输入/基线、操作、预期、失败判定和输出位置。 |
| 自动冷却与无人值守边界 | 通过 | 计数冻结为当前 Core owner 内存范围；达到快速失败窗口后按单 generation、初始 30 分钟冷却继续自动重试，成功探针重置窗口；不引入配置 Schema 持久化，也不恢复永久人工熔断。 |
| 验证、失败和回滚边界 | 通过 | 阶段 1/2 只使用 fake runner、专项回归和隔离 Release 验证；身份不符、取消、超时、权限拒绝和命令错误均 fail-closed 并进入冷却；失败时只回滚本计划独立提交，不删除 plist、不改 ECS/远端规则、不接触凭证。 |
| 高影响范围与共享编辑 | 通过 | GitNexus 对 `LaunchCtlExecutor` 的 upstream 结果为 CRITICAL，已知 22 个符号、3 条流程、6 个模块；计划已登记该风险，要求每个实际修改符号前重新做 impact，并在提交前做 `detect_changes()`；Rust 共享生命周期文件串行编辑。 |
| 治理门禁与当前阻塞 | 通过 | Step 0 已有 Rust 66+1、Swift 139 回归证据；`plan-governance-cli check . --strict-readiness` 与 `git diff --check` 已通过；阶段 0 不再有未解决阻塞。 |

## 准入结论

阶段 0 的目标、范围/非目标、Step 0、身份失败语义、样本矩阵、验证方式、失败/回滚边界、高影响编辑边界均已明确，达到“待实施”标准。该结论只允许后续建立阶段 1 的实现 Step 0，不代表阶段 1 已准入，也不代表当前程序已经具备自动发信号或无人值守恢复能力。

阶段 1 实施前必须新增并通过自己的 Step 0 与独立准入，至少实现并验证：Rust 身份读取抽象、信号执行抽象、PID 复用负例、冻结 PID 无人工释放 fixture、generation 取消、stop → ECS → start 顺序反证和自动冷却计数测试。真实 App 验收继续保留在阶段 3，且不得人工释放冻结 PID。

本次复核未调用真实 `launchctl`、SSH、ECS、远端接口或用户隧道，未发送任何进程信号。
