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
| [ECS 动态 SSH 公网 IP 同步](plans/ecs-dynamic-ssh-ip.md) | 实施中 | 阶段 1 | 2026-08-29 | - | [阶段 0 本机预检](data-quality/ecs-dynamic-ssh-ip-stage0-local-preflight-20260829.md)；[CLI 与凭证准备](data-quality/ecs-dynamic-ssh-ip-stage0-cli-credential-prep-20260829.md)；[云端只读验证](data-quality/ecs-dynamic-ssh-ip-stage0-cloud-readonly-20260829.md)；[控制台拓扑基线](data-quality/ecs-dynamic-ssh-ip-stage0-console-topology-20260829.md)；[项目外受控实跑](data-quality/ecs-dynamic-ssh-ip-stage0-controlled-run-20260829.md)；[阶段 1 实现与验证](data-quality/ecs-dynamic-ssh-ip-stage1-implementation-20260829.md) |
| [TunnelPad 界面优化](plans/tunnelpad-ui-refinements.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1 | [阶段 1 证据](data-quality/tunnelpad-ui-refinements-stage1-20260829.md)；[阶段 2 证据](data-quality/tunnelpad-ui-refinements-stage2-20260829.md)；[阶段 3 与阶段 1 收尾证据](data-quality/tunnelpad-ui-refinements-stage3-20260830.md)；[阶段 4 证据](data-quality/tunnelpad-ui-refinements-stage4-20260830.md) |
| [TunnelPad 代码质量重构](plans/tunnelpad-code-quality-refactor.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1, tunnelpad-ui-refinements | [阶段 0 基线证据](data-quality/tunnelpad-code-quality-refactor-stage0-20260830.md)；[阶段 1 实施证据](data-quality/tunnelpad-code-quality-refactor-stage1-20260830.md)；[阶段 2–4 实施证据](data-quality/tunnelpad-code-quality-refactor-stage2-4-20260830.md)；[专项计划](plans/tunnelpad-code-quality-refactor.md) |
| [TunnelPad Rust Core 迁移](plans/tunnelpad-rust-migration.md) | 实施中 | 阶段 2 | 2026-08-30 | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | [阶段 0 基线证据](data-quality/tunnelpad-rust-migration-stage0-20260830.md)；[阶段 1 证据](data-quality/tunnelpad-rust-migration-stage1-20260830.md)；[专项计划](plans/tunnelpad-rust-migration.md) |

允许状态：`候选`、`设计中`、`待实施`、`实施中`、`已完成`、`已替代`、`已合并`、`已废弃`。

## 推荐顺序

1. `tunnelpad-v1` 与 `ecs-dynamic-ssh-ip` 阶段 0 可并行推进。
2. `ecs-dynamic-ssh-ip` 后续阶段按其自身独立准入复核推进。
3. `tunnelpad-ui-refinements` 各阶段按其自身独立准入复核推进，可与 `ecs-dynamic-ssh-ip` 并行。
4. `tunnelpad-code-quality-refactor` 先完成阶段 0 基线与兼容边界确认；实现阶段默认排在 `tunnelpad-ui-refinements` 收尾及阶段 4 独立复核之后，避免重构与 UI 行为同时修改。
5. `tunnelpad-rust-migration` 阶段 0、阶段 1 均已通过独立复核；阶段 2（组件 parity + 差分测试）实施中，差分一致并通过独立复核后才进入阶段 3。

## 依赖关系

| 计划 | 依赖 | 原因 |
|---|---|---|
| tunnelpad-v1 | - | - |
| ecs-dynamic-ssh-ip | - | 用户确认可立即进行本计划的阶段 0 准备；本计划不修改 TunnelPad v1 范围，与 v1 无阶段依赖。 |
| tunnelpad-ui-refinements | tunnelpad-v1 | 前置 v1 已完成；本计划不修改 config schema 与隧道启停语义，与 ecs-dynamic-ssh-ip 无依赖。 |
| tunnelpad-code-quality-refactor | tunnelpad-v1, tunnelpad-ui-refinements | v1 提供现有运行契约；界面优化阶段 1–4 已完成，重构实现不与已验收 UI 行为并行修改；阶段 0–4 已完成。 |
| tunnelpad-rust-migration | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | Rust 只替换内部 Core；必须先继承已验收的 Swift 行为契约；已确认 C ABI 主路径为默认 bridge 方案，待独立准入复核通过后进入阶段 1，保持迁移变更隔离。 |

## 替代、合并和废弃

| 计划 | 关系 | 目标 | 原因 |
|---|---|---|---|
| - | - | - | - |

## 当前阻塞项

| 问题 | 推荐方案 | 影响范围 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|---|
| - | - | - | 否 | 已延后 |
| 阶段 1 实现与独立复核 | 阶段 1 已完成实现、fixture 验证和真实 ECS 只读回归；阶段 2 自动集成尚未启动，需另行准入。运行时任一双端点不一致、规则歧义、API 写入未确认或锁冲突都必须停止或保留新旧规则；Workbench 保留为恢复通道 | ecs-dynamic-ssh-ip 阶段 1 | 否 | 已通过 |
| Rust Core 组件 parity 与差分回归 | 阶段 0–1 已完成并通过独立复核；阶段 2 实现 9 类组件 parity 并以差分 harness 证明与 Swift 行为一致，任一不一致即暂停该组件替换 | tunnelpad-rust-migration 阶段 2 | 是（阶段 3 实施） | 实施中 |
| - | - | - | 否 | 已完成 |

## 完成证据

| 计划 | 阶段 | 证据 |
|---|---|---|
| tunnelpad-v1 | 阶段 0 | [基线快照](data-quality/tunnelpad-v1-stage0-baseline-20260829.md)（样本矩阵四项通过，2026-08-29） |
| tunnelpad-v1 | 阶段 1 | [接管与验证记录](data-quality/tunnelpad-v1-stage1-takeover-20260829.md)（双隧道接管/杀进程 1s 重连/退出即停双路径/重启恢复，2026-08-29） |
| tunnelpad-v1 | 阶段 2 | [功能与验收记录](data-quality/tunnelpad-v1-stage2-features-20260829.md)（9 行矩阵全过、app 执行器/探针/日志/打包，.app 交付，2026-08-29） |
| tunnelpad-ui-refinements | 阶段 1 | [阶段 1 收尾证据](data-quality/tunnelpad-ui-refinements-stage3-20260830.md)（关闭自动滚动回看保持、信息文案与 UI 收尾补验，2026-08-30） |
| tunnelpad-ui-refinements | 阶段 3 | [阶段 3 实机闭环证据](data-quality/tunnelpad-ui-refinements-stage3-20260830.md)（新建→删除、配置恢复、产物清理，2026-08-30） |
| tunnelpad-ui-refinements | 阶段 4 | [阶段 4 菜单栏证据](data-quality/tunnelpad-ui-refinements-stage4-20260830.md)（单项启停实机通过、移除批量启停入口、构建/测试/打包通过，2026-08-30） |
| tunnelpad-code-quality-refactor | 阶段 0 | [阶段 0 基线证据](data-quality/tunnelpad-code-quality-refactor-stage0-20260830.md)（兼容边界确认、调用图审计、风险热点和 63 项测试清单，2026-08-30） |
| tunnelpad-code-quality-refactor | 阶段 1 | [阶段 1 实施证据](data-quality/tunnelpad-code-quality-refactor-stage1-20260830.md)（Core 边界、异步取消保护及兼容切片；73 项测试与构建通过，2026-08-30） |
| tunnelpad-code-quality-refactor | 阶段 2–3 | [阶段 2–4 实施证据](data-quality/tunnelpad-code-quality-refactor-stage2-4-20260830.md)（异步生命周期、主面板拆分、共享表单和 AX 冒烟，2026-08-30） |
| tunnelpad-code-quality-refactor | 阶段 4 | [阶段 2–4 实施证据](data-quality/tunnelpad-code-quality-refactor-stage2-4-20260830.md)（失败注入、隔离 demo 生命周期、release 构建和治理检查通过，2026-08-30） |
| tunnelpad-rust-migration | 阶段 0 | [阶段 0 基线与复验证据](data-quality/tunnelpad-rust-migration-stage0-20260830.md)（基线、64e126fa 复验与独立准入复核通过，2026-08-30） |
| tunnelpad-rust-migration | 阶段 1 | [阶段 1 证据](data-quality/tunnelpad-rust-migration-stage1-20260830.md)（C ABI 原型 5 门槛通过与独立完成复核通过，2026-08-30） |
