# 计划：TunnelPad 隧道稳定性与健康恢复

- 状态：设计中
- 当前阶段：阶段 0
- 最后更新：2026-08-30
- 前置：`tunnelpad-v1`、`tunnelpad-code-quality-refactor` 已完成；`tunnelpad-rust-migration` 阶段 3–4 完成并通过独立复核后，才进入本计划的实现阶段

本计划独立处理 TunnelPad 的运行稳定性，不回写 v1 已冻结的探针展示语义，也不与当前 Rust Core 迁移并行修改执行器、生命周期或探针模块。阶段 0 可以先完成基线和准入设计；在 Rust Core 迁移阶段 3–4 完成并通过独立复核前，不实施本计划的运行时行为变化。

## 背景

当前 TunnelPad 的 `keepAlive` 能处理“受管进程退出后重新拉起”，但探针只在刷新或启停动作中执行，且只更新界面展示。当 SSH 进程仍显示运行、而 TCP 转发或本机映射的 HTTP 服务已经不可用时，现有逻辑不会由探针触发恢复；主窗口隐藏时也没有独立的后台健康监测。

此外，TunnelPad 崩溃后重新启动时，当前启动路径只加载配置并刷新状态：`launchd` 可以从系统查询受管任务，`app` 执行器却只检查新进程内存中的上下文，不会主动读取旧 pidfile 或收敛残留子进程。这可能留下 app 执行器孤儿进程和过期 pidfile。

这不是 v1 已验收行为的回归结论，而是下一阶段稳定性能力的缺口。新的行为必须与现有手动停止、删除、退出清理、`keepAlive` 和两类执行器语义保持一致，并且在达到重试上限后使当前隧道的监测与重试任务一起停止，避免界面状态和实际生命周期分叉。启动收敛还必须避免 PID 被系统复用后误杀无关进程。

## 目标

- 对已配置 HTTP 探针的隧道建立与主窗口可见性无关的后台健康监测。
- 识别“进程仍在但隧道实际不可用”的情况，并在连续失败达到阈值后通过现有生命周期边界安全重启。
- 固定、可测试地执行连续失败、退避、最大重试次数和熔断停止语义，避免重启风暴。
- 第 10 次自动恢复仍失败时，停止当前隧道并取消该隧道全部监测、重试和自动恢复任务；其他隧道不受影响。
- TunnelPad 下一次启动时扫描已配置 `app` 隧道的 pidfile，安全识别并清理崩溃后遗留的匹配子进程，清理无进程的过期 pidfile，并对身份无法确认的 PID 保守告警而不误杀。
- 保留进程意外退出时的现有 `keepAlive` 自动拉起能力，并确保手动启动/重启能够重新开启监测、清零失败计数。
- 用隔离 fixture、失败注入、两类执行器测试和受控应用冒烟证明无迟到任务、无状态倒灌和无计划外隧道操作。

## 非目标

- 不新增 TCP 探测、额外 SSH 探测或第二套凭证/连接通道；健康信号只使用现有 HTTP 探针。
- 不把远端业务服务自身不可用、HTTP 鉴权失败或错误的探针 URL 自动解释成 SSH 网络故障；它们只按探针失败参与本计划的恢复策略。
- 不修改 `config.json` Schema、现有 `probe` 字段含义、`keepAlive` 字段含义、launchd label、日志路径或 pidfile 路径。
- 不增加用户可配置的监测周期、失败阈值、退避序列或最大次数；本计划 v1 固定这些策略，未来开放配置需另立计划。
- 不因单条隧道失败而停止、重启或修改其他隧道。
- 不在 Rust Core 迁移阶段 3–4 未完成独立复核前修改稳定性实现，也不在真实用户隧道上做未经批准的故障注入。
- 不承诺 TunnelPad 进程自身崩溃期间仍能实时监测；但下次启动必须执行本计划定义的 app 孤儿进程安全收敛，应用正常退出时仍遵循既有退出即停语义。
- 不扫描或强制终止与已配置 app 隧道无法建立身份对应关系的任意系统进程；PID 存在但可执行文件或命令行不匹配时只记录告警并保留人工处理边界。

