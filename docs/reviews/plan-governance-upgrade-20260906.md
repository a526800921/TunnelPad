# 计划规范同步与文档复核

- 日期：2026-09-06。
- 受审基线：`cf3cd37d1b8cf10965f532f4a828696a7d0f3b18`；范围为本次工作树 Markdown 差异。
- 目标：按用户指定的新版 plan-governance 同步现有计划，保持既有阶段门禁、历史独立结论及业务范围。
- 规范入口：已安装 `plan-governance` skill 的 SKILL.md、三个 references；与 CLI `1.0.0` 的同名规则及两个计划模板逐文件一致。

## 基线与实际范围

- 初始工作树干净；14 个计划均为 `已完成`，当前阶段均为 `-`；普通及严格治理检查通过。
- 带历史的工作集原有 21 条警告，包含自由文字被误读为阻塞、能耗计划已解决事项仍为“是 / 待决策”、日志保留计划布尔字段混入旧阶段说明。
- 本次修改 14 个专项计划、PLAN_MAP、ADR-0003 和 Rust owner migration，以及本复核记录；本地 AGENTS.md、CLAUDE.md 通过 `init --root . --update-agent-rules-only` 更新治理受管块。两份代理规则已被仓库 .gitignore 忽略，不属于可提交 diff；已核对工具仅替换受管块，当前 ECS 约定和 GitNexus 内容仍在。未保存两文件更新前 hash，因此不声称独立完成了块外前后字节比较。
- 仓库 `scripts/check_plan_governance.py` 是尚不支持风险分流的旧副本，本次未修改；使用已核对同源的安装 CLI。未安装依赖、修改源码/测试/配置、构建或操作本机/云端服务，未提交。

## 同步内容与证据归属

| 项目 | 本次处理 | 可核对入口 |
|---|---|---|
| 新规范与旧计划 | 新计划使用同源风险模板；已完成计划保持旧独立历史；移除计划头部重复状态元数据，最后更新归地图 | [规范适用与历史兼容](../PLAN_MAP.md#规范适用与历史兼容)；14 个计划顶部说明 |
| 当前阻塞表达 | 当前摘要的无阻塞字段统一为 `无`，补充说明移表外；不删除历史失败或改成自验通过 | `git diff -- docs/plans`；各计划最新独立结论和独立记录 |
| 能耗旧阻塞 | 将已由无人值守专项解决的信号处置问题同步为已完成；保留首轮人工释放、隔夜失败和后续恢复结论 | [无人值守阶段 3 独立完成复核](../data-quality/tunnelpad-unattended-managed-ssh-recovery-stage3-independent-completion-review-20260904.md)；[能耗日志修复后独立完成复核](../data-quality/tunnelpad-health-monitor-energy-post-log-retention-fix-independent-completion-review-20260905.md) |
| 索引与契约漂移 | 移除推荐顺序中的旧待实施时态和字段级重复；迁移状态改引用地图；ADR 保留策略链接已完成后续计划 | [迁移说明](../migrations/tunnelpad-rust-owner-cutover.md)；[ADR-0003](../adr/0003-log-event-stream-and-retention.md)；[低写放大不变量](../plans/tunnelpad-log-write-amplification.md#不变量) |
| 验收闭环 | 新增工作按实际风险和用户可观察场景验收；本次不追溯编造用户接受、性能测量或新的业务完成证据 | [规范适用与历史兼容](../PLAN_MAP.md#规范适用与历史兼容) |

## 验证记录

以下命令均在仓库根目录执行；结果覆盖本次文档范围，代码测试及覆盖率不适用。

| 检查 | 命令或方法 | 结果 |
|---|---|---|
| 普通治理 | `plan-governance-cli check .` | 通过 |
| 严格治理 | `plan-governance-cli check . --strict-readiness` | 通过；无活跃阶段，不构成任何新阶段准入 |
| 当前工作集 | `plan-governance-cli workset . --json --strict-readiness` | 通过；0 个活跃计划，0 警告 |
| 历史工作集 | `plan-governance-cli workset . --json --include-history --strict-readiness` | 通过；14 个已完成计划，0 警告，0 当前阻塞 |
| 历史完整性 | 对比 HEAD 与当前树中 14 个计划的 `最新独立准入复核`、`独立复核记录` 整节内容 | 全部逐字一致，历史日期、身份、失败及解除链未改写 |
| 索引与链接 | 对比 HEAD 的计划身份/状态/阶段/依赖；逐个解析本次新增的相对链接及 Markdown 标题锚点 | 14 项身份与生命周期不变；39 个新增本地链接均可访问 |
| 反向引用 | `rg` 检索相关计划名、P 编号、状态/关键字段及旧草案事实源措辞 | 现行状态与来源已同步；旧草案措辞仅命中检查命令，不把草案作为规范 |
| 图谱引用 | `plan-governance-cli graph validate .` | 通过；38 节点、75 关系；不改图谱 |
| 差异格式 | `git diff --check` | 通过 |
| 漂移范围 | `plan-governance-cli check . --drift` | 退出 0，4 条提示：地图跨计划同步、ADR、migration 和本复核报告不归属活跃计划；本次明确授权的文档范围已在本报告列明，不为消除提示虚构活跃计划 |

## 历史快照限制

`plan-governance-cli check . --check-attestations --strict-readiness` 在修改前已将本机 API、稳定性的最新关系快照派生为 `needs_review`，原因包含地图 hash 变化；另外 3 份快照为 `superseded`。本次仍保留全部 5 份 JSON，不生成替代快照。文档变化会增加计划 hash 差异，结构退出 0 不代表快照重新有效，也不构成当前业务验收。

## 独立文档复核

- 日期：2026-09-06。
- 复核者：`/root/governance_review`，未参与编辑的独立只读 subagent；本次规则更新没有使用新增自验策略自批。
- 结论：**通过，本次文档规范同步无剩余阻塞。**
- 独立核对：14 项计划身份、状态、阶段、依赖不变；28 个历史独立复核章节与基线逐字一致；39 个新增相对文件/锚点有效；能耗失败解除链、ADR 后续契约引用、migration 关闭证据和同源规范版本均有实际材料支持。
- 独立复跑：普通/严格治理、当前及历史工作集、图谱、差异格式、范围漂移、快照检查，以及 Python 内容比较和 `rg` 反向引用。结果与上表一致；当前/历史工作集均无警告，4 条范围提示及旧快照限制已披露。
- 复核修正：初稿在新增报告前记录了 3 条漂移提示；独立复跑发现最终范围应为 4 条，已修正。代理规则缺少更新前字节基线的限制已补充，未假称完成前后字节比较。
- 结论边界：只证明本次文档规范同步通过，不构成历史业务重新验收、当前运行验收、新阶段准入或旧快照重新有效。
