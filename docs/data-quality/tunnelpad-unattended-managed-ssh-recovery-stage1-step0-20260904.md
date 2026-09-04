# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 1 Step 0

- 日期：2026-09-04
- 基线类型：Rust Core 高风险生命周期实现前的内部契约、隔离 fixture 和失败边界
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 前置：[阶段 0 独立准入复核](tunnelpad-unattended-managed-ssh-recovery-stage0-independent-review-20260904.md)
- 结论：阶段 1 Step 0 已建立；当前只允许进行阶段 1 独立准入，不代表 Rust 信号升级已经实现。

## 当前实现基线

| 项目 | 当前事实 | 证据/命令 | 判定 |
|---|---|---|---|
| Rust launchd API | `LaunchCtlExecutor` 只执行 `bootstrap`、`bootout`、`status`；`TunnelStatus::Running` 只携带可选 PID | `rust/tunnelpad-core/src/launchctl.rs`、`launchd_executing.rs` | 已确认 |
| Rust stop | `CoreOwner.stop_with_generation` 一次 bootout 后只读一次 status；未收敛时返回过渡态，不会释放冻结旧 PID | `rust/tunnelpad-core/src/owner.rs` | 已确认 |
| Swift 自动恢复 | 连续 3 次探针失败后按既有退避调度；第 10 次恢复失败进入人工停止分支 | `Sources/TunnelPadCore/HealthRecovery.swift`、`TunnelManager.swift` | 已确认；本阶段修改 |
| 现有进程控制 | 仅 `SystemProcessRunner` 在取消外部 `launchctl` 时调用子进程 `kill()`；没有受管 SSH PID 信号接口 | `rg -n 'kill\\(|SIGCONT|SIGTERM|SIGKILL|proc_pidinfo|proc_pidpath' rust/tunnelpad-core/src Sources/TunnelPadCore` | 已确认 |
| 阶段 0 影响 | `LaunchCtlExecutor` upstream 为 CRITICAL，已知 22 个符号、3 条流程、6 个模块；接口动态分派可能低估 | [阶段 0 Step 0](tunnelpad-unattended-managed-ssh-recovery-stage0-step0-20260904.md) | 已登记 |

## 阶段 1 冻结实现契约

### 受管身份

每次信号前重新取得并核对以下组合，全部相等才允许继续：当前隧道 ID、当前恢复 generation、目标 launchd label、`launchctl print` 返回的 PID、进程 UID、进程启动时间（秒与微秒）和 `proc_pidpath` 返回的可执行路径。launchd label 的归属由同一 label 的状态查询确认；完整 argv 不读取、不记录，也不作为硬依赖。任何查询失败、PID 变化、启动时间变化、UID 变化、可执行路径变化或 label 不再处于目标状态，均视为未知并立即 fail-closed，不发信号、不进入 ECS/start。

`proc_pidinfo(PROC_PIDTBSDINFO)` 与 `proc_pidpath` 的系统实现只在 macOS 可用；权限拒绝、进程已退出和系统 API 返回异常统一映射为“身份未知”。fake runner 必须能够显式注入成功、进程消失和字段变化，不能用默认值掩盖失败。

### 收敛状态机

1. 捕获运行中受管 SSH 的 PID 与身份票据；若目标已 `notLoaded`，直接返回收敛成功。
2. 执行一次可取消 `launchctl bootout`，然后以 100ms 为最小间隔轮询目标 label，最多等待 3 秒；期间取消或 generation 失效立即停止后续动作。
3. 若 label 已 `notLoaded`，不得发任何升级信号，返回 stop 成功。
4. 若仍未收敛，按“重新核验身份 → 发送信号 → 有界等待”的原子序列执行 `SIGCONT`（最多等待 1 秒）、`SIGTERM`（最多等待 2 秒）、`SIGKILL`（最多等待 1 秒）。每一级都必须重新查询 label/PID/身份票据；不允许跳级、盲杀进程组或按名称/端口扩大范围。
5. 最后必须同时确认 label 为 `notLoaded` 且原 PID 已消失；任何超时、权限拒绝、状态不可分类或身份不一致均返回错误，Swift 既有 ECS/start 门禁不得被解锁。

真实系统信号只由 `LaunchCtlExecutor` 的受控实现发送；`LaunchdExecuting` 增加可注入的受管 stop 能力，旧 fake 默认保持 bootout/status 语义，专项 fake 显式记录信号历史。C ABI 不新增函数或字段。

### 自动冷却

