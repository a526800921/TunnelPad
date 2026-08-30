# 计划：TunnelPad 代码质量重构

- 状态：设计中
- 当前阶段：阶段 0（重构基线与契约冻结）
- 最后更新：2026-08-30
- 前置：`tunnelpad-v1` 与 `tunnelpad-ui-refinements` 均已完成；本计划阶段 0 仅固定重构基线与兼容边界

当前说明：用户已要求新建代码质量重构计划。本计划先固定现状、边界和验收口径，不直接修改代码；界面优化计划已收尾，阶段 1 及以后仍必须在阶段 0 完成并通过独立准入复核后实施。

## 背景

TunnelPad v1 与界面优化已经形成可运行功能，但当前工作树中的核心编排仍集中在少数对象中。主要风险不是代码行数本身，而是同步 I/O、进程生命周期、配置持久化、异步探针、窗口轮询和 UI 表单之间缺少稳定边界，导致后续功能容易出现卡顿、竞态和回归。

本计划只负责内部质量重构，和界面优化计划分开管理，避免把尚未完成的 UI 实机验证与架构变更混在同一批提交中。

## 目标

- 在不扩大产品范围的前提下，降低核心对象的职责密度和修改耦合。
- 为 launchd、app 两类执行器建立可替换、可测试的运行时边界。
- 消除主线程上的可长时间阻塞操作，并为停止、删除、keepAlive 重启和探针刷新建立取消/过期保护。
- 消除新建/编辑表单、启停编排、退出清理等重复逻辑。
- 把失败回滚、异步竞态和窗口可见性轮询纳入可复现测试矩阵。
- 保留一条可独立回滚的提交路径，每个阶段都能用现有真实隧道和 demo 隧道验证。

## 非目标

- 不在本计划中新增业务功能或改变菜单栏、主面板的产品取舍；菜单栏单项启停仍由界面优化计划阶段 4 管理。
- 不默认修改 `config.json` schema、launchd 标签、日志路径、退出即停、迁移回滚或执行器语义。
- 不把 TunnelPad 改造成远程管理、多机同步、HTTP API 或通用任务编排框架。
- 不引入第三方依赖，除非另有独立计划和用户确认。
- 不在阶段 0 清理、覆盖或回滚当前工作树中的既有未提交改动。

## 需求探索

### 已确认事实（2026-08-30 查证）

- 用户要求新建一个独立的代码质量重构计划，暂未授权直接修改代码。
- 当前工作树存在未提交改动，涉及 TunnelPad 界面收尾、ECS 计划和其他文档/脚本；重构前必须记录工作树基线，不能把这些改动误归入重构提交。
- `TunnelManager` 是 `@MainActor` 门面，同时承担配置读写、状态刷新、探针调度、迁移、新增/删除和三类启停操作（见 `Sources/TunnelPadCore/TunnelManager.swift`）。
- `LaunchCtlExecutor` 和 `AppProcessExecutor` 的部分操作是同步的；`AppProcessExecutor.stop()` 最长等待 5 秒，可能从主线程调用。
- `AppProcessExecutor` 的 keepAlive 延迟重启、`TunnelManager` 的 detached 探针任务和多个 UI 定时刷新均有独立生命周期，目前缺少统一取消令牌或操作版本。
- `TunnelSettingsSheet` 与 `NewTunnelSheet` 重复实现表单状态、命令解析、探针校验和保存前检查。
- `AppDelegate` 与 `Shutdown` 都包含退出清理编排；`TunnelManager` 的启停/删除/迁移路径各自处理 busy、错误文案和刷新。
- 当前 Core 测试共 63 个测试方法；已有执行器、迁移、配置、探针和 TunnelManager 测试，但尚未覆盖所有 UI 与异步竞态路径。
- 当前治理索引已存在，且 `tunnelpad-ui-refinements` 已完成阶段 1–4；本计划不替代其实现或验收事实源。

### 推荐但尚未确认的约束

| 决策点 | 推荐方案 | 未确认前的处理 |
|---|---|---|
| 行为兼容边界 | 第一轮只做内部重构：保留 schema、启停/退出/迁移语义和现有 UI 行为 | 作为阶段 0 阻塞项，不冻结为实施契约 |
| 并发模型 | Core 使用 async/await；运行时状态由 actor 或单一串行协调器维护 | 阶段 1 Step 0 先做最小原型和性能/取消实验 |
| 执行器抽象 | 定义内部 `TunnelExecutor` 能力边界，launchd/app 分别实现 | 不先承诺公共 API，不改变现有 `TunnelManager` 对外方法 |
| 配置持久化 | 保留现有 JSON 格式，先抽出 repository 和原子提交/回滚边界 | Schema 变更必须另行确认 |
| UI 共享表单 | 抽出共享编辑状态与校验，分别保留新建/编辑入口 | 不改变现有字段和默认值 |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 第一轮重构是否以现有行为完全兼容为硬约束 | 是；先拆边界、去阻塞、补测试，再单独讨论行为变更 | 是 | 等待用户确认 |
| 是否接受后续将停止/探针/轮询改为 async 实现 | 是，但必须保持外部行为和可观察状态一致，并以竞态测试与实机回归为门槛 | 否（阶段 1 前确认） | 待阶段 0 原型验证 |