## 需求探索

### 已确认事实

- 当前 `ProbeService` 对配置 URL 执行 HTTP GET，默认超时 3 秒，按期望状态码返回满足、不满足或失败三态；它本身不执行启停。[ProbeService.swift](../../Sources/TunnelPadCore/ProbeService.swift)
- 当前 `TunnelManager.runProbes()` 由同步/异步刷新路径调用，结果只写入运行时展示状态；现有阶段证据明确登记“探针只影响展示、无后台轮询”。[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)；[v1 阶段 2 证据](../data-quality/tunnelpad-v1-stage2-features-20260829.md)
- 当前主窗口的状态刷新任务每 5 秒运行一次，但只在主窗口可见时运行；这不能作为常驻稳定性监测的所有者。[MainPanelView.swift](../../Sources/tunnelpad/MainPanelView.swift)
- `AppDelegate.applicationDidFinishLaunching` 只安装信号处理、创建菜单栏控制器并显示窗口；`TunnelManager.init` 只加载配置，当前启动路径没有调用 `Shutdown.killByPidfile` 或等价的 app 孤儿收敛流程。[AppDelegate.swift](../../Sources/tunnelpad/AppDelegate.swift)；[Shutdown.swift](../../Sources/TunnelPadCore/Shutdown.swift)
- `AppProcessExecutor` 的 `status` 只查询当前进程内存中的 `contexts`，新建的执行器不会从 pidfile 恢复上下文或识别旧子进程。[AppProcessExecutor.swift](../../Sources/TunnelPadCore/AppProcessExecutor.swift)
- `launchd` 执行器将 `keepAlive` 写入 plist，由 launchd 观察受管进程生命周期；`app` 执行器在 termination handler 收到非手动退出后，按 `throttleInterval` 延迟重启。[LaunchdPlistRenderer.swift](../../Sources/TunnelPadCore/LaunchdPlistRenderer.swift)；[AppProcessExecutor.swift](../../Sources/TunnelPadCore/AppProcessExecutor.swift)
- 现有 v1 和代码质量重构计划已冻结手动停止、删除、退出清理、过期任务保护和探针展示兼容边界；本计划是行为增强，不替代这些事实源。[TunnelPad v1 计划](tunnelpad-v1.md)；[代码质量重构计划](tunnelpad-code-quality-refactor.md)
- 当前工作树存在 Rust Core 阶段 3 的未提交修复和验证文档改动；本计划必须与这些改动隔离，待 Rust 迁移阶段 3–4 完成独立复核后才实施共享生命周期模块的稳定性行为。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 已配置 HTTP 探针可以代表本机通过隧道访问目标服务的可用性 | 隔离本机 HTTP fixture + 隧道生命周期 fake executor；确认期望状态码、连接拒绝和超时分别进入预期状态 |
| 连续 3 次失败比单次失败更能避免瞬时抖动误重启 | 失败序列 fixture：单次失败后成功不触发重启；连续三次失败只触发一次恢复流程 |
| 现有 `TunnelLifecycleCoordinator` 是 launchd/app 健康重启的安全边界 | 对两类执行器注入 bootstrap/bootout/start/stop 结果，确认重启不绕过手动停止、删除和退出代次保护 |
| 后台监测可以独立于主窗口运行且不会产生重复监测任务 | 应用生命周期与取消测试：窗口隐藏、配置重载、手动停止、删除和退出后只保留合法任务或无任务 |
| 退避四级加第 10 次熔断足以限制重启风暴 | 状态机 fixture 验证 `10 秒 → 30 秒 → 60 秒 → 5 分钟封顶`、累计 10 次后停止当前隧道并取消该隧道任务 |
| 启动时可以安全收敛 app 孤儿进程 | 隔离 pidfile + 可控子进程 fixture；验证匹配命令可终止、已退出 PID 可清理、PID 复用或身份不匹配不发信号 |

### 范围与非目标

