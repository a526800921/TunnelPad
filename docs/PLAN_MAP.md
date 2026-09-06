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

### 已完成

| 计划 | 状态 | 当前阶段 | 最后更新 | 依赖 | 证据 |
|---|---|---|---|---|---|
| [TunnelPad 日志低写放大与流式保留](plans/tunnelpad-log-write-amplification.md) | 已完成 | - | 2026-09-05 | tunnelpad-log-streaming, tunnelpad-log-retention-energy-regression, tunnelpad-rust-migration | [阶段 1 实施证据](data-quality/tunnelpad-log-write-amplification-stage1-implementation-20260905.md)；[阶段 2 真实 Release 实施证据](data-quality/tunnelpad-log-write-amplification-stage2-implementation-20260905.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-log-write-amplification-stage2-independent-completion-review-20260905.md)；[专项计划](plans/tunnelpad-log-write-amplification.md) |
| [TunnelPad 隧道稳定性与健康恢复](plans/tunnelpad-stability.md) | 已完成 | - | 2026-09-02 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, ecs-dynamic-ssh-ip | [阶段 2 总体独立完成复核](data-quality/tunnelpad-stability-stage2-independent-completion-review-20260902.md)；[阶段 3 独立完成复核](data-quality/tunnelpad-stability-stage3-independent-completion-review-20260902.md)；[阶段 3 Step 0](data-quality/tunnelpad-stability-stage3-step0-20260902.md) |
| [TunnelPad Rust Core 风险收敛与覆盖率提升](plans/tunnelpad-core-hardening.md) | 已完成 | - | 2026-09-02 | tunnelpad-stability, tunnelpad-rust-migration | [阶段 1 实施证据](data-quality/tunnelpad-core-hardening-stage1-implementation-20260902.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-core-hardening-stage2-independent-completion-review-20260902.md) |
| [TunnelPad v1 隧道管理应用](plans/tunnelpad-v1.md) | 已完成 | - | 2026-08-29 | - | [阶段 2 功能与验收记录](data-quality/tunnelpad-v1-stage2-features-20260829.md) |
| [TunnelPad 界面优化](plans/tunnelpad-ui-refinements.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1 | [阶段 1 证据](data-quality/tunnelpad-ui-refinements-stage1-20260829.md)；[阶段 2 证据](data-quality/tunnelpad-ui-refinements-stage2-20260829.md)；[阶段 3 与阶段 1 收尾证据](data-quality/tunnelpad-ui-refinements-stage3-20260830.md)；[阶段 4 证据](data-quality/tunnelpad-ui-refinements-stage4-20260830.md) |
| [TunnelPad 代码质量重构](plans/tunnelpad-code-quality-refactor.md) | 已完成 | - | 2026-08-30 | tunnelpad-v1, tunnelpad-ui-refinements | [阶段 0 基线证据](data-quality/tunnelpad-code-quality-refactor-stage0-20260830.md)；[阶段 1 实施证据](data-quality/tunnelpad-code-quality-refactor-stage1-20260830.md)；[阶段 2–4 实施证据](data-quality/tunnelpad-code-quality-refactor-stage2-4-20260830.md)；[专项计划](plans/tunnelpad-code-quality-refactor.md) |
| [TunnelPad Rust Core 迁移](plans/tunnelpad-rust-migration.md) | 已完成 | - | 2026-08-31 | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | [阶段 5 删除后收尾证据](data-quality/tunnelpad-rust-migration-stage5-step0-20260830.md)；[ADR-0001](adr/0001-rust-core-single-owner.md)；[ADR-0002](adr/0002-app-bundle-id-migration.md)；[迁移说明](migrations/tunnelpad-rust-owner-cutover.md)；[专项计划](plans/tunnelpad-rust-migration.md) |
| [ECS 动态 SSH 公网 IP 同步](plans/ecs-dynamic-ssh-ip.md) | 已完成 | - | 2026-08-31 | tunnelpad-rust-migration（阶段 2 前置已完成） | [阶段 1 实现与验证](data-quality/ecs-dynamic-ssh-ip-stage1-implementation-20260829.md)；[阶段 2 实施与验收证据](data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md)（真实 App 启动/重启、负向隔离、恢复和 SSH 闭环通过，2026-08-31）；[专项计划](plans/ecs-dynamic-ssh-ip.md) |
| [TunnelPad 隧道备注说明与列表副标题](plans/tunnelpad-tunnel-remarks.md) | 已完成 | - | 2026-08-31 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration | [阶段 1–3 实施证据](data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md)；[专项计划](plans/tunnelpad-tunnel-remarks.md) |
| [TunnelPad 日志事件流与面板生命周期](plans/tunnelpad-log-streaming.md) | 已完成 | - | 2026-09-01 | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, tunnelpad-stability | [专项计划](plans/tunnelpad-log-streaming.md)；[阶段 0 基线证据](data-quality/tunnelpad-log-streaming-stage0-20260831.md)；[阶段 1 实施证据](data-quality/tunnelpad-log-streaming-stage1-step0-20260901.md)；[阶段 2 Step 0](data-quality/tunnelpad-log-streaming-stage2-step0-20260901.md)；[阶段 3 Step 0](data-quality/tunnelpad-log-streaming-stage3-step0-20260901.md)；[ADR-0003](adr/0003-log-event-stream-and-retention.md) |
| [TunnelPad 日志保留与能耗回归修复](plans/tunnelpad-log-retention-energy-regression.md) | 已完成 | - | 2026-09-05 | tunnelpad-log-streaming, tunnelpad-rust-migration | [阶段 1 实施证据](data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)；[阶段 2 真实验收](data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md) |
| [TunnelPad 后台健康监测能耗优化](plans/tunnelpad-health-monitor-energy.md) | 已完成 | - | 2026-09-05 | tunnelpad-stability, tunnelpad-rust-migration, tunnelpad-log-streaming, tunnelpad-unattended-managed-ssh-recovery, tunnelpad-log-retention-energy-regression | [日志修复后独立完成复核](data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)；[阶段 2 真实验收](data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md) |
| [TunnelPad 本机 HTTP API 服务](plans/tunnelpad-local-api.md) | 已完成 | - | 2026-09-02 | tunnelpad-stability, tunnelpad-rust-migration, tunnelpad-log-streaming, tunnelpad-core-hardening | [专项计划](plans/tunnelpad-local-api.md)；[阶段 0 基线证据](data-quality/tunnelpad-local-api-stage0-20260902.md)；[阶段 0 独立准入复核](data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md)；[阶段 1 实施证据](data-quality/tunnelpad-local-api-stage1-implementation-20260902.md)；[阶段 1 真实环境验收](data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md)；[阶段 2 Step 0](data-quality/tunnelpad-local-api-stage2-step0-20260902.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md) |
| [TunnelPad 无人值守受管 SSH 收敛恢复](plans/tunnelpad-unattended-managed-ssh-recovery.md) | 已完成 | - | 2026-09-04 | tunnelpad-stability, tunnelpad-rust-migration | [专项计划](plans/tunnelpad-unattended-managed-ssh-recovery.md)；[阶段 3 实施与真实验收](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)；[阶段 3 独立完成复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md) |

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
8. `tunnelpad-stability` 阶段 0–3 已完成并通过各自独立复核；阶段 2 的 ECS 自动恢复、启动/退出资源收敛、跨层状态一致性和配置重载资源收敛切片均已完成，真实 App/launchd 生命周期与探针假死触发 ECS 自动恢复验收已通过；阶段 3 的隔离 demo、Release 产物、受控 App 和最终治理门禁也已通过，稳定性计划已关闭。日志计划阶段 0–3 已完成，不再构成稳定性前置；后续稳定性若修改 `TunnelManager`、`TunnelRuntimeState`、主面板或共享测试目录，仍使用单一编辑窗口，不覆盖日志计划已验收行为。
9. `tunnelpad-log-retention-energy-regression` 阶段 0–2 已完成并通过独立复核；CRLF 行计数、尾部扫描、大日志日志保留、真实 CPU/Activity Monitor、两隧道状态和退出清理均已收口。
10. `tunnelpad-log-write-amplification` 新增为日志保留计划完成后的后续优化；阶段 0 基线、阶段 1 实现与回归、阶段 2 真实 Release 长期验收、Activity Monitor、退出清理和独立完成复核均已通过，计划已关闭。
11. `tunnelpad-health-monitor-energy` 首轮验收和隔夜反证均保留为历史；日志修复后的真实 Release 回归和最新独立完成复核已通过，计划已关闭；`refreshAsync` 实现仍不在范围。
12. `tunnelpad-unattended-managed-ssh-recovery` 阶段 0–3 已完成并通过独立完成复核；真实 Release App 单次目标 `SIGSTOP` 无人工释放、自动恢复、HTTP 探针和非目标隔离均已通过，计划已关闭。
13. `tunnelpad-core-hardening` 先完成 Rust Core 的 Step 0 独立准入，再实施 shutdown 重试修复、Core/FFI 反证测试和 production-only 覆盖率复测；不重新打开 `tunnelpad-stability`，也不引入 UI、app executor 或 pidfile/orphan 范围。
14. `tunnelpad-local-api` 阶段 0–2 已完成并通过独立复核；真实 Debug/签名 Release App 的固定 9998 启动、基础接口、端口冲突和退出清理验收已落盘。后续不扩大到远程访问、配置写入或 ECS。

## 依赖关系

| 计划 | 依赖 | 原因 |
|---|---|---|
| tunnelpad-v1 | - | - |
| ecs-dynamic-ssh-ip | tunnelpad-rust-migration（仅阶段 2，已完成） | 阶段 0/1 不依赖 Rust 迁移；当前阶段 2 只消费已完成的 Rust Core 唯一 owner、version=1 配置和 launchd 边界，不重新修改迁移 owner。 |
| tunnelpad-ui-refinements | tunnelpad-v1 | 前置 v1 已完成；本计划不修改 config schema 与隧道启停语义，与 ecs-dynamic-ssh-ip 无依赖。 |
| tunnelpad-code-quality-refactor | tunnelpad-v1, tunnelpad-ui-refinements | v1 提供现有运行契约；界面优化阶段 1–4 已完成，重构实现不与已验收 UI 行为并行修改；阶段 0–4 已完成。 |
| tunnelpad-rust-migration | tunnelpad-v1, tunnelpad-ui-refinements, tunnelpad-code-quality-refactor | Rust Core 阶段 0–5 已完成；阶段 5 的唯一 owner 切换、真实隧道验证、删除后回归和独立收尾复核均已通过。 |
| tunnelpad-stability | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, ecs-dynamic-ssh-ip | 稳定性行为增强依赖 Rust Core 阶段 5 的唯一 owner，并复用 ECS 动态 SSH 阶段 2 的受管来源同步边界；阶段 0–3 已完成并通过独立复核，隔离 demo、受控应用、Release 产物和治理门禁均已收口；日志计划已完成但共享实现仍须串行。 |
| tunnelpad-log-retention-energy-regression | tunnelpad-log-streaming, tunnelpad-rust-migration | 复用已完成日志计划的 2000 行保留/锁失败契约和 Rust Core owner 边界；独立承接隔夜复验发现的 CRLF 漏计与全文裁剪热点，修复后向能耗计划提供长期复验输入。 |
| tunnelpad-health-monitor-energy | tunnelpad-stability, tunnelpad-rust-migration, tunnelpad-log-streaming, tunnelpad-unattended-managed-ssh-recovery, tunnelpad-log-retention-energy-regression | 首轮验收和隔夜反证均保留为历史；日志实现缺陷由独立计划修复并通过真实 Release 回归，能耗阶段 2 已据最新独立完成复核重新关闭。`refreshAsync` 实现不在范围。 |
| tunnelpad-log-write-amplification | tunnelpad-log-streaming, tunnelpad-log-retention-energy-regression, tunnelpad-rust-migration | 复用已完成日志事件流、2000 行保留、500 条内存缓存、launchd 文件身份和 Rust Core owner 边界；承接真实 Release 复验发现的整文件重写写放大，阶段 0 先冻结流式追加、高水位批量压缩和 512 KiB 临时超限边界。 |
| tunnelpad-unattended-managed-ssh-recovery | tunnelpad-stability, tunnelpad-rust-migration | 复用既有 Rust Core 唯一 owner、健康恢复 generation 和 ECS fail-closed；已完成受管 PID 身份核验、信号升级、自动冷却及无人工真实验收，计划已关闭。 |
| tunnelpad-log-streaming | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration, tunnelpad-stability（仅共享实现串行，不构成阶段 0 前置） | 日志事件流依赖 Rust Core 阶段 5 的最终 owner 和当前 `launchd` 范围；阶段 0–3 已完成并通过本计划自身 fixture、隔离 App 和发布门禁；稳定性阶段 2 四个当前切片、无运行中受管隧道的真实 App 验收及单条 `admin-tunnel` 真实生命周期验收已完成，共享实现仍保持单一编辑窗口。 |
| tunnelpad-tunnel-remarks | tunnelpad-v1, tunnelpad-code-quality-refactor, tunnelpad-rust-migration | 备注字段依赖 Rust Core 阶段 5 确认的配置事实源；阶段 0–3 已完成并通过专项复核；与日志事件流共享侧栏文件，后续改动必须串行。 |
| tunnelpad-core-hardening | tunnelpad-stability, tunnelpad-rust-migration | 复用已完成的 Rust Core 生命周期/配置 owner 和稳定性反证边界；本计划只收敛 shutdown 重试、Core/FFI 测试及覆盖率，不改变既有公共契约。 |
| tunnelpad-local-api | tunnelpad-stability, tunnelpad-rust-migration, tunnelpad-log-streaming, tunnelpad-core-hardening | API 只消费已完成的稳定性、日志和 Rust owner 边界；实现会触及 `TunnelManager`/AppDelegate/测试共享面，需与 Core hardening 的生命周期修改保持单一编辑窗口。 |

## 替代、合并和废弃

| 计划 | 关系 | 目标 | 原因 |
|---|---|---|---|
| - | - | - | - |

## 当前阻塞项

| 问题 | 推荐方案 | 影响范围 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|---|
| - | - | - | 否 | 已延后 |
| 日志保留与能耗回归修复阶段 2 真实回归 | [阶段 2 真实验收](data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)和[阶段 2 独立完成复核](data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)已通过；两隧道窗口、日志 2000 LF、CPU/能耗、运行栈和清理均已核对 | tunnelpad-log-retention-energy-regression 阶段 2；曾阻塞能耗计划阶段 2 | 否 | 已完成 |
| 后台健康监测能耗优化阶段 2 夜间复验未通过 | [真实运行反证](data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)已由日志保留修复计划的真实 Release 回归和[最新独立完成复核](data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)处理 | tunnelpad-health-monitor-energy 阶段 2 | 否 | 已完成 |
| 阶段 2 自动集成实施 | `ECSPreStartChecker` 已补齐 Finder/launchd 的 PATH/HOME 兜底；真实 App 启动/重启、负向失败隔离、恢复重试、探针和本机 SSH 闭环均已通过 | ecs-dynamic-ssh-ip 阶段 2 | 否 | 已完成 |
| Rust Core 阶段 5 独立收尾复核 | 阶段 5 完成条件逐项核对；旧 Swift Core/app 实现已删除，删除后回归、最终反向引用审计和最新打包 App 实机验证已完成 | tunnelpad-rust-migration 阶段 5 | 否 | 已完成 |
| TunnelPad 稳定性实现前置 | Rust Core 阶段 5、日志计划阶段 0–3、稳定性阶段 0–3 已完成并通过独立复核；阶段 2 四个切片、真实 App/launchd 生命周期和探针假死自动恢复验收已通过，阶段 3 隔离 demo、Release 和治理门禁已收口；未来 `app` 执行器仍另立计划 | tunnelpad-stability | 否 | 已完成 |
| TunnelPad 日志事件流实现前置 | Rust Core、ECS 阶段 2 和备注阶段 1–3 已完成；日志计划阶段 0–3 已通过独立复核；Rust 50+1 差分、Swift 101/101、Release 构建、隔离 Release App 和治理门禁已通过 | tunnelpad-log-streaming 阶段 0–3 | 否 | 已完成 |
| TunnelPad 隧道备注实现前置 | Rust Core 迁移阶段 5 已完成并确定 Rust 配置事实源；本计划阶段 0–3 已完成，备注专项完成复核通过 | tunnelpad-tunnel-remarks 阶段 1–3 | 否 | 已完成 |
| Rust Core 风险收敛阶段 0 独立准入 | 基线复验、C0–C7 fixture 矩阵和独立只读复核已通过；阶段 1 可实施 | tunnelpad-core-hardening 阶段 0 | 否 | 已完成 |
| 本机 HTTP API 阶段 1–2 实现与验收 | SwiftNIO Server、backend、AppDelegate 接入、typed result、原位清空日志、随机端口契约测试、真实 Debug/签名 Release App、固定 9998 端口冲突、退出清理和独立复核均已完成 | tunnelpad-local-api 阶段 1–2 | 否 | 已完成 |
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
| tunnelpad-stability | 阶段 0 | [阶段 0 基线证据](data-quality/tunnelpad-stability-stage0-20260901.md)；[阶段 0 独立准入复核](data-quality/tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md)（现状基线、6 项契约 fixture 和独立准入通过，2026-09-01） |
| tunnelpad-stability | 阶段 1 Step 0 | [阶段 1 Step 0 证据](data-quality/tunnelpad-stability-stage1-step0-20260902.md)（生产实现基线、4 个高影响目标、8 类故障注入矩阵和验证/回滚边界已登记，独立准入已通过，2026-09-02） |
| tunnelpad-stability | 阶段 1 准入 | [阶段 1 独立准入复核（r2）](data-quality/tunnelpad-stability-stage1-independent-review-20260902-r2.md)（Step 0、8 行矩阵、影响复核、验证/回滚边界和共享日志边界通过，达到“待实施标准”，2026-09-02） |
| tunnelpad-stability | 阶段 1 实施 | [阶段 1 实施证据](data-quality/tunnelpad-stability-stage1-implementation-20260902.md)（后台监测、3 次失败恢复、10 次熔断停止、`keepAlive=false`、手动操作/删除取消、配置 fail-closed 和 `bootout` fail-closed 的隔离验证通过，2026-09-02） |
| tunnelpad-stability | 阶段 1 完成复核 | [阶段 1 独立完成复核](data-quality/tunnelpad-stability-stage1-independent-completion-review-20260902.md)（9/9 专项测试、全量 Swift/Rust 回归、范围和安全边界核对通过；阶段 2 保持设计中，2026-09-02） |
| tunnelpad-stability | 阶段 2 ECS 自动恢复切片准入 | [独立准入复核](data-quality/tunnelpad-stability-stage2-ecs-recovery-independent-review-20260902.md)（bootout-first、`notLoaded` 门禁、ECS fail-closed、影响/验证/回滚边界通过；后续阶段 2 切片不在范围内，2026-09-02） |
| tunnelpad-stability | 阶段 2 ECS 自动恢复切片实施 | [实施证据](data-quality/tunnelpad-stability-stage2-ecs-recovery-implementation-20260902.md)（5/5 专项、123/123 Swift、Rust 51+1 和治理门禁通过；启动/退出与跨层一致性随后由各自切片补齐，2026-09-02） |
| tunnelpad-stability | 阶段 2 启动/退出资源收敛切片准入 | [独立准入复核](data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-review-20260902.md)（启动首轮状态发现、shutdown 单入口、逐条清理和失败/回滚边界达到“待实施”标准，2026-09-02） |
| tunnelpad-stability | 阶段 2 启动/退出资源收敛切片实施 | [实施证据](data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-implementation-20260902.md)（启动 fixture 2/2、阶段 2 专项 7/7、Swift 125/125、Rust 53+1 和治理门禁通过；跨层一致性随后由独立切片补齐，2026-09-02） |
| tunnelpad-stability | 阶段 2 启动/退出资源收敛切片完成复核 | [独立完成复核](data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-completion-review-20260902.md)（当前仓库代码、启动/退出失败注入、专项与全量回归、治理和变更范围独立核对通过；仅关闭该切片，跨层一致性随后由独立切片补齐，2026-09-02） |
| tunnelpad-stability | 阶段 2 跨层状态一致性切片 Step 0 | [Step 0 基线证据](data-quality/tunnelpad-stability-stage2-cross-layer-consistency-step0-20260902.md)；[独立准入复核](data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-review-20260902.md)（统一结果门禁、busy 状态保护、C1–C8 矩阵和回滚边界已登记并达到“待实施”标准，2026-09-02） |
| tunnelpad-stability | 阶段 2 跨层状态一致性切片实施 | [实施证据](data-quality/tunnelpad-stability-stage2-cross-layer-consistency-implementation-20260902.md)（迟到 snapshot/probe 结果门禁、生命周期失效、busy 状态保护；专项 11/11、Swift 129/129、Rust 53+1、治理和变更范围检查通过，2026-09-02） |
| tunnelpad-stability | 阶段 2 跨层状态一致性切片完成复核 | [独立完成复核](data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-completion-review-20260902.md)（C1–C3/C7 反证、当前代码、专项与全量回归、治理和变更范围独立核对通过；仅关闭该切片，阶段 2 整体仍在实施，2026-09-02） |
| tunnelpad-stability | 阶段 2 真实 App 受控验收 | [真实 App 受控验收](data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md)（旧版 App 正常退出、当前 App 构建/签名/启动、`not_loaded` 状态发现、真实 `admin-tunnel` 启动/HTTP `401`、KeepAlive 重拉起、App 崩溃后重启发现、正常退出清理和无 App/label 残留通过；ECS 仅执行 `--check` 未写入，2026-09-02） |
| tunnelpad-stability | 阶段 2 跨层状态一致性切片准入 | [独立准入复核](data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-review-20260902.md)（异步快照/探针结果门禁、busy 状态保护、迟到结果失效和 C1–C8 矩阵达到“待实施”标准；2026-09-02） |
| tunnelpad-stability | 阶段 2 配置重载资源收敛切片 Step 0 | [Step 0 基线证据](data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-step0-20260902.md)；[独立准入复核](data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-review-20260902.md)（删除 label 先停止/复核再提交、失败保留旧 owner 配置、同 ID 参数修改下次显式重启生效；CfgR-1–CfgR-9 矩阵达到“待实施”标准，2026-09-02） |
| tunnelpad-stability | 阶段 2 配置重载资源收敛切片实施 | [实施证据](data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-implementation-20260902.md)（删除 label 先停止/复核再提交、候选失败保留旧 owner 配置、新增不自动启动、同 ID 参数不自动重启；CfgR-1–CfgR-9、Rust 62+1 和 Swift 129 回归通过，已通过独立完成复核，2026-09-02） |
| tunnelpad-stability | 阶段 2 配置重载资源收敛切片完成复核 | [独立完成复核](data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-completion-review-20260902.md)（候选失败保留旧 owner 配置、删除 label 先停止/复核、同 ID 参数不自动重启；CfgR-1–CfgR-9、Rust 62+1、Swift 129、治理和 App 冒烟边界通过，2026-09-02） |
| tunnelpad-stability | 阶段 2 真实探针假死/ECS 自动恢复验收 | [真实 App 受控验收](data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md#追加验收http-探针假死触发-ecs-自动恢复)（真实 PID 身份校验后 `SIGSTOP`；连续 3 次探针失败；`stop → ECSPreStartChecker.checkAsync → start`；同步日志 `already_current`；新 PID `15710` 与 HTTP `401`；清理后无 App/label/PID/端口残留，2026-09-02） |
| tunnelpad-stability | 阶段 2 总体独立完成复核 | [独立完成复核](data-quality/tunnelpad-stability-stage2-independent-completion-review-20260902.md)（四个切片、真实 App/launchd 生命周期、探针假死触发 ECS 自动恢复、Swift/Rust、治理和环境清理均通过，阶段 3 保持设计中，2026-09-02） |
| tunnelpad-stability | 阶段 3 Step 0 | [阶段 3 Step 0 证据](data-quality/tunnelpad-stability-stage3-step0-20260902.md)（隔离 demo、Release 产物、受控 App 和治理门禁矩阵已固定，尚未获得阶段 3 独立准入，2026-09-02） |
| tunnelpad-stability | 阶段 3 独立准入 | [独立准入复核](data-quality/tunnelpad-stability-stage3-independent-review-20260902.md)（Step 0、样本矩阵、验证/回滚边界和阶段 2 前置均通过，达到“待实施”标准，2026-09-02） |
| tunnelpad-core-hardening | 阶段 0 | [阶段 0 基线与独立准入](data-quality/tunnelpad-core-hardening-stage0-20260902.md)；[独立准入复核](data-quality/tunnelpad-core-hardening-stage0-independent-review-20260902.md)（C0–C7、覆盖率采集链路、CRITICAL impact 和回滚边界通过，2026-09-02） |
| tunnelpad-core-hardening | 阶段 1–2 | [阶段 1 实施证据](data-quality/tunnelpad-core-hardening-stage1-implementation-20260902.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-core-hardening-stage2-independent-completion-review-20260902.md)（shutdown 重试、Core/FFI 反证、production-only 85.16%、Rust/治理门禁通过，2026-09-02） |
| tunnelpad-local-api | 阶段 0 | [阶段 0 基线证据](data-quality/tunnelpad-local-api-stage0-20260902.md)；[阶段 0 独立准入复核](data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md)（本机回环 API 契约、A0–A9 矩阵、适配边界、失败/回滚策略和 CRITICAL impact 已复核，达到“待实施”标准，2026-09-02） |
| tunnelpad-local-api | 阶段 1–2 | [阶段 1 实施证据](data-quality/tunnelpad-local-api-stage1-implementation-20260902.md)；[阶段 1 真实环境验收](data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md)；[阶段 2 Step 0](data-quality/tunnelpad-local-api-stage2-step0-20260902.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md)（SwiftNIO Server、MainActor backend、typed result、原位日志清空；API 4/4、日志 11/11、全量 Swift 134/134；真实 Debug/签名 Release App 固定 9998、9 路由基础响应、详情/日志状态、未知 ID、端口冲突、退出清理和独立复核通过，2026-09-02） |
| tunnelpad-unattended-managed-ssh-recovery | 阶段 1 实施 | [实施证据](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-implementation-20260904.md)；[独立完成复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage1-independent-completion-review-20260904.md)（Rust 72+1、Swift 139、身份复核/有界信号/初始未加载与状态异常 fail-closed、自动冷却通过；GitNexus 影响仍为 `critical`，2026-09-04） |
| tunnelpad-unattended-managed-ssh-recovery | 阶段 2 Step 0 与准入 | [阶段 2 Step 0](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-step0-20260904.md)；[独立准入复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-review-20260904.md)（Release/FFI/隔离 App 矩阵、失败/回滚边界通过，达到待实施标准；2026-09-04） |
| tunnelpad-unattended-managed-ssh-recovery | 阶段 2 实施与完成复核 | [阶段 2 实施证据](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-implementation-20260904.md)；[独立完成复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md)（Release/FFI/隔离 App、签名/资源和启动退出通过；2026-09-04） |
| tunnelpad-unattended-managed-ssh-recovery | 阶段 3 Step 0 与准入 | [阶段 3 Step 0](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-step0-20260904.md)；[独立准入复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-review-20260904.md)（真实目标/非目标、身份核验、单次 SIGSTOP、无人工观察和回滚矩阵通过，达到待实施标准；2026-09-04） |
| tunnelpad-unattended-managed-ssh-recovery | 阶段 3 实施与完成复核 | [阶段 3 实施与真实验收](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-implementation-20260904.md)；[阶段 3 独立完成复核](data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)（真实 Release App 单次目标 SIGSTOP 无人工释放，自动恢复到新 PID 与 HTTP 401/satisfied，非目标隧道不变；Rust 76+1、Swift 139/139、Release/治理门禁通过；2026-09-04） |
| tunnelpad-health-monitor-energy | 阶段 2 首轮独立完成复核（历史） | [能耗计划独立完成复核](data-quality/tunnelpad-health-monitor-energy-independent-completion-review-20260904.md)（仅保留首轮窗口结论；当前以[2026-09-05 隔夜复验未通过](data-quality/tunnelpad-health-monitor-energy-overnight-revalidation-20260905.md)为准，不能据历史记录关闭计划） |
| tunnelpad-health-monitor-energy | 完成后回归修复 | [回归修复与验证](data-quality/tunnelpad-health-monitor-energy-post-completion-regression-fix-20260904.md)（无探针隧道启动后的 `xpcproxy` 状态仅在显式 start/restart 内有界复核；Swift 140/140，治理检查通过，2026-09-04） |
| tunnelpad-log-retention-energy-regression | 阶段 0–2 | [阶段 0 独立准入复核](data-quality/tunnelpad-log-retention-energy-regression-stage0-independent-review-20260905.md)；[阶段 1 实施证据](data-quality/tunnelpad-log-retention-energy-regression-stage1-implementation-20260905.md)；[阶段 2 真实验收](data-quality/tunnelpad-log-retention-energy-regression-stage2-implementation-20260905.md)；[阶段 2 独立完成复核](data-quality/tunnelpad-log-retention-energy-regression-stage2-independent-completion-review-20260905.md)（CRLF/尾部扫描修复、Swift/Rust/Release、真实两隧道 CPU/能耗、日志 2000 LF、运行栈和清理通过，2026-09-05） |
| tunnelpad-health-monitor-energy | 阶段 2 日志修复后重新完成复核 | [日志修复后独立完成复核](data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md)（真实两隧道 Release 窗口、CPU/Activity Monitor、日志保留、状态、运行栈和资源清理通过，阶段 2 关闭，2026-09-05） |
| tunnelpad-health-monitor-energy | 修复后隔夜对比基线与 09-06 复测（观测记录，非复核） | [修复后隔夜对比基线](data-quality/tunnelpad-health-monitor-energy-post-fix-overnight-baseline-20260905.md)（2026-09-05 19:14–19:18 只读采集：修复构建进程 CPU 峰值 0.7% 且无周期峰、RSS 约 146.7 MiB、隧道日志自 13:53/13:57 起零写入、活动监视器能耗影响 0.5→0.0、12 小时电源 184.97 为滚动均值锚点；[09-06 复测追加](data-quality/tunnelpad-health-monitor-energy-post-fix-overnight-baseline-20260905.md#2026-09-06-复测结果追加)显示全部预期满足：12 小时电源回落至 0.39、CPU 无 >2% 周期峰（仅 10 秒探针节奏 ≤1.5% 单样本毛刺）、日志零写入、双隧道与探针正常；2026-09-05/06） |
