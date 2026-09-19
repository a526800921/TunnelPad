# 计划：TunnelPad 无人值守 SSH 异常恢复与孤儿清理

## 背景

2026-09-15，用户明确要求：无人值守运行期间，连接异常后必须能够自动恢复，并清理孤儿 SSH。该范围是对已完成的[无人值守启动恢复](tunnelpad-unattended-launch-recovery.md)和[受管 SSH 收敛恢复](tunnelpad-unattended-managed-ssh-recovery.md)的新增加固，不重写它们的历史完成证据。

当前版本为 launchd 作业增加了日志时间戳代理，运行关系变为：`launchd → tunnelpad-log-proxy → ssh`。这解决了原始 launchd 日志没有逐行时间的问题，但也新增了一个必须由本计划收敛的监督边界：代理异常退出、日志写入失败、信号升级或 App/Bundle 路径变化时，不能遗留 SSH，也不能让新的重试与旧实例重叠。

## 目标

- 无人值守连接异常时，沿用现有退避、generation、锁和健康恢复 owner 自动重试；恢复前不重复 bootstrap。
- 每个 TunnelPad launchd 作业只能拥有一个可证明归属的代理及 SSH 进程树；停止、重启、退出、代理异常和日志 I/O 失败后，旧进程在有界时间内退出并被回收。
- TERM 不响应、管道被孙进程持有、代理被强制终止等故障，均不得留下可继续占用转发端口的孤儿 SSH；无法证明归属时 fail-closed，不杀任意 SSH。
- launchd 状态中的 PID/可执行文件与 Rust Core 的受管身份核验一致；旧实例未收敛时禁止启动新实例。
- 日志代理失效、辅助程序缺失或 Bundle 路径不再有效时，输出可定位的本地错误，并在满足前置条件后自动恢复。
- 本地进程树已经收敛但 ECS 仍遗留远端监听时，对显式开启 `forceRemotePortCleanup` 的隧道，在新 SSH 启动前强制结束该 `-R` 远端端口的全部 TCP 监听进程；确认端口为空后才重连。

## 非目标

- 不修改 `18080` 端口映射、SSH 转发参数语义或 ECS 远端授权；配置 schema 只新增默认关闭的逐隧道强杀布尔值。
- 不清理目标 `-R` 端口以外的进程；关闭配置时不执行任何远端端口清理。
- 不使用固定历史 PID、`fuser -k` 或 `pkill`；开启强杀后以“监听目标端口”为用户明确授权，进程类型、UID、IP 和会话归属不再作为筛选条件，但仍使用 pidfd 防止 PID 复用误伤。
- 不把当前真实隧道的偶发错误日志直接判定为代码修复完成；真实验收必须有隔离故障注入和独立复核证据。

## 现状基线与已知缺口

### 已观察事实

- 当前日志代理给 stdout/stderr 逐行写入本地时间戳，子进程退出码会传递给 launchd，正常信号路径会向 SSH 进程组转发信号。
- launchd 当前直接管理日志代理，因此状态查询返回的受管 PID 是代理 PID，不再是 `/usr/bin/ssh` PID。
- 现有代理的日志写入循环在 `write_log_line(...)` 出错时会提前返回；该路径必须先终止并等待 SSH，再允许代理退出，否则 launchd 的 KeepAlive 重试可能与旧 SSH 重叠。
- 当前 plist 中代理路径来自运行时 App Bundle 的绝对路径。Bundle 移动、替换或资源缺失时，自动恢复必须先识别为本地前置失败，不能盲目 bootstrap。
- 现有 Rust `stop_managed_cancellable` 按可执行文件核验受管身份；代理接管后需要明确“launchd PID 是代理、代理子进程是 SSH”的身份契约，避免停止 fallback 误判或绕过核验。
- 2026-09-19 真实断线后，本地 SSH 已退出但 ECS 仍由旧 `sshd` 持有 `127.0.0.1:18080`；服务端未启用 SSH 层 client-alive，默认 TCP keepalive 可能使监听保留数小时。用户决定保持 `18080`，并明确要求为 `motorcycle` 开启排他端口强杀：任何监听该端口的进程均结束，不检查 IP 或归属。