## 不变量与安全边界

以下内容作为现状基线，只有用户明确确认并同步本计划后才能改变：

- `config.json` 仍为 version 1；配置损坏时保留原文件并重建空配置的行为不被静默改变。
- 隧道 id、launchd 标签、日志路径和 pidfile 派生关系保持兼容。
- 手动停止、删除和退出操作不能被 keepAlive 延迟任务重新拉起。
- 删除必须避免出现“配置已删但实例仍运行”或“实例已停但配置状态误报运行”的中间态；无法保证时保留配置并报告错误。
- 迁移接管仍为备份→卸载旧 agent→加载新 agent→验证运行，失败自动回滚。
- 探针只影响展示，不改变隧道进程启停；过期结果不得覆盖新配置结果。
- 退出 TunnelPad 仍停止全部受管 launchd 隧道和 app 子进程。
- 不读取或记录私钥、AccessKey、ECS 地址等敏感内容。

## 影响模块或文件

- Sources/TunnelPadCore/TunnelManager.swift
- Sources/TunnelPadCore/AppProcessExecutor.swift
- Sources/TunnelPadCore/LaunchCtlExecutor.swift
- Sources/TunnelPadCore/LaunchdPlistRenderer.swift
- Sources/TunnelPadCore/ConfigStore.swift
- Sources/TunnelPadCore/TunnelPaths.swift
- Sources/TunnelPadCore/ProbeService.swift
- Sources/TunnelPadCore/Shutdown.swift
- Sources/tunnelpad/AppDelegate.swift
- Sources/tunnelpad/MainPanelView.swift
- Sources/tunnelpad/TunnelSettingsSheet.swift
- Sources/tunnelpad/NewTunnelSheet.swift
- Sources/tunnelpad/LogView.swift
- Sources/tunnelpad/MenuBarController.swift
- Tests/TunnelPadCoreTests/
- docs/data-quality/

职责拆分建议、验证边界和阶段目标见下文，不在影响目标列表中重复定义。

## 公共契约变化

当前阶段暂不冻结公共 API 或磁盘 Schema 变化。候选方案是把新增抽象保持为 `TunnelPadCore` 内部实现细节，继续由现有 `TunnelManager` 作为 UI 门面；如果需要公开新协议、改变 JSON 字段或改变退出语义，必须先更新本计划并进行独立兼容性评估。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定工作树基线、行为契约、风险清单和重构门禁 | 用户确认第一轮兼容边界 | 只读审计、现有测试、治理检查、最小基线证据 | 设计中 |
| 阶段 1 | Core 边界拆分：repository、执行器能力、运行时状态、错误/结果模型 | 阶段 0 完成并独立准入通过 | 单元/契约测试，保持现有 63+ 用例通过 | 候选 |
| 阶段 2 | 异步生命周期与取消：停止、keepAlive、探针、轮询、退出清理 | 阶段 1 完成并独立复核 | 竞态/取消测试、UI 不阻塞验证、实机启停回归 | 候选 |
| 阶段 3 | UI 组合与共享表单：拆分主面板、合并新建/编辑校验、统一状态投影 | 阶段 2 完成；界面优化阶段 3/4 已闭环 | AX 样本矩阵、表单回归、菜单栏回归 | 候选 |
| 阶段 4 | 发布前硬化：失败注入、真实隧道回归、性能与文档收口 | 阶段 3 完成并独立复核通过 | `swift build`、`swift test`、打包、实机矩阵、治理检查 | 候选 |

## 当前阶段

### 目标与范围（阶段 0：重构基线与契约冻结）

- 记录当前 HEAD、工作树未提交改动、源码/测试规模和现有可观察行为。
- 把“第一轮行为兼容”作为待用户确认的决策，不在确认前开始代码重构。
- 形成按风险排序的拆分清单，以及每个后续阶段的最小可验证门禁。
- 确认重构与 `tunnelpad-ui-refinements` 的依赖顺序，避免同时改同一入口。

### 非目标（阶段 0）

- 不修改 Swift 源码、Package.swift、测试实现或构建产物。
- 不运行会改变运行中隧道、配置、launchd 状态或日志的操作。
- 不把当前工作树已有 diff 重新格式化、回滚或提交。

### Step 0

类型：架构探索的现状快照与风险实验准备。

基线信息：当前 HEAD 由 `git rev-parse HEAD` 取得；工作树非洁净，必须同时记录 `git status --short` 与 `git diff --stat`。当前审计已确认 63 个 Core 测试方法、`TunnelManager`/`AppProcessExecutor`/主面板/双表单为主要重构热点；完整证据待落盘至 `docs/data-quality/tunnelpad-code-quality-refactor-stage0-20260830.md`。

