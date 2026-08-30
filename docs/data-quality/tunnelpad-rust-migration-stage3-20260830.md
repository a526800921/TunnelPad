# TunnelPad Rust 迁移阶段 3 证据

日期：2026-08-30
计划：[tunnelpad-rust-migration.md](../plans/tunnelpad-rust-migration.md)
基线：阶段 2 完成提交 `e599a58`；阶段 3 实施工作树起点为 `c2e11b5`

## 当前结论

上一轮独立完成复核发现的 takeover、shutdown-all stale generation 和 Swift race 证据缺口已修复。第三轮独立功能复核确认实现与反证通过；治理文档同步后，`--strict-readiness` 也已通过。

当前没有修改 `Sources/` 产品路径、SwiftUI 接入、真实 `launchctl`、真实 SSH 或真实隧道。

阶段 4 不在本证据中自动视为可实施：Rust 与 Swift 的时间戳语义（Rust UTC、Swift 本地时区）仍是阶段 4 的前置对齐项，阶段 4 还需要自己的 Step 0 和独立准入复核。

## 实施内容

- 新增隔离 demo 编排模块 `rust/tunnelpad-core/src/demo.rs`：固定 `demo-` ID 前缀、独立临时 home、config/plist/pidfile/日志清理，以及 install、start、stop、restart、status、remove、takeover、shutdown-all 分支；takeover 复用 `MigrationService` 的备份、bootout、bootstrap、运行验证和回滚语义，并在 demo owner 层拒绝非 `demo-` ID。
- Rust `AppProcessExecutor::handle_exits()` 现在返回带 `generation` 的 `RestartPlan`；`restart_if_current()` 在 owner 延迟执行前拒绝已被 stop/remove/shutdown-all 失效的计划。
- Swift 与 Rust 差分 harness 均增加 `demo-lifecycle` 和 `demo-race` 分支；ScriptedRunner 要求 fixture 中的调用全部消费，避免错误的 fixture 顺序被静默接受。
- 新增 7 个阶段 3 fixture：6 个生命周期 fixture（含 takeover 成功与非 demo 拒绝）和 1 个竞态 fixture。阶段 3 新增 35 个 operation/scenario 条目；连同阶段 2 既有 fixture 共 20 个 fixture 文件。
- 新增 Rust demo 直接测试：非 demo ID 拒绝，以及 launchd 生命周期完成后 config、plist、pidfile 和 run 文件清理。

修复记录：`DemoLifecycle.shutdown_all()` 现在先调用 app executor 正常退出路径以推进 generation；Swift race harness 通过“允许重启”场景等待不同 PID 的实际延迟重启，再验证 stop/remove/shutdown-all 拦截旧计划；takeover 已接入双端 demo lifecycle 差分，并有非 demo negative fixture 与 Rust 直接边界测试。

## 审计中发现并修复的问题

1. 首次编译发现 `DemoLifecycle::new` 移动 `paths` 后再次使用，导致 Rust `E0382`；已在构造阶段 clone 一份给 app executor。
2. `lifecycle-remove-running.json` 的 ScriptedRunner 顺序与 Swift remove 编排不一致，导致 status 结果错位；已按“初始状态 → bootout → 复查状态”修正。
3. 原 Rust app executor 的迟到重启计划只有 tunnel 与 delay，没有 generation 校验；这会允许 stop/remove 之后的旧计划再次启动 app。已补充 `RestartPlan.generation` 和 owner 校验。
4. 首轮 Rust/Swift 差分发现 race 场景的 Rust remove 分支没有清理日志；已改为通过 `DemoLifecycle::remove` 复用 app 日志清理路径，随后差分恢复一致。

这些失败均发生在当前阶段验证过程中，修复后已重新执行对应门禁；没有把失败结果当作通过证据。

## 样本矩阵与验证结果

| # | 输入/基线 | 可执行命令或操作 | 结果 | 输出/判定 |
|---|---|---|---|---|
| 1 | 阶段 2 Rust Core + 阶段 3 demo 模块 | `cargo test --manifest-path rust/Cargo.toml` | 通过：35 个 Rust 单元测试、1 个差分测试 | 任一测试失败即不通过；当前 0 失败 |
| 2 | 20 个生命周期/组件 fixture，其中阶段 3 新增 35 个 operation/scenario 条目 | `./rust/scripts/differential.sh` | 通过：Swift harness 1/1、Rust differential 1/1 | 事件流、状态、文件副作用和 runner 调用一致 |
| 3 | `lifecycle-race.json` 的允许重启、stop/remove/shutdown-all 失效计划场景 | 差分 harness 内运行 `demo-race` | 通过：两侧均观察到真实延迟重启，并在三类取消动作后拒绝迟到重启 | stop/remove/shutdown-all 后无 pidfile，remove 后无残留日志 |
| 4 | 既有 Swift Core 回归 + 差分 harness | `swift test` | 通过：75/75（74 个既有测试 + 1 个差分测试） | 既有 Swift 行为保持通过 |
| 5 | Release/C ABI/测试组合门禁 | `./rust/scripts/smoke.sh` | 通过 | Rust 35/35 + differential 1/1、Swift C ABI smoke、arm64、签名校验全部通过 |
| 6 | 阶段 3 结构化准入 | `plan-governance-cli check . --strict-readiness` | 通过 | 仅保留已有的 ECS 计划重复影响目标 WARNING，不构成本计划错误 |

差分中间产物写入 `rust/target/differential/swift-events.json`；fixture 执行使用隔离临时 home。全量 `cargo fmt --check` 仍会报告仓库既有阶段 2 Rust 格式差异，本阶段没有进行无关的全仓格式化。

## 安全与边界

- demo 只接受 `demo-` 前缀配置 ID，并使用独立临时目录。
- launchd 生命周期只使用注入的 ScriptedRunner；没有调用真实 `launchctl`。
- app 生命周期只使用 `/bin/sleep` 或 `/usr/bin/true` 测试进程；没有连接真实隧道。
- 没有执行 ECS、SSH、网络穿透、SwiftUI 产品接入或安装替换动作。
- 当前工作树仍有未提交改动；变更范围限于 Rust Core/demo、Rust/Swift 差分 harness、fixture 和本证据/计划文档。

## 后续准入

阶段 3 的完成条件已满足；阶段 4 仍保持“设计中”，直到补齐时间戳语义对齐、阶段 4 自身 Step 0、样本矩阵和独立准入复核。
