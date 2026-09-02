# TunnelPad Rust Core 风险收敛与覆盖率提升：阶段 0 独立准入复核

日期：2026-09-02
计划：[TunnelPad Rust Core 风险收敛与覆盖率提升](../plans/tunnelpad-core-hardening.md)
复核类型：独立只读准入复核

## 结论

**通过，达到阶段 1 `待实施` 标准。**

## 逐项核对

| 条件 | 结论 | 证据 |
|---|---|---|
| 当前阶段目标、范围和非目标明确 | 通过 | 专项计划“需求探索”“P1/P2 选择”“依赖与非目标” |
| Step 0 基线类型明确 | 通过 | Rust 回归基线、LLVM 原始报告、production-only 过滤口径均已记录 |
| 样本/fixture 矩阵可执行 | 通过 | C0–C7；C1/C5 明确输入、预期、失败判定和输出位置 |
| 修复符号影响已核对 | 通过 | GitNexus 精确定位 `CoreOwner::shutdown`，upstream impact 为 CRITICAL；高影响已向用户提示，范围未扩散 |
| 验证、失败、回滚边界明确 | 通过 | 只改 Rust Core owner/tests，不改 JSON/ABI/Schema/UI/真实隧道；失败可回退单一 owner 改动 |
| 当前阶段阻塞项 | 无 | 基线回归和治理检查通过；后续实现仍须执行 impact 和变更范围检查 |

## 复核意见

本次选定的 shutdown 修复具有单用户场景下仍然成立的实际价值：它解决的是清理失败后的资源收敛能力，不是多客户兼容性或 UI 体验问题。配置 fail-closed 和 restart `bootout` fail-closed 已经存在，复核要求其作为既有契约回归，不重复扩展生产语义。app executor、pidfile/orphan 和 Swift/UI 项目按计划延后。

阶段 1 可以开始，但修改前必须再次对实际准备编辑的生产符号执行 GitNexus upstream impact；如果新增生产符号，必须补充影响分析并重新确认范围。
