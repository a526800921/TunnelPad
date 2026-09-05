# TunnelPad 日志保留与能耗回归修复：阶段 0 独立准入复核

- 日期：2026-09-05（Asia/Shanghai）
- 关联计划：[日志保留与能耗回归修复](../plans/tunnelpad-log-retention-energy-regression.md)
- 复核类型：阶段 0 独立准入复核
- 结论：通过；阶段 0 已完成，阶段 1 达到“待实施”标准。

## 复核范围

本轮只复核计划边界、现状证据、样本矩阵、验证方式、失败/回滚边界、依赖同步和代码影响范围，不修改 Swift/Rust、测试、配置、真实日志或构建产物。用户已确认按推荐方案推进：LF/CRLF 以字节边界计行，单独 CR 暂按正文保留；大日志小量追加采用有界的字节级尾部检查，不以提高 10 秒周期、关闭探针或降低日志级别规避问题。

## 证据核对

| 项目 | 核对结果 | 证据 |
|---|---|---|
| 真实缺陷基线 | 通过 | [隔夜复验与诊断](tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)：新 Release App、约 10 秒 CPU 峰值、watcher/`trimIfNeeded` 栈、约 8.4 MB CRLF 日志和未修改真实日志边界 |
| 当前实现定位 | 通过 | `Sources/TunnelPadCore/LogEventStore.swift` 的 `LogFileRetention.trimIfNeeded` 及 `LogEventStore.refreshState/fileDidChange` 调用关系；当前为全文读取、字符切分和无条件裁剪检查 |
| 既有契约 | 通过 | [ADR-0003](../adr/0003-log-event-stream-and-retention.md)：每隧道最近 2000 行、原位/安全裁剪、锁失败保留原文件、路径与 stdout/stderr 路由不变 |
| 依赖和 owner 边界 | 通过 | 已完成的 `tunnelpad-log-streaming` 与 `tunnelpad-rust-migration`；本计划只触及 Swift 日志保留和测试，不接管 Rust 生命周期或健康监测 |
| 样本矩阵 | 通过 | 专项计划阶段 0 样本矩阵 1–7，覆盖现状、LF、CRLF、混合换行、末行无换行、空文件、裸 CR、大日志小追加、锁/并发/替换和真实长期复验 |
| 失败/回滚边界 | 通过 | 阶段 0 不改实现；阶段 1 锁失败、身份/大小变化、写入失败保留原文件并延后；阶段 2 失败只恢复本地 App，不修改配置、ECS、凭证或非目标隧道 |

## 影响分析

GitNexus 已对 `LogFileRetention.trimIfNeeded` 执行 upstream impact：`CRITICAL`，1 个直接调用者、16 个受影响符号、6 条执行流、3 个模块。直接调用者为 `LogEventStore.refreshState`；间接执行流包括启动监控、同步、清空日志、日志读取、本机 API 清空日志和测试。该影响已纳入阶段 1 的专项测试与完整回归要求，修改范围限定为：

- `Sources/TunnelPadCore/LogEventStore.swift` 的 `LogFileRetention.trimIfNeeded`，必要时仅调整其日志存储调用衔接。
- `Tests/TunnelPadCoreTests/LogEventStoreTests.swift` 的隔离 fixture。

不修改健康循环、`ProbeService`、`MainPanelView`、Rust Core、HTTP API、配置 Schema、launchd 标签或真实日志路径。

## 准入结论

当前阶段目标、范围和非目标已明确；Step 0 真实基线可复现且不触碰真实日志；样本矩阵包含输入、命令、预期、失败判定和输出位置；验证与回滚边界明确；用户取舍已确认；`PLAN_MAP.md` 已同步。阶段 0 关闭，阶段 1 置为“待实施”。

## 验证记录

- `git diff --check`：通过。
- `plan-governance-cli check .`：通过；仅保留后台健康监测能耗计划此前隔夜复验未通过的 WARNING。
- `plan-governance-cli check . --strict-readiness`：全局仍受后台健康监测能耗计划的当前失败复核阻塞；该结果不否定本计划阶段 1 的局部准入，不能伪造为全局通过。
- GitNexus `query`/`context`/`impact`：已完成；影响等级 CRITICAL，已记录直接调用者和执行流。

## 复核者

Codex（基于当前仓库、源码、GitNexus 影响结果和真实运行证据的独立准入复核）
