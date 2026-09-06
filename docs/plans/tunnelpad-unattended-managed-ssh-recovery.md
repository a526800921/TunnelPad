# 计划：TunnelPad 无人值守受管 SSH 收敛恢复

> 规范适用（2026-09-06）：本计划保留完成时的阶段、验收条件与独立复核历史；后续变更遵循[新版规范与历史兼容](../PLAN_MAP.md#规范适用与历史兼容)。状态、当前阶段和最后更新以[计划索引](../PLAN_MAP.md#计划索引)为准。

- 前置：[TunnelPad 隧道稳定性与健康恢复](tunnelpad-stability.md)、[TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md) 已完成；此前阶段 2 的[真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md)仅作为本计划的背景证据，不构成前置依赖。共享 Rust 生命周期文件必须串行编辑。

## 需求探索

用户已确认目标：健康恢复不依赖人工释放冻结 PID、人工点启停或人工重启 App。已确认边界：自动信号处置只针对可证明属于当前 TunnelPad 受管隧道的 SSH 进程；不能为追求可用性而按进程名、端口或 PID 单独匹配并终止未知进程。

本计划采用“受管身份核验后的渐进式自动处置”而非单纯延长等待：`launchctl bootout` 后先等待正常收敛，超时且身份仍一致时依次 `SIGCONT`、`SIGTERM`、`SIGKILL`；仅在旧进程和 label 均收敛后才继续既有 ECS 前置与启动。原有“最多 10 次后永久停止”的熔断改为带频率上限的自动冷却重试，避免需要人工重新开启。

## 背景

当前健康恢复已经在 stop 后等待 `notLoaded`、start 后等待 `running`，可正确容纳短暂的 `SIGTERMed`、`xpcproxy` 等 launchd 过渡态。真实故障注入还发现：若受管 SSH 被 `SIGSTOP` 冻结，进程无法处理 bootout 触发的终止信号；若测试窗口不人工恢复该 PID，旧进程退出确认可能长期不收敛。

这不是能耗优化本身的问题，而是 Rust Core 对受管 launchd 服务的停机收敛能力缺口。现有能耗计划保持其阶段 2 证据与完成条件；本专项计划拥有新的进程信号、身份、自动冷却和真实无人值守验收事实。

## 目标

- 对健康监测触发的受管 SSH 假死，完成从探针失败到新进程健康的全自动闭环，不要求人工释放旧 PID。
- 在一个可验证的隧道恢复 generation 内，保证旧进程完全退出后才执行既有 ECS 前置检查和启动。
- 保留持续自动恢复能力：10 次快速失败后不永久熔断为人工操作，而是进入受限频率的自动冷却重试；成功探针重置计数。
- 保持 Rust Core 为唯一生命周期和进程信号 owner；Swift 继续只编排现有 stop → ECS → start 顺序。

## 非目标

- 不按 `ssh` 进程名、监听端口或孤立 PID 执行广泛终止；不处理非 TunnelPad 所有的进程。
- 不修改 `config.json` Schema、C ABI、HTTP API、UI 设置、SSH 参数、launchd label 或远端/ECS 资源契约。
- 不改变健康探针协议、10 秒监测周期、连续 3 次失败触发条件、手动操作取消语义或 ECS fail-closed 边界。
- 不承诺在 macOS 拒绝信号、系统级权限限制或外部进程占用端口时强行夺取资源；这些状态保持自动隔离与退避重试，不越权终止未知进程。

## 不变量

- 每次升级信号前都必须核验同一 `tunnelID`、恢复 generation、launchd label、PID、UID、进程启动时间、可执行文件路径及其 launchd 归属；任一项不匹配或读取失败即禁止发信号。完整 argv 不作为运行时必需条件，因为当前 macOS `libproc` 查询不提供它。
- `SIGCONT` 只用于已确认仍是原受管进程且 bootout 未收敛的情形；`SIGTERM`、`SIGKILL` 都必须重新核验身份。
- 未确认 `notLoaded`、旧 PID 消失和本地资源释放前，不执行 ECS 前置、不调用 start、不宣告恢复成功。
- 现有手动 stop/restart、删除、配置重载、退出和 generation 失效必须取消正在进行的自动处置；取消后不得再发任何信号或启动。
- 自动冷却只限制频率，不把隧道置为要求人工介入的永久状态；成功探针或手动成功操作可重置窗口。
- 所有用于恢复决策的 `launchctl print` 查询必须有界；查询超时视为状态未知并 fail-closed，不能把超时降级为 `notLoaded`，也不能阻塞健康循环。自动启动成功后必须先取得一次稳定的 `running + PID` 状态，才能把该 PID 作为后续超时恢复的受管身份缓存。
- 运行日志只记录隧道 ID、处置阶段、信号类别和结果；不得记录完整 SSH 参数、私钥、地址或命令行。

## 影响模块或文件

- rust/tunnelpad-core/src/launchctl.rs: 新增受管 PID 身份读取、信号执行和有界收敛状态机；GitNexus 对 LaunchCtlExecutor 的 upstream 分析为 CRITICAL，已知 22 个受影响符号、3 条流程。
- rust/tunnelpad-core/src/launchd_executing.rs: 增加可注入的受管 stop 能力，保留旧 fake 的默认行为。
- rust/tunnelpad-core/src/owner.rs: 只在 SSH 隧道的 Rust stop 路径接入受管收敛；不得把此行为复制到 Swift owner。
- rust/tunnelpad-core/src/owner_ffi.rs: 只验证既有 stop/start 结果、错误清理与 C ABI 行为保持兼容；本计划不新增 ABI。
- Sources/TunnelPadCore/HealthRecovery.swift: 将第 10 次失败后的人工熔断改为内存自动冷却，保留 generation/取消/手动操作边界。
- Sources/TunnelPadCore/TunnelManager.swift: 接入自动冷却结果，保留 generation/取消/手动操作边界。
- Tests/TunnelPadCoreTests/StabilityStage1Tests.swift: 覆盖受管收敛、取消、冷却时钟和多隧道隔离，不调用真实外部资源。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage0-step0-20260904.md: 记录阶段 0 基线和边界。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage0-independent-review-20260904.md: 记录阶段 0 独立准入复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md: 记录阶段 1 Step 0。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-review-20260904.md: 记录阶段 1 独立准入复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-implementation-20260904.md: 记录阶段 1 实施与验证证据。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-completion-review-20260904.md: 记录阶段 1 独立完成复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-step0-20260904.md: 记录阶段 2 Step 0、Release/FFI 矩阵和隔离边界。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-review-20260904.md: 记录阶段 2 独立准入复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-implementation-20260904.md: 记录阶段 2 Release/FFI/隔离 App 实施证据。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md: 记录阶段 2 独立完成复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md: 记录阶段 3 真实环境 Step 0、身份核验和回滚矩阵。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-review-20260904.md: 记录阶段 3 独立准入复核。
- docs/data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-failure-20260904.md: 记录阶段 3 首次真实验收的超时失败与回滚。

## 公共契约变化

不新增配置、API 或 ABI 字段。用户可观察的变化仅为：原本在快速失败上限后停止自动恢复的受管隧道，改为进入自动冷却重试；当前恢复消息可使用既有状态/日志表达“自动收敛中”或“自动冷却重试中”。具体内部状态类型不得通过 C ABI、HTTP API 或配置文件泄漏。

## 收敛状态机

```text
连续 3 次 HTTP 探针失败
  → 在有界超时内读取目标最新状态并锁定 recovery generation
  → Rust Core 捕获受管进程身份
  → launchctl bootout
  → 等待 notLoaded（最多 3 秒）
  → 身份仍一致且未收敛：SIGCONT，等待 1 秒
  → 身份仍一致且未收敛：SIGTERM，等待 2 秒
  → 身份仍一致且未收敛：SIGKILL，等待 1 秒
  → 重新确认 label=notLoaded、原 PID 消失、资源已释放
  → 既有 ECS preflight（fail-closed）
  → 既有 start，等待 running，再由 HTTP 探针确认
```

上述时间已由阶段 1 的隔离 fixture 固定为实现初值；`launchctl print` 单次查询还必须在 2 秒内返回，仍必须在阶段 2 的 Release 兼容性验证和阶段 3 的真实受控验收中验证，不能仅以 sleep 成功代替状态确认。自动启动后的短暂 `notLoaded/other` 只能在有界窗口内重读，未取得稳定 `running + PID` 前不得宣告启动成功。任何身份不一致、取消、查询超时或命令错误均不得进入 ECS/start；进入自动冷却重试。快速尝试达到既有 10 次窗口上限后，初始冷却为 30 分钟，后续每次只允许一个新的恢复 generation；成功探针重置窗口。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定身份核验、信号升级、自动冷却和失败边界 | 已确认无人值守目标与 Rust owner 约束 | 现状快照、脚本化 fixture 矩阵、CRITICAL 影响分析、独立准入复核 | 已完成 |
| 阶段 1 | 在 Rust Core 实现受管进程收敛器，并让 Swift 自动冷却替代人工熔断 | 阶段 0 自己的 Step 0 与独立准入通过；阶段 1 自己的 Step 0 与独立准入通过 | Rust 单元/差分、Swift 顺序反证、取消与 PID 复用、冷却时钟测试 | 已完成 |
| 阶段 2 | 验证自动冷却、FFI 恢复顺序和 Release 产物 | 阶段 1 完成且阶段 2 自己的 Step 0 与独立准入通过 | 全量回归、签名 Release App、无真实远端写入的隔离验证 | 已完成 |
| 阶段 3 | 在用户授权的真实活动隧道上验收无人值守恢复 | 阶段 2 完成且真实环境边界与回滚已复核 | 仅注入已核验 PID 的 `SIGSTOP`；不人工释放；自动恢复到 HTTP 探针成功 | 已完成 |

## 当前阶段

### 范围

阶段 1 的 Rust/Swift 隔离实现、阶段 2 的 Release/FFI/隔离 App 验证和阶段 3 的真实受控无人值守验收均已通过独立完成复核；本专项计划已关闭。真实信号只针对执行前重新核验的 `admin-tunnel` PID，成功观察窗口不人工释放或启停；`reverse-ssh`、未知进程和远端规则扩大均不在范围内。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | [阶段 3 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md)已建立。 |
| 样本矩阵 | [阶段 3 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md)；覆盖实时 Release App、目标/非目标身份、ECS 只读前置、`SIGSTOP`、无人工观察、恢复、清理和治理。 |
| 验证方式 | 执行前实时身份核验；用户授权的单次 `SIGSTOP`；只读轮询目标 label/PID/HTTP 探针；Rust/Swift/差分回归、GitNexus `detect_changes()` 和严格治理检查。 |
| 失败/回滚边界 | 身份未知/变化、状态异常、取消、ECS 前置失败或超时均 fail-closed；仅恢复目标隧道，不处理 `reverse-ssh`，不删除配置/凭证/远端规则。 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | [阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)已通过；阶段 3 已完成。历史准入记录仍保留在下方。 |

阻塞说明：历史失败原因已修复，阶段 3 真实无人值守闭环和独立完成复核均已通过。

### 实施步骤

1. 阶段 2 Release/FFI/隔离 App 验证及独立完成复核已完成。
2. 已建立阶段 3 Step 0，并完成真实环境独立准入复核。
3. 已执行一次目标 PID 实时核验后的 `SIGSTOP` 无人工释放验收，并记录自动恢复和非目标隔离。
4. 已完成阶段 3 独立完成复核，并同步关闭本计划及能耗计划的剩余边界。

### Step 0 证据

阶段 3 Step 0 已建立，基线为真实 Release App、真实受管 launchd 隧道、HTTP `401` 探针、ECS `--check` 和执行前 PID 身份核验；阶段 3 独立准入复核已通过，授权范围仅为一次目标 PID `SIGSTOP` 无人工释放验收。历史失败尝试暴露了无界状态查询、启动后状态缓存时序和 `proc_pidpath` 长度读取三个问题，均已修复并由最终真实验收覆盖。

### 样本矩阵

阶段 3 样本矩阵见[阶段 3 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md)；阶段 1/2 历史实施证据见对应阶段文档。

### 阶段证据

阶段 2 实施与完成证据见[阶段 2 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-implementation-20260904.md)和[阶段 2 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md)；阶段 3 首次修复尝试见[失败记录](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-failure-20260904.md)，最终实施和真实验收见[阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)，独立完成结论见[阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)。

### 验证方式

- 阶段 1：已完成 Rust/Swift/差分回归、`git diff --check`、GitNexus `detect_changes()` 和严格治理检查；证据见[阶段 1 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-implementation-20260904.md)。
- 阶段 2：已完成 Release 构建/签名/启动退出、Rust/Swift/差分回归、FFI 兼容性、自动冷却隔离验证、`git diff --check`、GitNexus `detect_changes()` 和严格治理检查。
- 阶段 3：已由程序完成启动后稳定 `running + PID` 确认，并使用真实 Release App 对执行前已核验的受管 PID 做一次不人工释放的无人值守故障注入；目标恢复、非目标隔离、回归、Release 和治理证据均已复核。

### 测试覆盖率

测试通过：阶段 1/2 的实施与验证见对应证据；阶段 3 最终 Rust 为 76 项单元测试、差分 1 项，Swift 为 139/139，Release 构建/签名校验和真实无人值守尾检见[阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)。

### 完成条件

- 阶段 1 实施证据、独立完成复核、Rust/Swift/差分回归、影响检测和治理检查全部通过；阶段 2 Step 0 与独立准入已通过。
- 阶段 2 Release/FFI/隔离 App 验证和独立完成复核已通过；阶段 3 真实无人值守闭环、清理和独立完成复核已通过，未改变配置、ABI、HTTP API 或既有 ECS 规则契约。
- 历史失败原因已关闭：真实状态查询和 `bootout` 均有 2 秒边界；启动后状态在有界窗口内收敛；`proc_pidpath` 有效字节长度读取已修正并有回归测试。

## 阶段 1 实施与完成证据

### 范围

阶段 1 只在 Rust Core 和 Swift 健康恢复内部实现已准入契约；不修改配置、launchd label、ECS 或远端资源，不新增 C ABI。实际系统信号实现必须保留可注入 fake，并在阶段 1 完成前不进行真实进程处置。

### 阶段 1 准入与实施记录

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| Step 0 | [阶段 1 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md)；阶段 0 的身份边界与 CRITICAL impact 已先通过独立准入。 |
| 样本矩阵 | [阶段 1 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md)；10 行矩阵覆盖信号、PID 复用、取消、冷却、FFI 和多隧道隔离。 |
| 验证方式 | Rust 单元/差分、Swift 专项与全量回归、GitNexus 影响复核、治理检查；阶段 3 才允许用户授权的真实 App 验收。 |
| 失败/回滚边界 | 实施失败仅回滚本计划独立提交；不改配置、真实 plist、ECS 规则或凭证。 |
| 当前阻塞项 | 无；阶段 1 已通过独立准入，当前正在实现与隔离验证；阶段 2/3 仍须各自 Step 0 和独立准入。 |
| 最新独立准入复核 | [阶段 1 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-review-20260904.md)已通过，达到待实施标准；仅限阶段 1。 |

### 实施步骤

1. 用可注入 `ProcessIdentityReading`/`ProcessSignaling` 和 launchd 状态脚本实现 Rust 受管收敛器；系统信号只在 macOS 执行器中启用。
2. 在每一级信号前复核 label、PID、UID、启动时间、可执行路径和 launchd 归属；实现 bootout-first、CONT → TERM → KILL、有界等待和取消门禁。
3. 将 Swift 第 10 次失败后的人工停止改为内存 30 分钟冷却；保留成功清零、手动取消、generation 和多隧道隔离。
4. 用 Rust/Swift 专项 fixture、FFI 顺序反证和全量回归验证；不调用真实进程信号、launchd、SSH、ECS 或远端资源。
5. 阶段 1 完成后先做独立完成复核；阶段 2 再验证 Release 产物和兼容性，阶段 3 才进行一次用户授权的真实无人值守故障注入。

### Step 0 证据

基线类型为高风险生命周期行为变更。阶段 1 的最小证据包括：现有 stop/status 的受控脚本化快照、同一 PID 复用的负例、冻结后不人工释放的原子信号序列、取消门禁、FFI stop → ECS → start 顺序反证，以及第 10 次失败后的自动冷却行为。阶段 1 完成前，任何“可自动杀掉卡住 SSH”的说法都只是实现候选，不是生产验收结论。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 正常 bootout | Rust fake runner 的 stop fixture | `notLoaded` 前不调用 ECS/start，且不发升级信号 | 提前启动或多余信号 | 阶段 1 Step 0/实施证据 |
| 2 | 已核验受管 PID 被冻结 | 脚本化 `SIGSTOP → SIGCONT` fixture | 无人工操作后自动继续退出 | fixture 需外部释放或提前启动 | 阶段 1 Step 0/实施证据 |
| 3 | `SIGCONT` 后仍存活 | 脚本化信号历史 fixture | 重新核验后依次 TERM、KILL，且每步有界等待 | 跳级、未核验或无限等待 | 阶段 1 Step 0/实施证据 |
| 4 | PID 已复用/身份字段不一致 | 身份不匹配 fixture | 不发任何信号，不进入 ECS/start，转自动冷却 | 错杀或启动第二条隧道 | 阶段 1 Step 0/实施证据 |
| 5 | 手动 stop、删除、配置重载、退出 | generation/cancel fixture | 取消后不再发信号或启动 | 迟到的自动操作越界 | 阶段 1 Step 0/实施证据 |
| 6 | 10 次快速恢复失败 | 冷却窗口 fixture | 无需人工操作，30 分钟后只创建一个新 generation | 永久熔断或高频重试 | 阶段 1 Step 0/实施证据 |
| 7 | Rust stop 的收敛错误/取消 | Rust FFI 顺序 fixture | stop 未收敛时不向 Swift 宣告成功；既有 ECS/start 不得被错误解锁 | 顺序反转或绕过 fail-closed | 阶段 1 Step 0/实施证据 |
| 8 | 启动短暂 `other` 状态 | start 收敛 fixture | 仅在 `running` 与 HTTP 探针成功后复位恢复窗口 | 过早成功或计数未复位 | 阶段 1 Step 0/实施证据 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-04 | 阶段 0 Step 0 基线 | 核对 Rust `LaunchCtlExecutor`、`LaunchdExecuting`、`CoreOwner.stop`、健康恢复上限和信号入口；Rust 66+1、Swift 139 回归通过；未发送信号或改真实资源 | [阶段 0 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage0-step0-20260904.md) | 已建立；阶段 0 独立准入已通过 | Codex |
| 2026-09-04 | 阶段 0 独立准入复核 | 复核目标、范围、libproc 身份字段、失败语义、8 行矩阵、CRITICAL 影响和回滚边界；冻结“读取失败不发信号”、当前 Core owner 内存冷却和阶段 3 真实验收边界 | [阶段 0 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage0-independent-review-20260904.md) | 通过，达到待实施标准；不代表阶段 1 已准入或已实现 | Codex |
| 2026-09-04 | 阶段 1 Step 0 与独立准入复核 | 登记 Rust 身份/信号抽象、bootout-first 收敛、PID 复用/取消/FFI 反证、Swift 30 分钟内存冷却和 10 行隔离矩阵；Rust 66+1、Swift 139 基线回归通过 | [阶段 1 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-step0-20260904.md)；[阶段 1 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-review-20260904.md) | 通过，进入实施；不代表功能完成或真实环境验收 | Codex |
| 2026-09-04 | 阶段 1 实施与独立完成复核 | Rust 受管身份/有界信号收敛、初始未加载和状态异常 fail-closed、SSH/非 SSH 路由、Swift 30 分钟自动冷却；Rust 72+1、Swift 139、GitNexus 8 文件/79 符号/23 流程 `critical`、治理检查通过 | [阶段 1 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-implementation-20260904.md)；[阶段 1 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-completion-review-20260904.md) | 阶段 1 完成；不代表阶段 2 准入或真实环境验收 | Codex |
| 2026-09-04 | 阶段 2 Step 0 与独立准入复核 | 冻结 Release/FFI/隔离 App 样本矩阵、失败/回滚边界和阶段 3 后置真实信号边界 | [阶段 2 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-step0-20260904.md)；[阶段 2 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-review-20260904.md) | 通过，达到待实施标准；不代表阶段 2 已完成或真实环境已验收 | Codex |
| 2026-09-04 | 阶段 2 实施与独立完成复核 | Release/FFI/隔离 App 验证、包签名/资源、启动退出和全量回归通过；未发送真实进程信号 | [阶段 2 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-implementation-20260904.md)；[阶段 2 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md) | 阶段 2 完成；不代表阶段 3 真实环境已验收 | Codex |
| 2026-09-04 | 阶段 3 Step 0 与独立准入复核 | 固定真实 Release App、目标/非目标隧道、实时身份核验、单次 `SIGSTOP`、无人工观察、恢复和回滚矩阵 | [阶段 3 Step 0](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md)；[阶段 3 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-review-20260904.md) | 通过，达到待实施标准；不代表阶段 3 已完成 | Codex |
| 2026-09-04 | 阶段 3 首次真实验收 | 目标 PID 实时核验通过后注入 `SIGSTOP`；目标 HTTP 变为 `000`，但健康循环卡在无超时 `launchctl print`，90 秒内未进入自动恢复；随后人工 `SIGCONT` 回滚 | [阶段 3 首次验收失败](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-failure-20260904.md) | 未通过；当前阶段阻塞，未计入完成 | Codex |
| 2026-09-04 | 阶段 3 修复与真实验收 | 为状态查询、bootout 和启动后重读加入有界收敛；修正 `proc_pidpath` 有效字节长度读取；Release App 中对目标 PID 单次 `SIGSTOP` 后无人工释放，约 50 秒由 launchd 拉起新 PID `64393`，约 60 秒 HTTP 恢复 `401/satisfied`，非目标 `reverse-ssh` PID `63343` 未变 | [阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md) | 通过；阶段 3 实施完成 | Codex |
| 2026-09-04 | 阶段 3 独立完成复核 | 独立核对身份保护、有界 stop、无人工恢复、探针成功、非目标隔离、ECS 只读边界、Rust/Swift 回归、Release 和治理门禁 | [阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md) | 通过；阶段 3 完成，本计划关闭 | Codex（独立只读复核） |

### 验证方式

- 阶段 0：GitNexus impact、脚本化 runner/状态机设计、身份负例和严格治理检查。
- 阶段 1：Rust 身份/信号专项测试、Swift 冷却/取消/顺序专项测试、`cargo test --manifest-path rust/Cargo.toml`、`swift test`、差分测试、`git diff --check` 和 GitNexus `detect_changes()`。
- 阶段 2：Swift 全量回归、Rust 全量/差分回归、`git diff --check`、Release 构建与签名验证、`plan-governance-cli check . --strict-readiness`。
- 阶段 3：用户授权的真实 Release App；冻结经过身份核验的受管 PID 后不再人工释放，验收自动进入 `notLoaded → ECS → running → HTTP satisfied`，并确认不影响其他隧道或远端规则。

### 测试覆盖率

测试通过：阶段 0/1 的基线、实现和复核见对应证据；阶段 2 的 Release/FFI/隔离 App 证据见对应文档。阶段 3 最终通过 Rust 76+1、Swift 139/139、Release 构建/签名和真实无人值守验收；证据见[阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)和[阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)，真实验收不替代任一隔离反证。

### 完成条件

- 受管身份字段在 macOS 与 fake runner 中均可复核，PID 复用、身份不符、取消和信号失败均不会误伤其他进程；完整 argv 不作为硬依赖。
- `SIGSTOP` 的受管 SSH 在无人工 `SIGCONT`、无人工启停 App 的条件下，能完成有界信号升级、旧进程收敛、ECS preflight、启动、`running` 和 HTTP 探针成功。
- 连续快速失败达到阈值后进入自动冷却，不永久要求人工重试；冷却期间不出现恢复风暴，成功后窗口重置。
- 保持配置、ABI、HTTP API、ECS fail-closed、手动操作取消和多隧道隔离契约；全量 Rust/Swift/差分、Release 与治理检查通过。
- 最新独立准入与完成复核通过，`PLAN_MAP.md` 与关联能耗计划同步。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-04 |
| 阶段 | 阶段 3 |
| 结论 | 通过，阶段 3 完成；本计划关闭 |
| 证据 | [阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)；实施与真实验收见[阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md) |
| 复核者 | Codex（独立只读完成复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-04 | 独立准入复核 | 阶段 0 | 通过，达到待实施标准 | [阶段 0 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage0-independent-review-20260904.md)；不代表阶段 1 已准入或已实现 | Codex（独立只读复核） |
| 2026-09-04 | 独立准入复核 | 阶段 1 | 通过，达到待实施标准 | [阶段 1 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-review-20260904.md)；不代表阶段 1 已完成或真实环境已验收 | Codex（独立只读复核） |
| 2026-09-04 | 独立完成复核 | 阶段 1 | 通过，阶段 1 完成 | [阶段 1 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-completion-review-20260904.md)；不代表阶段 2 已准入或真实环境已验收 | Codex（独立只读复核） |
| 2026-09-04 | 独立准入复核 | 阶段 2 | 通过，达到待实施标准 | [阶段 2 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-review-20260904.md)；不代表阶段 2 已完成或阶段 3 真实环境已验收 | Codex（独立只读复核） |
| 2026-09-04 | 独立完成复核 | 阶段 2 | 通过，阶段 2 完成 | [阶段 2 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md)；不代表阶段 3 已准入或真实环境已验收 | Codex（独立只读复核） |
| 2026-09-04 | 独立准入复核 | 阶段 3 | 通过，达到待实施标准 | [阶段 3 独立准入复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-review-20260904.md)；不代表阶段 3 已完成 | Codex（独立只读复核） |
| 2026-09-04 | 独立完成复核 | 阶段 3 | 通过，阶段 3 完成；本计划关闭 | [阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)；真实实施与验收见[阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md) | Codex（独立只读复核） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| macOS 上如何同时证明 PID 未复用、仍属于目标 launchd 服务且可执行身份一致 | 使用 `proc_pidinfo(PROC_PIDTBSDINFO)` 的启动时间/UID、`proc_pidpath` 的可执行路径，加上目标 launchd label 与受管 plist/配置关系；任一字段读取失败均视为未知并禁止发信号；完整 argv 不作为硬依赖 | 否 | 已冻结；阶段 1 需用 fake 与受控 API 反证 |
| 冷却窗口的计数是否跨 App 重启保存 | 默认仅在当前 Core owner 生命周期内计数；不新增配置 Schema 或持久化；后续若需跨重启保持另立计划 | 否 | 已冻结；阶段 1/2 验证 |
| 未知外部进程长期占用本地端口时如何保持无人值守 | 不杀未知进程；记录隔离原因并自动冷却重试。端口夺取或扩大权限不在本计划范围 | 否 | 已冻结 |
| 冻结受管 SSH 后 `launchctl print` 是否可能无限等待 | 已为真实 runner 的状态查询和 bootout 增加 2 秒有界执行；启动后增加稳定 `running + PID` 重读，并修正 `proc_pidpath` 有效字节读取；真实无人值守验收已通过 | 否 | 已解决；阶段 3 独立完成复核通过 |

## 风险和回滚

- `LaunchCtlExecutor` 的变更为 CRITICAL 影响面，阶段 1 实现必须先完成已准入 Step 0，并在每个实际修改符号前重新做 impact；Rust/Swift 共享文件串行编辑。
- 错误身份匹配可能误杀用户进程；因此身份不符默认不行动，宁可自动延迟恢复也不扩大信号范围。
- 自动冷却可能掩盖持续配置/远端故障；必须保留脱敏诊断事件和现有 fail-closed 结果，但诊断不应成为人工恢复前置。
- 实施或真实验收失败时，回滚本计划独立提交并恢复先前 Release App；不得通过删除 plist、改写 config 或修改 ECS 规则回滚。

## 关联 ADR、迁移、spec 或 issue

- [Rust Core 作为唯一生命周期 owner](../adr/0001-rust-core-single-owner.md)
- [TunnelPad Rust Core owner 切换迁移说明](../migrations/tunnelpad-rust-owner-cutover.md)
- [此前阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md)
