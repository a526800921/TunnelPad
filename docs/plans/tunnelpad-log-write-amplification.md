# 计划：TunnelPad 日志低写放大与流式保留

- 状态：已完成
- 当前阶段：-
- 最后更新：2026-09-05
- 前置：[TunnelPad 日志事件流与面板生命周期计划](tunnelpad-log-streaming.md)、[TunnelPad 日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)和[TunnelPad Rust Core 迁移计划](tunnelpad-rust-migration.md)已完成；本计划复用既有日志路径、launchd 生命周期和 2000 行裁剪契约，并承接真实运行中新发现的磁盘写放大问题。

## 背景

日志保留的 CPU 热点已经通过字节级尾部扫描收敛，但真实 Release App 的磁盘观测仍显示约 30 秒增加 1.7 MB，折算约 57 KB/s。进一步只读复验发现：两个日志文件在 30 秒内大小没有增加，`admin-tunnel.log` 的修改时间却约每 10 秒更新一次，说明日志内容只小量追加，随后被整文件重写。

当前 `admin-tunnel.log` 约 199 KB、2000 行；`reverse-ssh.log` 约 129 KB、2000 行。两个当前配置都显式包含 SSH `-v`，因此端口转发成功、通道创建/释放等 `debug1` 信息会持续追加。`LogEventStore.refreshState` 在文件变化时调用 `LogFileRetention.trimIfNeeded`；超过 2000 行后，裁剪逻辑会读取保留尾部、建立回滚副本并原位写回整个文件。

本计划回答“日志能否流式新增和删除”：普通文件可以流式追加，但不能无代价删除文件头；`ftruncate` 只能截断文件尾部，删除前缀必须搬移剩余字节或引入独立日志代理/环形存储。当前推荐保留 launchd 直接写固定日志文件的边界，改为追加期间不裁剪、达到高水位后批量压缩。

## 需求探索

### 已确认事实

- 用户要求新增独立计划，并确认接受“文件最多约 512 KB，达到阈值后压缩回最近 2000 行”的方案。
- 用户确认正常运行自动关闭独立 `-v` 详细日志，仅在故障排查时通过设置打开；错误、断线和认证失败信息仍需保留。
- 用户希望降低磁盘写入，不改变隧道转发功能，也不依赖人工定期清理。
- 当前 Release App 的两个隧道日志均保持 2000 行；`admin-tunnel.log` 约每 10 秒发生一次同大小重写，证明主要问题是写放大而非日志内容新增量。
- `launchd` 直接把隧道 stdout/stderr 写入固定路径；Rust Core 继续拥有隧道生命周期，本计划不引入第二个生命周期 owner。
- 当前两个隧道配置带有独立 `-v`；该参数是当前写放大的源头之一，阶段 1 纳入正常运行默认静默、设置按需恢复详细日志的兼容迁移。

### 已确认的方案摘要

- 正常读取阶段只做流式增量采集和内存缓存更新，不因每一行变化触发整文件裁剪。
- 以文件字节高水位作为主要触发条件：默认 512 KiB；达到高水位后才执行一次安全压缩。
- 压缩完成后保留最近 2000 个逻辑行；压缩前允许文件短暂超过 2000 行，但不得无限增长。
- 保留文件路径、launchd 标准输出/错误路由、文件身份优先、锁失败保留原文件和后续重试边界。
- UI 仍实时显示最近 500 条内存缓存；磁盘文件是恢复和重开窗口的持久化来源。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 当前实际磁盘写入主要来自超过行数后重复重写，而不是持续产生 57 KB/s 的新日志 | 真实 Release 窗口同时记录日志大小、修改时间、逻辑行数、Activity Monitor 累计读写和进程树；预期日志大小稳定但重写频率随现实现象出现 |
| 512 KiB 高水位可以在不造成无界增长的前提下显著降低写放大 | 隔离 fixture 模拟持续追加，记录追加字节、压缩次数、压缩写入字节和最大文件大小；要求最大值有界且压缩后为最近 2000 行 |
| 流式追加期间不裁剪不会破坏日志采集或重开面板 | 隔离 App/actor fixture 覆盖追加、读取、关闭、重开、切换和文件替换；真实窗口核对日志状态与 UI 快照 |
| 保持固定文件身份可以兼容 launchd 正在持有的 stdout/stderr 描述符 | 锁失败、并发追加、截断、替换和裁剪异常 fixture；失败时检查原文件可读、无删除和可重试 |