### 现有契约复用

- Rust Core 继续作为配置、launchd 生命周期、进程信号和代次校验的唯一 owner。
- 复用现有 60 秒操作预算、bootout-first、`notLoaded`/收敛门禁、健康恢复退避、generation 取消和资源锁；本计划只补齐代理层进程树及其与 launchd 的交接。日志追加/保留和写放大约束沿用[日志低写放大与流式保留](tunnelpad-log-write-amplification.md)。
- ECS 前置检查、日志保留/写放大、HTTP API 与 `18080` 映射不变；新增顺序为“本地收敛 → `/32` 同步 → 远端专用监听清理 → 启动”。

## 不变量

- 任何发送给进程的信号，都必须由当前 label 的 fresh 状态、PID、UID、可执行文件和/或受管进程组身份共同证明；证明失败只返回 fail-closed。
- 代理退出前必须完成：停止读管道、向受管子进程请求退出、限时等待、必要时升级到 SIGKILL、`wait` 回收；任何错误路径都不能跳过该闭环。
- 同一 label 在旧作业未确证 `notLoaded` 且受管进程未收敛前，禁止写新 plist/bootstrap。
- 对 `autoStart + keepAlive` 的无人值守 SSH，launchd plist 必须禁用 `KeepAlive`；断线后的重新调度只由 TunnelManager 的“收敛旧实例 → ECS 前置 → 启动”单一恢复链负责，禁止形成第二个 SSH 启动 owner。
- 代理、SSH 及其必要孙进程的归属边界必须可测试；不对未知进程做全局清理。
- 远端强杀只在本地 launchd 已确认 `notLoaded`、共享 `/32` 同步成功且该隧道显式开启配置后执行；只按当轮解析出的远端端口枚举监听者，使用 pidfd 发 SIGKILL，并确认端口为空。权限、pidfd、清理或确认失败均 fail-closed。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 现状、身份契约、故障样本和回滚边界收敛 | 用户明确需求；已有无人值守计划已完成 | 静态调用图、隔离最小复现、独立设计复核 | 设计中 |
| 阶段 1 | 实现代理进程树回收、launchd 身份对齐和恢复去重 | 阶段 0 独立准入；用户实现授权已给出 | Rust/Swift 回归、故障注入、隔离 launchd 生命周期 | 实施中 |
| 阶段 2 | Release 包与真实 TunnelPad 受控验收 | 阶段 1 完成；真实操作停止条件明确 | 真实异常恢复、无孤儿 SSH、端口释放、用户验收 | 待实施 |

