# TunnelPad 隧道稳定性阶段 2 Step 0 基线

- 日期：2026-09-02
- 阶段：阶段 2
- 基线类型：架构探索基线 + 缺陷安全边界
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 当前结论：本 ECS 自动恢复切片的 Step 0 基线已固定并已完成实施；阶段 2 整体仍在实施中，启动/退出资源收敛切片另有独立 Step 0 与证据

## 目标与边界

本 Step 0 固定阶段 2 的三个待处理边界：

1. 启动、正常退出、信号退出和下次启动时的 `launchd` 资源收敛必须使用同一组受管 label、身份校验和结果分类。
2. 已配置 HTTP 探针的 SSH 隧道在自动恢复前必须先执行既有 ECS 公网 IPv4 同步；同步失败时不能让 `launchd KeepAlive` 继续绕过前置并使用旧来源重连。
3. Rust Core 的生命周期状态、Swift `TunnelManager` 的展示状态和健康恢复任务必须对同一隧道使用一致的代次、取消和最终状态。

本阶段不实现 app 执行器、pidfile 孤儿进程收敛、全局公网 IP 定时轮询、ECS API 逻辑复制、`config.json` 新字段或真实 `launchctl`/SSH/ECS 操作。

## 当前代码基线

### 1. 后台探针已经是稳定性协调器的触发来源

`TunnelManager` 在初始化时启动独立的后台健康监测任务，不依赖主窗口可见性；每轮先读取 Rust 快照，再由独立 `healthProbeCoordinator` 执行配置中的 HTTP 探针，并把结果交给按隧道隔离的健康状态机。对应路径为：

- `Sources/TunnelPadCore/TunnelManager.swift:383-447`
- `Sources/TunnelPadCore/HealthRecovery.swift:26-109`

阶段 1 已固定 10 秒监测、连续 3 次失败、10/30/60/300 秒退避、最多 10 次以及第 10 次停止当前隧道。阶段 2 复用这一协调器，不再增加独立的公网 IP 轮询 owner。

### 2. Manager 自己发起的自动恢复已经有 ECS 前置调用

当前 `performAutomaticRecovery` 对生产 ECS checker 的 SSH 恢复先通过 Rust owner `stop`/`bootout`，确认 `notLoaded` 后执行 `preStartChecker.checkAsync(tunnel:)`，成功后沿用同一操作代次调用 Rust `start`/`bootstrap`；普通注入 checker 和非 ECS 场景仍保留原有 `restart` 兼容路径：

- `Sources/TunnelPadCore/TunnelManager.swift:505-565`
- `Sources/TunnelPadCore/ECSPreStart.swift:95-138`
- `Sources/TunnelPadCore/SSHCommand.swift:5-12`

这说明阶段 1 已保护“由 TunnelManager 发起的恢复”路径，但不能直接证明 `launchd` 自己因 `KeepAlive` 重启进程时也经过同一前置。

### 3. ECS 前置适配器的安全边界已存在

`ECSPreStartChecker` 从打包 App 资源定位 `update-ecs-ssh-ip`，以 `/bin/bash` 运行，保留环境变量 allowlist，默认超时 30 秒，并把非零退出、超时、启动失败转换为可诊断错误；外部命令的 stdout/stderr 不直接进入 UI：

- `Sources/TunnelPadCore/ECSPreStart.swift:31-60`
- `Sources/TunnelPadCore/ECSPreStart.swift:63-138`
- `Sources/TunnelPadCore/ECSPreStart.swift:144-203`
- `scripts/build_app.sh:86-88`

阶段 2 不复制 `scripts/update-ecs-ssh-ip` 的云端逻辑，也不把凭证、IP 或 ECS 参数写入 TunnelPad 配置。

### 4. 当前仍存在 `launchd KeepAlive` 可能绕过前置的基线缺口

`LaunchdPlistRenderer` 把原始 `TunnelConfig.command` 写入 `ProgramArguments`，并把 `keepAlive` 写入 plist。隧道进程退出后，launchd 可以根据 plist 直接重新拉起该命令；这条直接重启路径不调用 Swift `TunnelManager` 的 `preStartChecker`：

