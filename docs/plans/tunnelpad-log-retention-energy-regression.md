# 计划：TunnelPad 日志保留与能耗回归修复

> 规范适用（2026-09-06）：本计划保留完成时的阶段、验收条件与独立复核历史；后续变更遵循[新版规范与历史兼容](../PLAN_MAP.md#规范适用与历史兼容)。状态、当前阶段和最后更新以[计划索引](../PLAN_MAP.md#计划索引)为准。

- 前置：`tunnelpad-log-streaming` 已完成，`ADR-0003` 已冻结日志路径、2000 行文件保留、锁失败保留原文件和 Rust Core owner 边界。本计划独立承接隔夜能耗复验暴露的日志保留实现缺陷；后台健康监测能耗计划是本计划完成后重新复验的消费者，不是本计划的实现前置。

## 背景

2026-09-05 的隔夜真实 Release App 复验仍出现约 10 秒一次的 CPU/能耗峰值。运行产物已核验为 2026-09-04 新构建，两个真实隧道保持运行；两次进程栈采样均指向 `LogEventStore.ensureWatcher → fileDidChange → refreshState → LogFileRetention.trimIfNeeded`，而不是旧版健康循环或未重新打包。

真实 `admin-tunnel.log` 约 8.4 MB，包含约 83,516 个 CRLF 行；当前 `trimIfNeeded` 每次文件变化都会读取整个文件，转换为 `String` 后以 `"\n"` 切分。真实 CRLF 输入被漏计，2000 行裁剪门槛失效，小量追加仍会触发大文件全文扫描。完整证据保留在[隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)。

此计划与已完成的[日志事件流与面板生命周期计划](tunnelpad-log-streaming.md)保持边界关系：已完成计划的 2000 行保留目标仍然有效，但本计划负责修复其在真实 CRLF 大日志输入下的实现缺口；不把已完成计划改写为未完成。

## 需求探索

### 已确认事实

- 用户已确认新增独立计划，先解决日志保留实现与能耗回归，再重新验证后台能耗计划；当前不直接开启原能耗计划的阶段 3。
- 当前运行的 Release App 与仓库 release 可执行文件的 Mach-O UUID 和代码段一致，已排除“没有重新打包或仍运行旧进程”。
- `fileDidChange` 在日志 watcher 变化时调用 `refreshState`，`refreshState` 在增量读取之前无条件调用 `LogFileRetention.trimIfNeeded`。
- 真实日志以 CRLF 为主，文件每约 10 秒增加少量 SSH 转发调试日志；当前实现的全文读取和字符切分与该输入组合产生可重复的 CPU 峰值。
- 既有契约为每条隧道本地持久日志最多保留最近 2000 行，路径、stdout/stderr 路由、内存缓存 500 条和单行 8000 字符上限不在本计划改变范围。
- 既有锁失败边界为保留原文件、延后裁剪和后续重试；本计划不以删除真实日志、关闭探针或降低日志级别掩盖问题。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 以字节识别 LF/CRLF 可以在不改变日志正文的情况下正确计算逻辑行数 | 隔离文件 fixture 覆盖 LF、CRLF、混合换行、末行无换行和空文件；核对保留前后原始字节与最近 2000 行 |
| 小量追加不应每次重新解码和切分整个大文件 | 在隔离大文件 fixture 中记录本次裁剪检查读取的字节范围；要求小追加路径不等于整文件扫描，且结果仍正确 |
| 裁剪与 launchd 并发写入可以继续采用失败保留原文件的安全边界 | 锁失败、并发追加、截断、替换和异常中断 fixture；失败时检查文件可读、无删除、无伪造和可重试 |
| 修复日志热点后，10 秒周期本身仍可保留且长期峰值应消失 | 修复后的 Release App 在用户授权的真实配置上进行 CPU、Activity Monitor、日志行数、隧道状态和进程栈复验；不把绝对能耗数值当作跨设备门槛 |

### 范围与非目标

本计划覆盖 `LogFileRetention` 的行边界识别、裁剪检查的读取成本、与 `LogEventStore.refreshState/fileDidChange` 的调用衔接，以及相关隔离测试和真实长期回归。阶段 0 只冻结事实、契约、样本和准入，不修改实现。

非目标如下：

- 不改变 `config.json` Schema、HTTP API、日志路径、launchd label、stdout/stderr 路由、Rust Core 生命周期 owner、探针协议、10 秒监测周期或健康恢复阈值。
- 不把健康循环、`MainPanelView`、`refreshAsync()`、ProbeService 或真实 SSH/ECS 行为并入本计划。
- 不修改已完成日志计划的内存缓存容量、单行字符上限、面板订阅语义或日志输入范围；未来 app 执行器日志另立计划。
- 不在真实日志上直接执行裁剪试验，不清空用户日志，不通过关闭日志、关闭探针或降低日志级别代替修复。
- 不新增配置项、迁移文件或公共 API；若实现超出 ADR-0003 已接受的文件/并发/失败契约，先更新治理文档并评估是否需要新增 ADR。

### 候选方案与取舍

| 方案 | 取舍 | 结论 |
|---|---|---|
| 仅把 `String.split` 改成能识别 CRLF | 可修复行数漏计，但大文件小追加仍可能每次全文解码和字符遍历 | 不足，不单独采用 |
| 字节级识别行边界，并让裁剪检查只读取必要范围或按安全阈值触发 | 保留原始字节，能覆盖 CRLF；需要明确文件增长、尾部不完整行和并发变化的边界 | **推荐，作为阶段 0 后的实现方向** |
| 提高 10 秒间隔、关闭 SSH verbose 或停止探针 | 可能降低表面能耗，但改变已冻结行为并隐藏日志处理缺陷 | 不采用 |

## 不变量

- LF 和 CRLF 各计为一个逻辑行；CRLF 中的 CR 不得被额外计数。末尾没有换行但包含内容的记录仍需可恢复；裸 CR 暂按日志正文保留，不在本计划新增独立换行语义。
- 裁剪完成后每条隧道本地文件最多保留最近 2000 个逻辑行，只淘汰更旧记录；文件路径、stdout/stderr 路由和隧道关联不变。
- 裁剪必须尽量保留 launchd 已打开的文件身份。发现锁不可用、文件身份/大小在检查期间变化、写入失败或异常中断时，保留原文件并延后重试，不删除、不替换为不完整内容。
- 小量追加不能再次触发与整个大文件等量的无界字符解码/切分；必要的边界扫描必须有可观察的上界或增长阈值，并由 fixture 验证。
- 日志存储仍是观察 launchd 文件的 owner，不接管 Rust Core 生命周期；健康监测仍保持 10 秒、探针和恢复契约。
- 真实环境验证只在用户授权的受控窗口执行；验证失败时先停止扩大真实范围，保留日志和配置，不操作 ECS、凭证或非目标隧道。

## 影响模块或文件

- `Sources/TunnelPadCore/LogEventStore.swift`：`LogFileRetention.trimIfNeeded`、`LogEventStore.refreshState`/`fileDidChange` 的裁剪调用衔接。
- `Tests/TunnelPadCoreTests/LogEventStoreTests.swift`：LF/CRLF/混合换行、末行无换行、大日志小追加、锁失败和并发变化 fixture。
- `docs/data-quality/`：阶段 0 基线、实现证据、真实 Release App 长期复验和独立复核记录。
- `docs/PLAN_MAP.md` 与本计划：状态、依赖、阻塞项、验证结果和引用同步。

实现前必须对将修改的 Swift 符号执行 GitNexus upstream impact；若结果为 HIGH/CRITICAL，要在实现前记录影响范围并确认仍在本计划边界内。提交前必须执行 `detect_changes()`，确认没有健康循环、Rust owner、API 或真实配置的计划外变更。

## 公共契约变化

无 API、Schema、迁移或外部日志路径变化。保留既有“每条隧道最近 2000 行”的用户可观察目标；本计划只修正 LF/CRLF 行边界和裁剪检查的成本/并发实现。若发现末尾空行、裸 CR、非法 UTF-8 或原位写入语义必须改变，先暂停实现并更新本计划及必要的 ADR，不用隐式改变现有契约。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定真实缺陷、行语义、成本指标、样本矩阵和安全边界 | 已有隔夜真实证据；补齐本计划 Step 0 与独立准入 | 现状复核、隔离 fixture 设计、GitNexus impact、治理检查 | 已完成 |
| 阶段 1 | 修复 CRLF 行计数并收敛大日志小追加路径 | 阶段 0 最新独立复核达到“待实施”标准 | Swift 专项测试、字节读取预算、锁/并发/替换回归 | 已完成 |
| 阶段 2 | Release App 长期能耗与日志保留回归，解除能耗计划阻塞 | 阶段 1 实现复核通过；用户授权真实窗口；阶段 2 Step 0 和独立准入通过 | CPU/Activity Monitor、日志逻辑行数、隧道/API 状态、进程栈和完整回归 | 已完成 |

## 当前阶段

### 范围

阶段 0 已完成：隔夜真实复验确认了 CRLF 漏计、全文裁剪扫描和每 10 秒小量追加证据，并已冻结实现边界、样本矩阵、验证命令、失败策略和回滚边界。阶段 1 已完成：字节级 LF/CRLF 尾部扫描、原位安全写回、回滚副本和隔离回归已进入 Release 产物。阶段 2 已完成：用户授权的真实两隧道 Release 窗口、CPU/Activity Monitor、日志逻辑行数、运行栈和退出清理均通过，本计划关闭。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 阶段 0：[阶段 0 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage0-independent-review-20260905.md)；阶段 2：[阶段 2 Step 0](../data-quality/tunnelpad-log-retention-energy-regression-stage2-step0-20260905.md) |
| 样本矩阵 | 下表 1–7 和[阶段 2 Step 0](../data-quality/tunnelpad-log-retention-energy-regression-stage2-step0-20260905.md)的 R1–R6 均包含输入、命令、预期、失败判定和输出位置 |
| 验证方式 | 阶段 1 使用隔离 Swift fixture、读取范围/字节计数、锁回归、Swift/Rust/Release；阶段 2 使用用户授权的真实 Release App、CPU/能耗、日志元数据、API、launchd 和进程栈 |
| 失败/回滚边界 | 阶段 1 失败时保留原文件并延后裁剪，代码按独立提交回滚；阶段 2 失败时停止真实扩大范围，只停止本机隧道/App，不改配置、ECS、凭证、真实日志或非目标隧道 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | 通过并完成；[阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)确认阶段 2 完成，本计划关闭 |

阻塞说明：R1–R6 真实验收已完成

### 实施步骤

1. 阶段 0 已用隔夜证据固定真实输入、热点调用链和版本核验，不把“旧包未替换”作为后续假设。
2. 用户已确认逻辑行定义和推荐的字节级有界扫描方向：LF/CRLF 计行，裸 CR 暂按正文保留，10 秒周期不调整。
3. 阶段 0 独立复核已确认下方矩阵、验证方式、失败/回滚边界和 `PLAN_MAP.md` 同步情况。
4. 阶段 1 实施前保持单一编辑窗口，先记录 `trimIfNeeded` 的 CRITICAL upstream impact，再修改实现和隔离测试。
5. 阶段 1 已完成，证据见[阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)；定向测试 15/15、Swift 全量 144/144、Rust 76+1、Release 构建和无隧道真实启动均通过。
6. 阶段 2 Step 0 和独立准入已通过；R1–R6 真实 Release 验证已完成，真实隧道只使用既有配置，结束后按边界清理本机资源。

### Step 0 证据

基线类型为“隔夜真实 Release App + 连续 CPU 采样 + Activity Monitor + 两次运行栈 + 真实日志元数据/换行统计”的性能缺陷现状快照。现有证据确认：App 为新构建；CPU 峰值约每 10 秒出现；watcher 分支采样主要落在 `trimIfNeeded`；`admin-tunnel.log` 约 8.4 MB 且以 CRLF 为主；本轮未裁剪或改写真实日志。该证据只用于固定问题，不代表修复准入或完成验收。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 现有真实缺陷基线 | 查阅[隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)；复核 `top -l 66 -pid <PID> -stats pid,cpu,threads,time -s 1`、`sample` 与日志元数据记录 | 能复现“约 10 秒峰值 + watcher/trimIfNeeded 热点”的证据链，且产物核验通过 | 把旧包、健康探针或日志输入之外的原因当作已证实根因 | 本计划 Step 0；隔夜诊断 |
| 2 | LF 2001 行、末尾换行 | 新增隔离测试后运行 `swift test --filter LogEventStoreTests` | 保留最近 2000 个逻辑行，最旧记录被淘汰，现有 LF 行为不回归 | 行数错误、最新记录丢失、路径或文件身份异常 | 阶段 0/1 实现证据 |
| 3 | CRLF 2001 行、末尾换行 | 新增隔离测试后运行 `swift test --filter LogEventStoreTests` | CRLF 每个换行计一行，保留最近 2000 行，不把 CR 计成额外正文或行 | 仍漏计 CRLF、文件超过上限不裁剪或正文改变 | 阶段 0/1 实现证据 |
| 4 | 混合 LF/CRLF、末行无换行、空文件和裸 CR | 新增隔离测试后运行 `swift test --filter LogEventStoreTests` | 已冻结的逻辑行规则稳定；末行可恢复；空文件不产生伪造内容 | 版本/快照异常、末行丢失、裸 CR 被无意解释为新语义 | 阶段 0/1 实现证据 |
| 5 | 约 8 MB 大文件，每次只追加几百字节 | 隔离 fixture 记录裁剪检查的读取区间/字节计数，并运行专项测试 | 小追加路径不等量读取整个文件；仍能在超过 2000 行时保留正确尾部 | 读取量与全文件相同、每次重新做全量字符切分，或最新尾部不完整 | 阶段 0/1 实现证据 |
| 6 | 锁失败、并发追加、截断、替换和异常中断 | 运行锁/并发 fixture；在 Swift 回归后执行 `git diff --check` 与治理检查 | 失败保留原文件、无删除/伪造，可安全延后重试；文件替换后不重复发布 | 文件损坏、丢追加、重复事件、绕过锁或阻塞重试 | 阶段 0/1 实现证据 |
| 7 | 修复后的真实 Release App 长期窗口 | 用户授权后运行 `top`/Activity Monitor、`sample`、本机回环 API 和真实日志元数据；保持当前两条隧道配置 | 约 10 秒固定高峰消失或不再由日志裁剪路径触发；隧道状态稳定；日志逻辑行数收敛到 2000 行 | 周期峰值持续、日志持续无界增长、状态漂移、`xpcproxy`/过渡态再次卡住或影响非目标隧道 | 阶段 2 真实验收与能耗计划新复核 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-05 | 计划建立/现状基线登记 | 根据隔夜真实复验新增独立日志修复计划；登记新产物、周期峰值、watcher/裁剪栈和 CRLF 大日志，不修改实现 | [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md) | 进行中；阶段 0 待独立准入 | Codex |
| 2026-09-05 | 阶段 0 独立准入复核 | 核对现状证据、用户推荐方案、样本矩阵、验证/回滚边界、依赖同步和 CRITICAL impact；阶段 0 关闭，阶段 1 达到待实施标准 | [阶段 0 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage0-independent-review-20260905.md) | 通过；阶段 1 待实施 | Codex（独立准入复核） |
| 2026-09-05 | 阶段 1 实施与回归 | 完成字节级尾部扫描、CRLF 正确计行、原位回滚保护和隔离矩阵；Swift 15/15、144/144，Rust 76+1，Release/签名和无隧道真实启动通过 | [阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md) | 通过；阶段 1 完成 | Codex |
| 2026-09-05 | 阶段 2 Step 0 与独立准入 | 固定真实 Release 长期回归矩阵、启动/停止顺序、失败/回滚边界；未把真实隧道验证预先写成通过 | [阶段 2 Step 0](../data-quality/tunnelpad-log-retention-energy-regression-stage2-step0-20260905.md)；[阶段 2 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-review-20260905.md) | 通过；阶段 2 准入完成 | Codex（独立准入复核） |
| 2026-09-05 | 阶段 2 真实 Release 验收 | 两隧道运行约 46 秒；日志均保持 2000 LF；CPU 最高约 7.7%；Activity Monitor 即时能耗约 2.0；状态、运行栈和退出清理通过 | [阶段 2 实施与真实验收证据](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md) | 通过；等待独立完成复核 | Codex |
| 2026-09-05 | 阶段 2 独立完成复核 | 逐条核对日志行语义、尾部读取、失败边界、回归、Release、真实两隧道窗口和清理；完成条件满足 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md) | 通过；阶段 2 完成，本计划关闭 | Codex（独立只读完成复核） |