### 范围与非目标

本计划覆盖日志裁剪触发策略、追加期间的增量采集、批量压缩的写放大、真实日志长期写入验证和相关治理证据。

非目标如下：

- 不改变隧道的 SSH 转发参数、探针协议、KeepAlive、重连、Rust Core owner、HTTP API 或 C ABI。
- 不修改日志路径、launchd label、stdout/stderr 路由和现有文件身份优先策略。
- 不把真实日志迁移到远程服务、网络代理、数据库或公网存储。
- 不直接删除真实日志，不在真实日志上做破坏性裁剪试验，不通过停止探针或停止隧道掩盖写入。
- 正常运行自动关闭现有 SSH 命令中的独立 `-v`，保留设置按需重新打开详细日志的能力；不修改 `-vv`、`-vvv` 或其他非独立参数。
- 不在本计划引入日志代理、FIFO、后台 helper 或环形文件；这些方案会改变 launchd 文件写入边界，若需要另立架构计划。

## 候选方案与取舍

| 方案 | 说明 | 取舍 | 结论 |
|---|---|---|---|
| A. 每行追加后立即裁剪 | 继续保持文件始终接近 2000 行 | 写放大高，重复读写约 200 KB 文件 | 不采用 |
| B. 追加 + 高水位批量压缩 | 文件变化只增量读取；达到 512 KiB 后一次性压缩到最近 2000 行 | 压缩前短暂超过 2000 行，需要严格字节上限和失败回滚 | **推荐** |
| C. 日志代理或环形文件 | 由 helper 接收 stderr，按环形块流式淘汰 | 可减少整文件重写，但改变 launchd 路由、进程生命周期和故障面 | 本计划不采用 |

## 不变量

- 每条隧道的显示缓存最多 500 条，单行最多 8000 字符；该契约不变。
- 每次批量压缩完成后，每条隧道持久日志保留最近 2000 个逻辑行，LF/CRLF 语义不变。
- 压缩前持久文件允许暂时超过 2000 行，但必须受 512 KiB 高水位和追加失败边界约束；不得无界跳过压缩。
- 日志正常追加不触发整文件写回；只有达到高水位、启动发现超限或明确停止收尾时才允许进入压缩路径。
- 压缩必须尽量保持 launchd 已打开的文件身份。无法加锁、文件身份/大小发生变化、写入失败或异常中断时，保留原文件并延后重试。
- 不通过重命名替换固定日志文件来规避写入；避免 launchd 继续写入旧 inode 而造成日志分叉。
- 隧道生命周期和日志存储仍然分离；本计划不接管 Rust Core 或 launchd 的启动、停止和重连。

## 公共契约变化

无 API、Schema、ABI 或外部日志路径变化。用户可观察变化仅为：持久日志在压缩前允许短暂超过 2000 行、但受 512 KiB 高水位约束；面板内存缓存和压缩后的最近 2000 行语义保持不变。若实现需要增加配置字段、改变 launchd 路由或新增 helper，必须暂停并更新本计划及必要 ADR，不隐式扩大范围。

## 影响模块或文件

- `Sources/TunnelPadCore/LogEventStore.swift`：追加期间的裁剪触发状态、批量压缩调度和现有安全写回路径。
- `Sources/TunnelPadCore/SSHCommand.swift` 与配置编辑路径：实现正常运行静默、设置按需恢复 `-v` 的兼容迁移；不改变 `-vv`、`-vvv` 或其他参数。
- `Tests/TunnelPadCoreTests/LogEventStoreTests.swift`：追加阈值、最大文件大小、压缩次数/写入量、重开、文件替换和失败重试 fixture。
- `Tests/TunnelPadCoreTests/SSHCommandTests.swift`：仅在日志级别切片进入范围时补充默认/详细日志行为测试。
- `docs/data-quality/`：Step 0 基线、实现证据、真实 Release 磁盘写入回归和独立复核记录。
- `docs/PLAN_MAP.md` 与本计划：计划状态、阶段、依赖、阻塞项和证据链接。

