# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 0 Step 0

- 日期：2026-09-04
- 基线类型：高风险生命周期行为变更的源码现状、已有真实故障诊断和可执行 fixture 矩阵
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 结论：Step 0 基线已建立，阶段 0 独立准入已通过；这不代表信号升级已实现，阶段 1 仍须自己的 Step 0 与独立准入。

## 现状基线

| 项目 | 当前事实 | 证据/命令 | 判定 |
|---|---|---|---|
| launchd 状态模型 | Rust `TunnelStatus` 只有 `Running { pid }`、`NotRunning`、`NotLoaded`、`Other { state }`；PID 是可选字段，没有启动时间、可执行文件身份或命令指纹 | `rust/tunnelpad-core/src/launchctl.rs` 的 `TunnelStatus`、`parse_status` | 已确认 |
| launchd 执行入口 | `LaunchCtlExecutor` 当前只有 `bootstrap`、`bootout`、`status`；没有针对受管 SSH PID 的 `SIGCONT`、`SIGTERM` 或 `SIGKILL` 入口 | `rg -n "bootstrap|bootout|status|SIGCONT|SIGTERM|SIGKILL" rust/tunnelpad-core/src/launchctl.rs rust/tunnelpad-core/src/launchd_executing.rs` | 已确认 |
| Rust stop 行为 | `CoreOwner.stop_with_generation` 执行一次 `bootout_cancellable`，随后只读一次 status 并返回；未收敛时不自动释放旧 PID | `rust/tunnelpad-core/src/owner.rs` 的 `stop_with_generation` | 已确认 |
| owner 抽象边界 | `LaunchdExecuting` 是共享接口，当前有多处实现/转发；新增信号能力会影响 Rust owner、FFI 及测试 fake | `node .gitnexus/run.cjs impact --uid 'Struct:rust/tunnelpad-core/src/launchctl.rs:LaunchCtlExecutor' --direction upstream --repo TunnelPad --include-tests --depth 3 --summary-only` | CRITICAL |
| 健康恢复上限 | `HealthRecoveryPolicy.maximumRecoveryAttempts = 10`；第 10 次失败后 Swift 记录“需手动启动或重启”，并停止后续自动恢复 | `Sources/TunnelPadCore/HealthRecovery.swift`、`Sources/TunnelPadCore/TunnelManager.swift` | 已确认 |
| 现有信号代码 | Rust 仅在取消外部命令时调用 `child.kill()`；没有对受管 SSH 子进程执行可核验的信号升级。Swift 的 SIGTERM/SIGINT 处理属于 App 退出清理，不是隧道 PID 处置 | `rg -n "kill\\(|SIGSTOP|SIGTERM|SIGCONT|SIGKILL|processIdentifier|startTime|proc_pidinfo|ProcessInfo" rust/tunnelpad-core/src rust/tunnelpad-core/tests Sources/TunnelPadCore Tests/TunnelPadCoreTests` | 已确认 |
| 真实故障诊断 | 阶段 2 真实 Release App 中，受控冻结受管 SSH 后观察到 launchd 进入 `SIGTERMed`；不释放原 PID 时旧进程退出确认可能阻塞，释放后既有 stop → ECS → start 链路完成 | [阶段 2 真实 App 验收](tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md) | 已确认；仅为背景，不是无人值守通过证据 |

## macOS 身份接口查证

| 接口/字段 | 查证结果 | 计划用途 |
|---|---|---|
| `proc_pidinfo` / `PROC_PIDTBSDINFO` | Xcode SDK 的 `libproc.h` 与 `sys/proc_info.h` 可用；`proc_bsdinfo` 提供 PID、UID、进程名和 `pbi_start_tvsec`/`pbi_start_tvusec` | 形成不依赖 PID 单独匹配的启动时间与用户身份证明 |
| `proc_pidpath` | Xcode SDK 提供稳定的进程可执行路径查询 | 与当前隧道配置的首个可执行路径比较，拒绝路径不一致的 PID |
| 完整参数 | `proc_pidinfo`/`proc_pidpath` 本身不返回完整 argv；当前 TunnelPad 也不读取或记录完整 SSH 参数 | 不把完整参数作为必须的运行时读取条件；以 label、PID、启动时间、UID、可执行路径和受管 plist/配置关系组成最小身份闭环，指纹只在内存中使用 |

查证命令：`rg -n "proc_pidinfo|PROC_PIDTBSDINFO|pbi_start_tvsec|pbi_uid|proc_pidpath" /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/sys/proc_info.h /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/libproc.h`；未改系统文件或项目实现。