本计划只覆盖“本机 TunnelPad 已配置 HTTP 探针的单条隧道”的后台健康恢复；无探针隧道继续使用进程存活与既有 `keepAlive` 语义。健康恢复对 `keepAlive=false` 的隧道只记录和展示失败，不自动重启。熔断只作用于当前隧道，其他隧道继续独立运行。

### 候选方案与取舍

| 方案 | 取舍 | 结论 |
|---|---|---|
| 只观察进程退出 | 与现有 v1 完全一致，但无法处理进程假死或转发失效 | 保留为无探针/兼容路径，不足以完成本计划 |
| HTTP 探针 + 后台监测 + 有界恢复 | 能验证本机业务路径，复用现有探针和生命周期边界；需要新增运行时状态机与取消保护 | **采用** |
| 新增 TCP/SSH 探测 | 覆盖面更广，但会引入端口语义、凭证、误判和额外连接管理 | 不纳入本计划 |
| 无限固定间隔重启 | 实现简单，但可能造成重启风暴和远端服务压力 | 不采用 |
| 固定退避 + 10 次熔断 | 可预测、易测试；熔断后需人工重新启动 | **采用** |
| 启动 pidfile 收敛 | 只处理已配置 app 隧道；匹配身份才终止，无法确认则告警，避免 PID 复用误杀 | **采用** |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| Rust Core 迁移阶段 3–4 完成后再实施稳定性运行时变化 | 先完成迁移及独立复核；本计划阶段 0 可并行做只读设计，阶段 1 实施必须等待前置通过 | 是（阻塞后续实现，不阻塞本阶段写计划） | 已确认（2026-08-30） |

### 用户确认的探索结论

2026-08-30 用户确认：建立独立的 TunnelPad 稳定性计划，目标包括进程仍运行但隧道不可用/假死的场景；健康信号只使用现有 HTTP 探针；后台监测不依赖主窗口是否可见；连续失败 3 次后触发恢复；恢复退避固定为 10 秒、30 秒、60 秒、5 分钟封顶；最多自动重试 10 次，第 10 次仍失败后停止当前隧道并停止该隧道全部监测、重试和自动恢复任务，其他隧道不受影响；手动启动/重启后恢复监测并清零；策略固定，不新增配置字段或设置项；本计划独立于当前 Rust Core 迁移，待其阶段 3–4 完成并通过独立复核后再实施。

2026-08-30 用户补充确认：TunnelPad 崩溃后下一次启动必须检测并安全清理 app 执行器的孤儿进程；清理当前配置隧道相关的全部残留托管任务，不能留下与 UI/运行时状态不一致的进程；无法确认 PID 身份时不得误杀无关进程。

## 不变量

- `ProbeConfig` 仍是可选的；未配置探针的隧道不进入健康恢复状态机。
- 单条隧道最多存在一个有效的健康监测/恢复协调实例；配置重载、手动停止、删除和退出必须使旧任务失效。
- 探针满足期望状态码时清零连续失败数和退避级别；不满足状态码、连接错误和超时均按一次失败计数。
- 只有 `keepAlive=true` 且非手动停止/删除/退出路径，才允许健康失败触发自动恢复。
- 失败 3 次触发一次恢复尝试；恢复尝试最多 10 次，等待时间按固定退避序列执行，超过第四级后以 5 分钟为上限。
- 第 10 次恢复仍未使探针恢复时，当前隧道必须进入已停止/人工处理状态，并取消该隧道所有后续探针、延迟重启和恢复任务；不得留下迟到任务重新拉起它。
- 手动启动或重启当前隧道会清除熔断状态、失败计数和退避状态；手动停止不会被后台任务重新拉起。
- 健康恢复不得改变其他隧道的进程、配置、探针结果或操作代次。
- 既有进程意外退出后的 `keepAlive` 语义继续有效；健康恢复不得绕过现有 launchd/app 生命周期边界。
- 启动收敛只处理配置中 `executor=app` 的隧道及其 pidfile：pidfile 无法解析或 PID 已不存在时清理 pidfile；PID 存在时必须先验证可执行文件或命令行与该隧道记录匹配，身份无法确认不得发送终止信号。
- 启动收敛必须在该 app 隧道进入正常监测/恢复状态前完成；匹配的孤儿进程按现有安全停止语义终止并清理 pidfile，停止失败必须保留错误和人工处理信息，不得谎报已清理。
- `launchd` 任务仍由 launchd 负责状态和进程托管；启动收敛不得按 pidfile 逻辑扫描或终止非 app 执行器进程。
- 不在日志、计划、测试输出或错误文案中记录私钥、AccessKey、完整远端凭证或其他敏感内容。