实施前必须对实际修改的 Swift 符号执行 GitNexus upstream impact；若为 HIGH/CRITICAL，要记录影响范围并确认仍在本计划边界内。提交前必须执行 `detect_changes()`，确认没有健康循环、Rust owner、API、配置或远端资源的计划外变化。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定写放大基线、流式/批量语义、阈值和安全边界 | 已有真实 30 秒磁盘与日志复验；完成需求探索和独立准入 | 源码调用链、真实元数据、样本矩阵、GitNexus impact、治理检查 | 已完成 |
| 阶段 1 | 实施正常运行静默、追加期间不裁剪和 512 KiB 高水位批量压缩 | 阶段 0 Step 0 与独立准入通过 | Swift/Rust fixture、全量回归、命令兼容、读取/写入计数、文件身份和失败重试 | 已完成 |
| 阶段 2 | Release App 真实磁盘写入与隧道长期回归 | 阶段 1 完成；阶段 2 自己的 Step 0 和独立准入通过 | Activity Monitor、进程累计读写、日志大小/修改时间、CPU、隧道状态和退出清理 | 已完成 |

## 当前阶段

### 范围

阶段 0 已完成真实 Release App 磁盘写放大基线和独立准入，阶段 1 已完成实现、专项回归和 Release 打包，阶段 2 已完成真实 Release 窗口、Activity Monitor 复核和退出清理。以下保留最终范围和验证边界；本计划不修改真实日志内容，不扩大到 ECS、凭证、远端资源或非目标隧道。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | [阶段 2 Step 0](../data-quality/tunnelpad-log-write-amplification-stage2-step0-20260905.md)：最新 Release App、两个真实隧道、静默配置和 40 秒现场窗口已复核 |
| 样本矩阵 | 下表 1–7 固定代码/真实基线；阶段 2 A/B/C 固定 30 分钟静默窗口、Activity Monitor 读数和退出清理 |
| 验证方式 | 阶段 1 Swift/Rust/Release 回归；阶段 2 真实 App 窗口、Activity Monitor、日志元数据、本地 API、隧道状态和退出清理 |
| 失败/回滚边界 | 锁失败、文件变化、压缩异常时保留原文件并延后重试；真实验收失败时停止扩大范围，只恢复本地 App/本地代码，不改 ECS、凭证或非目标隧道 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | 通过；[阶段 2 独立完成复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md)确认阶段 2 完成条件、真实窗口和退出清理均通过 |

### 实施步骤

1. 阶段 0 已完成真实磁盘写入与日志修改时间基线，并通过独立准入复核。
2. 阶段 1 实施前对将修改的 Swift 符号执行 GitNexus upstream impact，记录共享日志路径影响范围。
3. 阶段 1 已让正常 SSH 运行默认不带独立 `-v`，设置打开时才追加；正常文件变化只走增量读取，达到高水位、启动超限或显式收尾时进入批量压缩。
4. 阶段 1 已补充持续追加小行、阈值、压缩触发、原始换行、文件替换和锁失败重试等 fixture，并完成 Swift/Rust/Release 回归。
5. 阶段 2 Step 0 已完成，真实 Release App 和两个隧道已启动，静默配置及短时窗口已复核；阶段 2 独立准入已通过。
6. 阶段 2 已执行 30 分钟真实窗口，同时记录 Activity Monitor 磁盘累计写入、能耗/CPU、日志大小/mtime、API 状态和隧道状态。
7. 阶段 2 已结束 App 并验证受管 launchd 清理，随后恢复用户当前需要的运行状态；已同步 `PLAN_MAP.md`、证据文档和计划状态。

### Step 0 证据