### 验证方式

- 阶段 0：只读复核现有证据，完成行语义、成本指标、样本矩阵、失败/回滚边界、GitNexus impact 和治理同步；不运行会改写真实日志的命令。
- 阶段 1：[阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)中的隔离测试、Swift/Rust 回归、Release 构建、签名和无隧道真实启动；并执行 `git diff --check`、`plan-governance-cli check .` 和 GitNexus `detect_changes()`。
- 阶段 2：[阶段 2 实施与真实验收证据](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)记录用户授权的真实 Release App 两隧道窗口；核对 CPU 周期峰值、Activity Monitor、日志逻辑行数/大小、两个隧道状态、本机 API、进程栈、清理和非目标隔离，并回填后台健康监测能耗计划的最新独立复核。

### 测试覆盖率

阶段 1 已记录 LF、CRLF、混合换行、末行无换行、空/小文件、裸 CR、2000 行边界、大日志尾部扫描、锁失败、文件替换和增量采集结果；Swift 专项测试 15/15 通过、全量测试 144/144 通过，Rust 测试 76+1 通过。阶段 2 已补充真实日志追加/裁剪、两隧道状态、CPU/Activity Monitor、运行栈和退出清理；并发/截断异常仍遵守失败保留原文件边界。测试覆盖率证据见[阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)、[阶段 2 真实验收证据](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)和[阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)。