## 影响模块或文件

- `Sources/TunnelPadCore/ProbeService.swift`
- `Sources/TunnelPadCore/ProbeCoordinator.swift`
- `Sources/TunnelPadCore/TunnelManager.swift`
- `Sources/TunnelPadCore/TunnelLifecycleCoordinator.swift`
- `Sources/TunnelPadCore/AppProcessExecutor.swift`
- `Sources/TunnelPadCore/LaunchCtlExecutor.swift`
- `Sources/TunnelPadCore/LaunchdPlistRenderer.swift`
- `Sources/TunnelPadCore/Shutdown.swift`
- `Sources/TunnelPadCore/TunnelPaths.swift`
- `Sources/TunnelPadCore/TunnelRuntimeState.swift`
- `Sources/tunnelpad/AppDelegate.swift`
- `Sources/tunnelpad/MainPanelView.swift`
- `Sources/tunnelpad/TunnelDetailComponents.swift`
- `Tests/TunnelPadStabilityTests/`（本计划后续新增的独立测试目录；迁移差分 harness 仍由 Rust 迁移计划负责）
- `rust/tunnelpad-core/`（仅在 Rust Core 迁移阶段 3–4 完成并通过独立复核后，按迁移后的实际边界同步）
- `docs/data-quality/`
- `docs/PLAN_MAP.md`

实现时必须先对上述符号执行 GitNexus upstream impact 分析；任何 HIGH/CRITICAL 结果都要在修改前记录并重新确认范围。提交前必须执行 GitNexus `detect_changes()`，确认只影响稳定性计划声明的模块和执行流。

## 公共契约变化

当前计划不新增公共 API、HTTP API、`config.json` 字段或迁移文件。`probe`、`expectedStatuses`、`keepAlive` 和 `throttleInterval` 的既有序列化与兼容语义保持不变。启动时的 pidfile 收敛属于内部生命周期行为，保持现有 pidfile 路径；若实现需要改变 pidfile 格式，必须另行记录兼容和迁移边界。

新增的失败计数、退避级别、恢复尝试次数、熔断状态和取消令牌均属于运行时内部状态，不落盘、不跨进程持久化。若后续需要让用户配置这些策略，必须另立计划并重新进行 Schema、UI、兼容性和回滚评估。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定现状基线、最小复现、状态契约、失败/回滚边界和实施门禁 | 用户确认结构化探索结论 | 只读审计、隔离 fixture 设计、现有测试与治理检查 | 设计中 |
| 阶段 1 | 实现独立后台监测、启动孤儿进程收敛与单隧道健康恢复状态机 | 阶段 0 独立准入通过；Rust Core 迁移阶段 3–4 已完成并通过独立复核 | 状态机、启动收敛、取消、代次、窗口隐藏和成功清零测试 | 待实施 |
| 阶段 2 | 接入 launchd/app 两类生命周期，完成 10 次熔断停止和手动恢复 | 阶段 1 实现与单元/契约测试通过 | fake executor、故障注入、迟到任务和回滚测试 | 待实施 |
| 阶段 3 | 隔离 demo 与受控应用验收、文档和发布门禁收口 | 阶段 2 独立复核通过 | `swift test`、`cargo test`（适用时）、构建、AX/应用冒烟和治理检查 | 待实施 |

## 当前阶段

### 范围