基线类型为“真实 Release App 运行窗口 + 日志文件元数据 + 进程树 + Activity Monitor 磁盘累计读写”的性能缺陷现状快照。已观察到：30 秒内两个日志文件大小不变；`admin-tunnel.log` 约每 10 秒更新修改时间；当前文件约 199 KB/2000 行；两个隧道配置带 `-v`；Activity Monitor 进程累计写入窗口折算约 57 KB/s。由于当前环境没有可用的 root `fs_usage` 追踪权限，精确到每一次系统写调用的归因留到阶段 2；现有修改时间和源码写回路径足以作为阶段 0 的替代基线。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前真实日志元数据 | 记录日志 `stat`、逻辑行数、Activity Monitor 累计读写和 `ps` 进程树至少 30 秒 | 复现文件大小稳定、修改时间周期变化或确认其消失 | 把累计写入误判成新增日志量；无法关联日志变化 | 阶段 0 证据 |
| 2 | 小行持续追加 fixture | 以固定小块追加并记录每次 `stat`、压缩调用和字节计数 | 未达到 512 KiB 时不压缩；文件最大值有界 | 每次追加都重写、文件无界增长或阈值失效 | 阶段 1 专项测试 |
| 3 | 超过 512 KiB 的 LF/CRLF 文件 | 运行 `LogEventStoreTests` 追加/压缩 fixture | 只触发一次批量压缩，保留最近 2000 个逻辑行和原始换行 | 行数错误、最新记录丢失、反复压缩 | 阶段 1 专项测试 |
| 4 | 混合换行、末行无换行、裸 CR | 运行既有日志保留矩阵并记录逻辑行数 | 与既有 ADR-0003 行语义一致 | 裸 CR 被改成新行语义或末行丢失 | 阶段 1 专项测试 |
| 5 | 文件身份/并发变化 | 注入追加、截断、替换、锁失败和压缩异常 | 保留原文件、无删除/伪造、下次可重试 | 覆盖最新追加、破坏 launchd 文件身份或产生半文件 | 阶段 1 专项测试 |
| 6 | 面板关闭、重开和切换 | 隔离 actor/session fixture | 追加采集不依赖面板可见性；重开可恢复最近缓存/持久尾部 | 关闭面板停止采集、迟到事件串隧道或快照倒退 | 阶段 1 回归 |
| 7 | 修复后的真实 Release App | 正常模式运行两个现有隧道，另做一次详细日志开关回归；记录至少 30 分钟日志大小、mtime、Activity Monitor 磁盘、CPU 和 API 状态 | 正常模式不再周期性产生 verbose 通道日志；追加不再每 10 秒整文件写回；详细日志开关仍可恢复诊断信息；隧道状态稳定 | 静默模式仍持续写成功调试日志、开关失效、仍保持 10 秒整文件重写、写入接近 57 KB/s 或隧道行为改变 | 阶段 2 真实证据 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-05 | 计划建立/需求探索 | 用户确认接受 512 KiB 高水位和批量压缩，并确认正常运行关闭独立 `-v`、故障排查时按需打开；完成流式追加、前缀删除和 launchd 文件身份取舍说明 | 本计划需求探索；真实 Release App 只读复验 | 通过；阶段 0 完成 | Codex |
| 2026-09-05 | 阶段 0 独立准入复核 | 固定真实日志大小/mtime、配置详细日志开关、launchd 文件身份和批量压缩边界；确认阶段 1 可实施 | [阶段 0 独立准入复核](../data-quality/tunnelpad-log-write-amplification-stage0-independent-review-20260905.md) | 通过；阶段 1 实施中 | Codex（独立只读复核） |
| 2026-09-05 | 阶段 1 实施前影响分析 | `trimIfNeeded` 为 CRITICAL，直接调用者 1 个，影响 16 个符号、6 条流程、3 个模块；`refreshState` 为 CRITICAL，直接调用者 5 个，影响 18 个符号、6 条流程、3 个模块；SSH 详细日志和 launchd plist 路径为 LOW | GitNexus upstream impact；目标为 `LogFileRetention.trimIfNeeded`、`LogEventStore.refreshState`、`SSHCommand.removingVerboseFlag`、`LaunchdPlistRenderer.plistDictionary` | 通过；范围限定为日志与配置兼容回归 | Codex |
| 2026-09-05 | 阶段 1 实施与回归 | 删除文件变化时无条件裁剪，增加 512 KiB/64 KiB 高水位状态，完成静默配置迁移、专项/全量测试、Rust 回归、Release 构建和打包 | [阶段 1 实施证据](../data-quality/tunnelpad-log-write-amplification-stage1-implementation-20260905.md) | 通过；阶段 1 完成 | Codex |
| 2026-09-05 | 阶段 2 Step 0 与独立准入 | 最新 Release App 真实启动、两个隧道静默运行、API/探针/日志短时窗口及详细日志开关回归通过；阶段 2 长期窗口准入通过 | [阶段 2 Step 0](../data-quality/tunnelpad-log-write-amplification-stage2-step0-20260905.md)；[阶段 2 独立准入复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-review-20260905.md) | 通过；阶段 2 实施中 | Codex（独立准入复核） |
| 2026-09-05 | 阶段 2 真实 Release 实施 | 30 分钟/31 样本真实静默窗口、Activity Monitor CPU/能耗/磁盘、日志元数据、API/隧道状态和退出清理通过；随后恢复最新 App 与两个隧道 | [阶段 2 真实 Release 实施证据](../data-quality/tunnelpad-log-write-amplification-stage2-implementation-20260905.md) | 通过；阶段 2 完成 | Codex |
| 2026-09-05 | 阶段 2 独立完成复核 | 对完成条件、当前仓库验证、真实窗口、退出清理、范围和治理反向引用独立核对通过；GitNexus `detect_changes --repo TunnelPad --scope unstaged` 为 CRITICAL，影响 24 条日志相关流程、74 个符号，与已记录的共享日志枢纽影响一致 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md) | 通过；专项计划完成 | Codex（独立完成复核） |

