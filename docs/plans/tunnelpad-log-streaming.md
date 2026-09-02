# 计划：TunnelPad 日志事件流与面板生命周期

- 状态：已完成
- 当前阶段：-
- 最后更新：2026-09-01
- 前置：`tunnelpad-v1`、`tunnelpad-code-quality-refactor` 和 `tunnelpad-rust-migration` 阶段 5 已完成并关闭；阶段 0–3 均已独立复核并完成，日志事件流与面板生命周期计划已收口

本计划独立处理 TunnelPad 的日志采集、内存缓存、追加事件和面板生命周期，不并入隧道探针健康恢复计划。阶段 0 已与稳定性计划阶段 0 并行完成基线和准入设计；Rust Core 迁移阶段 5 已完成并关闭，本计划阶段 1 已通过自身独立准入并完成 Core 实现，不与 Rust Core owner 并行修改共享执行器。日志计划阶段 0–3 已完成；稳定性计划阶段 0 已完成并通过独立准入，当前转入阶段 1 设计，双方后续若触及 `TunnelManager`、`TunnelRuntimeState`、主面板和共享测试目录，仍必须使用单一编辑窗口串行。当前实现范围先按 `launchd` owner 设计，未来 `app` 执行器重新开发后再补充对应日志采集范围。

## 背景

当前日志界面由 `LogView` 在主窗口可见时每 2 秒读取一次日志文件末 500 行，比较完整文本后更新 SwiftUI 状态；日志内容未变化时虽会跳过状态写入，但日志显示仍由 UI 定时任务驱动。阶段 5 后当前运行路径只保留 `launchd`，通过 plist 的 `StandardOutPath`/`StandardErrorPath` 由系统写文件；历史 v1 的 `app` stdout/stderr 管道不再属于当前实现。

目标是改为“日志追加事件触发 UI 更新”：日志采集与面板生命周期解耦，内存缓存保存有界的近期日志，追加新日志时发布带隧道 ID 和单调版本的事件，UI 只订阅当前隧道并在事件到达时更新。日志文件继续保留，作为崩溃、重启、面板关闭期间和 `launchd` 日志的持久来源。

面板关闭/打开和隧道切换必须成为明确的订阅生命周期：关闭只停止 UI 订阅，不停止日志采集；打开要先建立订阅再取得快照，避免漏事件；切换要使旧隧道事件失效并隔离新隧道日志，避免串日志或重复订阅。

## 目标

- 用内存日志缓冲和追加事件替代 `LogView` 的固定周期文件轮询，日志真正追加时才触发 UI 更新。
- 当前阶段支持 `launchd`：launchd 继续写文件并由后台日志采集器转化为追加事件；`app` 捕获进程输出的范围留待未来 app 计划。
- 保留现有日志路径和可恢复的文件记录；内存缓存只作为实时显示与短期快照来源，不成为唯一日志来源。
- 每条隧道的本地持久日志文件最多保留最近 2000 行；超过上限时淘汰更旧记录，且该文件上限独立于内存缓存容量。
- 面板关闭或隐藏时继续采集日志；重新打开后显示关闭期间产生的最新缓存，并在必要时从文件补齐。
- 切换隧道时取消旧订阅、加载新隧道快照并阻止旧事件倒灌；每条隧道的日志、版本和订阅相互隔离。
- 自动滚动只在开启且收到新日志/新快照时滚到底部；关闭自动滚动时允许自由回看历史，新增日志不改变用户位置。
- 用隔离 fixture 证明无定时 UI 轮询、无漏日志、无重复事件、无串隧道、无迟到事件和无计划外真实隧道副作用。

## 非目标

- 不改 `config.json` Schema、HTTP API、隧道 ID、launchd label、日志路径或 stdout/stderr 路由；本地日志文件保留上限属于本计划明确的行为变化。
- 不改探针三态、隧道状态、自动恢复、重试上限或孤儿进程收敛策略；健康恢复继续由[稳定性计划](tunnelpad-stability.md)负责。
- 不采用纯内存日志；TunnelPad 崩溃/重启后仍应能够从日志文件恢复近期内容。
- 不把“面板打开”作为日志采集启动条件；面板关闭期间不停止 `app` 管道、`launchd` 文件采集或内存缓冲。
- 不让 UI 继续使用固定周期 Timer 作为日志变化检测机制；后台对 `launchd` 文件的增量监听/读取不等于 UI 轮询。
- 不在真实用户隧道上注入日志故障、替换真实 plist 或改变真实日志文件；所有行为测试使用隔离目录和可控子进程。
- 不在本计划阶段 0 独立准入前修改共享执行器或日志核心；Rust Core 迁移阶段 5 独立收尾复核完成前，后续 owner 变化由迁移计划先行收口。