阶段 0 只做稳定性缺口的现状确认、最小可观察复现、启动孤儿进程收敛基线、状态机契约和后续实现门禁设计。不修改 Swift/Rust 稳定性实现，不修改配置，不启停真实用户隧道，不创建新的 Schema 字段。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 设计中 |
| Step 0 | 基线类型已确定为“缺陷现状快照 + 隔离最小复现”；现有源码和阶段证据已查证，独立 Step 0 证据尚待落盘 |
| 样本矩阵 | 8 行，覆盖现有探针/刷新边界、进程保活、假死复现、失败状态机、启动孤儿收敛、两类执行器隔离和治理检查；见下方样本矩阵 |
| 验证方式 | 只读源码核对、隔离 fixture、现有测试清单、后续失败回归测试和 `plan-governance-cli check . --strict-readiness` |
| 失败/回滚边界 | 阶段 0 不改变运行状态；实现阶段按独立提交回滚，不覆盖当前 Rust 阶段 3 未提交改动；任何真实隧道误操作立即停止该场景 |
| 当前阻塞项 | Rust Core 迁移阶段 3–4 的独立复核尚未完成；它阻塞阶段 1 实施，但不阻塞本阶段建立计划和补齐基线 |
| 最新独立准入复核 | 尚未进行；阶段 0 尚未达到“待实施”标准 |

### 实施步骤

1. 记录当前工作树、源码/测试边界和 Rust 迁移前置状态，不将既有未提交改动归入本计划。
2. 补充两个不操作真实用户隧道的最小复现：进程保持存活且 HTTP 探针连续失败；TunnelPad owner 消失后 pidfile 指向仍存活的 app 子进程。
3. 冻结健康恢复状态机以及启动孤儿收敛的输入、身份校验、计数、退避、熔断、手动恢复和取消语义。
4. 设计 launchd/app 两类执行器的 fake/fixture 矩阵以及失败和回滚边界。
5. 等 Rust 迁移阶段 3–4 完成独立复核后，重新核对影响面，再申请阶段 1 准入。

### Step 0 证据

基线类型：缺陷修复与架构探索结合的现状快照。当前已查证的替代基线是：`ProbeService` 只执行 HTTP GET；`TunnelManager` 只在刷新/启停路径调度探针；主面板 5 秒刷新受窗口可见性限制；`keepAlive` 只由 launchd 或 app 执行器在进程退出时负责拉起；启动路径没有读取 app pidfile 或收敛孤儿进程。上述事实由源码、v1 阶段 2 证据和代码质量重构计划共同锚定。