## 当前阶段

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| 复核策略 | 风险分流 |
| 风险级别 | 高影响：共享生命周期、进程信号、无人值守恢复 |
| Step 0 | [阶段 0 Step 0](#step-0-证据)及[远端转发清理增量 Step 0](../data-quality/tunnelpad-unattended-remote-forward-cleanup-step0-20260919.md) |
| 样本矩阵 | O1–O7 本地/隔离故障 fixture；O8 当前 `motorcycle-local-docker` 真实验收；R1–R15 远端排他端口强杀 |
| 验证方式 | Rust/Swift 全量回归、代理故障注入、隔离 launchd 生命周期、Release 构建和 `detect_changes()`；阶段 2 再做真实隧道验收 |
| 失败/回滚边界 | 身份、进程组归属、资源路径或清理结果无法证明时 fail-closed；未确认收敛前不 bootstrap；回滚只恢复同版 App/辅助程序/plist，不触碰配置、ECS 或非目标隧道 |
| 最新阶段复核 | [最新阶段复核](#最新阶段复核)：实施者已按唯一独立设计复核的 5 项 P1 完成修复自验；历史 `NOT READY` 保留，不重复独立复核 |
| 当前阻塞项 | 无 |
| 下一动作 | 等待用户按阶段 2 场景触发真实断线或 `/32` 漂移，验证 `18080` 旧监听被强杀、新 SSH 自动接管且无需人工干预 |

### 样本矩阵

| 样本 | 故障注入/操作 | 必须满足 | 失败判定 |
|---|---|---|---|
| O1 | 正常 SSH 退出并由 TunnelManager 立即进入恢复链 | 先收敛旧代理/SSH，再执行 ECS 前置并按有界退避重连；每次只有一个代理/SSH，没有旧 PID | launchd `KeepAlive` 绕过前置自行重拉、新旧 SSH 重叠或端口被旧实例占用 |
| O2 | 单行日志写入失败/日志目录不可写 | 代理记录失败原因；先清理受管子进程，再退出；后续可恢复 | 代理已退出但 SSH 仍存活 |
| O3 | 代理收到 TERM/INT/HUP/QUIT | 信号转发、限时等待、必要时升级并回收；launchd 可再次加载 | 未回收、晚写日志或下次启动冲突 |
| O4 | SSH 忽略 TERM、SIGSTOP 或持有输出管道的孙进程 | 只对当前受管身份/进程组处理；在总预算内结束 | 无限等待、杀到未知进程或遗留端口监听 |
| O5 | 代理被 SIGKILL、App 退出、launchd bootout | 再次查询为 `notLoaded` 或已确证收敛；不重复 bootstrap | 新代理启动时旧 SSH 仍活跃 |
| O6 | stale PID、同 label 外部替换、状态查询超时 | 身份不确定时 fail-closed，不发危险信号；保持可诊断 | 仅凭 PID/端口/日志清理其他进程 |
| O7 | Bundle 移动、代理资源缺失或版本不匹配 | 标记 local prerequisite，暂停启动；资源恢复后重新验证并恢复 | 自动循环报错、启动不存在的路径或永久卡死 |
| O8 | 当前 `motorcycle-local-docker` 受控重启/异常恢复（阶段 2） | 日志有逐行时间；运行状态 fresh；18080 转发恢复；同一时刻最多一条 SSH | 只看 HTTP 200 但 SSH/端口仍有孤儿，或需要人工点击 |
| R1–R15 | 配置开关、任意类型/UID/IP 的目标端口监听、多 PID、pidfd 竞态、取消、共享同步与 SSH 参数边界 | 关闭时零远端动作；开启时在本地收敛和 `/32` 同步后强杀目标端口全部监听者并确认释放 | 默认扩大权限、普通 PID kill、漏杀、并行清理、绕过前置启动或失败后停止重试；详见增量 Step 0 |

## Step 0 证据

阶段 0 Step 0 已登记本计划的现状事实、影响边界、O1–O8 故障样本、清理不变量和回滚停止条件。实现前还需将隔离命令、进程组观测字段和错误注入点固化为可复现证据，并完成独立设计复核；本节不把设计登记误认为实现通过。

当前阶段只执行 O1–O7 的本地/隔离基线，不启动、停止或故障注入真实 TunnelPad 隧道；O8 延后阶段 2，并需要单独的真实操作授权和停止条件。

### 可执行验证入口

以下命令和观测字段是阶段 1 实现门禁的固定入口；阶段 0 先记录现状输出，阶段 1 再把对应入口变成通过/失败的自动 fixture：

| 样本 | 可执行入口 | 必须记录的字段 |
|---|---|---|
| O1 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy prefixes_stdout_and_stderr_lines_with_local_timestamps`；隔离 launchd 作业的 `launchctl print` | label、state、active count、代理 PID、SSH PID、代理/SSH PGID、重试间隔 |
| O2 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy log_write_failure_cleans_child`（阶段 1 新增） | 注入点、代理退出码、SSH/孙进程 PID/PGID、`wait` 结果、日志最后写入时间 |
| O3 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy forwards_and_escalates_signals`（阶段 1 新增） | 信号顺序、每次等待耗时、kill 返回值、最终 child status |
| O4 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy closes_descendant_pipe_and_reaps_group`（阶段 1 新增） | 父子关系、PGID、管道持有者、清理 deadline、剩余进程 |
| O5 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy launchd_kill_does_not_leave_child`（阶段 1 新增）及隔离 launchd bootout | proxy/SSH 的 PID、PGID、bootout 后状态、端口/监听句柄、孤儿扫描 |
| O6 | `cargo test --manifest-path rust/Cargo.toml launchctl::tests::managed_stop_refuses_signal_when_launchd_pid_changes` 及新增身份票据 fixture | fresh status、PID、UID、启动时间、可执行路径、PGID、发出的信号列表 |
| O7 | `cargo test --manifest-path rust/Cargo.toml --test log_proxy missing_proxy_is_local_prerequisite`（阶段 1 新增）及 App 资源移动隔离样本 | plist 代理路径、文件存在/可执行性、错误分类、是否发生 bootstrap、恢复后的重写路径 |

### 验证方式（阶段 0/1）

- 对现有 Rust owner、launchd executor、代理和打包路径做源码/调用链核对；所有影响结论以源码证据和 GitNexus 结果交叉确认。
- 为 O1–O7 建立不依赖真实 ECS 的本地隔离样本，记录代理 PID、SSH PID/进程组、label 状态、端口释放和日志最后写入时间；测试输出脱敏。
- O8 仅做受控当前隧道观察，不以一次 HTTP 成功替代 SSH 进程树收敛；真实异常注入需在阶段 2 明确授权和停止条件后执行。
- O8 在阶段 0 不执行；阶段 2 才观察当前 `motorcycle-local-docker`，并同时核对 launchd 状态、代理/SSH 进程树、18080 监听和日志时间序列。
- 阶段 0 使用 `plan-governance-cli check .`；进入阶段 1 前必须由独立复核确认 `--strict-readiness`、风险边界和实现前置完整；阶段 1 收尾继续执行严格检查。

### 设计决策待收敛

1. 进程树所有权：确认 launchd 是否负责代理及其子进程组的最终清理；代理自身必须覆盖 I/O 错误、取消、信号和 wait 失败路径。
2. 身份契约：将 launchd 受管身份定义为代理可执行文件，并为代理子 SSH 保存受管 PID/进程组票据；停止操作不能继续把 `/usr/bin/ssh` 当作 launchd 顶层 PID。
3. 辅助程序部署：选择稳定的同版资源路径或显式 fail-closed 的安装前置；禁止 plist 永久引用已不存在的旧 Bundle。
4. 端口与清理：新增默认关闭的 `forceRemotePortCleanup`。用户对 `motorcycle` 明确授权端口单因子强杀；开启时不检查 IP/UID/进程类型/会话归属，必须用 pidfd 强杀该端口全部监听 PID并确认释放；关闭时零远端动作。

### 失败与回滚边界

- 状态查询超时、身份票据不一致、进程组无法证明归属或代理资源缺失时，停止新增 bootstrap，保留脱敏错误并等待下一次受限恢复；不杀未知 SSH。
- 任何一次清理未确认完成，均不得释放该 Tunnel 的启动资格，不得并行重试。
- 回滚前必须先停止自动恢复、bootout 当前 label，并确认代理、SSH、受管孙进程、端口监听和在途 launchd 操作均已收敛；若无法确认，保留 fail-closed 状态并请求人工处理。
- 回滚只恢复同一版本的 App/辅助程序和 plist 形状，不回滚用户配置，不清理非 TunnelPad 资源。

## 阶段 1 实施边界

预计涉及：

- `rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs`：统一正常、信号、I/O 错误、读管道错误和 wait 错误的子进程清理；补充测试注入点。
- `rust/tunnelpad-core/src/plist_render.rs`、`rust/tunnelpad-core/src/owner.rs`、`rust/tunnelpad-core/src/launchctl.rs`：对齐 launchd 顶层代理身份与受管 SSH 子进程的停止/重启契约，保持 bootout-first 和 fail-closed。
- `Sources/TunnelPadCore/LaunchdPlistRenderer.swift`、打包脚本及必要的安装资源定位：仅在阶段 0 证明需要时修改，不能绕过 Rust owner。
- `rust/tunnelpad-core/tests/`、`Tests/TunnelPadCoreTests/`：覆盖 O1–O7 适用分支，并为阶段 2 的 O8 保留隔离 launchd 进程树检查入口。
- Swift/Rust `TunnelConfig` 与设置表单：增加默认关闭且带风险说明的 `forceRemotePortCleanup`，保持 JSON parity。
- `Sources/TunnelPadCore/ECSPreStart.swift`、`TunnelManager.swift`、`SSHCommand.swift`、`scripts/`、`scripts/build_app.sh` 及对应测试：共享 `/32` 同步后执行逐隧道 pidfd 端口强杀；不改变普通手动前置。

所有既有函数、方法或结构体的编辑前必须先执行 GitNexus upstream impact；若结果为 HIGH/CRITICAL，先向用户报告 blast radius 并暂停实现，直至风险边界收敛。

## 验证与完成条件

- 阶段 0：Step 0、O1–O7、身份/所有权/超时/回滚契约写实；唯一独立复核结论及用户追加权限已登记；其发现必须由实现后的修复自验闭环。
- 阶段 1：Rust/Swift 全量测试、代理故障注入、隔离 launchd 生命周期、`git diff --check`、构建与打包通过；`detect_changes()` 只显示预期符号和流程。
- 阶段 2：受控 Release App 验证异常恢复、端口释放、无孤儿 SSH、非目标进程隔离及长时间无人值守；用户接受后才关闭计划。
- 技术测试通过不等于真实无人值守验收通过；在用户验收前计划保持“实施中”，下一动作记录为等待验收。

## 最近记录

| 日期 | 类型 | 记录 | 状态 |
|---|---|---|---|
| 2026-09-15 | 需求 | 用户要求无人值守异常自动恢复并清理孤儿 SSH | 已登记 |
| 2026-09-15 | 基线 | 发现日志代理 I/O 错误路径未显式回收子 SSH；launchd 顶层 PID 已由 SSH 变为代理；Bundle 路径需验证稳定性 | 待独立复核 |
| 2026-09-15 | 隔离复现 | 使用临时非 TunnelPad 作业对当前 Release 代理发送 SIGKILL：代理 PGID 与 SSH PGID 不同，代理退出后 SSH 仍存活并被 1 号进程接管；已立即按 PID 清理测试进程 | 已确认 O5 缺口 |
| 2026-09-15 | 独立复核 | 首轮未准入；补齐 O2–O7 可执行入口、隔离输出和 O8 阶段边界 | 已闭合 |
| 2026-09-16 | 独立复核 | 修订后的 Step 0、O1–O7 基线和 O8 后移边界通过；阶段 1 准入，实施必须守住进程树回收、身份 fail-closed、资源缺失不回退三条边界 | 通过 |
| 2026-09-16 | 阶段 1 实施 | 日志代理统一清理 I/O/reader/信号路径；SSH 继承 launchd 作业组；加入代理/子 SSH 身份与 PGID 核验、稳定辅助程序路径和资源缺失 fail-closed；Rust 85 项、代理隔离 4 项、Swift 176 项通过，Release 构建通过；新包已平滑接管运行态 | [阶段 1 实施证据](../data-quality/tunnelpad-unattended-ssh-recovery-stage1-implementation-20260916.md)；实施中，待隔离 launchd 与真实验收 |
| 2026-09-19 | 既有评审整改 | 修复可信 launchd 身份、持续输出子进程检测、有界停止、唯一原子临时文件、全量进程组重枚举、配置更新前旧身份停止及退出清理重试；Swift 190、Rust 108、日志代理 7 项及隔离 Release 打包通过 | [阶段 1 评审整改证据](../data-quality/tunnelpad-unattended-stage1-review-remediation-20260919.md)；代码整改自验通过，最新独立“不通过”不被覆盖，阶段 2 未进入 |
| 2026-09-19 | 合并独立复核与整改 | 首轮发现配置事务缺少全局线性化、清理中重复退出可绕过门禁，并指出登录项错误证据不准确；已增加完整配置事务锁、重复退出状态门和失败注入测试 | [合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)；本地门禁通过，待同一复核者增量复验 |
| 2026-09-19 | 补充只读核对 | 原复核者确认配置事务、重复退出和登录项错误三项发现均已闭合，未发现新增 P0/P1；该结果不作为第二次独立门禁 | [合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)“补充只读核对（非新增独立门禁）” |
| 2026-09-19 | 修复自验 | 实施者按首轮独立发现完成配置事务、重复退出和登录项错误的“发现 → 修复 → 验证”闭环 | [阶段 1 整改证据](../data-quality/tunnelpad-unattended-stage1-review-remediation-20260919.md)；阶段 1 合并代码门禁通过，阶段 2 未进入 |
| 2026-09-19 | 运行期退避修复 | 真实端口冲突暴露短暂 `running` 结束恢复任务、监控随后重复按首次故障调度的问题；统一为 `0/5/10/30/60/60…` 秒，并要求连续两次健康采样才清零 | [运行期退避修复证据](../data-quality/tunnelpad-unattended-runtime-backoff-remediation-20260919.md)；本地自验通过，当前 App 尚未替换，待阶段 2 真实复验 |
| 2026-09-19 | 新版部署与启动 | 提交 `8502ecd` 的新包原位替换并启动；旧 App 优雅退出后代理、SSH、launchd label 均收敛，未保留备份；新版 App/代理/SSH 单实例稳定超过 1 分钟，远端 `18080` 单 listener | [运行期退避修复证据](../data-quality/tunnelpad-unattended-runtime-backoff-remediation-20260919.md)“新版部署与启动”；阶段 2 连续故障完整退避复验仍待执行 |
| 2026-09-19 | 远端孤儿反例与方案变更 | 真实断线后旧 ECS `sshd` 长期占用 `18080`；用户决定保持端口并采用严格身份核验后的精确进程清理。GitNexus 将共享前置标为 CRITICAL，实施前冻结范围并安排一次独立设计复核 | [远端转发清理增量 Step 0](../data-quality/tunnelpad-unattended-remote-forward-cleanup-step0-20260919.md)；待设计复核 |
| 2026-09-19 | 远端清理独立设计复核 | 唯一 `medium` 独立复核结论 `NOT READY`：共享结果复用、归属不足、PID 复用、取消后延迟动作和 SSH 参数边界共 5 项 P1 | [独立设计复核](../reviews/tunnelpad-unattended-remote-forward-cleanup-independent-review-20260919.md)；待修复自验，不重复独立复核 |
| 2026-09-19 | 用户追加强杀权限 | 新增默认关闭的 `forceRemotePortCleanup`；`motorcycle` 的 `18080` 为排他端口，开启后任何监听进程均 pidfd SIGKILL，不检查 IP/UID/类型/归属 | [远端转发清理增量 Step 0](../data-quality/tunnelpad-unattended-remote-forward-cleanup-step0-20260919.md)；待实现与自验 |
| 2026-09-19 | 远端清理修复自验与部署 | 完成共享 `/32`/逐隧道清理拆分、pidfd 强杀、远端单动作、SSH 允许列表和默认关闭配置；Swift 205、Rust 111、ECS 18、监督 9、helper 2 项及真实 ECS 隔离端口通过，Release 已启动且 `motorcycle` 单独开启 | [远端清理修复自验](../data-quality/tunnelpad-unattended-remote-forward-cleanup-remediation-20260919.md)；阶段 1 代码阻塞解除，等待阶段 2 用户验收 |

## 阶段复核记录

| 日期 | 类型 | 阶段 | 方式 | 风险 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|---|---|
| 2026-09-16 | 准入复核 | 阶段 1 | 独立 | 高影响 | 通过：阶段 1 准入边界通过，进入实现 | [阶段 0 Step 0](../data-quality/tunnelpad-unattended-ssh-recovery-stage0-step0-20260915.md)；独立复核确认进程树回收、身份 fail-closed、资源缺失不回退 | 独立只读复核轮次 |
| 2026-09-19 | 实现风险复核 | 阶段 1 | 独立 | 高影响 | 不通过：P1 身份授权放宽、持续输出掩盖子命令退出；停止/安装/诊断 P2 待修复；保持阶段 1 实施中 | [端到端风险复核](../reviews/tunnelpad-unattended-end-to-end-review-20260919.md)，尤其 R3/R7–R10/R13 与测试证据限制；本轮未重新构建、未启停真实 App/隧道 | Banach（独立生命周期审核）；Codex 综合核对 |
| 2026-09-19 | 合并实现复核 | 阶段 1 | 独立 | 高影响 | 不通过：配置事务线性化、清理中重复退出为 P1；登录项失败证据为 P2。整改已完成自验，但在同一复核者增量结论写回前不解除阶段 1 门禁 | [合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)首轮结论与[阶段 1 整改证据](../data-quality/tunnelpad-unattended-stage1-review-remediation-20260919.md) | Kierkegaard（独立只读复核） |
| 2026-09-19 | 修复自验 | 阶段 1 | 自验 | 高影响 | 通过：已按合并独立复核的配置事务、重复退出和登录项错误发现完成“发现 → 修复 → 验证”闭环；阶段 1 合并代码门禁解除。计划保持实施中，阶段 2 真实无人值守验收未进入。 | [合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)首轮发现；[阶段 1 整改证据](../data-quality/tunnelpad-unattended-stage1-review-remediation-20260919.md)；Swift 196、Rust 111、ECS 18、监督 9、Release/隔离包与 GitNexus/diff 门禁；后续只读核对仅作补充证据 | Codex（实施者） |
| 2026-09-19 | 增量修复自验 | 阶段 1 | 自验 | 高影响 | 通过：现场快速重试反例已修复为 `0/5/10/30/60/60…` 秒统一退避，连续两次健康采样后才清零；本次属于既有独立复核范围内的增量修复，按风险分流由实施者自验，不重复发起独立复核。计划保持实施中，阶段 2 新 build 真实无人值守验收未完成。 | [运行期退避修复证据](../data-quality/tunnelpad-unattended-runtime-backoff-remediation-20260919.md)；Swift 全量 197、Rust 111、ECS 18、监督 9 项和 Release 编译通过；既有[合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)范围保持有效 | Codex（实施者） |
| 2026-09-19 | 远端清理设计复核 | 阶段 1 | 独立 | 高影响 | 未通过：无 P0；共享结果、归属、PID 复用、远端延迟动作及 SSH 参数边界 5 项 P1。用户随后追加默认关闭的排他端口强杀权限；其余发现和配置隔离仍待实现后修复自验。 | [独立设计复核](../reviews/tunnelpad-unattended-remote-forward-cleanup-independent-review-20260919.md)；[修订 Step 0](../data-quality/tunnelpad-unattended-remote-forward-cleanup-step0-20260919.md) | Hume（独立只读复核） |
| 2026-09-19 | 修复自验 | 阶段 1 | 自验 | 高影响 | 通过：唯一独立设计复核的共享结果、显式授权、PID 复用、远端延迟动作和 SSH 参数边界 5 项 P1 均已完成“发现 → 修复 → 验证”；不重复独立复核。阶段 1 代码阻塞解除，计划保持实施中等待阶段 2 长时与用户验收。 | [远端清理修复自验](../data-quality/tunnelpad-unattended-remote-forward-cleanup-remediation-20260919.md)；Swift 205、Rust 111、ECS 18、监督 9、helper 2 项、真实 ECS `48080` 隔离强杀、Release 构建与当前 App 启动观察 | Codex（实施者） |

### 最新阶段复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-19 |
| 阶段 | 阶段 1 |
| 方式 | 自验 |
| 风险 | 高影响 |
| 风险依据 | 新增远端进程 SIGKILL 权限、共享 ECS 前置拆分、配置 schema 与 SSH 参数解析；GitNexus 对共享前置为 CRITICAL |
| 结论 | 通过：唯一独立设计复核的共享结果、显式授权、PID 复用、远端延迟动作和 SSH 参数边界 5 项 P1 均已完成“发现 → 修复 → 验证”；不重复独立复核。阶段 1 代码阻塞解除，计划保持实施中等待阶段 2 长时与用户验收。 |
| 证据 | [远端清理修复自验](../data-quality/tunnelpad-unattended-remote-forward-cleanup-remediation-20260919.md)；Swift 205、Rust 111、ECS 18、监督 9、helper 2 项、真实 ECS `48080` 隔离强杀、Release 构建与当前 App 启动观察 |
| 复核者 | Codex（实施者） |