## 影响分析

GitNexus 对 `LaunchCtlExecutor` 的 upstream 结果为：已知影响 22 个符号、3 条执行流程、6 个模块，风险 `CRITICAL`；`LaunchdExecuting` 的接口动态分派未完全计入，实际影响可能更高。主要涉及 Rust FFI roundtrip/error、`CoreOwner.run`、`launchctl` runner 和多套 fake runner。

因此本计划要求：先在 Rust 内部引入可测试的身份读取/信号执行抽象，不先扩展 C ABI，不让 Swift 直接调用系统信号，也不把信号逻辑写入 `TunnelManager`。

## Step 0 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前 Rust/Swift 基线 | `cargo test --manifest-path rust/Cargo.toml`；`swift test` | Rust 66+1、Swift 139 项全通过 | 基线回归失败或结果无法区分 | 本文件与终端输出 |
| 2 | 当前信号入口 | `rg -n "kill\\(|SIGSTOP|SIGTERM|SIGCONT|SIGKILL|processIdentifier|startTime|proc_pidinfo|ProcessInfo" rust/tunnelpad-core/src rust/tunnelpad-core/tests Sources/TunnelPadCore Tests/TunnelPadCoreTests` | 除取消子进程和 App 退出信号外，没有受管隧道 PID 升级路径 | 发现未登记的生产信号旁路 | 本文件 |
| 3 | 正常 bootout | Rust fake runner 的 stop fixture | 不发升级信号；`notLoaded` 前不解锁后续生命周期 | 提前 start、ECS 或多余信号 | 阶段 1 专项测试 |
| 4 | 已核验受管 PID 被冻结 | 脚本化 `SIGSTOP → SIGCONT` fixture | 无人工操作也能继续收敛 | fixture 依赖外部释放 | 阶段 1 专项测试 |
| 5 | PID 复用/身份不符 | 身份字段不一致 fixture | 不发任何信号，不启动第二条隧道，进入自动冷却 | 错杀、越过门禁或无限忙等 | 阶段 1 专项测试 |
| 6 | 快速失败达到 10 次 | 自动冷却计数 fixture | 无需人工操作，按频率上限创建后续 generation | 永久熔断或高频恢复风暴 | 阶段 1/2 专项测试 |
| 7 | 取消、手动 stop、删除、重载、退出 | generation/cancellation fixture | 取消后不再发信号、不再 ECS/start | 迟到任务越过生命周期边界 | 阶段 1 专项测试 |
| 8 | ECS/start 顺序 | Rust FFI 顺序 fixture | 旧 PID 和 label 收敛后才允许既有 ECS/start；启动后需 `running` | 顺序反转或绕过 fail-closed | 阶段 2 专项测试 |

## Step 0 阻塞与准入边界

- 当前状态只证明“问题可定位且方案可测试”，不证明 `SIGCONT/TERM/KILL` 已实现。
- 阶段 0 独立复核已冻结两个技术边界：`libproc` 身份读取或 launchd 归属核验失败均视为未知并禁止发信号；自动冷却计数仅存在于当前 Core owner 内存生命周期，不跨 App 重启保存，也不新增配置 Schema。
- 用户要求无人值守已确认；“无人值守”不等于对未知进程盲杀。身份无法证明时，程序自动退避重试并保留安全边界。
- 真实阶段 3 必须在无人工释放原 PID 的条件下验收；此前“测试窗口人工释放原 PID 后恢复”不能替代该验收。

## 验证结果

| 验证 | 结果 |
|---|---|
| Rust 回归 | 66 项单元测试通过，差分 1 项通过 |
| Swift 回归 | 139 项通过 |
| GitNexus impact | `LaunchCtlExecutor` CRITICAL，22 个已知影响符号、3 条流程、6 个模块；动态接口边界可能低估 |
| 真实环境操作 | 本 Step 0 未发送信号、未改 launchd、未改 config、未执行 ECS/远端写入 |
| 治理检查 | `plan-governance-cli check . --strict-readiness` 已通过；阶段 0 已达到待实施标准，未宣称阶段 1 已具备实施准入 |

## Step 0 结论

Step 0 已建立，阶段 0 独立准入已通过。阶段 1 仍须自己的 Step 0 与独立准入；在阶段 1 达到“待实施”标准前，不实施 Rust Core 信号升级，不进行真实 `SIGSTOP` 无人工释放验收。
