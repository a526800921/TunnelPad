# TunnelPad Rust Core 风险收敛与覆盖率提升：阶段 0 基线证据

日期：2026-09-02
计划：[TunnelPad Rust Core 风险收敛与覆盖率提升](../plans/tunnelpad-core-hardening.md)
状态：通过，提交独立准入复核

## 1. 基线与范围

本次只核对 `rust/tunnelpad-core`，不运行 UI 用例，不操作真实用户的 launchd 隧道。工作树在复验前只有计划文档变更，没有生产代码变更。

已选择的修复项是 `CoreOwner::shutdown`：当前实现先把 owner 标记为 closed，再执行逐条清理；若某个 `bootout` 失败，错误会返回，但 owner 仍不可再次调用，可能把未清理的受管服务留在 launchd 中。并发 shutdown 的单入口语义保留不变。

已确认不纳入本计划的风险是 app executor 切换、pidfile PID reuse、app 孤儿进程、Swift/UI 探针串行化以及日志/状态 UI 轮询。

## 2. Rust 回归基线

命令：

```bash
cargo test --locked --manifest-path rust/Cargo.toml
```

结果：

- `tunnelpad_core` unit tests：62 passed，0 failed。
- differential test：1 passed，0 failed。
- incompatible fixture crate：0 tests，编译通过。
- doc-tests：0 tests，编译通过。

## 3. 覆盖率采集基线

首次尝试没有设置 `LLVM_PROFILE_FILE`，没有产出 profraw；这不是测试失败。修正后的采集命令如下，使用隔离临时 target 和临时 profile，避免污染工作树：

```bash
coverage_root="$(mktemp -d)"
target_dir="$coverage_root/target"
export LLVM_PROFILE_FILE="$coverage_root/%p-%m.profraw"
CARGO_TARGET_DIR="$target_dir" RUSTFLAGS='-C instrument-coverage' \
  cargo test --locked --manifest-path rust/Cargo.toml
find "$coverage_root" -type f -name '*.profraw' -print
xcrun llvm-profdata merge -sparse \
  $(find "$coverage_root" -type f -name '*.profraw' -print) \
  -o "$coverage_root/merged.profdata"
xcrun llvm-cov report \
  "$target_dir"/debug/deps/tunnelpad_core-* \
  -instr-profile="$coverage_root/merged.profdata"
```

修正后的命令成功生成 profraw、合并 profile 并输出 LLVM 报告；原始报告会包含 Rust 标准库、依赖和 `#[cfg(test)]` 代码，因此不作为 production-only 目标。

当前工作树基线的 production-only 口径是：过滤 `#[cfg(test)]` 代码并合并 unit/differential 数据，行覆盖率 `80.60% (1620/2010)`；原始 LLVM 汇总曾为行 `86.94%`、函数 `85.03%`，分支列为 `0`。LLVM 合并多个测试二进制时可能出现 generic/function data mismatch 警告，阶段 1 必须保留原始输出并说明过滤口径。

当前低覆盖模块：

| 模块 | production-only 行覆盖率 |
|---|---:|
| `owner_ffi.rs` | 0% |
| `launchd_executing.rs` | 53.33% |
| `launchctl.rs` | 78.37% |
| `config_store.rs` | 78.90% |
| `demo.rs` | 80.79% |

## 4. Step 0 样本矩阵核对

| ID | 核对结果 | 证据 |
|---|---|---|
| C0 | 通过 | 62 个 unit + 1 个 differential 全绿 |
| C1 | 已定义，待阶段 1 实现 | shutdown 首次部分失败、第二次重试成功；实现前已完成 `CoreOwner::shutdown` upstream impact |
| C2 | 通过基线 | 既有非法候选/非法 executor 不改 owner 配置的反证测试 |
| C3 | 通过基线 | 既有删除 label 停止失败/仍 loaded 时保留旧配置的反证测试 |
| C4 | 通过基线 | 既有 `restart_blocks_bootstrap_after_bootout_error` 测试 |
| C5 | 已定义，待阶段 1 实现 | Core owner C ABI NULL、非法 UTF-8、非法 JSON、正常生命周期 |
| C6 | 通过采集链路 | 修正 `LLVM_PROFILE_FILE` 后 profraw/profile/LLVM report 均成功；production-only 目标和过滤口径已登记 |
| C7 | 通过 | `plan-governance-cli check .`、`--strict-readiness`、`git diff --check` 均通过 |

## 5. 影响与回滚边界

GitNexus 对 `rust/tunnelpad-core/src/owner.rs` 的 `CoreOwner::shutdown` 精确 upstream impact 结果为：`CRITICAL`，9 个受影响符号，8 条执行流，直接影响 `execute` 和 shutdown 相关测试。该结果已在实施前向用户提示。

计划内改动只允许：

- `owner.rs` shutdown 失败后的 closed 状态恢复和对应反证测试。
- `owner_ffi.rs` 的内部 C ABI 传输/生命周期测试。
- 阶段 1 覆盖率证据和计划文档。

不改 JSON 命令、C ABI、配置 Schema、launchd label、Swift/UI 或真实 launchd 状态。若测试失败，回退 owner 的单一修复和新增测试即可，不触碰已完成稳定性实现。