- `Sources/TunnelPadCore/LaunchdPlistRenderer.swift:5-16`
- `Sources/TunnelPadCore/TunnelConfig.swift:30-45`
- `docs/adr/0001-rust-core-single-owner.md`

因此，“探针失败后先同步再恢复”在阶段 2 中不能只验证 Manager 的调用顺序，还必须验证 `KeepAlive` 不会在同步失败期间独立拉起 SSH。经评估，当前切片冻结为不新增 wrapper：健康恢复协调器先通过现有 Rust owner `stop`/`bootout`，确认返回 `notLoaded` 后再运行 ECS 前置；前置成功后通过同一操作代次 `start`/`bootstrap`。任何停止失败、状态仍已加载或前置失败都不进入启动。这样在同步窗口内没有受管 SSH 实例可供 `KeepAlive` 直接拉起，同时保持现有 plist、Rust C ABI 和配置 Schema 不变。

### 5. 运行时状态存在多个需要对齐的边界

`TunnelRuntimeState` 聚合 `statuses`、`probeResults` 和 `busyIDs`；健康恢复状态、延迟恢复任务和代次则由 `TunnelManager` 按 tunnel ID 维护。Rust Core 另外持有配置、每隧道锁、操作代次和关闭状态：

- `Sources/TunnelPadCore/TunnelRuntimeState.swift:7-35`
- `Sources/TunnelPadCore/TunnelManager.swift:17-39`
- `rust/tunnelpad-core/src/owner.rs:100-124`

阶段 2 必须用迟到任务、取消、配置重载、手动停止和退出序列验证三层最终状态一致，不能只看单次 UI 字典更新。

### 6. 当前退出路径已取消 Swift 任务并交给 Rust owner

`TunnelManager.shutdownAsync()` 取消 UI 探针、后台健康监测和恢复任务，等待任务结束后调用 Rust `shutdown`；`Shutdown` 的信号路径也通过 owner 停止全部受管 `launchd` 隧道。阶段 2 要验证正常退出、信号退出和下次启动对同一组 label 的发现与结果分类：

- `Sources/TunnelPadCore/TunnelManager.swift:777-804`
- `Sources/TunnelPadCore/Shutdown.swift:20-59`
- `rust/tunnelpad-core/src/owner.rs:516-553`

## 用户已确认的阶段 2 方案

2026-09-02 用户确认：

- 复用现有 10 秒后台 HTTP 探针作为公网 IP 同步的唯一触发入口。
- 仅当 SSH 隧道的探针失败累计到自动恢复尝试前，先运行既有 `update-ecs-ssh-ip` 同步/校验。
- 同步成功后才允许进入 Rust 重连生命周期；本切片具体为 `start`/`bootstrap`。同步失败、超时、取消或结果无法分类时，阻断本次 SSH 重连并沿用现有退避/熔断。
- 不新增独立全局公网 IP 轮询、配置字段或 ECS API 实现。

这项确认解决的是“网络切换后公网 IP 已变化，ECS 安全组仍允许旧来源，`launchd KeepAlive` 直接重连又绕过 ECS 同步”的问题；它不改变普通 HTTP 服务故障、非 SSH 隧道或无探针隧道的既有语义。

