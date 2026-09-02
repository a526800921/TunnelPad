# TunnelPad 稳定性阶段 2 启动/退出资源收敛切片 Step 0

- 日期：2026-09-02
- 计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 阶段：阶段 2
- 切片：`launchd` 启动/退出资源收敛
- 基线类型：架构探索基线 + 缺陷安全边界
- 当前结论：已完成 Step 0，允许进行本切片独立准入复核

## 目标与边界

本切片只处理当前 `launchd` 执行器的启动状态发现和应用退出资源收敛：

1. TunnelPad 启动后，不依赖主面板出现、打开或切换隧道，即通过现有后台健康协调器查询 Rust owner 的受管状态快照。
2. 启动状态查询只读，不因为崩溃后仍加载的受管服务而盲目 `start`、`stop` 或 `restart`；配置中的 `launchd` 服务仍由 `launchd` 托管，状态必须先回填 UI。
3. 正常退出与 SIGTERM/SIGINT 退出继续使用同一个 Rust owner 句柄和同一套 shutdown 语义。
4. 退出清理按稳定顺序逐条处理配置中的受管 label；单条 `bootout` 失败不能截断后续隧道的清理尝试，最终仍返回可诊断的失败结果。
5. shutdown 开始后立即关闭 owner 的新操作入口，并取消已有操作；并发或重复 shutdown 不得重复操作 launchd。
6. 每条退出操作在 `bootout` 后复核状态；只有已确认 `notLoaded` 才计为收敛，状态仍加载或结果不明必须保留失败证据。

本切片不扫描配置外的任意系统进程，不恢复 app 执行器、pidfile 或孤儿进程语义，不修改配置 Schema、Rust C ABI 版本、plist 命令、`KeepAlive` 或 ECS 自动恢复顺序，也不处理 Swift UI 与 Rust 快照之间更广泛的跨层迟到任务。

## 当前代码基线

- `TunnelManager.init` 读取 Rust owner 的有效配置后立即启动 `healthMonitorTask`；后台循环第一轮调用 `rustCore.snapshot()`，因此启动状态发现已经有唯一协调入口，但需要 fixture 证明它不依赖 `MainPanelView`。
- `MainPanelView` 的 `task` 和可见时刷新只是 UI 刷新，不应成为启动资源收敛的 owner。
- Rust `CoreOwner.snapshot()` 只查询配置中的 launchd label，不产生生命周期副作用；未加载服务返回 `notLoaded`。
- Rust `CoreOwner.shutdown()` 当前会取消操作、锁定配置中的隧道并逐条 `bootout`，但遇到第一条 executor 错误会提前返回，后续 label 不再尝试；当前也没有 shutdown 入口的并发门禁。
- 正常退出由 `TunnelManager.shutdownAsync()` 使用 `shutdownHandle` 对应的同一 Rust owner 调用 shutdown；信号处理也持有该 handle，因此不需要再创建第二个 owner。
- 当前 C ABI 为版本 1；本切片只调整已有 shutdown JSON 结果或 owner 内部状态，不新增 ABI 符号和公共配置字段。

## 冻结的实现方案

### 启动

- 保留 `healthMonitorTask` 作为启动后的唯一后台状态发现入口，使用现有 `snapshot` 读回每个配置隧道的 `TunnelStatus`。
- 首轮快照失败时不使用旧状态触发生命周期副作用；不自动猜测或清理配置外资源。
- 已加载的配置隧道只展示真实 `launchd` 状态，不因为 TunnelPad 上次崩溃而自动重复启动。

### 退出

- shutdown 入口使用一次性关闭门禁：第一次调用使 owner 进入关闭态、取消全部操作并继续清理；并发调用直接返回 `OWNER_CLOSED`，不得再次 bootout。
- 先按隧道 ID 稳定排序取得锁，再逐条读取状态；已是 `notLoaded` 的 label 跳过 bootout。
- 对仍加载的 label 尝试 `bootout`，无论单条成功还是失败都继续处理剩余 label；每条处理后复查状态。
- 若任一条无法确认 `notLoaded`，在所有配置 label 都尝试完成后返回 executor 失败；成功响应仍报告停止数量。退出调用方不因第一条失败而提前结束清理序列。
- 正常退出和信号退出继续通过同一个 `Shutdown.OwnerHandle` 指向同一 Rust Core，不引入第二套清理逻辑。

