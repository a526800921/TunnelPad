# 计划：TunnelPad 后台健康监测能耗优化

- 状态：已完成
- 当前阶段：-
- 最后更新：2026-09-05
- 前置：`tunnelpad-stability`、`tunnelpad-rust-migration`、`tunnelpad-log-streaming` 和[日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)已完成；纯 `SIGSTOP` 无人工释放的收敛依赖 [无人值守受管 SSH 收敛恢复计划](tunnelpad-unattended-managed-ssh-recovery.md)。本计划不重开既有前置；共享模块后续仍须串行编辑。

## 背景

TunnelPad 空闲时出现约 10 秒一次的瞬时 CPU/能耗峰值。2026-09-03 的 25 秒只读采样记录到 `21:11:21` 的 `31.7% CPU` 与 `21:11:31` 的 `29.7% CPU`，与固定 10 秒健康监测周期一致。

每轮 `runHealthProbeCycle()` 先要求 Rust Core 生成完整 `snapshot()`；Rust owner 对配置中每条隧道同步执行一次 `launchctl print`。当前仅一条隧道启用 HTTP 探针，但配置中两条隧道都被状态扫描。阶段 2 真实运行又确认：主窗口的 5 秒 UI 刷新任务会反复调用 `refreshAsync()`；移除该调用后，运行时栈继续显示 `ProbeService.check → NSURLSession.data`，说明每轮探针新建并销毁临时会话也是周期开销来源。详见[阶段 0 基线](../data-quality/tunnelpad-health-monitor-energy-stage0-20260903.md)和[阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md)。

本计划依赖已完成的 [Rust Core 迁移](tunnelpad-rust-migration.md) 所确立的 lifecycle owner，不能以 Swift 旁路或 ABI 变更规避扫描。日志事件流边界复用已完成的 [日志事件流与面板生命周期计划](tunnelpad-log-streaming.md)；因 `TunnelManager` 和测试路径共享，后续实现仍须串行。

2026-09-05 隔夜复验未通过。已确认运行的是重新打包的新版本，现存主要热点为日志 watcher 触发的全文裁剪检查；CRLF 日志行数漏计导致文件保留上限失效。真实输入、两次运行栈、版本核验与拟议修复见[隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)。日志缺陷已由[日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)完成修复和真实 Release 复验；当前以日志修复后的独立完成复核为准。

## 目标

- 健康时不再由后台健康循环触发全量 `launchctl print` 状态扫描，消除已复现的固定 10 秒峰值来源。
- 保留 10 秒监测、HTTP-only 探针、连续 3 次失败和 10/30/60/300 秒退避；受管 SSH 第 10 次失败后的自动冷却由[无人值守专项计划](tunnelpad-unattended-managed-ssh-recovery.md)单独拥有。
- 保留 `keepAlive`、探针期望状态码、ECS fail-closed、Rust Core owner、日志事件流和现有 generation/取消边界。
- 仅让启用探针的隧道参与后台健康恢复判断；无探针隧道继续使用既有 KeepAlive 和显式状态展示路径。
- 移除主窗口每 5 秒触发的全量 `refreshAsync()` 定时任务；保留首次显示和启停/配置操作后的显式刷新，避免 UI 可见状态继续制造周期性 `launchctl print` 峰值。
- 让同一探针协调器复用一个禁用系统代理的 `URLSession`；保留 HTTP GET、超时、期望状态码和失败三态语义，避免每轮反复创建/销毁网络会话。

## 非目标

- 不改 `config.json` Schema、UI 设置、HTTP API、C ABI、launchd label、SSH 命令、日志路径或 ECS/远端配置。
- 不新增 TCP、SSH 或公网 IP 轮询，也不关闭现有探针、KeepAlive 或拉长 10 秒监测周期来规避功耗。
- 不改 `refreshAsync()` 实现、菜单栏流程或 Rust owner；仅调整 `MainPanelView` 对该高影响方法的周期性调用点。`refreshAsync()` 的 GitNexus upstream impact 为 CRITICAL，继续作为独立公共路径保留。
- 不把日志订阅、app 执行器或 pidfile 并入本计划；ProbeService 会话复用仅限当前健康/探针能耗切片，不改变网络边界。