### 完成条件

- 阶段 0 的真实缺陷证据、逻辑行定义、样本矩阵、验证方式、失败/回滚边界和 GitNexus 影响已独立复核通过。
- 阶段 1 实现、专项/全量回归、Rust 回归、Release 构建/签名和无隧道真实启动证据已完成；阶段 2 Step 0 和独立准入已通过。
- LF/CRLF 输入均能正确保留最近 2000 个逻辑行，末尾无换行和混合输入可恢复；日志路径、stdout/stderr 路由、内存缓存和事件版本语义不变。
- 大日志小量追加不再每次进行与整个文件等量的全文字符解码/切分；锁失败、并发、截断、替换和异常中断均优先保留原文件并可重试。
- Swift 专项/全量回归、适用的 Rust 回归、Release 构建和治理检查通过；`detect_changes()` 未发现计划外健康循环、Rust owner、API、配置或真实资源变更。
- 用户授权的真实 Release App 长期复验确认周期 CPU/能耗峰值不再由日志裁剪路径产生，日志行数收敛，两个隧道和非目标资源稳定；后台健康监测能耗计划已追加自己的最新独立完成复核。
- `PLAN_MAP.md`、本计划、阶段证据、测试证据和能耗计划引用同步；本计划独立完成复核通过并标记已完成。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-05 |
| 阶段 | 阶段 2 |
| 结论 | 通过；阶段 2 完成，本计划关闭 |
| 证据 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)；[阶段 2 实施与真实验收证据](../data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md) |
| 复核者 | Codex（基于当前仓库、回归输出、真实 Release 窗口和清理结果的独立只读完成复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-05 | 计划建立后的准入状态登记 | 阶段 0 | 待复核；不授予阶段 1 实施准入 | [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)；本计划 Step 0 与样本矩阵 | 尚未进行独立复核 |
| 2026-09-05 | 阶段 0 独立准入复核 | 阶段 1 | 通过；达到待实施标准 | [阶段 0 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage0-independent-review-20260905.md)；CRITICAL upstream impact 已登记 | Codex（独立准入复核） |
| 2026-09-05 | 阶段 1 实施复核 | 阶段 1 | 通过；阶段 1 完成 | [阶段 1 实施证据](../data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)；Swift/Rust/Release/真实无隧道控制组均通过 | Codex（基于证据的只读复核） |
| 2026-09-05 | 阶段 2 独立准入复核 | 阶段 2 | 通过；达到“待实施”标准 | [阶段 2 独立准入复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-review-20260905.md)；R3–R6 随后已实际执行 | Codex（独立准入复核） |
| 2026-09-05 | 阶段 2 独立完成复核 | 阶段 2 | 通过；阶段 2 完成，本计划关闭 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)；真实两隧道窗口、日志 2000 LF、CPU/能耗和清理均通过 | Codex（独立只读完成复核） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 裸 CR 是否应作为独立行边界 | 保持兼容：LF/CRLF 计行，裸 CR 先按正文保留；若样本证明现有日志需要其他语义，先更新计划和 ADR | 否 | 已确认（用户按推荐方案执行） |
| 裁剪检查何时触发、读取上界如何证明 | 隔离大文件读取计数 fixture 与[阶段 2 独立完成复核](../data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)已覆盖本计划范围；后续触发策略由[低写放大计划](tunnelpad-log-write-amplification.md#不变量)细化 | 否 | 已完成 |
| 是否需要新增 ADR | 先在 ADR-0003 既有边界内实现；只有路径、原位身份、并发失败或可观察保留语义变化时新增 ADR | 否 | 暂不需要 |
| 真实长期能耗验收是否由本计划独立关闭 | 本计划提供日志实现和真实回归证据；后台健康监测计划追加自己的最新独立完成复核并负责关闭自身阶段 2 | 否 | 已由能耗计划追加独立完成复核 |

## 风险和回滚

- CRLF 解析若仍依赖字符层，可能再次漏计或产生额外分配；优先使用原始字节边界，且用混合输入和原始字节对比 fixture 约束风险。
- 在 launchd 正在写入时裁剪可能丢失最新追加或破坏文件；必须先获得可用锁并核对文件身份/大小，任何不确定都保留原文件并延后重试。
- 过度减少裁剪检查可能让文件暂时超过 2000 行；允许在安全失败边界内暂时超限，但不能无限跳过且必须有可观测的下次重试路径。
- 读取成本修复若误触健康循环、探针或 Rust owner，会扩大共享模块风险；实现前做 GitNexus impact，提交前用 `detect_changes()` 反证范围。
- 真实验收失败时停止真实操作，保留配置、隧道和日志；只恢复本地 App 备份或回滚本计划实现，不删除真实日志、不操作远端资源、不触碰非目标隧道。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad 日志事件流与面板生命周期](tunnelpad-log-streaming.md)
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)
- [ADR-0003：日志事件流、缓存和文件保留边界](../adr/0003-log-event-stream-and-retention.md)
- [TunnelPad Rust Core owner 切换迁移说明](../migrations/tunnelpad-rust-owner-cutover.md)
- [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)
