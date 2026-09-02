# TunnelPad 稳定性阶段 2：配置重载资源收敛切片独立完成复核

- 日期：2026-09-02
- 复核对象：[配置重载资源收敛切片实施证据](tunnelpad-stability-stage2-config-reload-reconciliation-implementation-20260902.md)
- 对应准入：[配置重载资源收敛切片独立准入复核](tunnelpad-stability-stage2-config-reload-reconciliation-independent-review-20260902.md)
- 复核者：Codex（独立只读复核）
- 结论：通过，仅关闭配置重载资源收敛切片

## 独立核对

| 完成条件 | 当前仓库证据 | 结论 |
|---|---|---|
| 候选配置先校验，失败无生命周期副作用 | `CoreOwner::load_config` 在解析和 `validate_launchd_config` 成功前不访问 launchd；`reload_config_rejects_invalid_candidate_without_lifecycle_side_effects` 通过 | 通过 |
| 删除项先停止并复核再提交 | `load_config` 计算旧/新 ID 差集，按 ID 排序持锁，执行 `bootout` 后再次 `status`，确认 `NotLoaded` 后才替换 owner 配置 | 通过 |
| 停止失败或仍加载时保留旧配置 | `reload_config_rejects_stop_failure_and_retains_old_owner_config`、`reload_config_rejects_label_that_remains_loaded_after_bootout` 通过 | 通过 |
| 多删除项失败不截断后续尝试 | `reload_config_attempts_all_removed_labels_before_rejecting_candidate` 通过，调用顺序符合稳定排序 | 通过 |
| 新增不自动启动、同 ID 参数不自动重启 | `reload_config_commits_new_tunnels_without_starting_them`、`reload_config_keeps_same_loaded_label_without_automatic_restart` 通过 | 通过 |
| 与同隧道生命周期操作串行 | `reload_config_waits_for_same_tunnel_lifecycle_lock` 通过；owner 使用同一隧道锁 | 通过 |
| 不改变既有公共契约和真实隧道范围 | 无 Schema/UI/执行器枚举变化；未调用真实 `launchctl`、SSH 或 ECS 故障注入 | 通过 |

## 验证证据

```text
cargo test --manifest-path rust/tunnelpad-core/Cargo.toml owner::tests::reload_config
9 passed; 0 failed

cargo test --manifest-path rust/Cargo.toml
62 unit tests passed; 1 differential test passed; 0 failed

swift test
129 tests passed; 0 failed

plan-governance-cli check .
计划治理检查通过。

plan-governance-cli check . --strict-readiness
计划治理检查通过。

plan-governance-cli check . --stale-days 10
计划治理检查通过。

git diff --check
通过
```

GitNexus `impact({target: "load_config", direction: "upstream"})` 返回 HIGH，已在实施前登记；实施后 `detect_changes({scope: "unstaged"})` 报告当前工作区 84 个变更符号、124 个受影响符号、整体 `critical`。该结果包含之前已存在的 `TunnelManager`/ECS/生命周期共享改动；本切片的新增生产符号限于 Rust owner `load_config`，新增 fixture 限于 `owner.rs` 测试模块，属于预期影响范围。

## App 冒烟边界

使用 `xcodebuildmcp` 重新构建并签名当前 `dist/TunnelPad.app` 后启动成功；进程 PID 为 8528，Bundle ID 为 `com.jafish.tunnelpad.app`，两个现有受管 label 均为 `not_loaded`。该冒烟只证明当前 App 可启动和无运行中受管隧道时不猜测性拉起服务，不等价于运行中真实隧道的 bootout 验收；当前 App 保持运行，未对真实 SSH/ECS 做故障注入。

## 结论与后续

配置重载资源收敛切片完成，关闭范围仅为本切片；阶段 2 计划仍保持“实施中”。剩余边界是运行中受管隧道的真实 bootout 清理、ECS/SSH 业务闭环，以及未来 app 执行器语义，不因本切片完成而自动关闭。
