# TunnelPad 日志事件流与面板生命周期阶段 0 基线证据

- 日期：2026-08-31；追加验证：2026-09-01
- 关联计划：[TunnelPad 日志事件流与面板生命周期](../plans/tunnelpad-log-streaming.md)
- 基线类型：行为迁移现状快照 + 隔离最小复现
- 结论：源码、日志路由、Rust owner 和并行工作树边界已完成只读核验；现状基线最小复现和阶段 0 独立准入复核已通过，阶段 1 Step 0 证据已单独落盘

## 复核范围

本证据只覆盖日志事件流计划阶段 0。阶段 0 不修改 Swift/Rust 日志实现、不修改配置、不启停真实隧道、不删除或重写真实日志文件，也不生成项目交付构建产物；测试工具产生的外部 DerivedData 仅用于验证。

相关计划的变更在本轮开始时曾位于工作树；备注/ECS 变更已随完成计划提交，但稳定性阶段 0 文档仍有并行未提交变更；它们不能归入本计划：

- 备注阶段 1 相关的配置模型、Rust 配置序列化、表单和侧栏改动；其中 `Sources/tunnelpad/TunnelDetailComponents.swift` 与本计划未来面板范围重叠，暂不触碰。
- ECS 阶段 2 的计划文档及阶段证据。
- 稳定性阶段 0 的并行计划边界和共享模块说明。
- 本阶段证据包含隔离基线测试，并由日志计划与 `PLAN_MAP.md` 引用；稳定性阶段 0 的基线、测试和准入仍属于另一条计划。

## Step 0 现状核验

### 工作树基线

| 项目 | 命令 | 结果 | 判定 |
|---|---|---|---|
| 基线提交 | `git rev-parse HEAD` | `9b3311658ba2dbf203a4bbeeb6122f456c8b995e` | 通过 |
| 现有变更 | `git status --porcelain=v1`、`git diff --stat` | 备注/ECS 计划变更已包含在基线提交；当前有稳定性计划文档及本计划文档、隔离基线测试未提交，未新增生产实现代码 | 通过，按计划边界隔离 |
| 补丁格式 | `git diff --check` | 无空白错误 | 通过 |

### 当前日志 UI 基线

对干净 HEAD 中的 `Sources/tunnelpad/LogView.swift` 和 `Sources/TunnelPadCore/LogTail.swift` 进行只读核对：

- `LogView` 绑定 `appDelegate.isMainWindowVisible` 的视图任务；窗口可见时先 `load()`，随后每 `2_000_000_000` 纳秒再次 `load()`。
- `load()` 在后台调用 `LogTail.lastLines(of:maxLines:)`，上限为 500 行；只有完整尾部文本或文件存在状态变化时才写入 UI 状态。
- 当前基线没有统一的每隧道日志追加事件、独立订阅句柄、单调事件版本或面板关闭期间的事件快照链路。
- 因而，当前源码能证明“日志变化由下一次 Timer 驱动 UI 读取”，不能证明事件驱动实现已经存在。

证据命令：

```text
git show HEAD:Sources/tunnelpad/LogView.swift | rg -n 'task\\(id: appDelegate\\.isMainWindowVisible\\)|2_000_000_000|LogTail\\.lastLines|load\\(\\)'
```

输出命中 `task(id:)`、2 秒等待、`load()` 和 `LogTail.lastLines(... maxLines: 500)`。

### 当前 launchd 日志路由基线

对干净 HEAD 中的 Swift plist 渲染器和 Rust 路径实现进行只读核对：

- `LaunchdPlistRenderer` 将 `StandardOutPath` 和 `StandardErrorPath` 指向同一个 `logURL.path`。
- Rust `TunnelPaths.log_url` 从日志目录派生 `<tunnel-id>.log`；日志路径不由面板是否打开决定。
- 当前 owner 的 `start`、`stop`、`restart`、`remove` 以及退出清理仍由 Rust Core 统一承载；日志计划不得另起一套生命周期 owner。

证据命令：

```text
git show HEAD:Sources/TunnelPadCore/LaunchdPlistRenderer.swift | rg -n 'StandardOutPath|StandardErrorPath|plistDictionary|plistXMLData'
git show HEAD:rust/tunnelpad-core/src/paths.rs | rg -n 'logs_directory|log_url|\\.log'
git show HEAD:docs/adr/0001-rust-core-single-owner.md | rg -n '唯一生命周期 owner|配置.*Rust|version=1|关闭窗口'
```

输出确认 stdout/stderr 路由、按隧道日志路径、Rust 唯一 owner、`config.json` version=1 和“关闭窗口不停止隧道”的既有边界。

## 样本矩阵状态

