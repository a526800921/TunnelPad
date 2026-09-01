# TunnelPad 日志事件流阶段 2 Step 0 证据

- 日期：2026-09-01
- 计划：[TunnelPad 日志事件流与面板生命周期](../plans/tunnelpad-log-streaming.md)
- 阶段：阶段 2
- 基线类型：阶段 1 Core 行为 fixture + 当前表示层生命周期契约核对

## 结论

阶段 1 的日志采集、缓存、文件保留和事件契约已完成并通过专项回归。阶段 2 的面板订阅接入、生命周期钩子和受控应用冒烟均已通过；本证据将源码/Core fixture 与隔离 App UI 观察分开记录，不把任一单独证据当作完整验收。

阶段 2 的实现边界如下：

- `LogView` 的任务同时绑定隧道 ID 和主窗口可见性；窗口关闭时任务取消，`defer` 调用 `LogSession.cancel()`，后台 `LogEventStore` 不因面板关闭而停止。
- 面板打开时通过 `manager.logSession(for:)` 获取 session；session 返回已衔接的快照和事件流，先应用快照，再消费事件，避免订阅空档。
- `LogView` 只接受当前 tunnel ID 且版本大于当前版本的事件；`TunnelDetailComponents` 保留 `.id(tunnel.id)`，切换隧道时隔离视图状态。
- `autoScroll=true` 时文本变化后滚到底部；`autoScroll=false` 时仍更新文本，但不调用 `scrollToEndOfDocument`，保留用户回看位置。
- 日志面板不再使用固定 Timer、`LogTail` 或 `load()` 文件轮询；“刷新”按钮只执行一次显式 `manager.refreshLog`。

## 阶段 2 Step 0 样本矩阵

