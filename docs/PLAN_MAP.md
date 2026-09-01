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

## 功能图谱

- [TunnelPad 功能图谱](graph/functional.yaml)
- [功能图谱审计与潜在问题](data-quality/tunnelpad-functional-graph-review-20260830.md)

## 计划索引

### 未完成

| 计划 | 状态 | 当前阶段 | 最后更新 | 依赖 | 证据 |
|---|---|---|---|---|---|
| [TunnelPad 隧道稳定性与健康恢复](plans/tunnelpad-stability.md) | 设计中 | 阶段 0 | 2026-09-01 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, ecs-dynamic-ssh-ip | [专项计划](plans/tunnelpad-stability.md)；[阶段 0 基线证据](data-quality/tunnelpad-stability-stage0-20260901.md)；[功能图谱审计](data-quality/tunnelpad-functional-graph-review-20260830.md) |

### 已完成

| 计划 | 状态 | 当前阶段 | 最后更新 | 依赖 | 证据 |
|---|---|---|---|---|---|
| [TunnelPad v1 隧道管理应用](plans/tunnelpad-v1.md) | 已完成 | - | 2026-08-29 | - | [阶段 2 功能与验收记录](data-quality/tunnelpad-v1-stage2-features-20260829.md) |
| [TunnelPad 界面优化](plans/tunnelpad-ui-refinements.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1 | [阶段 1 证据](data-quality/tunnelpad-ui-refinements-stage1-20260829.md)；[阶段 2 证据](data-quality/tunnelpad-ui-refinements-stage2-20260829.md)；[阶段 3 与阶段 1 收尾证据](data-quality/tunnelpad-ui-refinements-stage3-20260830.md)；[阶段 4 证据](data-quality/tunnelpad-ui-refinements-stage4-20260830.md) |
| [TunnelPad 代码质量重构](plans/tunnelpad-code-quality-refactor.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1, tunnelpad-ui-refinements | [阶段 0 基线证据](data-quality/tunnelpad-code-quality-refactor-stage0-20260830.md)；[阶段 1 实施证据](data-quality/tunnelpad-code-quality-refactor-stage1-20260830.md)；[阶段 2–4 实施证据](data-quality/tunnelpad-code-quality-refactor-stage2-4-20260830.md)；[专项计划](plans/tunnelpad-code-quality-refactor.md) |
| [TunnelPad Rust Core 迁移](plans/tunnelpad-rust-migration.md) | 已完成 | - | 2026-08-31 | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | [阶段 5 删除后收尾证据](data-quality/tunnelpad-rust-migration-stage5-step0-20260830.md)；[ADR-0001](adr/0001-rust-core-single-owner.md)；[ADR-0002](adr/0002-app-bundle-id-migration.md)；[迁移说明](migrations/tunnelpad-rust-owner-cutover.md)；[专项计划](plans/tunnelpad-rust-migration.md) |
| [ECS 动态 SSH 公网 IP 同步](plans/ecs-dynamic-ssh-ip.md) | 已完成 | - | 2026-08-31 | tunnelpad-rust-migration（阶段 2 前置已完成） | [阶段 1 实现与验证](data-quality/ecs-dynamic-ssh-ip-stage1-implementation-20260829.md)；[阶段 2 实施与验收证据](data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md)（真实 App 启动/重启、负向隔离、恢复和 SSH 闭环通过，2026-08-31）；[专项计划](plans/ecs-dynamic-ssh-ip.md) |
| [TunnelPad 隧道备注说明与列表副标题](plans/tunnelpad-tunnel-remarks.md) | 已完成 | - | 2026-08-31 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration | [阶段 1–3 实施证据](data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md)；[专项计划](plans/tunnelpad-tunnel-remarks.md) |
| [TunnelPad 日志事件流与面板生命周期](plans/tunnelpad-log-streaming.md) | 已完成 | - | 2026-09-01 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, tunnelpad-stability | [专项计划](plans/tunnelpad-log-streaming.md)；[阶段 0 基线证据](data-quality/tunnelpad-log-streaming-stage0-20260831.md)；[阶段 1 实施证据](data-quality/tunnelpad-log-streaming-stage1-step0-20260901.md)；[阶段 2 Step 0](data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md)；[阶段 3 Step 0](data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md)；[ADR-0003](adr/0003-log-event-stream-and-retention.md) |

### 已废弃

| 计划 | 状态 | 当前阶段 | 最后更新 | 依赖 | 证据 |
|---|---|---|---|---|---|

允许状态：`候选`、`设计中`、`待实施`、`实施中`、`已完成`、`已替代`、`已合并`、`已废弃`。

## 推荐顺序

1. `tunnelpad-v1`、`tunnelpad-ui-refinements`、`tunnelpad-code-quality-refactor`、`tunnelpad-rust-migration` 与 `ecs-dynamic-ssh-ip` 均已完成，作为当前实现基线。
2. `ecs-dynamic-ssh-ip` 已完成 Finder/launchd 运行环境修复及真实 App→ECS→隧道→SSH 端到端验收；后续如需定时同步、UI 设置项或 Keychain 凭证管理，另立计划。
3. `tunnelpad-ui-refinements` 已完成；后续与当前未完成计划无运行时依赖。
4. `tunnelpad-code-quality-refactor` 阶段 0–4 已完成；后续共享模块改动按各专项计划的独立准入顺序推进。
5. `tunnelpad-rust-migration` 阶段 5 已完成并关闭；当前 Rust `launchd` owner、配置事实源和 Bundle ID 决策以专项计划及 ADR 为准。
6. `tunnelpad-tunnel-remarks` 阶段 0–3 已完成；Rust Core 迁移阶段 5 已完成并确定 Rust 配置事实源，备注模型、双表单、列表副标题、差分、Release/AX 和回归证据已落盘。
7. `tunnelpad-log-streaming` 阶段 0–3 已完成并通过独立复核；阶段 1 的 launchd 文件采集、事件、500 条缓存、8000 字符单行、2000 行文件保留和锁失败重试已通过 10/10 专项测试与 101/101 全量回归，阶段 2 的隔离 App 追加、关闭/重开、切换和滚动位置冒烟及阶段 3 的 Rust/Swift、Release、签名和治理门禁已通过。共享模块改动继续使用单一编辑窗口。
8. `tunnelpad-stability` 保持暂停/独立边界；日志计划当前实现以本工作树为准，但不覆盖稳定性计划文档、测试或其生命周期决策。后续若恢复稳定性实现，仍需与日志计划共享模块串行。

## 依赖关系

| 计划 | 依赖 | 原因 |
|---|---|---|
| tunnelpad-v1 | - | - |
| ecs-dynamic-ssh-ip | tunnelpad-rust-migration（仅阶段 2，已完成） | 阶段 0/1 不依赖 Rust 迁移；当前阶段 2 只消费已完成的 Rust Core 唯一 owner、version=1 配置和 launchd 边界，不重新修改迁移 owner。 |
| tunnelpad-ui-refinements | tunnelpad-v1 | 前置 v1 已完成；本计划不修改 config schema 与隧道启停语义，与 ecs-dynamic-ssh-ip 无依赖。 |
| tunnelpad-code-quality-refactor | tunnelpad-v1, tunnelpad-ui-refinements | v1 提供现有运行契约；界面优化阶段 1–4 已完成，重构实现不与已验收 UI 行为并行修改；阶段 0–4 已完成。 |
| tunnelpad-rust-migration | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | Rust Core 阶段 0–5 已完成；阶段 5 的唯一 owner 切换、真实隧道验证、删除后回归和独立收尾复核均已通过。 |
| tunnelpad-stability | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, ecs-dynamic-ssh-ip | 稳定性行为增强依赖 Rust Core 阶段 5 的唯一 owner，并复用 ECS 动态 SSH 阶段 2 的受管来源同步边界；阶段 0 可继续设计，阶段 1 实施前还需本计划自身独立准入。 |
| tunnelpad-log-streaming | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, tunnelpad-stability（仅共享实现串行，不构成阶段 0 前置） | 日志事件流依赖 Rust Core 阶段 5 的最终 owner 和当前 `launchd` 范围；阶段 0 与 tunnelpad-stability 可并行，阶段 1–3 已完成并通过本计划自身 fixture、隔离 App 和发布门禁；后续若恢复稳定性实现，涉及共享模块仍保持单一编辑窗口。 |
| tunnelpad-tunnel-remarks | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration | 备注字段依赖 Rust Core 阶段 5 确认的配置事实源；阶段 0–3 已完成并通过专项复核；与日志事件流共享侧栏文件，后续改动必须串行。 |

## 替代、合并和废弃

| 计划 | 关系 | 目标 | 原因 |
|---|---|---|---|
| - | - | - | - |

## 当前阻塞项

| 问题 | 推荐方案 | 影响范围 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|---|
| - | - | - | 否 | 已延后 |
| 阶段 2 自动集成实施 | `ECSPreStartChecker` 已补齐 Finder/launchd 的 PATH/HOME 兜底；真实 App 启动/重启、负向失败隔离、恢复重试、探针和本机 SSH 闭环均已通过 | ecs-dynamic-ssh-ip 阶段 2 | 否 | 已完成 |
| Rust Core 阶段 5 独立收尾复核 | 阶段 5 完成条件逐项核对；旧 Swift Core/app 实现已删除，删除后回归、最终反向引用审计和最新打包 App 实机验证已完成 | tunnelpad-rust-migration 阶段 5 | 否 | 已完成 |
| TunnelPad 稳定性实现前置 | Rust Core 迁移阶段 5 已完成；继续推进本计划阶段 0，阶段 1 实施仍需本计划自身独立准入 | tunnelpad-stability 阶段 1–3 | 否（阻塞阶段 1） | 进行中 |
| TunnelPad 日志事件流实现前置 | Rust Core、ECS 阶段 2 和备注阶段 1–3 已完成；日志计划阶段 0–3 已通过独立复核；Rust 50+1 差分、Swift 101/101、Release 构建、隔离 Release App 和治理门禁已通过 | tunnelpad-log-streaming 阶段 0–3 | 否 | 已完成 |
| TunnelPad 隧道备注实现前置 | Rust Core 迁移阶段 5 已完成并确定 Rust 配置事实源；本计划阶段 0–3 已完成，备注专项完成复核通过 | tunnelpad-tunnel-remarks 阶段 1–3 | 否 | 已完成 |
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
| tunnelpad-rust-migration | 阶段 2 | [阶段 2 证据](data-quality/tunnelpad-rust-migration-stage2-20260830.md)（9 类组件 parity、差分全绿、突变反证与独立完成复核通过，2026-08-30） |
| tunnelpad-rust-migration | 阶段 3 | [阶段 3 证据](data-quality/tunnelpad-rust-migration-stage3-20260830.md)（demo 生命周期、takeover、generation 竞态与差分门禁通过；治理同步后 strict-readiness 通过，2026-08-30） |
| tunnelpad-rust-migration | 阶段 4 | [阶段 4 Step 0 证据](data-quality/tunnelpad-rust-migration-stage4-step0-20260830.md)（shadow bridge、回退、固定时区、Release/AX 和独立准入复核通过，2026-08-30） |
| tunnelpad-rust-migration | 阶段 5 | [阶段 5 删除后收尾证据](data-quality/tunnelpad-rust-migration-stage5-step0-20260830.md)（Rust owner 切换、旧 Swift Core 删除、真实隧道、Release/AX、删除后回归、反向引用审计和独立收尾复核通过，2026-08-31） |
| ecs-dynamic-ssh-ip | 阶段 0–2 | [阶段 1 实现与验证](data-quality/ecs-dynamic-ssh-ip-stage1-implementation-20260829.md)；[阶段 2 实施与验收证据](data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md)（PATH/HOME 兜底、自动化、资源/签名、真实 App 启动/重启、负向隔离、恢复和 SSH 闭环通过，2026-08-31） |
| tunnelpad-tunnel-remarks | 阶段 1–3 | [阶段 1–3 实施证据](data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md)（备注配置、双表单、列表副标题、差分、smoke、Release/AX 和独立完成复核通过，2026-08-31） |
| tunnelpad-log-streaming | 阶段 0 | [阶段 0 基线证据](data-quality/tunnelpad-log-streaming-stage0-20260831.md)（现状最小复现、Rust owner、并行边界和独立准入复核通过，2026-09-01） |
| tunnelpad-log-streaming | 阶段 1 | [阶段 1 Step 0 与实施证据](data-quality/tunnelpad-log-streaming-stage1-step0-20260901.md)（10/10 专项测试、101/101 全量回归；500 条内存缓存、8000 字符单行、2000 行文件保留、锁失败边界和事件恢复通过，2026-09-01） |
| tunnelpad-log-streaming | 阶段 2 | [阶段 2 Step 0 证据](data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md)（面板 session、关闭/重开、隧道切换、版本过滤、自动滚动、无 Timer 契约和隔离 App 冒烟通过，2026-09-01） |
| tunnelpad-log-streaming | 阶段 3 Step 0 | [阶段 3 Step 0 证据](data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md)（Rust/Swift 回归、Release target/dylib、隔离 Release App 签名/启动和发布门禁矩阵通过，2026-09-01） |
| tunnelpad-log-streaming | 阶段 3 | [阶段 3 Step 0 证据](data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md)（Rust/Swift 回归、Release target/dylib、隔离 Release App 签名/启动、锁失败重试和治理门禁通过，2026-09-01） |