## 不变量

- 自动恢复仍只通过现有 Rust 生命周期 owner 与 ECS 前置顺序执行，不创建第二套 owner。
- 手动 start/restart/stop、删除、配置重载、退出、busy 与迟到任务的现有代次语义不变。
- 恢复决策前必须读取目标隧道的有效状态；不得用过期状态或健康结果直接启停。
- 真实隧道、SSH、ECS、`launchctl` 故障注入和构建产物验证仅在用户明确授权的受控窗口执行。

## 影响模块或文件

- 阶段 1 的健康循环与恢复计数实现已完成；后续受管 SSH 进程收敛、信号和自动冷却由无人值守专项计划单独拥有，本计划不再声明这些文件的实现影响范围。
- Sources/TunnelPadCore/ProbeCoordinator.swift: 保留既有 HTTP 边界；阶段 2 复用每个协调器的禁用代理会话。
- Sources/TunnelPadCore/ProbeService.swift: 保留既有 HTTP 边界；ProbeService upstream impact 为 MEDIUM（28 个受影响符号），check 为 MEDIUM（9 个受影响符号、1 条流程）。
- Sources/tunnelpad/MainPanelView.swift: 阶段 2 新增最小调用点调整，移除 5 秒全量刷新循环；GitNexus upstream impact 为 LOW（1 个受影响符号）。
- Tests/TunnelPadCoreTests/HealthMonitorEnergyTests.swift: 后续只新增隔离 fake owner/fake probe 与调用计数测试，不调用真实外部资源。
- 高影响的 refreshAsync 实现明确排除；CRITICAL impact（17 个受影响符号、9 条流程），本计划不声明其实现为当前实施目标。

## 公共契约变化

无 API、Schema、迁移或兼容格式变化。阶段 1 冻结后台内部的状态读取顺序；阶段 2 移除主窗口每 5 秒的全量自动刷新，并复用单个探针协调器内的 HTTP 会话，保留首次显示、启停/配置操作后的显式状态刷新。用户可观察的探针语义、阈值、退避、手动操作和 KeepAlive 语义不得变化；受管 SSH 第 10 次失败后的自动冷却以[无人值守专项计划](tunnelpad-unattended-managed-ssh-recovery.md)为准。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定能耗基线、拆分契约、隔离样本矩阵和回滚边界 | 已记录真实运行与源码基线 | 25 秒采样、调用链/影响分析、fixture 设计、独立准入复核 | 已完成 |
| 阶段 1 | 实施“探针优先、按需状态复核”的健康循环 | 阶段 0 完成；阶段 1 自己的 Step 0 与独立准入通过 | 调用计数、失败序列、回归与治理检查 | 已完成 |
| 阶段 2 | 验证能耗改善与恢复契约 | 阶段 1 完成；阶段 2 自己的 Step 0 与独立准入通过；日志保留回归已完成 | 用户授权的真实 App 采样、受控恢复验收、日志修复后真实窗口与独立完成复核 | 已完成 |

## 当前阶段

### 范围

阶段 2 的首轮真实 App 能耗和恢复契约验收作为历史证据保留。阶段 1 已完成按需状态读取，阶段 2 已调整主窗口周期刷新、复用探针会话并完成受管 SSH 恢复边界验证。2026-09-05 隔夜复验曾出现周期 CPU/能耗峰值，运行栈定位到日志裁剪全文扫描及 CRLF 行数漏计；日志保留计划随后完成阶段 1 修复、阶段 2 真实 Release 回归和独立完成复核。本计划已基于[日志修复后阶段 2 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)重新满足完成条件并关闭。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | [阶段 2 Step 0](../data-quality/tunnelpad-health-monitor-energy-stage2-step0-20260904.md)；阶段 1 Step 0、实现和完成复核已闭合 |
| 样本矩阵 | [阶段 2 Step 0](../data-quality/tunnelpad-health-monitor-energy-stage2-step0-20260904.md)；覆盖真实 Release App、配置、CPU、Activity Monitor 和资源边界 |
| 验证方式 | 用户授权的真实 App 采样、回环 API、进程采样、Activity Monitor、Swift/Rust 回归和治理检查 |
| 失败/回滚边界 | 旧 App 已本地备份；失败时只恢复本地 App，不改用户配置、真实 plist、ECS 或凭证 |
| 当前阻塞项 | 无；日志保留缺陷已由独立计划完成修复、Release 回归和独立完成复核 |
| 最新独立准入复核 | 通过并完成；[日志修复后阶段 2 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)确认阶段 2 完成，本计划关闭 |