尚未完成的 Step 0 证据包括两项可执行隔离最小复现：“进程仍存活、探针持续失败、现有逻辑不触发恢复”以及“owner 消失后 pidfile 指向存活 app 子进程、下次启动当前逻辑不收敛”。复现必须使用 fake lifecycle/本机隔离 HTTP fixture/可控子进程，不得杀掉或修改真实用户隧道；完成后追加到本节和阶段证据文档。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前工作树与 Rust 阶段 3 未提交改动 | `git rev-parse HEAD && git status --short && git diff --stat` | 记录 HEAD、既有未提交文件和稳定性计划边界；不把 Rust 改动归入本计划 | 输出缺失、误覆盖既有 diff 或出现未声明的稳定性代码改动 | 阶段 0 证据文档 |
| 2 | 现有探针与刷新实现 | `rg -n 'runProbes|ProbeService|Task\.sleep|isMainWindowVisible' Sources Tests --glob '*.swift'`；只读核对 v1 阶段 2 证据 | 复现“探针只展示、刷新受窗口可见性限制、无健康恢复调用”的现状 | 找不到事实源、源码与证据矛盾或出现未登记行为变化 | 阶段 0 证据文档 |
| 3 | 进程退出保活基线 | `swift test --filter AppProcessExecutorTests`（Rust 迁移前后分别记录适用结果） | 现有意外退出、手动停止和延迟重启契约可复现 | 既有 keepAlive 语义失败或测试触碰真实用户隧道 | 阶段 0 证据文档 |
| 4 | 隔离假死最小复现 | 新增仅使用 fake executor + 注入式 ProbeService 的测试；命令：`swift test --filter StabilityBaselineTests` | 进程状态保持 running、探针连续失败 3 次；基线版本不触发自动恢复，明确缺口 | 测试无法稳定复现、触发真实 launchctl/SSH，或结果依赖主窗口 | 阶段 0 证据文档与测试文件 |
| 5 | 状态机候选契约 | 失败序列 `[fail, fail, fail, success]`、十次失败序列、手动 stop/start、删除和退出取消序列 | 明确计数、退避、成功清零、第 10 次熔断和迟到任务失效边界 | 计数漂移、成功不清零、熔断后仍拉起、其他隧道被修改 | 阶段 0 证据文档；阶段 1 契约测试 |
| 6 | 两类执行器隔离 | launchd/app fake executor 注入 bootstrap/bootout/start/stop 结果；不调用真实 `launchctl` 或 SSH | 两类执行器均遵守生命周期边界，其他隧道不受影响 | 出现真实外部副作用、跨隧道操作或迟到任务 | 阶段 0 证据文档；阶段 1–2 契约测试 |
| 7 | 启动孤儿进程基线 | 新增仅使用隔离 pidfile + 可控子进程的测试；命令：`swift test --filter StartupReconciliationTests` | 匹配的 app 子进程被安全终止并清理 pidfile；已退出 PID 可清理；PID 复用或身份不匹配不发信号 | 误杀无关进程、残留匹配子进程、pidfile 与状态不一致或触碰真实用户隧道 | 阶段 0 证据文档与测试文件 |
| 8 | 治理与反向引用 | `plan-governance-cli check . --strict-readiness`；`git diff --check`；`rg -n 'tunnelpad-stability|健康恢复|稳定性|keepAlive|探针|孤儿进程|pidfile|草案为准|以草案为事实源|详见草案' docs | 新计划链接、状态、依赖和关键术语一致；无新增治理 ERROR；旧草案不成为事实源 | 计划未被索引、重复定义、状态漂移或出现空白错误 | `docs/PLAN_MAP.md` 与阶段 0 证据文档 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 需求探索/计划建立 | 用户确认独立稳定性计划、HTTP-only、3 次失败、固定退避、最多 10 次并熔断停止、启动时收敛 app 孤儿进程；确认等待 Rust Core 迁移阶段 3–4 独立复核后实施 | 本计划“需求探索”与 `docs/PLAN_MAP.md` | 进行中 | Codex |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 只读治理检查 | 新计划写入前执行 `plan-governance-cli check . --strict-readiness`，既有仓库检查通过并保留一项既有 warning | 命令输出；本计划尚未落盘时的基线 | 通过 | Codex |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代独立准入复核。

### Attestation 说明

本计划完成快照沿用 `docs/attestations/<plan>.json` 兼容格式。阶段 0 未完成前不创建完成快照；阶段完成或发布门禁需要快照时，使用治理 CLI 生成并保留独立复核状态。

### 验证方式

阶段 0 使用只读源码核对、隔离最小复现、启动孤儿进程隔离 fixture、现有 keepAlive 回归测试、失败序列状态机 fixture、GitNexus 影响分析和治理检查。阶段 1–2 使用注入式 fake executor 验证 launchd/app 分支，不调用真实用户的 `launchctl` 或 SSH；阶段 3 才在隔离 demo 和受控应用冒烟中验证编排、日志、UI 状态和取消边界。

完成全计划时至少运行并记录：

- `swift test`；若 Rust Core 迁移后的事实源适用，则同时运行 `cargo test` 和迁移差分测试。
- 稳定性专项测试，覆盖单次失败、连续三次失败、成功清零、退避四级、第 10 次熔断、启动孤儿进程收敛、手动恢复、手动停止、删除、退出和窗口隐藏。
- 隔离 demo 应用冒烟，确认两类执行器的重启/停止状态、日志和 UI 展示一致，且其他隧道不受影响。
- `git diff --check`、`plan-governance-cli check .`、`plan-governance-cli check . --strict-readiness`，以及提交前 GitNexus `detect_changes()`。

### 测试覆盖率

当前没有为本计划新增覆盖率证据。完成阶段 1–2 后以专项测试矩阵和 `swift test`/`cargo test` 输出记录关键状态机、执行器分支、取消代次和回滚边界；若项目引入行覆盖率工具，再补充百分比和关键模块覆盖情况，不以全量测试通过替代状态机分支覆盖。

### 完成条件

- 阶段 0 Step 0 现状快照和假死最小复现已落盘，且不操作真实用户隧道。
- 阶段 1–2 的状态机、后台监测、两类执行器接入、取消和代次保护测试通过。
- 连续 3 次失败、固定退避、最多 10 次、第 10 次停止并取消当前隧道任务、手动恢复和成功清零均有可复现证据。
- `keepAlive=false`、手动停止、删除、退出和其他隧道隔离边界均有反证测试。
- TunnelPad 崩溃后下次启动的 app pidfile 收敛有证据：匹配孤儿被终止、过期 pidfile 清理、身份不匹配不误杀，且 launchd 状态不被 pidfile 清理破坏。
- 隔离 demo 与受控应用验收通过，未产生计划外 Schema、真实隧道或敏感数据变化。
- 最新独立准入/完成复核明确通过，`PLAN_MAP.md`、阶段证据、测试证据和状态同步。
- 治理普通检查和严格准入检查通过；提交前 `detect_changes()` 只报告本计划预期影响。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 尚未进行 |
| 阶段 | 阶段 0 |
| 结论 | 尚未达到待实施标准 |
| 证据 | Step 0 隔离假死复现和样本矩阵尚待执行；Rust Core 迁移阶段 3–4 前置尚未完成独立复核 |
| 复核者 | 尚未指定 |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| - | - | - | - | - | - |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 稳定性实现何时开始 | Rust Core 迁移阶段 3–4 完成并通过独立复核后，再进入本计划阶段 1；之前只补基线和准入证据 | 是（阶段 1 实施） | 顺序已确认，等待前置证据 |

## 风险和回滚

- HTTP 探针可能代表的是目标业务服务，而不是 SSH 链路本身；错误 URL、鉴权策略变化或远端服务停机可能触发恢复。通过只支持现有 HTTP 探针、要求期望状态码显式配置、连续失败阈值和最多 10 次熔断降低误判。
- launchd 自身也有 `KeepAlive` 和节流语义；健康恢复若绕过既有 lifecycle coordinator，可能与 launchd/app 的手动停止发生竞态。所有恢复必须通过统一生命周期边界，并以 generation/取消令牌阻止迟到任务。
- 退避或计数状态若按全局维护，可能把一条隧道的故障传播到其他隧道。状态必须按 tunnel id 隔离，并用多隧道 fixture 反证。
- PID 可能被系统复用；启动收敛不得仅凭 pidfile 中的整数发送信号，必须先做进程身份校验，无法确认时保守告警并保留人工处理。
- app 子进程可能无法按时终止；必须沿用现有安全停止语义记录失败，不得把未终止进程报告为已清理。
- 阶段 3–4 尚未完成时修改共享执行器会与 Rust 迁移冲突。实现前重新运行影响分析；若前置复核未通过，稳定性阶段 1 保持未实施。
- 若实现导致误重启、状态倒灌或无法可靠熔断，按阶段独立提交回滚稳定性实现，保留 `config.json` 和既有 TunnelPad v1 运行契约；不得用配置重写或删除真实 plist 作为回滚手段。
- 任何真实用户隧道验收只允许在用户明确指定、可观察、可恢复的窗口内进行；发现 stop/bootout、删除或退出清理异常时立即停止该场景并保留配置。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad v1 隧道管理应用](tunnelpad-v1.md)
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)
- [v1 阶段 2 功能与验收记录](../data-quality/tunnelpad-v1-stage2-features-20260829.md)
- 当前仓库暂无与本计划对应的 ADR 或 migration 文件；若实施中产生持久架构决策或兼容迁移，先补充对应文档，再更新本节。
