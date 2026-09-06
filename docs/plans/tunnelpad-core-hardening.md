# TunnelPad Rust Core 风险收敛与覆盖率提升计划

> 规范适用（2026-09-06）：本计划保留完成时的阶段、验收条件与独立复核历史；后续变更遵循[新版规范与历史兼容](../PLAN_MAP.md#规范适用与历史兼容)。状态、当前阶段和最后更新以[计划索引](../PLAN_MAP.md#计划索引)为准。


## 需求探索

用户希望在稳定性计划完成后的代码审核基础上，结合“仅自己使用”的实际场景，挑选值得修复的 P1/P2 风险，并同步提高 Rust Core 的测试覆盖率和反证测试覆盖。UI 用例不纳入本计划。

本计划将已完成的 `tunnelpad-stability` 作为实现基线，不重新打开该计划，也不把未来 `app` 执行器、pidfile/orphan 收敛或 Swift/UI 探针串行化问题混入本次范围。

已确认的范围：

- 修复 Rust Core `CoreOwner::shutdown` 在部分清理失败后永久进入 closed 状态、导致后续无法重试清理的生命周期风险。
- 增加 Core owner、C ABI 和关键失败路径的反证测试；保留并回归已实现的配置 fail-closed、`bootout` fail-closed、代次取消和隧道隔离语义。
- 建立可复现的 Rust Core production-only 覆盖率报告，覆盖率基线采用当前工作树实测值。

暂定目标：将 Rust Core production-only 行覆盖率从 `80.60% (1620/2010)` 提升至 `>=85%`，且 `owner.rs` 的 shutdown 失败/重试路径和 `owner_ffi.rs` 的主要传输错误路径有明确反证证据。该目标只统计 Rust Core，不统计 UI；若覆盖率工具链无法稳定生成 production-only 结果，则以原始 LLVM 报告、过滤规则和可复现命令一并记录，不用全量测试通过替代覆盖率证据。

## 阶段路线图

| 阶段 | 目标 | 状态 | 进入条件 | 退出条件 |
|---|---|---|---|---|
| 阶段 0 | 固化 P1/P2 选择、覆盖率基线、fixture 矩阵、影响范围和回滚边界 | 已完成 | 本计划建立，当前只读证据可复现 | Step 0 矩阵完整，独立准入复核明确通过 |
| 阶段 1 | 实现 shutdown 可重试修复并补齐 Core/FFI 反证测试 | 已完成 | 阶段 0 达到 `待实施` 标准 | Rust 专项、全量 Rust、覆盖率和变更范围检查通过 |
| 阶段 2 | 独立完成复核和治理收口 | 已完成 | 阶段 1 实施证据完整 | 独立完成复核通过，计划和 `PLAN_MAP.md` 同步 |

## 当前阶段

阶段 0–2 已完成。本次实施只涉及 Rust Core 的生命周期 owner 和 Core FFI 测试；Swift/UI 以及未来 app executor 相关风险明确延后。

### P1/P2 选择

| 风险 | 决策 | 理由 |
|---|---|---|
| shutdown 清理有失败时 owner 仍永久 closed | 本计划修复 | 可能留下受管 launchd 服务，且同一 owner 无法再次尝试清理；即使单用户使用也会造成实际资源和状态残留 |
| 配置重载失败导致旧配置丢失 | 不新增生产修复，补回归证据 | 当前 Rust owner 已先校验、停止/复核删除 label，失败保留旧配置；保留该反证作为不可回归契约 |
| restart 的 bootout 失败后继续 bootstrap | 不新增生产修复，补回归证据 | 当前已 fail-closed，既有测试已覆盖；本计划只验证覆盖率和反证证据不退化 |
| app executor 切换、pidfile PID reuse、孤儿进程收敛 | 延后 | 属于未来 app executor/pidfile 计划，不是当前 Rust Core 的实际 owner 边界 |
| Swift/UI 探针串行化、日志/状态轮询 | 延后 | 用户明确 UI 用例不纳入本次范围，且这些项不应通过 Rust Core 改动间接处理 |

### 阶段准入摘要

| 项目 | 当前结论 |
|---|---|
| 当前阶段目标 | 已明确：Core 生命周期风险收敛、反证测试和 production-only 覆盖率 |
| 范围与非目标 | 已明确：Rust Core；不含 UI、app executor、pidfile/orphan |
| Step 0 基线 | 已记录：Rust 62 个 unit + 1 个 differential 通过；production-only 行覆盖率 80.60% |
| 样本/fixture 矩阵 | 下表保留实施前的基线矩阵；实施及独立完成结果见[阶段 1 证据](../data-quality/tunnelpad-core-hardening-stage1-implementation-20260902.md)和[阶段 2 独立完成复核](../data-quality/tunnelpad-core-hardening-stage2-independent-completion-review-20260902.md) |
| 验证、失败和回滚边界 | 已建立：不改 Schema/ABI/JSON 协议；单一 owner 改动失败可回退 |
| 最新独立准入复核 | 阶段 0 已通过，阶段 1 达到 `待实施` 标准；阶段 1/2 实施和独立完成复核也已通过 |

## 完成说明

阶段 0–2 均已完成。阶段 1 实施前已执行符号级 impact，实施后已完成失败回滚边界、覆盖率和变更范围审计。

## Step 0 证据

阶段 0 基线和独立准入证据已落盘：

- [阶段 0 基线证据](../data-quality/tunnelpad-core-hardening-stage0-20260902.md)：Rust 62+1 回归、覆盖率采集链路、C0–C7 矩阵、CRITICAL impact 和回滚边界。
- [阶段 0 独立准入复核](../data-quality/tunnelpad-core-hardening-stage0-independent-review-20260902.md)：确认达到阶段 1 `待实施` 标准。

## 测试覆盖率

阶段 1 已完成 Core/FFI 反证和覆盖率复测，production-only 行覆盖率为 `1710/2008 = 85.16%`，高于 `>=85%` 目标。完整采集口径、原始 LLVM 警告和专项/全量测试输出见[阶段 1 实施证据](../data-quality/tunnelpad-core-hardening-stage1-implementation-20260902.md)。

## Step 0 基线与样本矩阵

### 基线证据

- Rust 基线：`cargo test --locked --manifest-path rust/Cargo.toml`，当前实测 62 个 Rust unit test 和 1 个 differential test 通过。
- 原始 LLVM 报告：行覆盖率 `86.94%`、函数覆盖率 `85.03%`；分支报告没有有效分支数据（`Branches 0`）。
- production-only 行覆盖率：过滤 `#[cfg(test)]` 测试代码并合并 unit/differential 数据后为 `80.60% (1620/2010)`。
- 当前低覆盖热点：`owner_ffi.rs 0%`、`launchd_executing.rs 53.33%`、`launchctl.rs 78.37%`、`config_store.rs 78.90%`。这些数字只作为当前工作树基线，不能替代阶段 1 复测。
- LLVM 合并多个测试二进制时出现过 generic/function data mismatch 警告；阶段 1 必须保留原始输出并说明合并口径，不能只报告一个无来源的百分比。

### 样本/fixture 矩阵

| ID | 输入或基线 | 可执行命令/动作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| C0 | 当前 Rust Core 工作树 | `cargo test --locked --manifest-path rust/Cargo.toml` | unit 与 differential 全部通过 | 任一测试失败、fixture 缺失或差分不一致 | 阶段 0/1 证据文档与命令输出 |
| C1 | shutdown：第一个受管 label 的 `bootout` 返回错误，后续 label 可成功停止 | 新增 `CoreOwner` scripted runner 反证测试 | 首次 shutdown 返回错误但继续处理后续 label；第二次 shutdown 可重试失败 label 并成功结束 | 首次失败后第二次调用直接 `OWNER_CLOSED`，或重复错误地 bootstrap/操作无关 label | `rust/tunnelpad-core/src/owner.rs` 测试与阶段 1 证据 |
| C2 | 配置重载候选非法 JSON/非法 executor | 复跑 owner 配置重载测试 | 当前有效配置保持不变且无 launchd 副作用 | owner 配置被清空、候选被部分提交或产生额外生命周期调用 | `rust/tunnelpad-core/src/owner.rs` 现有反证测试输出 |
| C3 | 配置删除项停止失败或停止后仍 loaded | 复跑配置重载失败矩阵 | 不提交新配置；错误明确返回 | 旧配置丢失、删除 label 脱离 owner 或错误被吞掉 | `rust/tunnelpad-core/src/owner.rs` 现有反证测试输出 |
| C4 | restart 前 `bootout` 返回非“未加载”错误 | `cargo test --locked --manifest-path rust/Cargo.toml restart_blocks_bootstrap_after_bootout_error` | 不写新 plist、不调用 bootstrap | 旧实例未收敛仍继续 bootstrap，或测试未能证明无后续调用 | `rust/tunnelpad-core/src/owner.rs` 现有反证测试输出 |
| C5 | C ABI NULL、非法 UTF-8、非法 JSON、正常 create/command/shutdown/destroy | 新增 `owner_ffi` 内部测试，使用隔离临时 home | 传输错误返回 NULL 并可取 last-error；成功输出清除 last-error；NULL destroy 安全 | 崩溃、错误槽位泄漏到下一次成功调用、返回字符串未释放或正常生命周期失败 | `rust/tunnelpad-core/src/owner_ffi.rs` 测试与阶段 1 证据 |
| C6 | 覆盖率：独立临时 target，unit+differential 数据，过滤 `#[cfg(test)]` | `RUSTFLAGS='-C instrument-coverage' cargo test --locked --manifest-path rust/Cargo.toml`，随后用 `xcrun llvm-profdata`/`xcrun llvm-cov` 生成原始和过滤报告 | production-only 行覆盖率达到 `>=85%`，关键新增分支有命中 | 无法复现、过滤口径不明、低于目标且没有记录差距 | 原始报告保存在临时目录；汇总写入阶段 1 证据文档 |
| C7 | 治理和变更范围 | `plan-governance-cli check .`、`git diff --check`、实现前后 GitNexus impact/detect_changes | 无新增治理 ERROR；只影响预期 Core/test 符号和预期执行流 | 治理漂移、共享 UI 文件被改、影响范围超出计划 | 阶段 1/2 证据文档与命令输出 |

## 最新独立准入复核

| 日期 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|
| 2026-09-02 | 阶段 0 → 阶段 1 | 通过，达到阶段 1 `待实施` 标准 | [阶段 0 基线证据](../data-quality/tunnelpad-core-hardening-stage0-20260902.md)；[阶段 0 独立准入复核](../data-quality/tunnelpad-core-hardening-stage0-independent-review-20260902.md) | Codex（独立只读复核） |

## 独立复核记录

| 日期 | 类型 | 结论 | 证据 | 状态 |
|---|---|---|---|---|
| 2026-09-02 | 计划建立与范围筛选 | 选定 shutdown 重试和 Core/FFI 反证覆盖；配置 fail-closed、restart fail-closed 作为既有契约回归；UI/app executor/pidfile 风险延后 | 本计划“P1/P2 选择”；`docs/data-quality/tunnelpad-functional-graph-review-20260830.md`；`docs/plans/tunnelpad-stability.md` | 待独立准入复核 |
| 2026-09-02 | 阶段 0 独立准入 | 基线、C0–C7 矩阵、CRITICAL impact、验证/回滚和非目标边界通过；阶段 1 达到 `待实施` 标准 | [阶段 0 基线证据](../data-quality/tunnelpad-core-hardening-stage0-20260902.md)；[独立准入复核](../data-quality/tunnelpad-core-hardening-stage0-independent-review-20260902.md) | 通过 |
| 2026-09-02 | 阶段 1 实施与阶段 2 独立完成复核 | shutdown 清理失败可重试；Core/FFI 反证测试通过；production-only 行覆盖率 85.16%；Rust、治理和变更范围检查通过 | [阶段 1 实施证据](../data-quality/tunnelpad-core-hardening-stage1-implementation-20260902.md)；[阶段 2 独立完成复核](../data-quality/tunnelpad-core-hardening-stage2-independent-completion-review-20260902.md) | 通过 |

## 实施方案

### 生产修复

`CoreOwner::shutdown` 继续保持单入口：shutdown 进行期间第二次调用仍返回 `OWNER_CLOSED`，避免并发重复 bootout；但如果本次清理最终失败，应释放 closed 门闩，使下一次调用可以重新执行剩余清理。成功时维持永久 closed 语义。

修复不得改变 JSON 命令、C ABI、配置 Schema、launchd label、并发锁顺序或“单条失败仍继续处理其他 label”的既有契约。需要对不可预期的 owner 内部错误也保持可重试，不留下无法收敛的 closed 状态。

### 测试与覆盖率

- 新增一次 shutdown 失败后重试成功的 scripted runner 反证测试，明确检查两次调用的结果和 launchd 调用序列。
- 新增 Core owner FFI 的传输层测试，覆盖 NULL、非法 UTF-8、非法 JSON、成功清错、shutdown/destroy 生命周期；不在测试中操作真实用户的 launchd 隧道。
- 保留并复跑配置重载和 restart fail-closed 的既有反证测试；如覆盖率报告证明关键分支仍未命中，只补测试，不扩展生产语义。
- 使用独立临时 `CARGO_TARGET_DIR` 生成报告，原始 LLVM 数据和过滤后的 production-only 汇总分开记录；不把 `rust/target` 或临时二进制当作提交产物。

## 验证方式

实施前：对准备修改的 `CoreOwner::shutdown` 再执行 GitNexus upstream impact；当前精确结果为 `CRITICAL`、9 个受影响符号、8 条执行流，已向用户提示。若实际准备修改的符号扩大，必须逐个补做 impact。

实施后依次执行：

1. C1–C5 专项反证测试。
2. `cargo test --locked --manifest-path rust/Cargo.toml`。
3. production-only 覆盖率复测和原始 LLVM 报告审阅。
4. `plan-governance-cli check .`、必要时 `--strict-readiness`、`git diff --check`。
5. GitNexus `detect_changes()`，确认只有计划内 Rust Core/test 符号和预期执行流受影响。

失败策略：测试失败或覆盖率口径不稳定时停在阶段 1，不宣称完成；若 shutdown 修复造成行为回归，只回退该 owner 改动和新增测试，不回退已完成稳定性计划的其他实现。不得通过删减测试、放宽失败断言或把测试代码计入 production-only 来达标。

## 完成条件

- 阶段 0 的 Step 0 矩阵、基线输出和独立准入复核完整，最新结论明确达到 `待实施` 标准后才可实施。
- shutdown 首次部分失败后，后续调用可以继续收敛未完成清理；并发重复 shutdown 仍不会产生重复副作用。
- 配置重载 fail-closed、restart bootout fail-closed、代次取消、隧道隔离和 C ABI 传输错误均有可执行反证或回归证据。
- Rust Core production-only 行覆盖率达到 `>=85%`，或若工具链限制导致无法稳定给出该数字，则计划明确记录限制、原始报告、过滤脚本/规则和可复现的覆盖率改进证据；不得用全量测试通过替代覆盖率结论。
- Rust 专项、全量 Rust、治理检查、空白检查和 GitNexus 变更范围检查通过；无 UI/app executor/pidfile 计划外改动。
- 阶段 2 独立完成复核通过，并同步 `docs/PLAN_MAP.md` 的状态、最后更新和证据链接。

## 依赖与非目标

- 依赖：`docs/plans/tunnelpad-stability.md` 已完成的 Rust Core 生命周期和配置收敛实现；`docs/plans/tunnelpad-rust-migration.md`、`docs/adr/0001-rust-core-single-owner.md` 和 `docs/migrations/tunnelpad-rust-owner-cutover.md` 的 owner/ABI 边界。
- 非目标：不新增 config 字段、不改变 JSON 命令或 C ABI、不实现 app executor、不做 pidfile 身份校验、不处理 Swift/UI 覆盖率、不把真实用户 launchd 隧道用于故障注入。
