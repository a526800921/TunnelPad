# TunnelPad Rust Core 风险收敛与覆盖率提升：阶段 2 独立完成复核

日期：2026-09-02
计划：[TunnelPad Rust Core 风险收敛与覆盖率提升](../plans/tunnelpad-core-hardening.md)
复核类型：独立只读完成复核

## 结论

**通过，计划目标已达到。**

## 逐项核对

| 条件 | 结论 | 证据 |
|---|---|---|
| 选定 P1/P2 风险已按单用户场景收敛 | 通过 | shutdown 清理失败可重试；app executor、pidfile/orphan、UI 风险仍明确延后 |
| 生产修复与既有契约一致 | 通过 | 成功 shutdown 仍永久 closed；并发单入口、逐条继续清理、配置 fail-closed 和 restart fail-closed 回归通过 |
| 反证测试完整 | 通过 | shutdown 重试 1 项、Core FFI 3 项、全量 Rust 66+1 全绿 |
| 覆盖率目标达到 | 通过 | production-only 行覆盖率 `1710/2008 = 85.16%`，高于 `>=85%` 目标 |
| 验证和治理门禁 | 通过 | `git diff --check`、治理普通/严格检查、GitNexus detect_changes 均有输出 |
| 计划外改动 | 未发现 | 无 UI、app executor、pidfile/orphan、Schema、JSON 或 ABI 改动；格式检查仅发现既有 owner.rs 样式债务 |
| 回滚边界 | 通过 | 改动集中在 Rust Core owner/test，失败可单独回退，不触碰真实隧道或已完成稳定性计划 |

## 复核意见

本次修复解决的是单用户场景仍然可能遇到的实际资源收敛问题：一次 launchd 清理失败不再把 owner 锁死在无法重试的状态。覆盖率证据明确区分原始 LLVM 报告、production-only 行覆盖率和无有效分支数据，未将全量测试通过冒充分支覆盖率。

计划可以标记为已完成；后续 app executor、pidfile 身份和 orphan 收敛如需处理，应另立计划。