| 样本 | 当前状态 | 证据或未完成原因 |
|---|---|---|
| 当前 UI 文件轮询基线 | 已完成 | 干净 HEAD 源码核验确认 2 秒 Timer、末 500 行和内容比较；`testCurrentPollingBaselineDoesNotExposeAppendUntilNextRefresh` 通过 |
| launchd 文件增量、分片 UTF-8、无换行尾部 | 部分完成 | 隔离 fixture 已证明完整 UTF-8 文件追加只能在下一次 `LogTail` 读取后可见；分片字节采集仍留待事件流实现 |
| 文件截断/替换 | 部分完成 | `testCurrentPollingBaselineObservesReplacementOnlyOnNextRead` 通过；事件采集器的 offset/文件身份恢复仍未实现 |
| 面板关闭/打开 | 已完成（现状基线） | `testCurrentPollingBaselineReopensWithSnapshotAfterPanelWasClosed` 通过；记录关闭期间无实时订阅、重开重新读取快照的现状 |
| 隧道切换与旧事件失效 | 未执行 | 尚无事件代次和订阅句柄 fixture |
| 自动滚动与内存缓存上限 | 未执行 | 当前 `NSTextView` 只覆盖现有文本刷新，事件缓存尚未实现 |
| 本地日志文件 2000 行保留上限 | 已完成（现状基线） | `testCurrentPollingBaselineDoesNotTrimPhysicalFileTo2000Lines` 通过，确认当前物理文件仍为 2001 行、UI 尾读为 500 行；裁剪实现尚未开始 |
| 重启/文件恢复 | 未执行 | 尚无事件缓存恢复实现；文件路径基线已确认 |
| 治理与反向引用 | 已完成 | 6 项阶段 0 基线测试通过，功能图谱校验、`git diff --check` 和治理普通/严格检查通过；共享目标 WARNING 已按并行计划边界记录 |

## Step 0 执行结果与尚未完成项

本阶段已执行 `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter LogStage0BaselineTests`，6 项通过、0 失败；在并行稳定性基线测试加入后，当前 Swift Package 全量回归为 91 项通过、0 失败。隔离最小复现覆盖：

1. 可控日志追加后，现状 UI 只能在下一次 2 秒 Timer 到达时看到变化。
2. 面板关闭期间没有事件订阅时，现状无法实时交付；重新打开需要重新读取快照。
3. 日志超过 2000 行时，现状没有安全裁剪机制。
4. 日志文件替换后，现状 UI 只能在下一次读取时看到新文件内容。

测试文件为 `Tests/TunnelPadCoreTests/LogStage0BaselineTests.swift`，只使用临时目录和现有纯函数，不操作真实用户日志、plist 或隧道。阶段 0 的独立准入已确认目标、非目标、验证、回滚、Rust owner 和共享文件串行边界；事件流实现所需的分片 UTF-8 增量、订阅句柄、事件版本、隧道切换隔离、自动滚动和内存缓存上限仍未执行，这些属于阶段 1/2 的实现验证，不能用本阶段现状基线冒充通过。阶段 1 的准入边界见[阶段 1 Step 0 证据](tunnelpad-log-streaming-stage1-step0-20260901.md)。

## 并行边界记录

- 日志计划阶段 0 的文档、基线和现状 fixture 可与已完成的备注阶段 1–3、ECS 阶段 2 证据并行维护。
- 日志实现涉及 `TunnelManager`、`TunnelRuntimeState`、`MainPanelView`、`TunnelDetailComponents` 和共享测试目录时，必须等待共享文件的单一编辑窗口；备注侧栏改动和稳定性生命周期改动不得同时改同一文件。
- ECS 阶段 2 只有在外部命令适配器和测试完全隔离时才可并行；其计划中的 `TunnelManager` 启动/重启前置与日志/稳定性生命周期编排必须串行合入。

## 后续准入条件

阶段 0 已完成并通过独立准入。阶段 1 已完成事件流、缓存、裁剪和版本隔离 fixture，并与稳定性计划共享模块保持串行编辑；当前阶段 2 的边界和证据见[阶段 2 Step 0 证据](tunnelpad-log-streaming-stage2-step0-20260901.md)。

## 后续阶段实施更新（2026-09-01）

本文件保留阶段 0 当日的历史基线和“事件流尚未执行”结论，不回写历史结果。后续阶段已经追加到专项计划和独立证据：阶段 1 的 `LogEventStoreTests` 9/9、Swift Package 全量 100/100 通过；阶段 2 的面板 session、窗口可见性、隧道切换、版本过滤和自动滚动源码契约已核对。阶段 2 仍待受控应用冒烟和独立完成复核，不能用本阶段 0 基线替代。