| 样本 | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| Core 事件与快照 | 隔离日志文件追加、watcher、分片 UTF-8、替换、锁失败和错误输入 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests` | 10/10 通过；事件、快照、版本和裁剪失败边界符合阶段 1 契约 | 任一专项失败、事件重复/遗漏、串隧道或锁失败时覆盖原文件 | 本文与测试输出 |
| 面板关闭/打开 | `LogEventStoreTests.testClosingAndReopeningUsesLatestSnapshotWithoutStoppingCollector`；核对 `LogView` 任务和取消路径 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testClosingAndReopeningUsesLatestSnapshotWithoutStoppingCollector`；`rg -n 'task\(id:|session\.cancel|logSession\(' Sources/tunnelpad/LogView.swift` | 重开得到关闭期间最新快照；任务取消只影响 UI 订阅 | 关闭停止采集、重开漏日志/重复订阅或没有取消 | 本文与命令输出 |
| 隧道切换/迟到事件 | 双隧道隔离 fixture；LogView ID/version guard；detail view identity | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testTwoTunnelsKeepEventsAndVersionsIsolated`；`rg -n '\.id\(tunnel\.id\)|event\.tunnelID|event\.version > version' Sources/tunnelpad/TunnelDetailComponents.swift Sources/tunnelpad/LogView.swift` | A/B 日志和版本隔离，旧事件不更新新隧道 | 串日志、旧事件倒灌、版本倒退或视图状态复用 | 本文与命令输出 |
| 自动滚动 | `LogTextView.updateNSView` 的文本变化分支 | `rg -n -C 3 'autoScroll|scrollToEndOfDocument' Sources/tunnelpad/LogView.swift` | 仅开启自动滚动时调用滚底；关闭时保持位置 | 关闭开关仍强制滚底，或新文本不显示 | 本文与命令输出 |
| 无固定日志轮询 | 当前 `LogView.swift` | `if rg -n 'Timer\.publish|Task\.sleep|LogTail|load\(\)' Sources/tunnelpad/LogView.swift; then exit 1; else echo 'LogView no fixed Timer/LogTail/load polling references'; fi` | 输出通过；日志 UI 只由 session 事件和显式刷新更新 | 出现固定 Timer、后台 sleep、LogTail 或文件轮询 | 本文与命令输出 |
| 全量回归 | 当前工作树全部 Swift Package 测试 | `xcodebuildmcp swift-package test --package-path .` | 101/101 通过，0 失败，0 跳过 | 任一回归失败或触碰真实资源 | 本文与测试输出 |
| 治理与补丁检查 | 当前计划、索引和全部工作树改动 | `plan-governance-cli check . --strict-readiness`；`plan-governance-cli graph validate .`；`git diff --check` | 严格治理、图谱和补丁格式通过 | 治理 ERROR、图谱无效或空白错误 | 计划与终端输出 |
| 受控应用冒烟 | 临时副本、虚构 `smoke-a`/`smoke-b`、临时日志目录；命令均为 `/usr/bin/true`，不触发启停 | `xcodebuildmcp swift-package build/run` 生成当前 debug 可执行文件后组装隔离 `.app`；`xcodebuildmcp macos launch/stop`；Computer Use 观察并追加临时日志 | A 追加事件即时显示；切换 B 只显示 B；关闭后进程仍在且重开恢复 `initial-A + event-A`；自动滚动关闭后回看位置保持；Release App 也能读取同一隔离快照 | 串日志、重开漏/重事件、窗口关闭退出 collector、滚动条被强制拉底或触碰真实隧道/日志 | 本文“受控应用冒烟”与阶段 3 Step 0 |

## 已执行结果（2026-09-01）

- `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests`：10/10 通过，0 失败，0 跳过；新增锁占用时延后裁剪、解锁后重试 fixture。
- `xcodebuildmcp swift-package test --package-path .`：101/101 通过，0 失败，0 跳过。
- LogView 静态门禁通过：`Sources/tunnelpad/LogView.swift` 不再包含 `Timer.publish`、`Task.sleep`、`LogTail` 或 `load()` 日志轮询；源码命中 `.task(id:)`、`logSession`、`for await event`、tunnel/version guard、`session.cancel`、`autoScroll` 和 `scrollToEndOfDocument`。
- 现有 `AppDelegate.windowShouldClose` 通过 `isMainWindowVisible=false` 隐藏窗口，`showMainWindow` 恢复为 `true`；日志任务 ID 随可见性变化而取消/重建。`TunnelDetailComponents` 的 `.id(tunnel.id)` 为切换隧道提供视图身份隔离。
- 临时副本的 `TunnelPaths.standard()` 固定到 `/tmp/tunnelpad-app-smoke.DCdeuB/home`，配置只包含 `smoke-a`/`smoke-b`，日志只写该目录；二进制 marker 和 AX 文本均确认未使用标准用户路径。
- 当前 debug 隔离 App AX 冒烟：初始显示 `Smoke A` 的 `initial-A`；追加 `event-A` 后面板即时出现；点击 `Smoke B` 后详情切换为 `Smoke B`，只显示 `initial-B` 和 B 路径。
- 关闭窗口后应用进程仍存活；重新创建窗口后，补充的 `MainPanelView.onAppear` 将 `isMainWindowVisible` 恢复为 `true`，日志面板恢复 `initial-A` 与 `event-A`，没有回到“尚未生成”或重复订阅。修复前曾复现新窗口可见但该标志仍为 `false` 的缺口。
- 追加 40 行后关闭“自动滚动”，将日志滚动条滚到值 `0`，再追加 `event-after-scroll-off`；AX 树同时显示新内容且滚动条仍为 `0`。启用自动滚动时追加内容保持底部值 `1`。
- 使用当前源码构建的隔离 Release `.app` 已通过 `codesign --verify --deep --strict` 和 `plutil -lint`，启动后 AX 显示同一批虚构隧道与临时日志路径；整个冒烟未点击启动、停止或重启，没有调用真实 `launchctl`、SSH 或标准日志路径。
- 受控应用冒烟通过，阶段 2 的行为验收条件已满足；阶段 2 可关闭，阶段 3 发布门禁另以独立 Step 0 和复核记录承载。

## 安全与回滚边界

本阶段不调用真实 `launchctl`、SSH、隧道或用户日志路径，不改变 Rust 生命周期 owner、配置 Schema、plist 日志路由和日志路径。若表示层冒烟发现订阅或滚动回归，可先回滚 `LogView` 的 session 接入，恢复文件快照显示；Core 采集、文件保留和日志文件本身不删除、不覆盖。