### 样本矩阵（阶段 0）

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前工作树 | `git rev-parse HEAD && git status --short && git diff --stat` | HEAD、未提交文件和规模可复现；明确哪些改动不属于本计划 | 输出缺失或把既有 diff 误标为重构改动 | 阶段 0 证据文档 |
| 2 | 当前 Swift 源码和测试 | `find Sources Tests -type f -name '*.swift' -print0 \| xargs -0 wc -l`；`rg -n '^\\s*func test' Tests --glob '*.swift'` | 记录代码规模、测试方法数和最大职责集中点 | 无法复现规模或遗漏测试目标 | 阶段 0 证据文档 |
| 3 | 现有行为契约 | 只读核对 `docs/plans/tunnelpad-v1.md`、`docs/plans/tunnelpad-ui-refinements.md` 与对应证据文档 | 列出 schema、启停、退出、迁移、探针、日志和菜单约束 | 计划与证据互相矛盾或出现未标注的行为变更 | 阶段 0 证据文档 |
| 4 | Core 现有测试 | `swift test --list-tests`（只列清单，不执行） | 测试目标和现有覆盖边界可见 | 测试目标不可列出或发现关键能力无测试入口 | 阶段 0 证据文档 |
| 5 | 风险热点 | 静态审计 `rg -n 'Task\\.detached|Thread\\.sleep|readDataToEndOfFile|FileManager\\.default|try\\? |@Published|Timer\\.publish' Sources Tests --glob '*.swift'` | 每个同步 I/O、可取消任务、全局文件访问和状态发布点都有归属 | 仍有未解释的主线程阻塞或异步生命周期 | 阶段 0 证据文档 |
| 6 | 治理一致性 | `plan-governance-cli check . --strict-readiness`；`git diff --check` | 新计划、索引和引用通过治理检查；无空白错误 | 任一 ERROR 或计划索引未同步 | 阶段 0 证据文档 |

### 验证方式（阶段 0）

阶段 0 只读完成条件为：用户确认第一轮兼容边界；基线证据文档落盘；上述矩阵 1–6 可复现；`PLAN_MAP.md` 已同步；治理普通检查和 `--strict-readiness` 均无本计划相关 ERROR；独立复核明确是否达到阶段 1 的待实施标准。

### 失败/回滚边界（阶段 0）

阶段 0 不改变代码、配置或运行中的隧道。若审计发现行为契约无法明确，保持计划“设计中”，只补充事实和未决问题；不以猜测冻结架构。后续任一实现阶段必须使用独立提交，失败时只回滚该阶段提交，不覆盖用户已有未提交改动。

### 阶段证据（阶段 0）

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 设计 | 完成只读代码质量审计并新建本计划；确认重构热点与主要竞态风险，兼容边界待用户确认 | 本文件；待补阶段 0 证据文档 | 进行中 | Codex |

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 设计中 |
| Step 0 | 工作树非洁净；已完成初步静态审计，完整基线证据待落盘 |
| 样本矩阵 | 6 行，覆盖工作树、规模、契约、测试清单、风险热点和治理检查 |
| 验证方式 | 只读命令 + 现有测试清单 + 计划治理检查；不改变代码或运行状态 |
| 失败/回滚边界 | 阶段 0 无运行时副作用；后续阶段独立提交可回滚 |
| 当前阻塞项 | 第一轮是否严格保持现有行为兼容 |
| 最新独立准入复核 | 尚未进行 |

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-30 |
| 阶段 | 阶段 0 |
| 结论 | 尚未复核；计划保持设计中 |
| 证据 | 待阶段 0 基线证据和用户兼容边界确认后补充 |
| 复核者 | 待定 |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-30 | 计划创建 | 阶段 0 | 未进入准入复核 | 只读审计已完成；兼容边界和基线证据尚未冻结 | Codex |

## 风险和回滚

- 主线程卡顿风险：同步 `launchctl`、文件读写和进程停止迁移到异步前，先用测试和可观察耗时建立基线；异步化后保留状态更新顺序。
- keepAlive 竞态风险：任何延迟重启都必须有取消或 generation 保护；删除/手动停止后不得恢复已失效配置。
- 持久化半事务风险：配置、运行实例和产物清理必须定义提交顺序与失败边界；无法原子化时优先保留可恢复配置。
- UI 回归风险：共享表单和状态投影重构必须保留现有默认值、校验文案语义和 AX 入口。
- 工作树污染风险：阶段 0 不清理现有改动；实现前要用明确基线提交或等价快照区分用户改动。
- 回滚策略：每阶段单独提交；只回滚该阶段；若发现 schema、退出语义或迁移契约需要变化，暂停实现并先更新计划/ADR。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad v1](tunnelpad-v1.md)：现有执行器、配置、迁移和退出语义的背景事实源。
- [TunnelPad 界面优化](tunnelpad-ui-refinements.md)：当前 UI 变更及菜单栏阶段 4 的事实源；本计划不替代它。
- 暂无独立 ADR 或 migration；若重构改变公共契约或兼容策略，再新增对应文档。