### 实施步骤

1. 阶段 0 已完成真实基线、调用链、fixture 设计和回滚门禁。
2. 阶段 1 已补齐 fake owner/fake probe 的健康/异常调用计数，并固定失败计数、状态未知、手动操作、配置代次和退出边界。
3. 阶段 1 已完成最小 Swift Core 健康路径实现，不触及 `refreshAsync`、Rust ABI 或现有 owner 契约。
4. 阶段 2 已按用户授权切换到真实 App；首轮当前配置采样发现主窗口 5 秒全量刷新和探针临时 `URLSession` 两类周期开销。
5. 已移除主窗口 5 秒全量 `refreshAsync()` 周期调用，保留首次/操作后刷新；真实活动 `admin-tunnel` 复测未再出现前一轮的 `70%–80%` 周期 CPU 峰值。
6. 已让同一探针服务复用禁代理 `URLSession`；活动隧道复测的即时能耗约 `0.5`，12 小时现场读数约 `10.13`，后续 CPU 保持低个位数。
7. 已补充两处有界重读：明确 `notLoaded` 才继续 ECS/start，明确 `running` 才完成恢复；带受控原 PID 释放和纯 `SIGSTOP` 无人工释放的真实活动隧道恢复链路均已通过。后者由[无人值守专项计划](tunnelpad-unattended-managed-ssh-recovery.md)在 Rust Core 受管身份核验后负责有界信号升级和自动冷却。
8. 应用户要求重新开启阶段 2 夜间复验：保持当前实际配置运行一夜，次日复验 CPU、Activity Monitor 能耗、约 10 秒周期峰值、隧道状态和 `xpcproxy` 是否再次出现；复验完成前不修改代码、不重新关闭计划。
9. 隔夜复验已完成且未通过；先记录日志裁剪热点和 CRLF 输入缺陷。修复样本、实现范围和安全边界转入[日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)，本轮不调整 10 秒契约或日志保留规则。

### Step 0 证据

