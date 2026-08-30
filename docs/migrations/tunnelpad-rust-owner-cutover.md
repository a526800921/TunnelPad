# TunnelPad Rust Core owner 切换迁移说明

- 状态：实施中
- 关联计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)
- 关联决策：[ADR-0001](../adr/0001-rust-core-single-owner.md)
- 日期：2026-08-30

## 迁移目标

将 TunnelPad 从“Swift Core 执行、Rust shadow 校验”切换为“SwiftUI/AppKit 外壳 + Rust Core 唯一 owner”。阶段 5 的首个生产范围只包括当前实际使用的 `launchd` 执行器；`app` 执行器未来另立计划。

## 保持不变的外部契约

- `config.json` 顶层 `version` 保持为 `1`。
- 隧道 ID、launchd label、launchd 日志路径和 SSH 命令参数保持不变；历史 app pidfile 路径不再属于当前运行契约。
- 启动、停止、重启、删除、状态查询和退出即停的用户可观察语义保持不变。
- SwiftUI/AppKit 的菜单栏、窗口、表单入口和状态展示保持不变。

## Owner 切换后的责任

| 责任 | Rust Core | Swift App |
|---|---|---|
| 配置文件读写与 schema 校验 | 唯一 owner | 不直接读写 |
| launchd bootstrap/bootout/status | 唯一 owner | 发命令、展示结果 |
| 运行时状态与操作代次 | 唯一 owner | 读取快照 |
| 同隧道串行/跨隧道并行 | 唯一 owner | 不作安全判断 |
| 后台探针/重试任务 | 后续稳定性计划 owner | 不创建第二套任务 |
| UI 表单临时值 | 接收 JSON 命令 | 唯一 owner |
| App 退出清理 | 执行停止和任务取消 | 发起 shutdown 并等待结果 |

生命周期异步调用先通过同一 owner 的 `begin` 命令取得隧道代次，再把代次带入后续命令；取消通过 `cancel` 使该代次失效。Rust 在代次失配时不得触发 launchd 或配置副作用。

## 迁移步骤

1. 完成阶段 5 Step 0：固定 owner ABI、JSON、handle、状态快照、错误、并发和退出契约。
2. 用 fake `launchd` 完成配置读写、命令序列、错误注入、并发和取消 fixture。
3. 将 Swift `TunnelManager` 收缩为 UI/FFI 门面，禁止直接调用 Swift `ConfigStore` 和 Swift 生命周期执行器；`MigrationService`/`LaunchCtlExecutor` 仅保留迁移接管兼容路径。
4. 隐藏并移除 `app` 执行器入口、实现和配置分支；当前配置只允许 `launchd`（已完成）。
5. 先在隔离 demo 验证 Rust owner，再完成当前两条真实 `launchd` 隧道的状态/重启闭环，以及 `admin-tunnel` 的探针闭环。
6. 完成 Release、签名、AX、退出清理和 GitNexus 反向引用审计（Release/签名、真实 Release App 退出清理、隔离 App AX/退出操作、app 入口隐藏回归、旧 Swift Core/app 实现删除和最终反向引用审计已完成）。
7. 阶段 5 独立准入复核通过后删除旧 Swift Core；删除后不保留 App 内 fallback（删除已完成，待独立收尾复核）。

## 配置兼容边界

- 当前 version=1 配置继续使用，不做一次性格式迁移。
- 当前已确认配置中没有 `executor=app` 条目。
- 阶段 5 不自动把 `app` 配置转换为 `launchd`；未来 app 支持另立计划。
- 备注字段和稳定性运行时字段不在本迁移步骤中提前加入，分别由后续计划在 Rust owner 完成后实施。

## 失败和安全边界

- Step 0、隔离 fixture 或真实验证失败时，停止扩大真实隧道范围，直接修复 Rust 后重跑。
- 不执行无目标批量 bootout/bootstrap，不修改远端配置，不修改凭证。
- 每次真实操作前确认目标 label；每次操作后确认目标状态和非目标隧道未变化。
- 不保留 App 内 Swift fallback，也不把旧版本运行时回滚作为交付要求。
- Git 历史和开发者本地备份可以保留，但不能被当前 App 当作自动恢复路径。