## 需求探索

### 已确认事实

- 当前 `LogView` 在主窗口可见时每 2 秒执行 `load()`，读取日志文件末 500 行；只有完整文本或文件存在状态变化时才写入 `@State`。[LogView.swift](../../Sources/tunnelpad/LogView.swift)
- 当前 `LogView` 使用 AppKit `NSTextView`，文本变化后由 `scrollToEndOfDocument` 实现自动滚动；自动滚动开关关闭时不主动滚动。[LogView.swift](../../Sources/tunnelpad/LogView.swift)
- 阶段 5 删除前，v1 的 `app` 执行器曾使用 `FileHandle` 将 stdout/stderr 追加到日志文件；该历史语义保留在 [TunnelPad v1 计划](tunnelpad-v1.md#app-执行器语义)，不再作为当前源码路径。
- 当前 `launchd` plist 把 stdout/stderr 指向同一日志文件，日志由 launchd 子进程直接写入。[LaunchdPlistRenderer.swift](../../Sources/TunnelPadCore/LaunchdPlistRenderer.swift)
- 当前日志文件路径由 `TunnelPaths.logURL` 派生，已有退出、删除和日志清理语义；本计划不改变该路径。[TunnelPaths.swift](../../Sources/TunnelPadCore/TunnelPaths.swift)
- 用户于 2026-08-30 确认：每条隧道的本地持久日志文件最多保留最近 2000 行；超过上限淘汰更旧记录，不新增配置项。该上限与进程内内存缓存容量分开定义。
- v1 已冻结“显示日志文件末 500 行、2 秒自动刷新”的旧行为；本计划是经确认的行为增强，不把新实现伪装成 v1 原有事实。[TunnelPad v1 计划](tunnelpad-v1.md)
- Rust Core 迁移计划要求首轮保持日志行为 parity；阶段 5 完成后，本计划实现阶段继续以 Rust `launchd` owner 的已冻结契约为边界。[TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 未来 `app` 执行器的 stdout/stderr 可以在不丢字节的前提下同时写入文件并解析为日志追加事件 | 未来 app 计划另行冻结；本计划不实现或验证 app 管道 |
| `launchd` 文件可以通过增量监听和 offset 读取转化为同一套追加事件 | 隔离日志文件写入/截断/重建 fixture；验证只读取新增字节、文件替换后重新定位且不重复 |
| 每条隧道独立的有界内存缓存可以满足面板重开和切换需求 | 多隧道 fixture；验证缓存隔离、容量淘汰、关闭期间追加和重开快照 |
| 每条隧道本地日志文件最多保留最近 2000 行，且裁剪不与 `launchd` 写入冲突 | 隔离文件写入、超过 2000 行、并发追加、截断/替换和异常中断 fixture；验证只淘汰旧记录且保留最新完整内容 |
| 订阅与快照可以原子衔接而不漏掉打开/切换瞬间的事件 | 注入 snapshot 前后追加事件的并发序列；验证单调版本连续、无重复和无旧隧道倒灌 |
| 追加事件比固定周期轮询更适合当前 UI | 移除 Timer 的测试 fixture；确认无新日志时无 UI 更新，新日志到达后只触发对应隧道更新 |
| 现有 `NSTextView` 可以保持用户滚动位置并响应事件驱动更新 | UI/表示层测试或受控应用冒烟；覆盖自动滚动开关、面板重开和切换隧道 |

### 范围与非目标

本计划覆盖单个 TunnelPad 进程内的当前 `launchd` 日志实时显示链路：launchd 输出进入每隧道日志存储，日志存储产生追加事件，当前面板订阅对应隧道并渲染快照。关闭面板、重新打开、切换隧道、自动滚动和应用重启后的文件恢复均属于范围；未来 app 输出接入另立计划。

内存缓存是有界的运行时缓存，不跨进程持久化；文件继续作为持久记录，但每条隧道的本地文件最多保留最近 2000 行。面板关闭不停止后台采集，应用重启后先从文件恢复近期内容，再继续接收新的追加事件。日志采集本身不改变隧道启停或健康恢复策略。

### 候选方案与取舍

| 方案 | 取舍 | 结论 |
|---|---|---|
| UI 继续每 2 秒读取文件 | 改动小，但 UI 更新有延迟，面板生命周期和日志采集耦合，无法表达追加事件 | 保留为现状基线，不采用 |
| 纯内存日志 | 实现简单、实时，但崩溃/重启和 `launchd` 面板关闭期间日志无法恢复 | 不采用 |
| 内存缓存 + 文件保留 + 追加事件 | UI 实时、可限流，保留崩溃恢复和 `launchd` 兼容；需要新增存储、采集和订阅边界 | **采用** |
| 只用文件监听并让 UI 订阅文件事件 | 可覆盖 launchd，但 UI 仍需自行解析文件，app/launchd 语义不统一，切换和快照更复杂 | 不采用 |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 内存缓存容量 | 每条隧道固定最多 500 条、单行最多 8000 字符；不新增配置项，达到上限淘汰最旧条目，版本继续单调递增 | 否 | 已确认（2026-09-01） |
| 本地日志文件 2000 行上限的裁剪时机与并发写入安全 | 在不改变 `launchd` stdout/stderr 路由的前提下，由日志 owner 采用可恢复的裁剪/轮换机制；阶段 0 用并发追加、截断、替换和异常中断 fixture 冻结边界 | 是（阶段 1 实施） | 阶段 0 待设计 |
| Rust Core 迁移与日志事件流的实施顺序 | Rust Core 迁移阶段 5 已完成 `launchd` owner；本计划阶段 0 可继续设计，阶段 1 实施仍需本计划自身独立准入，并重新确认共享日志 owner | 是（阻塞阶段 1 实施） | 已完成前置（2026-08-31） |

### 用户确认的探索结论

2026-08-30 用户确认建立独立的日志计划，采用“内存缓存 + 文件保留”，当前期望为“日志追加事件触发 UI 更新”，而不是 UI 固定周期读取并比较日志文本。

用户同时确认：面板关闭/隐藏时不停止日志采集；重新打开时恢复当前隧道的日志订阅并补显示期间产生的内容；切换隧道时取消旧订阅、加载新隧道快照并阻止旧日志事件串入。自动滚动只在开启时跟随新日志，关闭时保留用户回看位置。

用户同时确认：每条隧道的本地持久日志文件最多保留最近 2000 行；该限制只约束本地文件保留量，不改变日志路径、stdout/stderr 路由或进程内内存缓存的独立上限，且暂不开放为配置项。

2026-09-01 用户确认：每条隧道的进程内内存缓存最多保留 500 条日志，单行最多 8000 字符；缓存不开放配置，达到上限时淘汰最旧条目，日志版本仍继续单调递增。该上限独立于本地文件最近 2000 行保留上限。

2026-09-01 用户确认日志事件流计划与稳定性计划的共享边界：两个计划的阶段 0 可以并行；日志阶段 1 仍需本计划自身独立准入，且与稳定性计划共享模块的实现改动必须串行，不把稳定性作为日志阶段 0 的前置条件。日志阶段 0–3 已完成后，稳定性计划重新开始自己的阶段 0，日志行为和验收边界不被覆盖。

## 不变量

- 每条隧道拥有独立的日志缓冲、追加版本和订阅身份；一条隧道的事件不得更新另一条隧道的 UI。
- 日志追加事件只由采集器接受新日志后产生；无新日志时不靠 Timer 触发 UI 更新。
- 面板关闭/隐藏只取消或暂停 UI 订阅，不停止 `launchd` 增量采集、文件写入或内存缓存；未来 app 管道另立计划。
- 面板打开必须使用“订阅与快照无漏接”的衔接方式；打开前后到达的事件最多应用一次，版本不能倒退。
- 切换隧道必须使旧订阅和旧事件代次失效；新隧道先显示自身快照，再接收自身追加事件。
- `autoScroll=false` 时新日志仍更新内容，但不得主动改变滚动位置；`autoScroll=true` 时收到新内容后滚到最新位置。
- 内存缓存有固定上限，淘汰旧条目不影响文件记录；缓存达到上限后日志版本仍单调递增，不能以条数变化作为唯一更新判断。
- 每条隧道的本地持久日志文件在裁剪完成后最多保留最近 2000 行；裁剪只淘汰更旧记录，不改变日志路径、stdout/stderr 路由或当前隧道关联。
- 应用重启后可以从现有日志文件恢复近期快照；文件不存在或无法读取时只显示明确的缺失/错误状态，不伪造日志内容。
- 日志文件路径、删除清理、退出清理和敏感数据保护继续遵守 v1 既有边界。

## 影响模块或文件

- `Sources/TunnelPadCore/LaunchdPlistRenderer.swift`（保持 plist 文件日志契约；若实现无需改动仍需纳入 parity 检查）
- `Sources/TunnelPadCore/LogTail.swift`
- `Sources/TunnelPadCore/TunnelPaths.swift`
- `Sources/TunnelPadCore/TunnelManager.swift`
- `Sources/TunnelPadCore/TunnelRuntimeState.swift`
- `Sources/tunnelpad/LogView.swift`
- `Sources/tunnelpad/MainPanelView.swift`
- `Sources/tunnelpad/TunnelDetailComponents.swift`
- `Tests/TunnelPadCoreTests/` 与本计划后续新增的日志事件/生命周期测试 fixture
- `rust/tunnelpad-core/`（Rust Core 迁移阶段 5 完成后承载当前 `launchd` 日志 owner；未来 app 执行器另立范围）
- `docs/data-quality/`
- `docs/PLAN_MAP.md`

实现时必须先对上述将要修改的符号执行 GitNexus upstream impact 分析；任何 HIGH/CRITICAL 结果都要在修改前记录并重新确认范围。提交前必须执行 GitNexus `detect_changes()`，确认只影响日志事件流、面板生命周期及其声明的执行流。

## 公共契约变化

当前计划不新增 HTTP API、`config.json` 字段或迁移文件。日志文件路径、stdout/stderr 路由、复制内容和既有删除/退出清理语义保持不变；新增本地持久日志保留策略：每条隧道最多保留最近 2000 行。进程内新增 `LogSnapshot`、`LogEvent` 和 `LogSession` 运行时契约；每条隧道内存缓存最多 500 条，单行最多 8000 字符。

新增的日志缓冲、追加事件、订阅句柄、单调版本和面板代次属于进程内运行时状态，不落盘、不跨进程持久化。若后续需要让用户配置缓存容量、采集策略或持久化格式，必须另立计划并重新评估 Schema、兼容性和回滚。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定现状基线、事件/缓存契约、面板生命周期、失败/回滚边界和实施门禁 | 用户确认结构化探索结论 | 只读源码核对、最小 fixture、治理检查 | 已完成 |
| 阶段 1 | 实现 `launchd` 日志采集、本地文件 2000 行保留上限、内存缓存和追加事件 | 阶段 0 独立准入通过；Rust Core 迁移阶段 5 已完成 | 文件增量、文件保留上限、缓存上限、版本连续性测试 | 已完成 |
| 阶段 2 | 接入面板打开/关闭、隧道切换和自动滚动 | 阶段 1 日志事件契约与测试通过 | 订阅取消、快照衔接、无漏/无重/无串和滚动位置测试 | 已完成 |
| 阶段 3 | 隔离 demo 与受控应用验收、文件恢复、文档和发布门禁收口 | 阶段 2 独立复核通过 | `swift test`、`cargo test`（适用时）、构建、应用冒烟和治理检查 | 已完成 |

## 当前阶段

### 范围

阶段 3 已完成隔离 demo、受控应用验收、文件恢复、Release 构建和治理门禁。阶段 1 的 `launchd` 文件采集、每隧道内存缓存、追加事件和本地文件 2000 行保留上限，以及阶段 2 的面板打开/关闭、隧道切换、事件版本过滤和自动滚动行为，均已由隔离 fixture 或受控 App 验证。全程只使用隔离目录和 fake/fixture，不调用真实用户的 `launchctl`、SSH、隧道或日志路径；未来 app 输出不纳入本计划。

阶段 0 已完成并通过独立准入，阶段 1 已完成实现与专项回归，阶段 2 已完成受控 App 验收。阶段 3 与稳定性计划共享的 `TunnelManager`、`TunnelRuntimeState`、主面板和测试目录必须使用单一编辑窗口串行推进；稳定性计划文档和测试保留其自身范围，不被本计划覆盖。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 阶段 2 的隔离 App 冒烟已通过：追加事件即时显示、关闭/重开恢复最新快照、A/B 切换隔离、关闭自动滚动保持回看位置；阶段 3 的 Rust/Swift 回归、Release target/dylib、隔离 Release App 签名与启动校验、最终治理门禁均已通过 |
| 样本矩阵 | 阶段 1 的 `LogEventStoreTests` 10/10、Swift 全量 101/101、Rust 50+1 差分、debug/Release 隔离 App、窗口生命周期、滚动位置、锁失败重试和反向引用均已执行并留证 |
| 验证方式 | `xcodebuildmcp swift-package test/build`、`cargo test/build --release`、隔离 debug/Release App AX 冒烟、签名/Info.plist、反向引用和治理检查；不以编译或源码快照替代行为 fixture |
| 失败/回滚边界 | 仅修改当前日志事件实现及其测试；文件裁剪采用原位、可恢复、失败保留原文件；不覆盖 Rust owner、plist 路由、真实隧道或真实日志；阶段 1 可独立回滚到现有文件快照显示路径 |
| 当前阻塞项 | 无。`TunnelManager` upstream impact 为 CRITICAL，但改动已集中在本编辑窗口并完成回归与 `detect_changes()`；稳定性阶段 0 已完成，阶段 1 仍为独立设计/准入边界，后续共享改动继续保持独立边界 |
| 最新独立准入复核 | 2026-09-01 通过：阶段 3 已完成标准；Rust/Swift 回归、Release 构建、隔离 App 验收、治理检查和反向引用均已具备证据 |

### 实施步骤

1. 阶段 1 已完成：实现可分片 UTF-8 的日志解析、每隧道有界缓存、单调版本快照和 `launchd` 文件增量监听。
2. 阶段 1 已完成：处理追加、截断、替换、缺失、读取错误，并实现每隧道日志文件最近 2000 行的安全原位裁剪。
3. 阶段 1 已完成：通过事件、缓存、文件恢复、版本连续性和多隧道隔离 fixture；文件裁剪失败保留原文件并延后重试。
4. 阶段 2 已完成：将面板任务绑定窗口可见性与隧道 ID，确保打开时订阅/快照衔接、关闭取消 UI 订阅、切换隔离旧事件；补齐 `WindowGroup` 重开时的可见性同步。
5. 阶段 3 已完成：Rust/Swift 回归、Release 构建、隔离 demo/应用验收、治理检查和独立完成复核均通过。

### Step 0 证据

基线类型：行为迁移现状快照 + 隔离文件 fixture。阶段 0 已证明当前 `LogView` 依赖 2 秒 Timer 和 `LogTail` 末 500 行读取，当前 `launchd` 通过同一日志文件承载 stdout/stderr，且当前物理文件没有 2000 行裁剪。`LogStage0BaselineTests` 专项 6/6、阶段 0 复核时 Swift Package 全量 89/89 通过，运行只使用临时目录；证据见[阶段 0 基线证据](../data-quality/tunnelpad-log-streaming-stage0-20260831.md)。

阶段 1 在该基线上冻结实现契约：每隧道内存缓存最多 500 条，单行最多 8000 字符；本地文件最多保留最近 2000 行；事件携带 tunnel ID、单调版本和完整快照；文件变化由后台采集器驱动，UI 不使用 Timer。阶段 1 实现专属 fixture 已验证分片 UTF-8、追加/截断/替换、缓存/文件上限、版本连续性、读取错误和多隧道隔离，不依赖真实隧道或真实日志文件。阶段 2 的生命周期与表示层证据见[阶段 2 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md)。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 阶段 1 已验证的 Core 事件流 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests` | 10/10 通过；追加、watcher、分片 UTF-8、500/2000 上限、替换、锁失败、隔离、重开和错误状态均成立 | 任一专项测试失败，或依赖真实隧道/日志路径 | 阶段 1 Step 0 与阶段 2 Step 0 证据 |
| 2 | 面板关闭/打开 | 运行 `LogEventStoreTests.testClosingAndReopeningUsesLatestSnapshotWithoutStoppingCollector`；核对 `LogView` `.task(id:)` 与 `session.cancel()` | 关闭只取消 UI session；重开获得关闭期间最新快照，不重复订阅 | 关闭停止 collector、重开漏日志/重复，或任务未取消 | 阶段 2 Step 0 证据 |
| 3 | 隧道切换和迟到事件 | 运行 `LogEventStoreTests.testTwoTunnelsKeepEventsAndVersionsIsolated`；核对 `TunnelDetailComponents` 的 `.id(tunnel.id)` 和 LogView tunnel/version guard | A/B 缓存、版本和订阅隔离；旧事件不能更新当前隧道 | 串日志、旧事件倒灌、版本倒退或订阅无法失效 | 阶段 2 Step 0 证据 |
| 4 | 自动滚动开关 | 静态核对 `LogTextView.updateNSView` 的 `autoScroll` 分支，并执行全量 Swift Package 测试 | 开启时新内容滚底；关闭时不主动调用 `scrollToEndOfDocument` | 关闭自动滚动仍强制滚底，或日志内容不更新 | 阶段 2 Step 0 证据 |
| 5 | 无固定 Timer 的日志 UI | `if rg -n 'Timer\.publish|Task\.sleep|LogTail|load\(\)' Sources/tunnelpad/LogView.swift; then exit 1; else echo pass; fi` | LogView 无固定 Timer、`LogTail` 或文件轮询；只由 session 事件更新 | 重新出现日志 Timer/轮询或 UI 自行读取文件 | 阶段 2 Step 0 证据 |
| 6 | 构建与回归 | `xcodebuildmcp swift-package test --package-path .` | 当前工作树全量测试通过；不改变稳定性计划的独立测试边界 | 失败、并发改动越界或真实资源被触碰 | 阶段 2 Step 0 证据 |
| 7 | 受控应用冒烟 | 使用 xcodebuildmcp 的隔离构建/运行入口；不连接真实隧道，不写标准日志路径 | 关闭/重开/切换/滚动行为在应用表示层可观察且无状态倒灌 | 无法观察生命周期、出现串日志/迟到更新或影响隧道状态 | 阶段 2 Step 0 与阶段 3 Step 0 |
| 8 | 阶段 3 回归与发布门禁 | `cargo test --manifest-path rust/Cargo.toml`；`cargo build --release --manifest-path rust/Cargo.toml`；`xcodebuildmcp swift-package test --package-path .`；`xcodebuildmcp swift-package build --package-path . --target-name tunnelpad --configuration release`；隔离 Release App 校验 | Rust 50+1、Swift 101/101、Release 构建/签名/启动和文件恢复通过 | 任一回归、产物、签名或隔离启动失败 | 阶段 3 Step 0 证据 |
| 9 | 治理与反向引用 | `plan-governance-cli check . --strict-readiness`；`plan-governance-cli graph validate .`；`git diff --check`；`rg -n 'tunnelpad-log-streaming|日志事件|内存缓存|本地日志|2000 行|500 条|8000 字符|面板关闭|切换隧道|草案为准|以草案为事实源|详见草案' docs` | 索引、阶段、关键边界一致；无治理 ERROR 或旧草案重新成为事实源 | 计划漂移、重复定义、反向引用错误或治理失败 | `docs/PLAN_MAP.md` 与阶段证据 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 需求探索/计划建立 | 用户确认独立日志计划、内存缓存加文件保留、日志追加事件驱动 UI，并纳入面板关闭/打开与隧道切换生命周期 | 本计划“需求探索”与 `docs/PLAN_MAP.md` | 进行中 | Codex |
| 2026-08-30 | 需求确认 | 用户确认每条隧道的本地持久日志文件最多保留最近 2000 行；该限制独立于内存缓存，不新增配置项 | 本计划“用户确认的探索结论”与“阶段准入摘要” | 进行中 | Codex |
| 2026-09-01 | 阶段 1 实现 | 完成 `LogEventStore`：launchd 文件 watcher、分片 UTF-8、每隧道 500 条缓存、单行 8000 字符、文件最近 2000 行安全裁剪、版本化事件、错误/替换/重开恢复 | `Sources/TunnelPadCore/LogEventStore.swift`；`Tests/TunnelPadCoreTests/LogEventStoreTests.swift`；阶段 1 Step 0 证据 | 通过 | Codex |
| 2026-09-01 | 阶段 1 回归 | `LogEventStoreTests` 10/10、Swift Package 全量 101/101 通过；测试只使用临时目录，未触碰真实隧道、launchd 或日志路径；补充锁占用延后裁剪 fixture | 阶段 1 Step 0 证据；阶段 2 Step 0 证据；测试输出 | 通过 | Codex |
| 2026-09-01 | 阶段 2 实现 | `LogView` 改为按窗口可见性和隧道 ID 订阅 session；关闭取消订阅，重开先接快照，版本/隧道 guard 过滤迟到事件，保留自动滚动开关；manager 生命周期接入 log store | `Sources/tunnelpad/LogView.swift`；`Sources/TunnelPadCore/TunnelManager.swift`；阶段 2 Step 0 证据 | 通过 | Codex |
| 2026-09-01 | 阶段 2 受控应用验收 | 隔离 debug App 观察 A 追加、B 切换、窗口关闭/重开、自动滚动关闭后的回看位置；发现并修复 WindowGroup 重开未恢复 `isMainWindowVisible` 的生命周期缺口；隔离 Release App 启动/签名/Info.plist 校验通过 | [阶段 2 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md)；`Sources/tunnelpad/AppDelegate.swift`；`Sources/tunnelpad/MainPanelView.swift` | 通过 | Codex |
| 2026-09-01 | 阶段 3 Step 0 与回归 | Rust 50+1 差分、Swift 101/101、Rust/Swift Release 构建、隔离 Release App 和发布门禁矩阵完成 | [阶段 3 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md) | 通过 | Codex |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 只读架构核对 | 查证当前 `LogView` 2 秒文件轮询、app/launchd 文件日志落点和无统一追加事件；未修改代码 | 当前源码与 GitNexus 探索结果 | 通过 | Codex |
| 2026-08-31 | 阶段 0 基线核验 | 固定 HEAD、既有并行工作树变更边界、`LogView` Timer/末 500 行读取、launchd stdout/stderr 路由、Rust owner 和日志路径；未修改 Swift/Rust、配置或真实日志 | [阶段 0 基线证据](../data-quality/tunnelpad-log-streaming-stage0-20260831.md) | 通过（最小复现尚待执行） | Codex |
| 2026-09-01 | 阶段 0 现状最小复现 | 新增隔离日志基线 fixture；专项 6/6、当前 Swift Package 全量 91/91 通过；追加、关闭重开、文件替换、UTF-8 无换行尾部、2000 行物理文件现状和 launchd 双流路径均已记录；未修改生产日志实现 | [阶段 0 基线证据](../data-quality/tunnelpad-log-streaming-stage0-20260831.md)；`Tests/TunnelPadCoreTests/LogStage0BaselineTests.swift` | 通过（阶段 0 已完成） | Codex |
| 2026-09-01 | 阶段 0 独立准入复核 | 逐项核对目标、非目标、Step 0、样本矩阵、验证/回滚边界、Rust owner 与共享文件串行边界；确认阶段 0 关闭，阶段 1 进入待实施；500 条内存缓存上限已获用户确认 | 阶段 0 基线证据、6/6 隔离测试、全量 89/89 测试、GitNexus 影响结果、治理严格检查 | 通过（阶段 1 可开始；阶段 1 行为 fixture 仍需实际执行） | Codex（独立准入复核轮次） |
| 2026-09-01 | 阶段 2 Step 0 | 核对 LogView 生命周期契约、Core 重开/多隧道 fixture、自动滚动分支和无 Timer 静态门禁；未将源码核对当作受控应用完成证据 | [阶段 2 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md) | 通过（可继续受控应用冒烟） | Codex |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代独立准入复核。

### Attestation 说明

本计划完成快照沿用 `docs/attestations/<plan>.json` 兼容格式。阶段 0 未完成前不创建完成快照；阶段完成或发布门禁需要快照时，使用治理 CLI 生成并保留独立复核状态。

### 验证方式

阶段 0 使用只读源码核对、隔离日志文件、事件序列 fixture 和治理检查。阶段 1 使用 launchd 文件增量、本地日志 2000 行保留上限的 fake/fixture 验证，不调用真实用户的 `launchctl`、SSH 或真实日志路径；阶段 2 使用表示层测试和受控应用冒烟验证面板生命周期、切换和滚动；阶段 3 使用 Rust parity、发布构建、隔离 Release App 和完整治理门禁收口。未来 app 管道另立计划。

完成全计划时至少运行并记录：

- `swift test`；若 Rust Core 迁移后的事实源适用，则同时运行 `cargo test` 和迁移差分测试。
- 日志专项测试，覆盖 `launchd` 文件增量、本地日志 2000 行保留上限、内存缓存上限、事件版本、面板关闭/打开、隧道切换、自动滚动、迟到事件和文件恢复；app 输入留待未来 app 计划。
- 隔离 demo 与受控应用冒烟，确认 `launchd` 日志一致、关闭期间继续采集、重开不漏不重、切换不串日志，且健康恢复/隧道状态不受计划外影响。
- `git diff --check`、`plan-governance-cli check .`、`plan-governance-cli check . --strict-readiness`，以及提交前 GitNexus `detect_changes()`。

### 测试覆盖率

当前没有为本计划新增覆盖率证据。完成阶段 1–2 后以专项测试矩阵和 `swift test`/`cargo test` 输出记录采集器、缓存、事件版本、订阅取消、快照衔接、切换隔离和滚动分支；若项目引入行覆盖率工具，再补充百分比和关键模块覆盖情况，不以全量测试通过替代事件时序覆盖。

### 完成条件

- 阶段 0 Step 0 现状快照和 UI 轮询最小复现已落盘，且不操作真实用户日志或隧道。
- `launchd` 日志输入能进入统一的每隧道内存缓存和追加事件链路，文件记录仍可恢复；app 输入留待未来计划。
- 每条隧道的本地持久日志文件裁剪后最多保留最近 2000 行；超出部分只淘汰更旧记录，最新完整内容可恢复，且不改变日志路径或 stdout/stderr 路由。
- 无新日志时 UI 不因固定 Timer 更新；新日志到达时只更新对应隧道，事件版本连续且无重复。
- 面板关闭/打开、隧道切换和迟到事件边界均有可复现证据，无漏日志、串日志或重复订阅。
- 自动滚动开关、缓存上限、同条数替换和文件恢复均有测试证据。
- 未产生计划外 Schema、HTTP API、日志路径、真实隧道或敏感数据变化。
- 最新独立准入/完成复核明确通过，`PLAN_MAP.md`、阶段证据、测试证据和状态同步。
- 治理普通检查和严格准入检查通过；`detect_changes()` 报告本计划的日志/面板影响以及已在 `PLAN_MAP.md` 声明的稳定性并行文档与共享 `TunnelManager` 影响，未发现计划外生产代码范围。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-01 |
| 阶段 | 阶段 3 |
| 结论 | 通过；已完成 |
| 证据 | Rust 50+1 差分、Swift 101/101、Rust/Swift Release 构建、隔离 debug/Release App UI 验收、签名/Info.plist、锁失败重试和最终治理/图谱/补丁检查均通过；稳定性计划的独立文档和后续阶段 0 基线已保留在日志验收边界之外 |
| 复核者 | Codex（阶段 3 独立完成复核轮次） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-01 | 准入复核 | 阶段 1 | 通过；达到待实施标准 | 阶段 0 基线证据；专项 6/6 与当前全量 91/91 测试（阶段 0 复核时 89/89）；阶段 1 Step 0 契约证据；GitNexus 影响分析；`plan-governance-cli check . --strict-readiness` | Codex（独立准入复核轮次） |
| 2026-09-01 | 实施/完成复核 | 阶段 2 | 通过；已完成 | `LogEventStoreTests` 10/10；Swift Package 全量 101/101；LogView 生命周期/自动滚动/无 Timer 静态契约；隔离 debug App 追加、关闭/重开、切换和滚动位置冒烟；[阶段 2 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md) | Codex（阶段 2 独立完成复核轮次） |
| 2026-09-01 | 准入复核 | 阶段 3 | 通过；达到待实施标准，尚未完成 | Rust 50+1 差分；Swift 101/101；Rust/Swift Release 构建；隔离 Release App 签名、Info.plist、启动和文件恢复；[阶段 3 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md) | Codex（阶段 3 Step 0 复核轮次） |
| 2026-09-01 | 实施/完成复核 | 阶段 3 | 通过；已完成 | Rust 50+1 差分；Swift 101/101（含锁失败重试）；Rust/Swift Release 构建；隔离 debug/Release App AX 冒烟；`codesign --verify --deep --strict`、`plutil -lint`、`plan-governance-cli check . --strict-readiness`、Graph validate、`git diff --check` 和反向引用核对；[阶段 3 Step 0 证据](../data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md) | Codex（阶段 3 独立完成复核轮次） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 内存缓存容量最终值 | 每条隧道固定最多 500 条、单行最多 8000 字符；不开放配置，淘汰最旧条目，版本继续单调递增 | 否 | 已确认（用户 2026-09-01） |
| 阶段 1 实施时 Rust Core 的日志 owner | Rust Core 迁移阶段 5 已确认 Rust 单一 owner；Swift `LogEventStore` 只观察 launchd 已写入的文件，不接管隧道生命周期 | 否 | 已冻结并验证 |
| 阶段 3 最终治理门禁与独立完成复核 | 在阶段 3 Step 0 基础上运行最终治理/反向引用检查，追加完成结论和完成快照 | 否 | 已完成 |

## 风险和回滚

- app 管道读取和文件写入若采用不同的分片/换行处理，可能出现内存与文件日志不一致；用字节缓冲、统一行解析和输出对比 fixture 限制风险。
- launchd 文件可能被截断、替换或在监听建立前追加；使用文件 offset、文件身份和单调版本恢复逻辑，无法确认时重新读取受限尾部而不重复发布。
- 本地日志裁剪可能与 `launchd` 直接写入并发，导致新内容丢失、重复或文件损坏；使用隔离并发/异常 fixture 冻结安全边界，失败时保留原文件并回滚裁剪步骤，不删除真实日志。
- 面板关闭或隧道切换时订阅若未取消，可能造成重复更新、内存泄漏或旧日志倒灌；所有订阅必须带 tunnel ID 与代次，并在生命周期边界统一取消。
- 内存缓存容量过大可能增加 UI 和内存压力；容量固定为每隧道 500 条、单行截断至 8000 字符、文件保留，异常时可回滚到文件快照显示路径。
- Rust Core 迁移与本计划同时拥有日志采集权会产生重复写入或重复事件；实现前必须确认 Rust 单一 owner，阶段 5 独立收尾复核完成前本计划不实施，直到自身准入通过。
- 若事件流导致 UI 状态倒灌、滚动位置破坏或日志丢失，按阶段独立提交回滚事件订阅实现，恢复现有文件读取显示；不删除日志文件、不覆盖真实 plist。
- 任何真实用户日志/隧道验收只允许在用户明确指定、可观察、可恢复的窗口内进行；发现日志路径、进程或隧道状态异常时立即停止该场景并保留文件。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad v1 隧道管理应用](tunnelpad-v1.md)
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)
- [TunnelPad 隧道稳定性与健康恢复](tunnelpad-stability.md)
- [v1 阶段 2 功能与验收记录](../data-quality/tunnelpad-v1-stage2-features-20260829.md)
- [阶段 0 基线证据](../data-quality/tunnelpad-log-streaming-stage0-20260831.md)
- [ADR-0003：日志事件流、缓存和文件保留边界](../adr/0003-log-event-stream-and-retention.md)