## 验证方式

- 阶段 0：只读复核当前源码、配置摘要、日志元数据、进程树和 Activity Monitor 观测；建立隔离 fixture 设计，不改真实日志。
- 阶段 1：已运行日志专项测试、Swift 全量、Rust 回归和 Release build；记录压缩触发、最大文件边界、行语义、文件身份和失败重试；执行 `git diff --check`、治理检查和 `GitNexus detect_changes --repo TunnelPad --scope unstaged`。后者为 CRITICAL，影响 24 条日志相关流程、74 个符号，已核对未越出日志计划边界。
- 阶段 2：已运行最新 Release App；同时观察 Activity Monitor 磁盘累计读写、进程 CPU、日志大小/mtime、API 状态、隧道 PID 和退出清理，完成 30 分钟窗口并记录独立实施证据。

## 测试覆盖率

阶段 0 已完成真实基线复核。阶段 1 已覆盖正常静默与详细日志开关、未达阈值追加、达到阈值压缩、压缩后最近 2000 行、LF/CRLF/混合换行、文件替换、锁失败、重开和多隧道隔离；专项 16/16、Swift 全量 145/145、Rust 76 单元 + 1 differential、Release 构建和打包均通过。阶段 2 已完成 30 分钟/31 样本真实窗口、Activity Monitor 磁盘/CPU/能耗、日志元数据、API、隧道状态和退出清理；测试覆盖率证据见[阶段 1 实施证据](../data-quality/tunnelpad-log-write-amplification-stage1-implementation-20260905.md)、[阶段 2 真实 Release 实施证据](../data-quality/tunnelpad-log-write-amplification-stage2-implementation-20260905.md)和[阶段 2 独立完成复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md)。

## 完成条件

