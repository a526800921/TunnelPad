# TunnelPad 日志事件流阶段 1 Step 0 证据

- 日期：2026-09-01
- 计划：[TunnelPad 日志事件流与面板生命周期](../plans/tunnelpad-log-streaming.md)
- 阶段：阶段 1
- 基线类型：行为迁移现状快照 + 隔离文件/事件契约基线

## 结论

阶段 0 已完成并通过独立准入，阶段 1 的契约边界已经冻结并完成实现：每条隧道内存缓存最多 500 条，单行最多 8000 字符；本地日志文件最多保留最近 2000 行；事件只由后台文件增量采集产生，携带隧道 ID、单调版本和完整快照；面板不负责启动采集，也不使用固定 Timer 检测日志变化。

本证据不把编译、源码快照或阶段 0 现状测试当作阶段 1 行为完成证据。下方 fixture 已在实现后执行并追加实际结果；面板生命周期和自动滚动的表示层证据另见[阶段 2 Step 0 证据](tunnelpad-log-streaming-stage2-step0-20260901.md)。

## 已有基线

- `LogStage0BaselineTests`：6/6 通过，覆盖当前追加可见性、关闭重开、文件替换、UTF-8 无换行尾部、2000 行物理文件不裁剪和 launchd stdout/stderr 同一路径。
- Swift Package 全量测试：阶段 1 初次实现时 100/100 通过；当前工作树 101/101 通过（补充锁失败边界 fixture）；阶段 0 独立准入时的历史基线为 89/89，阶段 0 与稳定性基线加入后的中间结果为 91/91。
- 所有文件测试使用临时目录；不访问真实隧道、真实 `launchd`、SSH 或真实日志路径。
- Rust Core 阶段 5、ECS 阶段 2 和备注阶段 1–3 已完成；稳定性计划保持独立，和本阶段共享模块改动串行。

## 阶段 1 fixture 矩阵

| 场景 | 输入/操作 | 命令 | 预期 | 失败判定 | 输出 |
|---|---|---|---|---|---|
| 分片 UTF-8 与无换行尾部 | 分两次写入多字节字符及最后一行 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testSplitUTF8DoesNotPublishReplacementCharacters` | 不丢字节、不产生替换字符，最后一行可显示 | 重复/丢失/乱码或提前发布不完整字符 | 本文与测试输出 |
| 追加与版本 | 依次追加 A、B，无变化刷新一次 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testAppendPublishesOneEventAndNoEventWithoutNewBytes` | A/B 各产生一次事件；无新字节无事件；版本严格递增 | 重复、漏发、版本倒退或无变化发事件 | 本文与测试输出 |
| 多隧道隔离 | 隧道 A/B 交错追加并分别取快照 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testTwoTunnelsKeepEventsAndVersionsIsolated` | 缓存、版本、文本互不污染 | 串日志、串版本或跨隧道通知 | 本文与测试输出 |
| 500 条缓存边界 | 单隧道写入 2001 条，观察内存末 500 条 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testMemoryCacheKeepsLatest500AndFileKeepsLatest2000Lines` | 只保留最新 500 条，版本仍递增 | 超过 500、淘汰新内容或版本停滞 | 本文与测试输出 |
| 文件 2000 行裁剪 | 写入超过 2000 行并验证最新内容 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testMemoryCacheKeepsLatest500AndFileKeepsLatest2000Lines` | 文件最多 2000 行，路径/最新内容保留 | 丢新内容、文件损坏、路径变化或依赖真实日志 | 本文与测试输出 |
| 裁剪锁失败与重试 | 另一个文件句柄持有独占锁，随后释放并刷新 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests.testRetentionDefersWhenFileIsLockedAndRetriesLater` | 锁占用时保留原文件；解锁后下一次刷新裁剪到最近 2000 行 | 锁失败覆盖原文件、采集停止或解锁后不重试 | 本文与测试输出 |
| 截断/替换/读取错误 | 隔离文件替换、删除/缺失和无效 UTF-8 输入 | `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests` | 重新定位且不重复；缺失/错误为明确状态 | 采集停止、重复旧内容或伪造日志 | 本文与测试输出 |

## 安全与回滚边界

实现仅允许修改本计划声明的 Swift Core、面板日志视图及隔离测试；不修改 Rust owner、配置 Schema、plist 日志路径、真实日志文件或真实隧道。裁剪失败时保留原文件并延后，事件实现失败时恢复现有文件快照读取显示。`TunnelManager` 的 CRITICAL 影响结果已在阶段 0 复核，后续提交前必须重新运行影响范围与 `detect_changes()`。

## 实施后验证结果（2026-09-01）

- `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests`：9/9 通过，0 失败，0 跳过。
- `xcodebuildmcp swift-package test --package-path .`：100/100 通过，0 失败，0 跳过。
- 9 项专项测试实际覆盖：watcher 自动追加、显式刷新和无变化不发事件、分片 UTF-8、每隧道 500 条缓存、单行 8000 字符、本地文件最近 2000 行、文件替换、双隧道隔离、关闭后重开快照、无效 UTF-8 错误状态。
- 后续补充 `testRetentionDefersWhenFileIsLockedAndRetriesLater`：单项 1/1 通过；当前 `LogEventStoreTests` 为 10/10、Swift Package 全量为 101/101。锁失败时原文件保持 2001 行，释放后刷新保留最近 2000 行。
- 所有测试使用临时目录；未调用真实 `launchctl`、SSH、隧道或用户日志路径。阶段 1 完成证据不延伸为阶段 2 的 UI 受控应用验收。
