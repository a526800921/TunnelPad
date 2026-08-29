# PLAN_MAP

## 治理范围

本文件只跟踪跨阶段、影响公共契约、依赖真实反馈，或会与其他计划发生关系的计划。普通一次性任务不要加入这里。

## 文档权责

- `docs/PLAN_MAP.md` 是状态、依赖、替代/合并/废弃关系、推荐顺序、阻塞项和证据链接的事实源。
- `docs/plans/*.md` 是专项计划的实施细节事实源，记录字段方案、Schema、枚举、Step 0 证据、验证方式和完成条件。
- 总路线图、优先级计划和索引只记录顺序、状态摘要和专项计划链接，不复制字段级方案、枚举、Step 0 细节或完成定义。
- 当专项计划变化时，必须同步所有引用该计划的路线图、优先级计划或索引。
- 如果同一事实在多个文档中重复，保留一个事实源，其他文档改为链接引用。
- `PLAN_MAP.md` 的 `状态` 是计划级生命周期，`当前阶段` 是阶段身份指针；阶段 N 完成后，阶段 N+1 默认保持 `设计中`。
- 阶段准入摘要、样本矩阵和独立复核记录只写入专项计划，不复制到本索引。
- 启用治理后，已有草案、历史设计、归档计划和临时分析文档默认只作为背景材料，不再作为规范事实源；后续新规范默认进入 `docs/plans/*.md`、ADR、migration、正式 spec 或 `docs/PLAN_MAP.md`。

## 计划索引

| 计划 | 状态 | 当前阶段 | 最后更新 | 依赖 | 证据 |
|---|---|---|---|---|---|
| [TunnelPad v1 隧道管理应用](plans/tunnelpad-v1.md) | 已完成 | - | 2026-08-29 | - | [阶段 2 功能与验收记录](data-quality/tunnelpad-v1-stage2-features-20260829.md) |
| [ECS 动态 SSH 公网 IP 同步](plans/ecs-dynamic-ssh-ip.md) | 设计中 | 阶段 0 | 2026-08-29 | - | [阶段 0 本机预检](data-quality/ecs-dynamic-ssh-ip-stage0-local-preflight-20260829.md)；[CLI 与凭证准备](data-quality/ecs-dynamic-ssh-ip-stage0-cli-credential-prep-20260829.md) |

允许状态：`候选`、`设计中`、`待实施`、`实施中`、`已完成`、`已替代`、`已合并`、`已废弃`。

## 推荐顺序

1. `tunnelpad-v1` 与 `ecs-dynamic-ssh-ip` 阶段 0 可并行推进。
2. `ecs-dynamic-ssh-ip` 后续阶段按其自身独立准入复核推进。

## 依赖关系

| 计划 | 依赖 | 原因 |
|---|---|---|
| tunnelpad-v1 | - | - |
| ecs-dynamic-ssh-ip | - | 用户确认可立即进行本计划的阶段 0 准备；本计划不修改 TunnelPad v1 范围，与 v1 无阶段依赖。 |

## 替代、合并和废弃

| 计划 | 关系 | 目标 | 原因 |
|---|---|---|---|
| - | - | - | - |

## 当前阻塞项

| 问题 | 推荐方案 | 影响范围 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|---|
| - | - | - | 否 | 已延后 |
| 新专用 RAM 用户及其策略已由用户创建，但实际身份与授权边界尚未验证 | 只用新专用凭证建立隔离 CLI profile，先验证 STS 身份和安全组只读权限；现有 FullAccess 凭证持续排除 | ecs-dynamic-ssh-ip 阶段 0、阶段 1 | 是 | 部分完成 |
| 未确认受控实跑目标的 RegionId 与动态 SSH 安全组 ID | 用户提供非秘密的地域与安全组 ID；随后先做只读安全组基线与 Workbench 恢复通道确认 | ecs-dynamic-ssh-ip 阶段 0 | 是 | 待用户提供 |

## 完成证据

| 计划 | 阶段 | 证据 |
|---|---|---|
| tunnelpad-v1 | 阶段 0 | [基线快照](data-quality/tunnelpad-v1-stage0-baseline-20260829.md)（样本矩阵四项通过，2026-08-29） |
| tunnelpad-v1 | 阶段 1 | [接管与验证记录](data-quality/tunnelpad-v1-stage1-takeover-20260829.md)（双隧道接管/杀进程 1s 重连/退出即停双路径/重启恢复，2026-08-29） |
| tunnelpad-v1 | 阶段 2 | [功能与验收记录](data-quality/tunnelpad-v1-stage2-features-20260829.md)（9 行矩阵全过、app 执行器/探针/日志/打包，.app 交付，2026-08-29） |
