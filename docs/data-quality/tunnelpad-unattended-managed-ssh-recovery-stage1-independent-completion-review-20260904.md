# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 1 独立完成复核

- 日期：2026-09-04
- 阶段：阶段 1
- 复核者：Codex（独立只读复核）
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 实施证据：[阶段 1 实施证据](tunnelpad-unattended-managed-ssh-recovery-stage1-implementation-20260904.md)
- 结论：通过，阶段 1 完成；不代表阶段 2 已具备准入，也不代表真实环境已验收。

## 复核范围

本轮独立复核当前仓库中的阶段 1 Rust/Swift 实现、专项测试、全量回归、变更影响、治理状态和非目标边界。未发送真实进程信号，未调用真实 launchd、SSH、ECS 或远端接口。

## 完成条件逐项核对

| 完成条件 | 结果 | 证据与判断 |
|---|---|---|
| 受管身份可复核且失败不误伤 | 通过 | `ProcessIdentityReading`/`ProcessSignaling` 可注入；PID、UID、启动时间和可执行路径变化、读取失败、状态异常均不会继续发信号。 |
| bootout-first 与有界升级 | 通过 | 正常收敛零信号；未收敛时每一级均重新核验并记录 CONT → TERM → KILL；生产等待为 3 秒、1 秒、2 秒、1 秒，轮询最小间隔 100ms。 |
| 初始未加载与异常状态边界 | 通过 | 初始 `notLoaded` 直接返回且不重复 bootout；非“服务不存在”的状态查询失败返回错误，不解锁后续启动。 |
| 取消、generation、非 SSH和多隧道隔离 | 通过 | Rust/Swift 既有取消、busy、代次和隔离回归保持通过；非 SSH 继续旧路径，不调用受管 SSH 信号器。 |
| 第 10 次失败无人值守冷却 | 通过 | Swift 第 10 次恢复失败不再调用 stop，进入 30 分钟内存冷却；冷却时不创建恢复任务，冷却到期重新从第 1 次计数；手动 start 可清除窗口。 |
| Rust/Swift/差分回归 | 通过 | `cargo test --manifest-path rust/Cargo.toml` 为 72+1 通过；`swift test` 为 139 通过。 |
| 影响与治理 | 通过 | GitNexus 检测为 8 文件、79 符号、23 流程、`critical`，与计划已登记的 CRITICAL 共享生命周期影响一致；`git diff --check` 与 `plan-governance-cli check . --strict-readiness` 通过。 |
| 生产/真实环境边界 | 通过 | 实现仅保留系统执行器入口，当前验证全部使用 fake、临时目录和内存时钟；真实无人值守验收明确保留给阶段 3。 |

## 独立结论

阶段 1 的 Rust 受管进程收敛器和 Swift 自动冷却已满足本阶段实现范围、失败策略、取消/代次、多隧道隔离和验证条件，判定为阶段 1 完成。风险等级仍为 `critical`，后续阶段不得跳过自己的 Step 0 和独立准入；阶段 3 的真实 `SIGSTOP` 验收仍未完成。
