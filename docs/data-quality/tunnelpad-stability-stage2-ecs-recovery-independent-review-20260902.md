# TunnelPad 稳定性阶段 2 ECS 自动恢复切片独立准入复核

- 日期：2026-09-02
- 阶段：阶段 2
- 切片：ECS 自动恢复切片
- 复核者：Codex（独立只读复核）
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- Step 0 证据：[阶段 2 Step 0 基线](tunnelpad-stability-stage2-step0-20260902.md)
- 结论：达到“待实施”标准（仅限 ECS 自动恢复切片）

## 复核范围

本轮只准入“HTTP 探针连续失败触发 SSH 自动恢复前的 ECS 同步与 KeepAlive 阻断”切片，不把阶段 2 的启动/退出资源统一收敛、跨层状态一致性和迟到任务治理误计为已准入或已完成。

冻结的实现顺序为：SSH 隧道自动恢复先通过现有 Rust owner `stop`/`bootout`，确认返回 `notLoaded` 后调用现有 `ECSPreStartChecker`；前置成功后沿用同一操作代次调用 Rust owner `start`/`bootstrap`。停止失败、仍为 loaded、前置失败、超时、取消或结果无法分类均不启动；非 SSH 隧道继续使用原有 `restart` 路径。

## 严格准入逐项核对

| 准入条件 | 当前结果 | 证据与判断 |
|---|---|---|
| 当前切片目标、范围和非目标 | 通过 | 只处理现有后台 HTTP 探针触发的 SSH 自动恢复前置；不新增全局 IP 轮询、配置字段、wrapper、ECS API、Rust C ABI 或真实外部操作。 |
| 阶段 2 自身 Step 0 | 通过 | Step 0 已记录后台监测、ECS 适配器、launchd KeepAlive 直启缺口、Rust owner、用户确认的触发方案和本切片的 bootout-first 设计。 |
| 可执行样本矩阵 | 通过 | 已覆盖 SSH/非 SSH 分类、`stop → preflight → start` 顺序、`notLoaded` 门禁、ECS 失败类型、KeepAlive 绕过反证以及治理检查；每行包含输入、操作、预期、失败判定和输出位置。 |
| 验证方式 | 通过 | 使用 fake Rust owner、fake ECS 前置、fake 探针和隔离任务记录；专项验证调用顺序、失败不启动、非 SSH 兼容路径和单隧道隔离，再运行 Swift/Rust 回归与治理检查。 |
| 失败/回滚/安全边界 | 通过 | fail-closed：未确认 `notLoaded` 或 ECS 前置失败均不启动；不触碰真实 `launchctl`、SSH、ECS、用户隧道或凭证；实现可按单一提交回滚。 |
| 实际修改符号影响分析 | 通过 | `TunnelManager` upstream 为 CRITICAL（103 个受影响、74 个直接影响）；`performAutomaticRecovery` 为 LOW（3 个受影响、2 个健康流程）；`start` 为 LOW（4 个测试调用）；`restart` 为 LOW（无上游命中）。已登记高风险并限制改动面。 |
| 共享模块与并行边界 | 通过 | 只在稳定性切片的单一编辑窗口修改 `TunnelManager` 与新增专项测试，不改日志计划已验收的实现；Rust owner、日志事件流、备注和配置 Schema 保持原事实源。 |
| 当前切片无准入阻塞 | 通过 | ECS 自动恢复的阻断方式已冻结；其他阶段 2 切片仍保留为后续工作，不阻塞本切片进入实施。 |
| 治理门禁 | 通过 | 当前文档变更已执行普通/严格治理检查、停滞检查和 `git diff --check`；实现后还需再次执行全量验证和 `detect_changes()`。 |

## 准入结论

本轮确认 ECS 自动恢复切片的目标、范围/非目标、Step 0、样本矩阵、实现顺序、验证方式、失败/回滚边界、影响分析和共享边界均已明确，达到“待实施”标准。

该结论不代表阶段 2 整体完成，也不替代后续启动/退出统一资源收敛和跨层状态一致性切片的独立准入。实现完成后必须基于当前仓库代码、专项 fixture、全量回归、反向引用和 GitNexus `detect_changes()` 独立核对，不得仅依据本文件或计划状态判定完成。

本次复核未调用真实 `launchctl`、SSH、ECS 或用户隧道。