Swift `HealthRecoveryState` 保留连续 3 次失败和最多 10 次快速恢复尝试；第 10 次恢复失败不再停止隧道或要求人工启动，而是清零快速尝试计数并进入 30 分钟内存冷却。冷却期间只读探针，不创建新的恢复任务；冷却到期后重新按 3 次失败阈值开始第 1 次恢复。探针成功、手动 start 或手动 stop 清除冷却；冷却计数不落盘、不跨 App 重启持久化。原有取消、busy、generation 和多隧道隔离不变。

## 阶段 1 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 既有 Rust/Swift 基线 | `cargo test --manifest-path rust/Cargo.toml`；`swift test` | Rust 66 项单元 + 1 项差分、Swift 139 项通过 | 基线回归失败或无法与阶段 1 失败区分 | 本文件与终端输出 |
| 2 | 正常 `bootout` | `LaunchdExecuting` fake 注入 `notLoaded` 过渡 | 不发信号，stop 返回成功；ECS/start 顺序保持由 Swift 门禁控制 | 出现多余信号或提前解锁 start | 阶段 1 专项 Rust 测试 |
| 3 | 已核验 PID 后冻结 | fake 身份票据 + 状态脚本模拟 `SIGSTOP` 后无人工释放 | 自动记录 CONT → TERM → KILL，最终 `notLoaded`；不得依赖测试线程额外释放 | 需要人工释放、无限等待、跳级或无身份复核 | 阶段 1 专项 Rust 测试 |
| 4 | PID 复用/身份变化 | 在每一级信号前注入 PID、启动时间、UID 或路径变化 | 立即停止，零信号，不进入 ECS/start | 错杀、继续发信号或启动第二实例 | 阶段 1 专项 Rust 测试 |
| 5 | 权限拒绝/进程消失 | 身份 reader 或 signaler 返回失败；status 变为无 PID | fail-closed，保留安全错误分类，零后续信号 | 把未知当作匹配或继续升级 | 阶段 1 专项 Rust 测试 |
| 6 | 取消/手动 stop/删除/退出 | generation/cancellation fake 在 bootout、等待和每级信号前注入取消 | 取消后不再发信号、不 ECS/start、不回写迟到状态 | 迟到副作用越过代次边界 | 阶段 1 Rust/Swift 专项测试 |
| 7 | 第 10 次恢复失败 | Swift health fake 使用可控 uptime 运行 10 次失败 | 不调用人工 stop；进入 30 分钟冷却；冷却内无恢复风暴，到期后自动重新计数 | 永久熔断、立即重试或调用 stop | 阶段 1 Swift 专项测试 |
| 8 | 冷却期间探针成功/手动操作 | 注入 satisfied、manual start/stop 和退出 | 清除冷却、取消任务、状态与 generation 不倒灌 | 成功后仍冷却或手动操作触发迟到恢复 | 阶段 1 Swift 专项测试 |
| 9 | FFI 顺序 | Rust owner fake + Swift fake ECS 记录 stop/status/preflight/start | 旧 label/PID 收敛后才 ECS/start；Rust stop 错误不解锁后续 | 顺序反转、绕过 fail-closed 或 ABI JSON 变化 | 阶段 1 FFI/Swift 专项测试 |
| 10 | 非 SSH / 多隧道 | `/usr/bin/true` 或第二条隧道与目标 SSH 并行 fixture | 非 SSH 不发送受管 SSH 信号；其他隧道调用历史为空 | 按名称/端口广杀或跨隧道污染 | 阶段 1 Rust/Swift 专项测试 |

## 验证和回滚边界

- 阶段 1 实现前必须再次对实际修改符号执行 GitNexus `impact`；`LaunchCtlExecutor` 的 CRITICAL 结果不可忽略。
- 阶段 1 只使用 Rust/Swift fake、临时目录和内存状态；不调用真实 `kill`、真实 launchd、ECS、SSH 或用户隧道。
- 实现后运行 Rust 专项与全量回归、Swift 专项与全量回归、`git diff --check`、`plan-governance-cli check . --strict-readiness`，并在提交前运行 GitNexus `detect_changes()`。
- 失败时只回滚阶段 1 独立提交；不删除 plist、不改 config、不改 ECS 规则、不触碰凭证。真实 App 无人工释放验收仍留在阶段 3。

## Step 0 结论

阶段 1 的身份票据、信号顺序、超时/取消、冷却语义、fake 注入边界、FFI 顺序和非 SSH 隔离均已固定，达到申请独立准入所需的 Step 0 条件。当前不宣称 Rust 或 Swift 实现已改变；独立准入通过后才进入代码修改。
