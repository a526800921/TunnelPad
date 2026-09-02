# TunnelPad 稳定性阶段 2：配置重载资源收敛切片 Step 0

- 日期：2026-09-02
- 计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 切片：配置重载资源收敛
- 基线类型：架构探索基线 + 缺陷安全边界
- 当前结论：已达到待实施标准，尚未修改生产实现

## 目标与边界

本切片只处理外部修改 `config.json` 后点击刷新配置，以及设置面板保存单条配置时，配置事实源与已经托管的 `launchd` 实例发生分叉的边界。当前实现范围仍只有 `launchd`；不引入 `app` 执行器，不修改配置 Schema、label、plist 命令格式或 ECS/SSH 业务链路。

已冻结的兼容语义是：同一 `id` 的命令、`keepAlive`、退避或探针参数变更仍只保存配置，不自动重启运行中的隧道；界面继续提示“运行中的隧道在下次重启后使用新参数”。这样保留当前刷新/保存不产生网络副作用的行为。配置候选删除一个仍受管的隧道时，刷新不能让旧 label 失去 owner；必须先停止并复核该 label，全部待删除 label 收敛后才能替换 owner 的配置。

## 当前替代基线

- `TunnelManager.reloadConfig()`/`reloadConfigAsync()` 通过 Rust owner 读取磁盘配置，再把候选配置应用到 Swift 状态；刷新本身不调用 `restart`。
- Rust `CoreOwner::load_config()` 当前读取并校验候选后直接替换 owner 内存配置。若候选删除了仍加载的旧隧道，替换完成后 owner 不再持有该隧道，旧 label 可能成为孤儿服务。
- `TunnelManager.updateTunnel()`/`updateTunnelAsync()` 只保存新配置，不重写或重启运行中的实例，现有提示语明确新参数下次重启才生效。
- 显式 `remove` 已经遵循停止、状态复核、产物清理和配置提交顺序；本切片复用同一 Rust owner 的 `launchd` 停止与状态分类，不另造 Swift 执行器。
- Rust owner 的 `load_config()` 没有 Schema 变化；候选配置仍须先通过现有 `validate_launchd_config`，无效候选不能触发生命周期副作用。

## 固定顺序与安全语义

1. 读取并校验候选配置；校验失败时不查询、不停止、不替换 owner 配置。
2. 以旧 owner 配置和候选配置的 ID 差集确定待删除 label，按稳定顺序逐条取得隧道锁，避免与同一隧道的 start/stop/restart 并发。
3. 对待删除 label 查询状态：`notLoaded` 视为已收敛；已加载则执行 `bootout`，随后必须再次查询并确认 `notLoaded`。
4. 任一停止、状态复核或锁内操作失败时，拒绝候选配置提交并保留旧 owner 配置；已经成功停止的旧隧道仍保留在旧配置中但保持停止状态，后续可人工重试刷新，不能把它们从 owner 中遗失。
5. 全部待删除 label 收敛后，才替换 owner 配置。候选新增的隧道只进入配置，不自动启动。
6. 同一 ID 的参数差异不参与本切片的自动重启；后续显式手动重启才写入新 plist 并应用新参数。配置重载完成后，Swift 侧继续按现有代次门禁裁剪展示状态和探针结果。

## 样本矩阵

| 编号 | 输入/基线 | 可执行验证 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| CfgR-1 | 候选只新增隧道 | Rust owner fixture：旧配置与候选配置 | 候选提交成功；不调用 bootout/bootstrap；owner 使用候选配置 | 新隧道被自动启动或旧隧道发生副作用 | `cargo test --manifest-path rust/Cargo.toml` |
| CfgR-2 | 删除未加载隧道 | fake launchd 返回 `notLoaded` | 候选提交成功；不需要 bootout；旧 label 不再由候选配置引用 | 候选被拒绝或发生无关 label 操作 | 同上 |
| CfgR-3 | 删除已加载隧道，bootout 后复核为 `notLoaded` | fake launchd 注入 loaded → bootout success → notLoaded | 先停止并复核，再提交候选；owner 不遗留旧 ID | 先提交配置、未复核或继续 bootstrap | 同上 |
| CfgR-4 | 删除已加载隧道，bootout 失败 | fake launchd 注入 bootout error | 候选拒绝；旧 owner 配置保留；不提交候选 | owner 配置已变成候选或旧 label 失去管理 | 同上 |
| CfgR-5 | 删除已加载隧道，bootout 后仍 loaded | fake launchd 注入 bootout success 但 status 仍 loaded | 候选拒绝；旧配置保留并报告未收敛 | 接受候选或继续启动新配置 | 同上 |
| CfgR-6 | 多个删除项，其中一个停止失败 | fake launchd 按稳定顺序注入部分成功、部分失败 | 不提交候选；已成功停止项仍在旧 owner 配置中，后续可重试 | 丢失旧配置 ID、停止循环提前中断或操作无关 label | 同上 |
| CfgR-7 | 同 ID 只修改 command/keepAlive/probe，label 已 loaded | fake launchd 返回 loaded，记录 lifecycle 调用 | 只替换配置，不调用 bootout/bootstrap；新参数等待显式重启 | 自动重启、修改 plist 或清空运行状态 | `swift test --filter TunnelManagerTests` 与 Rust fixture |
| CfgR-8 | 候选 JSON/schema/id/command 无效 | Rust owner fixture 注入解析/校验失败 | 无 lifecycle 调用，旧 owner 配置和运行实例保持不变 | 配置变空、停止实例或产生半提交 | `swift test --filter StabilityStage1Tests` 与 Rust fixture |
| CfgR-9 | 重载与同 ID start/restart 竞态 | fake launchd 阻塞生命周期调用并并发 load | 同一 ID 按 owner 锁串行；不存在旧任务覆盖新配置 | 旧操作在新配置后回写或并发操作同一 label | `cargo test --manifest-path rust/Cargo.toml` |

## 验证方式、完成条件与回滚

- 实施前：完成影响分析、独立准入复核，并确认只修改 Rust owner 的 `load_config` 及其 fixture；若发现需要改变 Swift `TunnelManager` 的刷新提示或自动重启语义，先回到计划更新，不直接扩大切片。
- 实施中：先运行 CfgR-1–CfgR-9，再运行 Rust 全量、相关 Swift 专项和全量 Swift；补充 `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10`、`git diff --check` 和 GitNexus 变更范围检查。
- 完成条件：删除项在 owner 配置替换前全部达到 `notLoaded`；任何失败都不提交候选；同 ID 参数修改不自动重启；无效候选无生命周期副作用；全部矩阵和治理门禁通过，并有独立完成复核。
- 回滚：按本切片提交回滚 Rust owner 及 fixture；不重写真实 `config.json`，不删除真实 plist，不调用真实 `launchctl`、SSH 或 ECS。

## 非目标与风险

- 本切片不解决“修改同 ID 参数后是否自动重启”的产品策略；已保持当前“下次显式重启生效”语义。
- 如果多个删除项中途失败，之前已经成功停止的旧隧道会保持停止，但仍在旧 owner 配置中；这是 fail-closed 的可重试状态，优先避免配置提交后出现无人管理的运行实例。
- 本切片不覆盖 `app` 执行器、pidfile、孤儿进程身份校验、真实受管 SSH 隧道和 ECS 业务闭环。
