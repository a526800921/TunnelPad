# TunnelPad 稳定性阶段 2 启动/退出资源收敛切片实施证据

- 日期：2026-09-02
- 计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 阶段：阶段 2
- 切片：`launchd` 启动/退出资源收敛
- 前置：[切片 Step 0](tunnelpad-stability-stage2-lifecycle-reconciliation-step0-20260902.md)；[切片独立准入复核](tunnelpad-stability-stage2-lifecycle-reconciliation-independent-review-20260902.md)
- 状态：切片实现完成；阶段 2 整体仍在实施中

## 实施范围

本次只实现已经准入的 `launchd` 启动/退出资源收敛切片：启动后沿用现有后台健康协调器的首轮 Rust `snapshot` 读取配置内受管服务状态；退出时由同一 Rust owner 原子关闭新入口、取消在途操作、按稳定顺序逐条 `bootout`，单条失败不截断后续服务，并对成功的退出结果复核为 `notLoaded`。app 执行器、pidfile、配置外进程扫描和跨层 UI/Rust 状态协调不在本次实现内。

## 代码与测试变更

| 文件 | 变更 |
|---|---|
| `rust/tunnelpad-core/src/owner.rs` | `CoreOwner.shutdown()` 增加一次性关闭门禁；先关闭 owner 并取消在途代次；逐条处理所有配置内 label；保留首个错误但继续尝试剩余服务；成功 bootout 后复核 `notLoaded`；重复调用返回 `OWNER_CLOSED`。 |
| `rust/tunnelpad-core/src/owner.rs`（测试） | 更新 JSON owner 生命周期脚本以覆盖逐条状态复核；新增单条 bootout 失败后继续清理和重复 shutdown 不重复产生 launchd 调用的 fixture。 |
| `Tests/TunnelPadCoreTests/StabilityStage2Tests.swift` | 新增启动无面板首轮状态发现、snapshot 失败无生命周期副作用两项 fixture；阶段 2 专项共 7 项。 |

## 行为证据

- 启动首轮状态发现不依赖 `MainPanelView`，可回填配置内服务状态；snapshot 失败时不使用未知状态触发生命周期副作用。
- 正常退出和信号退出继续使用 `TunnelManager.shutdownHandle` 指向的同一 Rust owner；没有新增第二个 owner 或第二套 launchd 清理逻辑。
- shutdown 第一次调用即关闭 owner 入口，之后的新生命周期命令被拒绝；重复 shutdown 不会再次查询或 bootout。
- shutdown 按排序后的隧道 ID逐条处理；第一条 bootout 返回 executor error 时，后续 label 仍被尝试，最终返回带目标 label 的可诊断 executor 错误。
- bootout 成功但状态仍为 loaded 时不计为收敛，并在全部服务处理后返回 executor 错误；已是 `notLoaded` 的服务跳过 bootout。
- 不扫描或终止配置外 label，不恢复 app pidfile 语义，不改变配置 Schema、C ABI 版本、plist 命令、`KeepAlive` 或 ECS 自动恢复顺序。

## 验证结果

| 命令 | 结果 |
|---|---|
| `swift test --filter StabilityStage2Tests` | 7/7 通过 |
| `swift test` | 125/125 通过 |
| `cargo test --manifest-path rust/Cargo.toml owner::tests::shutdown_` | 4/4 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | Rust 53 个单测 + 1 个差分测试通过 |
| `git diff --check` | 通过 |
| `plan-governance-cli check .` | 通过 |
| `plan-governance-cli check . --strict-readiness` | 通过 |
| `plan-governance-cli check . --stale-days 10` | 通过 |
| GitNexus upstream impact | `CoreOwner.shutdown` 为 CRITICAL；修改限定在本切片并有对应 Rust/Swift 回归 |
| GitNexus `detect_changes()` | 仅报告本次 owner/启动 fixture、稳定性治理文档及工作区既有日志计划变更；`TunnelManager` 共享枢纽风险属于既有稳定性切片预期范围 |

## 未覆盖范围

阶段 2 的跨层状态一致性、迟到任务反证和真实应用验收仍未完成；本证据不能替代这些后续切片的 Step 0、独立准入或完成复核。真实用户的 `launchctl`、SSH、ECS 和信号操作未在本轮执行。