基线类型为性能缺陷的现状快照与恢复语义的兼容探索。已确认旧链路是：`startHealthMonitoring → runHealthProbeCycle → RustCoreClient.snapshot → CoreOwner.snapshot → LaunchCtlExecutor.status → launchctl print`，之后才由 `ProbeCoordinator → ProbeService.check` 执行 HTTP 请求。阶段 1 已将持续循环拆为配置读取、既有 HTTP 探针和异常时的目标状态读取；启动状态发现最多执行一次。基线不包含 SSH 命令、地址、凭证或私钥。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前一条探针、一条无探针配置 | `top -l 25 -pid <TunnelPad PID> -stats pid,cpu,threads,time -s 1` | 复现或否证固定 10 秒峰值 | 采样无法关联周期，或存在未声明手动操作 | 阶段 0 基线 |
| 2 | 当前健康调用链 | `rg -n 'startHealthMonitoring|runHealthProbeCycle|snapshot|monitorInterval' Sources/TunnelPadCore rust/tunnelpad-core/src` | 证明完整快照逐条触发状态查询 | 源码与基线矛盾 | 阶段 0 基线 |
| 3 | 健康稳定序列 | fake owner/fake probe 调用计数 fixture | 目标设计不做全量 snapshot，也不读无探针隧道 | 健康时仍扫描无探针隧道 | 阶段 0 追加证据与专项测试 |
| 4 | `[fail, fail, fail]` 与恢复成功 | 注入探针结果和 fake owner | 第 3 次失败、退避、恢复前状态门禁保持现有契约 | 少计/多计、提前/延后恢复或跨隧道操作 | 阶段 0 追加证据与专项测试 |
| 5 | KeepAlive、手动操作、删除、重载和退出 | 隔离生命周期/代次 fixture | 取消、清零、busy 与迟到结果门禁不变 | 自动恢复越过操作或退出边界 | 阶段 0 追加证据与专项测试 |
| 6 | 治理与反向引用 | `plan-governance-cli check . --strict-readiness`；`rg -n 'tunnelpad-health-monitor-energy|能耗优化|草案为准|以草案为事实源|详见草案' docs` | 状态、依赖与单一事实源一致 | 严格检查错误或文档漂移 | 本计划与 `PLAN_MAP.md` |
| 7 | 用户授权的真实 App 一夜运行 | 保持当前配置运行一夜；次日复核 `top`/Activity Monitor、本机 API 状态和固定周期 CPU/能耗峰值 | 无固定周期峰值，隧道状态稳定且不再卡在 `xpcproxy` | 出现可重复的约 10 秒峰值、状态漂移或启动过渡态未收敛 | [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)：未通过 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-03 | 真实运行基线与计划建立 | 25 秒只读采样复现约 10 秒 CPU 峰值；核对当前两条隧道、健康循环、Rust owner 和 launchctl 调用链；未修改生产配置或代码 | [阶段 0 基线](../data-quality/tunnelpad-health-monitor-energy-stage0-20260903.md) | 进行中；独立准入未进行 | Codex |
| 2026-09-05 | 隔夜反证与只读诊断 | 真实 CPU/能耗复验未通过；产物已核验，热点定位到 CRLF 大日志的全文裁剪检查 | `docs/data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md` | 未通过；待修复 | Codex |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-03 | 只读影响分析 | GitNexus：`runHealthProbeCycle` LOW、`ProbeCoordinator.run` LOW、`ProbeService.check` MEDIUM；`refreshAsync` CRITICAL，明确排除其改动 | [阶段 0 基线](../data-quality/tunnelpad-health-monitor-energy-stage0-20260903.md) | 通过；仅代表范围收敛 | Codex |
| 2026-09-03 | 治理文档建立 | 新建专项计划、阶段 0 基线并同步索引；未执行测试、构建或真实故障注入 | 本计划；`docs/PLAN_MAP.md` | 进行中 | Codex |
| 2026-09-04 | 阶段 1 实现与隔离回归 | 健康循环改为探针优先、按需目标状态复核；新增 3 项能耗调用计数测试；Swift 137/137、Rust 66+1、治理检查通过 | [阶段 1 实施证据](../data-quality/tunnelpad-health-monitor-energy-stage1-implementation-20260904.md)；[阶段 1 独立只读复核](../data-quality/tunnelpad-health-monitor-energy-stage1-independent-review-20260904.md) | 实施中；阶段 2 未完成 | Codex |
| 2026-09-04 | 阶段 1 独立完成复核 | 当前仓库代码、专项/全量回归、治理和 GitNexus 变更范围独立核对通过；阶段 1 关闭，阶段 2 保持独立验收 | [阶段 1 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-stage1-independent-completion-review-20260904.md) | 通过；不代表全计划完成 | Codex |
| 2026-09-04 | 阶段 2 Step 0、准入与真实 App 验收 | 用户授权跳过隔离 App；真实 `admin-tunnel` 运行时确认 UI 5 秒刷新和探针临时 `URLSession` 两类周期开销；追加移除 UI 周期调用、复用探针会话并完成活动隧道 CPU/能耗复测 | [阶段 2 Step 0](../data-quality/tunnelpad-health-monitor-energy-stage2-step0-20260904.md)；[阶段 2 独立准入复核](../data-quality/tunnelpad-health-monitor-energy-stage2-independent-review-20260904.md)；[阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md) | 能耗切片通过；活动隧道恢复和阶段 2 完成复核未完成 | Codex |
| 2026-09-04 | 阶段 2 真实故障注入诊断 | 在真实 Release App 中仅针对活动 `admin-tunnel` 冻结已核验的 SSH PID；探针按预期失败，bootout 后观察到短暂 `SIGTERMed`，既有即时 `notLoaded` 门禁在 ECS 前置前停止，未发生 ECS 或 start；随后已通过本机 API 恢复隧道 | [阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md) | 发现修复阻塞；环境已恢复 | Codex |
| 2026-09-04 | 阶段 2 自动恢复第二处诊断 | 在恢复后的真实 `admin-tunnel` 上执行受控手动 `stop → start` 对照；`start` 请求即时返回 launchd 过渡态 `other`，数秒后状态收敛为 `running`，证明自动恢复的即时 `isRunning` 检查还会误判启动未完成 | [阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md) | 已定位；待补有界启动状态重读 | Codex |
| 2026-09-04 | 阶段 2 自动恢复状态收敛实现与真实验收 | 补齐 stop 后 `notLoaded`、start 后 `running` 的有界重读；在真实 Release App 仅针对活动 `admin-tunnel` 注入 `SIGSTOP`，等待 launchd 进入终止过渡态后释放原 PID，自动链路完成新进程启动、ECS 同步/已是最新和 HTTP `401/satisfied`；未扩大远端变更范围 | [阶段 2 真实 App 验收](../data-quality/tunnelpad-health-monitor-energy-stage2-real-app-acceptance-20260904.md)；Swift 139/139；Rust 66+1；治理检查 | 条件通过；纯 `SIGSTOP` 无人工释放边界仍未关闭 | Codex |
| 2026-09-04 | 阶段 2 自动恢复后能耗尾检 | 自动恢复后的真实 App 继续运行 30 秒，31 个采样最高约 `18.4%` CPU，其中达到 `10%` 的采样 4 个；活动监视器即时能耗读数为 `0.0`，隧道探针保持 `401/satisfied` | `/tmp/tunnelpad-final-energy-30s.txt`；Activity Monitor；本机 API | 通过；不再出现旧基线的几十个百分点固定周期峰值 | Codex |
| 2026-09-04 | 阶段 2 受管 SSH 无人值守边界关闭 | 真实 Release App 中目标受管 PID 单次 `SIGSTOP` 后无人工释放，自动恢复到新 PID 和 HTTP `401/satisfied`；非目标隧道保持不变 | [无人值守阶段 3 实施证据](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)；[能耗计划独立完成复核](../data-quality/tunnelpad-health-monitor-energy-independent-completion-review-20260904.md) | 通过；阶段 2 完成，本计划关闭 | Codex（独立只读复核） |
| 2026-09-04 | 完成后 `xpcproxy` 状态回归修复 | `startAsync`/`restartAsync` 对当前隧道执行 30 次、100ms 间隔的有界状态复核；无探针隧道的 `xpcproxy` 可收敛为 `running`，不恢复后台全量刷新 | [回归修复与验证](../data-quality/tunnelpad-health-monitor-energy-post-completion-regression-fix-20260904.md)；Swift 140/140；GitNexus impact HIGH | 通过；不重开原阶段 | Codex |
| 2026-09-04 | 用户请求重新开启阶段 2 夜间复验 | 首轮实现和独立完成复核保留；用户将运行一夜，次日复验长期 CPU/能耗和状态稳定性，结果尚未产生 | 本计划；待补夜间复验记录 | 实施中；暂不关闭 | Codex |
| 2026-09-05 | 隔夜复验与根因定位 | 运行产物 UUID/代码段匹配；周期峰值仍在；两次运行栈和真实日志换行统计定位全文裁剪检查与 CRLF 漏计，补充拟议修复和测试缺口 | [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md) | 未通过；仅文档，未修改实现 | Codex |
| 2026-09-05 | 新增独立日志修复计划并完成阶段 0 准入 | 将 CRLF 行计数、全文裁剪热点、大日志小追加和并发失败边界从本计划拆出；独立日志计划阶段 0、阶段 1 实现/回归和阶段 2 Step 0 独立准入均已完成，本计划等待其真实长期回归 | [日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)；[阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)；[阶段 2 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-review-20260905.md)；`PLAN_MAP.md` | 通过；等待新计划阶段 2 完成 | Codex |
| 2026-09-05 | 日志修复后阶段 2 重新验收与完成复核 | 日志保留计划阶段 2 真实两隧道窗口通过；CPU 最高约 7.7%，Activity Monitor 即时能耗约 2.0，日志均为 2000 LF，状态和退出清理通过；本计划完成条件重新满足 | [日志保留阶段 2 真实验收](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)；[日志修复后独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md) | 通过；阶段 2 完成，本计划关闭 | Codex（独立只读复核） |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代独立准入复核。