## Step 0 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 后台健康监测 owner | `rg -n 'startHealthMonitoring|runHealthProbeCycle|healthProbeCoordinator|healthMonitorInterval' Sources/TunnelPadCore/TunnelManager.swift` | 只有现有后台健康协调器作为触发候选，无新增全局 IP 轮询 | 出现独立公网 IP Timer/第二个 owner | 本文“当前代码基线”与命令输出 |
| 2 | SSH 命令分类 | `rg -n 'SSHCommand\.isSSH|func isSSH' Sources/TunnelPadCore Tests/TunnelPadCoreTests` | ECS 同步只对 SSH 命令候选生效，非 SSH 不启动同步进程 | 非 SSH 进入 ECS 分支或分类逻辑重复 | `SSHCommand.swift`、ECS 测试 |
| 3 | Manager 恢复调用顺序 | `rg -n -C 5 'rustCore\.stop|preStartChecker\.checkAsync|rustCore\.start|rustCore\.restart' Sources/TunnelPadCore/TunnelManager.swift` | ECS SSH 为 `stop → preflight → start`，失败时没有 `start`；普通隧道保留 `restart` | 先 start/restart 后同步，或失败仍启动 | `TunnelManager.swift`、阶段 2 fixture |
| 4 | `launchd` 直接重启缺口 | `rg -n 'ProgramArguments|KeepAlive' Sources/TunnelPadCore/LaunchdPlistRenderer.swift` | 能明确识别 KeepAlive 直接拉起路径，阶段 2 fixture 必须覆盖绕过前置的反例 | 把现有 plist 语义误写成已自动经过 ECS 同步 | 本文第 4 节、阶段 2 fixture |
| 5 | ECS 同步失败 | fake 前置进程返回退出码 3/4/5/6/7、超时或取消 | 本次 SSH 自动恢复不调用 Rust `start`/`restart`，错误可诊断，后续仍受退避/熔断限制 | 任一失败仍拉起 SSH，或无限重试旧来源 | 阶段 2 契约测试输出 |
| 5a | bootout-first 顺序 | fake owner 记录 `stop → preflight → start`；`stop` 返回 `notLoaded` | ECS SSH 自动恢复不调用 `restart`；只有 stop 收敛且前置成功后才 `start` | 前置早于 stop、同步失败后 start，或 KeepAlive 窗口仍有 loaded 实例 | 阶段 2 契约测试输出 |
| 5b | stop 状态门禁 | fake owner 让 `stop` 返回 `running`/`notRunning` | 不运行 ECS 前置、不调用 `start`，错误进入既有恢复失败边界 | 未确认 `notLoaded` 仍继续同步或启动 | 阶段 2 契约测试输出 |
| 6 | 正常/信号退出与下次启动 | fake Rust owner/launchd 注入 label 已加载、未加载、停止失败和身份不明 | 同一受管 label 集合被发现和分类；失败不报告成功 | 资源集合分叉、误操作无关 label 或状态虚报 | 阶段 2 生命周期 fixture |
| 7 | 迟到任务和跨层状态 | 注入探针结果、配置重载、手动 stop、删除、退出与旧代次恢复结果 | 旧任务不能写回状态或拉起隧道；UI、Rust snapshot、恢复状态最终一致 | 迟到事件倒灌、busy 卡住、其他隧道状态变化 | 阶段 2 状态一致性 fixture |
| 8 | 安全与治理 | `plan-governance-cli check . --strict-readiness`；`git diff --check`；敏感字段 `rg` 扫描 | 文档、依赖、证据和失败边界同步；无凭证/IP 原文 | 新增 schema、敏感值或治理 ERROR | 治理命令输出与文档审阅 |

## 阶段 2 当前准入结论

Step 0 已固定现状、用户确认的触发方案和当前 ECS 自动恢复切片的 bootout-first 方案。该切片已通过独立准入并完成仓库内实现验证；整个阶段 2 仍未达到“已完成”。剩余阶段 2 工作是：

1. 已由专项 fixture 证明 bootout-first 后，ECS 同步失败时不会调用 `start`，`launchd KeepAlive` 没有 loaded 实例可绕过前置；真实 launchd 行为仍留待受控应用验收。
2. 正常退出、信号退出和下次启动的统一资源收敛已由独立切片实现并验证；真实 launchd 行为仍留待受控应用验收。
3. 跨层状态一致性和迟到任务反证尚未形成阶段 2 专项测试。
4. 后续跨层一致性切片仍需补充自己的 Step 0 和独立准入证据。

阶段 2 的 ECS 自动恢复和启动/退出资源收敛切片已完成独立准入和仓库内实现验证；跨层状态一致性仍保持后续设计边界。实现前已重新执行实际修改符号的 GitNexus upstream impact；实现后已补专项 fixture、全量回归、`detect_changes()` 和计划证据。整个阶段 2 仍不调用真实 `launchctl`、SSH、ECS 或用户隧道。