## Step 0 样本矩阵

| 编号 | 场景/输入 | 可执行验证 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 启动、配置含 running 与 notLoaded 隧道、无主面板刷新 | `swift test --filter StabilityStage2Tests.testStartupReconcilesManagedStatusesWithoutPanel` | 后台首轮 snapshot 回填状态；无 start/stop/restart | 首轮不查询、依赖 UI 或产生生命周期副作用 | `StabilityStage2Tests.swift` |
| 2 | 启动首轮 snapshot 失败 | `swift test --filter StabilityStage2Tests.testStartupSnapshotFailureDoesNotTriggerLifecycle` | 不使用未知状态启动/停止任何隧道 | 以旧状态触发副作用 | `StabilityStage2Tests.swift` |
| 3 | 正常退出，多个 label 均 loaded | `cargo test --manifest-path rust/Cargo.toml shutdown_attempts_all_loaded_services` | 按稳定顺序逐条 bootout，全部复核 `notLoaded` | 少清理一个 label、顺序漂移或未复核状态 | `owner.rs` 单测输出 |
| 4 | 第一条 bootout 返回 executor error，后续 label 可清理 | `cargo test --manifest-path rust/Cargo.toml shutdown_continues_after_bootout_error` | 后续 label 仍被尝试；最终返回可诊断失败 | 第一条错误直接终止循环 | `owner.rs` 单测输出 |
| 5 | 已有操作进行中时 shutdown | `cargo test --manifest-path rust/Cargo.toml shutdown_cancels_in_flight_lifecycle_commands` | 取消代次、关闭入口、完成剩余清理；不允许新副作用 | 迟到操作在 shutdown 后 bootstrap/bootout | `owner.rs` 单测输出 |
| 6 | 两个线程并发 shutdown | `cargo test --manifest-path rust/Cargo.toml shutdown_is_single_entry` | 只有一个调用执行清理，另一个得到 `OWNER_CLOSED` | 重复 bootout 或两个调用都成功 | `owner.rs` 单测输出 |
| 7 | SIGTERM/SIGINT 与菜单退出路径 | 现有 `Shutdown`/AppDelegate 静态核对 + Swift 回归 | 都指向同一个 owner handle；窗口关闭仍不退出 | 产生临时第二 owner 或遗漏清理 | 阶段 2 实施证据 |
| 8 | 配置外 label 或 app pidfile | 代码边界核对 | 不扫描、不终止、不恢复历史 app 语义 | 通过广泛进程扫描清理 | 本 Step 0 与专项计划 |

## 验证与安全边界

- 实现前必须对 `CoreOwner.shutdown`、`TunnelManager`、`Shutdown.installSignalHandlers` 等实际修改符号完成 upstream impact；`CoreOwner.shutdown` 已返回 CRITICAL，修改只允许保留在本切片范围并补齐 Rust/Swift 回归。
- 只使用 fake launchd、fake Rust owner 和隔离临时目录；不调用真实用户的 `launchctl`、SSH 或 ECS，不发送真实信号，不删除用户配置。
- 退出失败采用 fail-closed：继续尝试其他受管 label，但不得把未确认停止的 label 计为成功；owner 关闭后不再接受新生命周期命令。
- 若实现偏离“继续清理、逐条复核、单入口关闭”任一条件，先更新本 Step 0、专项计划和准入证据，再继续。
- 回滚只撤销本切片代码和测试；不得回滚已有阶段 1 健康恢复或阶段 2 ECS 自动恢复切片。

## 本切片完成条件

- 启动首轮状态发现有独立 fixture，且不依赖主面板、不产生启动副作用。
- shutdown 在单条失败后仍尝试全部配置 label，并对每条结果执行状态复核。
- shutdown 具备单入口门禁；正常退出、信号退出继续共享 Rust owner。
- Rust/Swift 专项与全量回归通过，治理、空白和 GitNexus 变更范围检查通过。
- 不新增配置字段、C ABI 版本、plist 命令或配置外进程扫描；后续跨层状态一致性仍单独切片。