### Attestation 说明

本计划首轮完成快照 `docs/attestations/tunnelpad-health-monitor-energy.json` 和首轮独立复核保留为历史；日志修复后的最新完成结论见[独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)，不覆盖历史文件。

### 验证方式

- 阶段 0：只读采样、源码调用链、GitNexus impact、隔离 fixture 设计与治理检查，已完成。
- 阶段 1：专项调用计数与状态机测试，随后运行 `swift test`、`cargo test --manifest-path rust/Cargo.toml`、`git diff --check`、治理检查与 GitNexus `detect_changes()`；已完成。
- 阶段 2：首轮短窗口、状态收敛、受管恢复和 `xpcproxy` 回归证据保留；日志修复计划阶段 2 已覆盖真实 CRLF 日志追加、CPU/Activity Monitor、周期峰值、状态、运行栈和退出清理，结果通过。

### 测试覆盖率

测试通过：阶段 1 已记录能耗专项 fixture、稳定性专项回归和阶段 1 独立完成复核；阶段 2 原验收 Swift 全量回归为 139/139，Rust 为 76+1；本次完成后回归修复追加的 Swift 全量回归为 140/140。阶段 2 已完成真实 App、活动 `admin-tunnel`、CPU 和 Activity Monitor 复测；stop/start 两处状态收敛与纯 `SIGSTOP` 无人工释放的进程处置均已通过独立复核，`xpcproxy` 回归修复证据见[回归修复与验证](../data-quality/tunnelpad-health-monitor-energy-post-completion-regression-fix-20260904.md)。

