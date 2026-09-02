# TunnelPad 本机 HTTP API 阶段 0 独立准入复核

日期：2026-09-02
复核阶段：阶段 0 → 阶段 1
复核者：Codex（独立只读复核）

## 结论

通过，达到“待实施”标准。阶段 1 可以开始实现，但尚未声明阶段 1 完成。实现前仍必须对实际修改的精确符号执行 GitNexus upstream impact；若出现 HIGH 或 CRITICAL，保持单一编辑窗口并补齐对应测试映射。

## 复核范围

- 当前专项计划、阶段 0 基线证据和 `docs/PLAN_MAP.md` 的状态/依赖/证据链接。
- 已确认的监听地址、路由集合、安全字段边界、同步启停、日志语义、App 生命周期和端口冲突语义。
- A0–A9 样本矩阵是否包含输入或基线、可执行动作、预期、失败判定和输出位置。
- MainActor backend、typed operation result、60 秒有界等待、原位清空日志和回滚边界是否已冻结。
- TunnelManager 类级 CRITICAL impact 及实现阶段的串行修改约束。

## 条件核对

| 准入条件 | 核对结果 | 证据 |
|---|---|---|
| 当前阶段目标、范围和非目标明确 | 通过 | 专项计划“目标”“非目标”“需求探索” |
| Step 0 基线类型和现状证据明确 | 通过 | [阶段 0 基线证据](tunnelpad-local-api-stage0-20260902.md) |
| 样本/fixture 矩阵可执行 | 通过 | 专项计划 A0–A9；A0/A1 已执行，A2–A9 标明阶段 1/2 执行动作 |
| 验证方式、完成条件、失败策略明确 | 通过 | 专项计划“验证方式”“完成条件”“风险和回滚” |
| 当前阶段阻塞项已清理 | 通过 | typed result、60 秒超时、原位清空 watcher 已冻结；剩余为实现验证项，不阻塞准入 |
| `PLAN_MAP.md` 状态、阶段和证据已同步 | 通过 | `PLAN_MAP.md` 未完成索引行、推荐顺序、依赖关系和当前阻塞项 |
| 独立复核结论明确 | 通过 | 本记录及专项计划“最新独立准入复核” |

## 关键设计冻结

- Server 固定绑定 `127.0.0.1:9998`；绑定失败沿用 ModelPad，只记录错误并继续 App，不换端口、不重试。
- API handler 只能通过受控 backend 访问 `@MainActor` 的 TunnelManager，不直接访问 Rust Core、launchctl、日志路径或私有状态。
- 启停请求使用请求级 typed operation result；HTTP 层 60 秒有界等待，超时返回 504 `operation_timeout`，不自动重试。
- 日志清空采用原位清空并保留 watcher、路径和配置，日志版本继续单调递增。
- 测试使用随机端口；固定 9998 只用于隔离 App/端口冲突验收，避免并行测试互相占用。

## 风险与准入边界

TunnelManager 类级 upstream impact 为 CRITICAL，影响 130 个上游符号（直接 81 个），涉及 TunnelPadCore 与 TunnelPadCoreTests。该风险不阻塞阶段 1 准入，但要求实现前对 `startAsync`、`stopAsync`、`restartAsync`、日志清空门面、AppDelegate 生命周期和实际新增 API backend 相关符号分别复核；任何 HIGH/CRITICAL 结果都必须写入实施证据并限制编辑范围。

本复核没有执行 API 行为测试、SwiftNIO 依赖解析、App 构建或真实隧道操作，因此不把阶段 1 实现、生产启动、Release/签名或真实 launchd 验收写成已完成。