- 阶段 0 的真实写放大基线、流式追加语义、512 KiB 高水位、临时超限边界、失败/回滚策略和样本矩阵通过独立准入复核。
- 阶段 1 未达到高水位时不触发整文件压缩；达到高水位后压缩次数与写入字节相对逐行裁剪显著下降，最大文件大小有界。
- 阶段 1 正常 SSH 运行不再携带独立 `-v`，错误日志仍可见；详细日志设置可恢复 `-v`，且不误改 `-vv`/`-vvv`。
- 阶段 1 完成后仍保留最近 2000 个逻辑行、500 条内存缓存、8000 字符单行上限、固定日志路径、launchd 文件身份和锁失败回滚边界。
- Swift/Rust/Release 回归、GitNexus 影响范围、治理检查和反向引用检查通过；没有计划外 API、Schema、Rust owner、ECS、凭证或远端资源变化。
- 阶段 2 真实窗口确认不再每约 10 秒整文件重写，累计磁盘写入显著低于当前约 57 KB/s 投影，CPU、隧道状态、日志恢复和退出清理无回归。
- 计划状态、`PLAN_MAP.md`、阶段证据、测试覆盖证据和独立完成复核同步后，才标记为已完成。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-05 |
| 阶段 | 阶段 2 |
| 结论 | 通过；阶段 2 完成，专项计划达到关闭条件 |
| 证据 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md)确认真实窗口、退出清理、完成条件、范围和治理反向引用均通过 |
| 复核者 | Codex（独立完成复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-05 | 计划建立后的需求探索登记 | 阶段 0 | 待复核；仅冻结候选方向，不授予实施准入 | 本计划需求探索与 Step 0 | 尚未进行 |
| 2026-09-05 | 阶段 0 独立准入复核 | 阶段 0 | 通过；阶段 0 完成，阶段 1 达到 `待实施` 标准 | [阶段 0 独立准入复核](../data-quality/tunnelpad-log-write-amplification-stage0-independent-review-20260905.md) | Codex（独立只读复核） |
| 2026-09-05 | 阶段 1 实施准入登记 | 阶段 1 | 通过；阶段 1 达到 `待实施` 标准，进入实施 | [阶段 0 独立准入复核](../data-quality/tunnelpad-log-write-amplification-stage0-independent-review-20260905.md) | Codex（基于独立准入证据） |
| 2026-09-05 | 阶段 2 独立准入复核 | 阶段 2 | 通过；阶段 2 达到 `待实施` 标准，允许开始真实 Release 长期回归 | [阶段 2 独立准入复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-review-20260905.md) | Codex（独立只读复核） |
| 2026-09-05 | 阶段 2 独立完成复核 | 阶段 2 | 通过；阶段 2 完成，专项计划达到关闭条件 | [阶段 2 独立完成复核](../data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md) | Codex（独立完成复核） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 详细日志兼容迁移落点 | 自动将现有独立 `-v` 纳入正常静默默认；保留 UI 开关按需恢复，阶段 1 用配置/launchd 回归确认保存和启动语义 | 否 | 已确认，阶段 1/2 已验证 |
| 512 KiB 是否需要按超长行动态放大 | 以 `max(512 KiB, 最近一次压缩后的文件大小 + 64 KiB)`作为下一次高水位，避免超长行导致反复压缩 | 否 | 已确认，阶段 1/2 已验证 |
| 是否需要独立日志代理实现真正的环形删除 | 当前不引入；只有批量压缩仍不能满足磁盘目标时另立架构计划 | 否 | 暂不采用 |

## 风险和回滚

- 压缩延迟可能使日志在高水位前暂时超过 2000 行；通过 512 KiB 上限、启动超限检查和显式收尾压缩约束，不允许无界增长。
- 追加期间不裁剪可能让进程重启前的日志尾部略大；启动时先做一次安全压缩，失败则保留原文件并下一次重试。
- 现有 launchd 正在持有日志文件；不使用重命名替换，压缩前后检查 inode/size/mtime，锁或快照不确定时保留原文件。
- 高水位参数若对超长行不适配，可能形成反复压缩；记录最近一次压缩后大小并动态设置下一水位，配合超长行 fixture 验证。
- 若真实 Release 仍出现高写入，先保留日志和配置，停止扩大真实范围；只回滚本地实现或恢复本地 App，不删除日志、不操作 ECS、不触碰凭证和非目标隧道。

## 关联 ADR、迁移、spec 或 issue

- [ADR-0003：日志事件流、缓存和文件保留边界](../adr/0003-log-event-stream-and-retention.md)
- [TunnelPad 日志事件流与面板生命周期计划](tunnelpad-log-streaming.md)
- [TunnelPad 日志保留与能耗回归修复计划](tunnelpad-log-retention-energy-regression.md)
- [隔夜复验与诊断](../data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)
