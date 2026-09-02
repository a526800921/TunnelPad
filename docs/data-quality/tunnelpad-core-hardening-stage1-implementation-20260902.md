# TunnelPad Rust Core 风险收敛与覆盖率提升：阶段 1 实施证据

日期：2026-09-02
计划：[TunnelPad Rust Core 风险收敛与覆盖率提升](../plans/tunnelpad-core-hardening.md)
状态：实施完成，提交独立完成复核

## 1. 实施内容

- `CoreOwner::shutdown` 仍使用 closed 门闩保证并发单入口；本次清理遇到错误时恢复 closed 门闩，允许下一次 shutdown 重试未收敛的受管服务。
- 成功 shutdown 后仍保持永久 closed；既有重复 shutdown 不产生 launchd 副作用的契约不变。
- 新增 shutdown 首次失败、继续处理其他 label、第二次重试成功的 scripted runner 反证测试。
- 更新原有 shutdown 错误测试，明确失败后 owner 仍可读取状态。
- 新增 Core FFI 的 NULL、非法 UTF-8、非法 JSON、成功清错、create/command/shutdown/destroy 和 NULL destroy 测试。
- 未改变 JSON 命令、C ABI、配置 Schema、launchd label、Swift/UI 或 app executor 行为。

## 2. 反证和回归结果

命令：

```bash
cargo test --locked --manifest-path rust/Cargo.toml
```

结果：

- Rust Core unit tests：66 passed，0 failed。
- differential test：1 passed，0 failed。
- incompatible fixture crate 和 doc-tests：通过。
- shutdown 重试专项：1 passed。
- owner FFI 专项：3 passed。
- 配置重载 fail-closed、restart bootout fail-closed、代次取消、隧道隔离和既有 shutdown 单入口测试均通过。

## 3. 覆盖率结果

采集使用隔离临时 `CARGO_TARGET_DIR`，并设置 `LLVM_PROFILE_FILE="$coverage_root/%p-%m.profraw"`。unit test binary 和 differential test binary 分别使用 `xcrun llvm-cov export -format=lcov` 导出，再以相同源文件行号取并集；过滤每个 Rust 源文件中的 `#[cfg(test)]` 模块后统计 production-only 行覆盖率。

结果：

- production-only 行覆盖率：`1710/2008 = 85.16%`。
- 相对阶段 0 基线 `80.60% (1620/2010)` 提升约 4.56 个百分点，达到计划目标 `>=85%`。
- `owner.rs`：`430/501 = 85.83%`。
- `owner_ffi.rs`：`82/102 = 80.39%`，从阶段 0 的 0% 提升。
- 分支列仍为 `0`，因此本证据只声明行覆盖率，不声称分支覆盖率。
- LLVM 合并/导出仍报告过 6 个 function data mismatch 警告；已保留原始输出并采用 unit/differential 分别导出后行数据并集，过滤口径已明确。

## 4. 范围与验证

- `git diff --check`：通过。
- `plan-governance-cli check .`：通过。
- `plan-governance-cli check . --strict-readiness`：通过。
- GitNexus `detect_changes(scope=unstaged)`：3 个已修改代码/治理文件被识别，16 个变更符号，21 个受影响符号，风险为 critical；主要集中在 `CoreOwner::shutdown` 及其已有生命周期测试，符合预期高影响边界。
- `cargo fmt --manifest-path rust/tunnelpad-core/Cargo.toml -- --check` 仍会报告 owner.rs 中原有的多处格式差异；本次未做无关的整文件格式化，新增代码已按 rustfmt 输出修正。该问题是既有格式债务，不改变本次测试和覆盖率结论。

## 5. 失败与回滚

覆盖率首次未设置 `LLVM_PROFILE_FILE` 时没有生成 profraw，已通过修正采集命令解决。实现和专项测试失败时只需回退 `owner.rs` 的 shutdown 改动及 `owner_ffi.rs` 新增测试；没有配置迁移、ABI 变更或真实 launchd 状态写入。