### 完成条件

2026-09-05 隔夜复验曾否证首轮结论；日志保留缺陷已修复并完成新的真实回归和独立完成复核，以下结论以最新证据为准。

- 阶段 0 的真实采样、隔离调用计数 fixture、恢复等价性矩阵和复核记录已通过；阶段 1 已完成；阶段 2 的 UI 周期调用和探针临时会话已收敛，活动隧道真实能耗复测已通过；stop/start 两处 launchd 短暂状态的有界重读、受控原 PID 释放和纯 `SIGSTOP` 无人工释放的真实恢复链路均已通过；阶段 2 独立完成复核已通过。
- 健康时后台循环不再执行全量 snapshot 或无探针隧道的 `launchctl print`；恢复前读取目标隧道有效状态。
- HTTP 探针、10 秒周期、3 次失败、固定退避、10 次熔断、ECS fail-closed、KeepAlive、手动操作、配置/退出代次和日志边界均有反证或回归证据。
- 阶段 2 收敛后的真实 App 采样不再出现可归因于健康循环、UI 全量刷新定时任务或探针会话初始化的固定高 CPU 峰值；当前窗口未影响非目标隧道或远端资源；活动隧道恢复已在受控原 PID 释放窗口验收。纯 `SIGSTOP` 无人工释放的进程处置已决策为独立无人值守专项计划，待其完成真实验收。
- 最新独立完成复核通过，`PLAN_MAP.md`、阶段证据和治理检查同步。
- 日志修复后的真实 Release 两隧道窗口已记录 CPU/能耗、固定周期峰值、日志行数、隧道状态、运行栈和资源清理；最新独立完成复核通过，阶段 2 关闭。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-05 |
| 阶段 | 阶段 2 |
| 结论 | 通过；阶段 2 完成，本计划关闭 |
| 证据 | [日志修复后阶段 2 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)；[日志保留阶段 2 真实验收](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md) |
| 复核者 | Codex（基于当前仓库、真实 Release 窗口、日志元数据和清理结果的独立只读复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-04 | 独立准入复核 | 阶段 1 | 通过 | [阶段 1 独立只读复核](../data-quality/tunnelpad-health-monitor-energy-stage1-independent-review-20260904.md)；阶段 2 真实能耗仍未验收 | Codex |
| 2026-09-04 | 独立完成复核 | 阶段 1 | 通过 | [阶段 1 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-stage1-independent-completion-review-20260904.md)；阶段 2 另行验收 | Codex |
| 2026-09-04 | 独立准入复核 | 阶段 2 | 通过 | [阶段 2 独立准入复核](../data-quality/tunnelpad-health-monitor-energy-stage2-independent-review-20260904.md)；达到“待实施”标准，不代表阶段 2 完成 | Codex |
| 2026-09-04 | 独立完成复核 | 阶段 2 | 通过，阶段 2 完成；本计划关闭 | [能耗计划独立完成复核](../data-quality/tunnelpad-health-monitor-energy-independent-completion-review-20260904.md)；受管 SSH 无人值守边界见[阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md) | Codex（独立只读复核） |
| 2026-09-04 | 完成后回归复核 | 阶段 2 | 通过；不重开原阶段 | [回归修复与验证](../data-quality/tunnelpad-health-monitor-energy-post-completion-regression-fix-20260904.md)；Swift 140/140；状态收敛仅限显式 start/restart | Codex（独立只读复核） |
| 2026-09-05 | 隔夜完成复核与准入撤回 | 阶段 2 | 未通过；阶段 2 隔夜能耗复验失败，日志裁剪热点未修复 | [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)；真实运行反证，不授予新增修复准入 | Codex（基于真实运行与源码的只读复核） |
| 2026-09-05 | 日志修复后独立完成复核 | 阶段 2 | 通过；阶段 2 完成，本计划关闭 | [日志修复后阶段 2 独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)；真实两隧道窗口和日志保留回归通过 | Codex（独立只读完成复核） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 如何消除健康周期全量读取且不改变失败计数 | 已用 fake owner/fake probe 固定“探针优先、异常/恢复前按需复核”路径；阶段 2 继续验证真实采样 | 否 | 隔离实现已验证 |
| 启动首次状态发现如何保留 | 保留启动阶段最多一次全量状态发现；持续健康周期不再重复扫描 | 否 | 已验证 |
| 是否同时优化 UI 刷新或 URLSession 创建 | 阶段 2 已在不修改 `refreshAsync()` 实现的前提下移除其 5 秒周期调用，并复用探针服务的禁代理会话 | 否 | 已完成 |
| 真实能耗验收阈值 | 以健康时无后台全量 snapshot/launchctl 为主判据；收敛后 30 秒以上采样验证固定周期峰值消失，不用跨设备绝对能耗作门槛 | 否 | 已冻结 |
| 隔夜复验暴露日志全文扫描与 CRLF 漏计 | 由[日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)完成阶段 1 实现、回归和阶段 2 真实长期验证；完成后回到本计划验证日志保留和长期能耗 | 否 | 已解决；日志计划阶段 2 真实回归和本计划最新独立完成复核通过 |
| 冻结 SSH 进程进入 launchd 终止过渡态时是否由自动恢复主动释放原进程 | 当前真实验收仅在核验过原 PID 且 launchd 进入终止过渡态后由测试窗口释放；是否把该信号处置纳入生产 Rust owner 需另行评估，避免绕过现有生命周期安全边界 | 是 | 待决策 |

## 风险和回滚

- 去掉每轮全量快照可能让状态缓存变旧；阶段 1 必须在失败计数、状态未知或恢复前读取目标隧道的新鲜状态，并保持代次门禁。
- 探针成功不能据此擅自启动/停止隧道；显式刷新、手动操作和既有启动收敛路径继续负责状态展示与生命周期入口。
- 若恢复提前、延后、误触发、绕过 ECS 前置或影响无探针隧道，回滚本计划独立提交，恢复当前路径；不得通过改写配置、删除真实 plist 或操作远端资源回滚。
- `TunnelManager` 与日志/稳定性共享模块和测试目录；实施期间必须串行编辑，提交前运行 GitNexus `detect_changes()`。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad 隧道稳定性与健康恢复](tunnelpad-stability.md)
- [Rust Core 作为唯一生命周期 owner](../adr/0001-rust-core-single-owner.md)
- [日志事件流、缓存和文件保留边界](../adr/0003-log-event-stream-and-retention.md)
- [TunnelPad Rust Core owner 切换迁移说明](../migrations/tunnelpad-rust-owner-cutover.md)
