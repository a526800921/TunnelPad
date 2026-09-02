# TunnelPad 稳定性阶段 2 启动/退出资源收敛切片独立完成复核

- 复核日期：2026-09-02
- 计划：`tunnelpad-stability`
- 阶段：阶段 2
- 复核对象：启动首轮 `launchd` 状态发现、正常退出/信号退出共享 Rust owner、退出资源逐条收敛
- 复核结论：**通过（仅限本切片已完成）**
- 复核边界：不代表稳定性阶段 2 整体完成；跨层状态一致性、迟到任务反向验证和真实受控应用验收仍属于后续切片

## 复核方法

本复核独立对照当前仓库代码、专项 Step 0、独立准入复核、实施证据和可复现测试命令；不以计划中的“已完成”文字单独作为完成依据。

## 完成条件核对

| 完成条件 | 当前证据 | 结论 |
|---|---|---|
| TunnelPad 启动后不依赖面板打开即可发现配置内受管服务状态 | `StabilityStage2Tests.testStartupReconcilesManagedStatusesWithoutPanel`；启动 fixture 2/2 | 通过 |
| 启动状态查询失败只保留可诊断失败，不触发生命周期操作 | `StabilityStage2Tests.testStartupSnapshotFailureDoesNotTriggerLifecycle` | 通过 |
| 正常退出和信号退出共用同一个 Rust owner 清理边界 | `AppDelegate.applicationShouldTerminate`、`Shutdown.installSignalHandlers` 均使用共享 owner；Rust owner 生命周期测试 | 通过 |
| shutdown 只允许单次进入，并取消进行中的操作 | `CoreOwner.shutdown` 的 closed gate、取消令牌和 `shutdown_is_single_entry` | 通过 |
| 退出时按稳定顺序尝试所有配置内 label，首个 `bootout` 失败不截断后续清理 | `shutdown_attempts_all_loaded_services`；首项失败后仍完成第二项调用 | 通过 |
| 成功清理后必须复查为 `notLoaded`，否则报告失败 | `CoreOwner.shutdown` 的 post-check；`lifecycle_and_shutdown_are_json_owned` | 通过 |
| 失败返回可诊断错误，同时不影响其他已配置服务的清理尝试 | owner 单元测试断言 `EXECUTOR` 错误、label 和完整调用序列 | 通过 |
| 不改变 Schema、C ABI、plist 或 ECS 同步契约 | 当前 diff 和 GitNexus 变更审计 | 通过 |

## 可复现验证

| 验证项 | 命令/输出 | 结果 |
|---|---|---|
| 阶段 2 Swift 专项 | `swift test --filter StabilityStage2Tests` | 7/7 通过 |
| Swift 全量回归 | `swift test` | 125/125 通过 |
| Rust 全量回归 | `cargo test --manifest-path rust/Cargo.toml` | 53 个 unit + 1 个 differential 通过 |
| Rust shutdown 定向回归 | `cargo test --manifest-path rust/Cargo.toml owner::tests::shutdown_` | 4/4 通过 |
| 治理兼容检查 | `plan-governance-cli check .` | PASS |
| 严格准入结构检查 | `plan-governance-cli check . --strict-readiness` | PASS |
| 活跃计划停滞检查 | `plan-governance-cli check . --stale-days 10` | PASS |
| 补丁格式检查 | `git diff --check` | PASS |

上述测试覆盖隔离 fake owner/runner 和代码契约；没有把真实 `launchctl`、真实 SSH/ECS、真实信号发送或崩溃注入写成已完成的生产验收证据。

## GitNexus 范围复核

本切片修改的生命周期热点是 Rust `CoreOwner.shutdown`。此前已完成 upstream impact：风险为 `CRITICAL`，影响 7 个符号、6 条执行流，且涉及正常退出、信号退出和生命周期 JSON 路径；该风险已在实施前告知，并将修改限制在逐条退出清理、取消和 post-check。

实施后的 `detect_changes()` 报告为 `critical`，变更文件 6 个、受影响符号 36 个。结果与当前工作区中已存在的 ECS 自动恢复、`TunnelManager` 共享生命周期改动以及日志计划文档改动一致；未发现超出本次稳定性切片和既有未提交工作范围的额外生产文件。

## 未关闭事项

- 跨层状态一致性：探针恢复、ECS 前置、启动快照、退出清理和 UI 状态之间的迟到任务/状态倒灌矩阵仍需单独切片。
- 真实受控应用验收：需要在批准的测试环境验证 launchd 启动、退出、首项失败继续清理和应用异常终止后的下一次启动路径。
- `app` 执行器 pidfile/孤儿进程：当前运行路径已移除 app 执行器，未来 app 计划另行定义，不属于本切片完成条件。

因此，本切片可以关闭；`tunnelpad-stability` 计划继续保持“实施中”，当前阶段仍为阶段 2。
