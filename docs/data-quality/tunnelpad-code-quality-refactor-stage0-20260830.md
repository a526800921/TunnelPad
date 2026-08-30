# TunnelPad 代码质量重构——阶段 0 基线证据（2026-08-30）

## 基线快照

| 项目 | 结果 |
|---|---|
| 当前提交 | `b6ffd2232833a2d3e6ef0d894f6cb23fa0448f48`（`b6ffd22`） |
| 当前分支 | `main` |
| 工作树 | 非洁净；未提交改动属于 `AGENTS.md`、ECS 计划/fixture/脚本等既有工作，不归入本次重构 |
| Swift 源码与测试规模 | `find Sources Tests -type f -name '*.swift' ... | wc -l` 合计 3,839 行 |
| Core 测试方法 | `rg -n '^\s*func test' Tests --glob '*.swift'` 计 63 个 |
| 可列出的测试用例 | `swift test list` 成功，输出 63 项；仅有 SwiftPM `--list-tests` 弃用提示 |
| GitNexus 索引 | 70 files、1,257 symbols、3,571 edges、50 clusters、108 processes；索引提交与当前提交均为 `b6ffd22` |
| 治理 | `plan-governance-cli check . --strict-readiness` 通过；仅有既有 ECS 重复影响目标 WARNING |

## 结构与影响面审计

- 最大源码文件：`MainPanelView.swift` 420 行、`TunnelManager.swift` 343 行、`AppProcessExecutor.swift` 254 行、`TunnelSettingsSheet.swift` 233 行、`NewTunnelSheet.swift` 206 行。
- `TunnelManager` 同时承担配置读写、状态刷新、探针调度、启停、删除、新增、迁移和退出相关编排。GitNexus `impact(TunnelManager, upstream)` 返回 48 个影响点、风险 `CRITICAL`，直接影响 Core 与测试模块；后续必须按接口→实现→调用方→测试顺序拆分。
- `TunnelSettingsSheet` 与 `NewTunnelSheet` 存在表单状态、命令解析、探针校验和保存前检查的重复区域。
- `AppProcessExecutor.stop()` 以同步等待方式最多等待 5 秒；`MigrationService` 和测试中存在 `Thread.sleep` 轮询。
- `TunnelManager` 使用 `Task.detached` 执行探针与迁移；`AppProcessExecutor` keepAlive 使用延迟重启；这些路径需要取消/代际保护，但第一轮不得改变可观察行为。
- `ProcessRunner` 使用 `readDataToEndOfFile()` 等待子进程输出收尾；配置和日志路径由多个对象直接使用 `FileManager.default`。
- `LogView` 有 2 秒 `Timer.publish` 刷新；`MainPanelView` 已有防止 refresh→发布→重建订阅反馈环的注释，轮询重构必须保留该约束。

## 行为兼容边界（用户确认）

2026-08-30 用户确认：第一轮代码质量重构以现有行为完全兼容为硬约束。允许拆分职责、建立可测试边界、处理阻塞与竞态并补充测试，但不得改变 config schema、启停/删除/退出/迁移语义或既有 UI/AX 可观察行为；任何产品行为变化另开计划。

## 阶段 0 样本矩阵结果

| # | 结果 | 证据 |
|---|---|---|
| 1 | 通过 | `git rev-parse HEAD`、`git status --short`、`git diff --stat` 已复跑；已区分 AGENTS/ECS 既有改动与重构范围。 |
| 2 | 通过 | Swift 行数、最大文件和 63 个测试方法已复跑。 |
| 3 | 通过 | 已核对 `tunnelpad-v1`、`tunnelpad-ui-refinements` 及阶段证据；schema、启停、删除、退出、迁移、探针、日志和菜单约束已写入本专项计划。 |
| 4 | 通过 | `swift test list` 输出 63 个测试用例。 |
| 5 | 通过 | 同步 I/O、进程停止、Task.detached、延迟重启、轮询和 `@Published` 热点已记录；原始匹配清单共 124 行，位于本机临时输出 `/tmp/tunnelpad-code-quality-risk-hotspots-20260830.txt`。 |
| 6 | 通过 | 严格治理检查和 `git diff --check` 均通过。 |

## 阶段 0 结论

阶段 0 的基线、风险清单和第一轮行为兼容边界已具备可复现证据。阶段 1 仍需先确认是否接受“内部 async/await + 取消保护、外部行为不变”，并完成自身 Step 0 原型/门禁后才能进入实施。
