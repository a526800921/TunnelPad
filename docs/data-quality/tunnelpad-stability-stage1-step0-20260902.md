# TunnelPad 稳定性计划阶段 1 Step 0 证据

- 日期：2026-09-02
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 前置：[阶段 0 基线证据](tunnelpad-stability-stage0-20260901.md)；[阶段 0 独立准入复核](tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md)
- 基线类型：生产实现现状快照 + 高影响调用图复核 + 隔离故障注入矩阵
- 结论：阶段 1 Step 0 已完成设计和基线登记；独立准入复核已通过。本文是实施前基线快照，生产实现结果另见[阶段 1 实施证据](tunnelpad-stability-stage1-implementation-20260902.md)。

## 阶段 1 范围

本阶段只处理当前 `launchd` 执行器的后台健康监测、运行状态收敛、配置 fail-closed 和单隧道恢复状态机。健康信号继续只使用现有 HTTP 探针；策略固定为连续 3 次失败触发恢复、退避 10/30/60/300 秒封顶、最多自动恢复 10 次，第 10 次仍失败后停止当前隧道并停止该隧道的自动重试/自动恢复，保留只读探针监测，其他隧道继续运行。阶段 1 不处理未来 `app` 执行器、不新增 `config.json` 字段、不改日志事件流、不连接真实隧道、SSH、ECS 或真实 `launchctl`。

阶段 0 的 6 项仅测试契约 fixture 只作为策略输入，不作为生产实现证据。阶段 1 已用生产协调路径接入 fake 探针、fake `launchd`、隔离配置和代次/取消边界重新验证；矩阵中的 ECS 运行中同步和启动/退出收敛保留为阶段 2 的设计交接项。

## 当前生产实现基线

### 探针与窗口生命周期

- `ProbeService` 执行一次 HTTP GET，返回 `satisfied`、`unexpected` 或 `failed` 三态；它不调用生命周期方法。
- `ProbeCoordinator` 只负责一批探针的串行执行和 generation 过期结果丢弃，不保存失败计数，不调度退避，也不拥有重启任务。
- `TunnelManager.refresh()`/`refreshAsync()` 在状态刷新后调用一次 `runProbes()`；`runProbes()` 取消上一批任务、执行一次探针并更新展示状态，没有后台常驻健康监测或自动恢复路径。
- 主面板刷新任务受窗口可见性控制，因此不能作为阶段 1 的后台监测 owner。

当前缺口由现状基线测试复现：[StabilityStage0BaselineTests.swift](../../Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift) 的 4 项测试通过，证明连续探针失败不会触发生命周期恢复，但不证明阶段 1 行为已经存在。

### Rust Core、配置和 `launchd`

- ADR-0001 和 Rust owner 切换迁移规定 Rust Core 是生命周期、配置、运行时状态和操作代次的唯一 owner；阶段 1 不新增 Swift 第二套恢复协调器。
- 当前 Rust owner 已有按隧道锁、操作 generation、取消令牌和副作用前置校验；这些边界必须被健康恢复复用。
- `restart_with_generation()` 当前会忽略 `bootout` 错误并继续写 plist/bootstrap；该缺口由 Rust 阶段 0 基线测试复现，阶段 1 必须改为失败分类、状态复查和安全阻断。
- Rust owner 初始配置解析对非法 JSON/schema/id/command 失败并返回错误；`TunnelManager` 对初始 owner 失败仍以空配置初始化，运行中 reload 失败则保留当前门面配置。阶段 1 必须把“当前有效配置不被错误裁剪、无效候选不提交、运行时状态不倒灌”固定到 owner/门面集成测试。
- `keepAlive` 仍由生成的 launchd plist 和 launchd 负责进程退出后的拉起；健康恢复不能绕过 Rust owner 或把 `keepAlive=false` 转成自动重启。

### ECS 运行中同步

当前 ECS 动态 SSH 同步只在显式 `TunnelManager.start/restart` 前执行。`launchd KeepAlive` 的直接重连不经过该前置；阶段 1 必须在自动恢复进入生命周期副作用前接入既有受管来源同步边界。来源双端点不一致、私网/不可用来源、规则同步失败或取消/超时均必须 fail-closed。

## 高影响调用图复核

本次在当前工作树执行 GitNexus upstream impact，结果如下：

| 目标 | 风险 | 影响范围 | 复核边界 |
|---|---|---:|---|
| `TunnelManager` | CRITICAL | 84 个符号，70 个直接影响 | 直接影响 `TunnelPadCoreTests` 13 项；修改会影响 UI/配置/启停/日志共享入口 |
| `RustLifecycleOwner` | CRITICAL | 77 个符号，54 个直接影响 | 接口有 2 个实现，动态分派未完全追踪，实际影响可能更高 |
| `ProbeCoordinator` | CRITICAL | 71 个符号，55 个直接影响 | 修改会影响探针刷新、取消和既有 generation 过期保护 |
| `TunnelRuntimeState` | LOW | 16 个符号，2 个直接影响 | 影响 Core 与测试模块；仍需保持状态更新的单值提交语义 |

因此阶段 1 的任何生产符号修改都必须先复核 upstream impact，并以单一编辑窗口串行修改 `TunnelManager`、`TunnelRuntimeState`、主面板和共享测试目录。高风险目标的回归不能只依赖 `swift test` 全量通过。

## 阶段 1 Step 0 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前 HEAD、未提交范围和阶段 0 产物 | `git rev-parse HEAD`、`git status --short`、`git diff --stat`；读取阶段 0 证据与日志计划完成证据 | 记录 `08d2ac5`、当前稳定性测试/计划改动与日志已完成边界，不把既有并行改动归入阶段 1 | HEAD/工作树范围无法复现，或把日志实现视为稳定性生产改动 | 本文“基线与范围”及计划阶段 1 Step 0 |
| 2 | 后台监测与窗口隐藏 | fake clock/fake probe sequence；先使窗口隐藏，再注入 `satisfied`、连续失败和取消 | 监测不依赖窗口；每条隧道最多一个协调实例；窗口隐藏/显示不产生重复任务 | 监测随窗口停止、同一隧道出现多个有效任务、旧结果回写 | 阶段 1 生产集成测试与命令输出 |
| 3 | 连续失败与恢复 | fake probe + fake `launchd`；输入 `running + [fail, fail, fail]`、恢复成功和连续 10 次恢复失败 | 第 3 次失败才进入恢复；退避为 10/30/60/300 秒；成功清零；第 10 次仍失败后停止当前隧道，取消其自动重试/自动恢复但保留只读监测，其他隧道不变 | 提前恢复、计数漂移、退避越界、成功不清零、熔断后仍自动拉起或影响其他隧道 | 阶段 1 状态机测试与阶段证据 |
| 4 | `keepAlive=false` 和手动停止 | 配置 `keepAlive=false`；注入探针失败、手动 stop、手动 start/restart | 只记录展示失败，不自动恢复；手动 stop 不被拉起；手动 start/restart 清零并恢复监测 | 后台拉起手动停止隧道、关闭 keepAlive 仍重启、手动恢复未清零 | 阶段 1 状态机/生命周期测试 |
| 5 | 配置候选和代次 | 有效配置→坏 JSON/半写入→新有效配置；并发 reload 与旧任务完成 | 无效候选留档但不替换当前有效运行配置；旧 generation 不能回写或裁剪状态；新配置成功后只作用于当前代次 | 空配置替换当前配置、运行实例被错误裁剪、旧任务倒灌或跨隧道回写 | 阶段 1 配置/代次集成测试 |
| 6 | `launchd` 生命周期失败 | fake `bootout` 返回 not-found、权限失败、spawn 失败；fake `bootstrap` 成功/失败；注入取消和退出 | not-found 可按未加载继续；其他停止失败阻断后续提交；bootstrap 失败可诊断；取消/退出不留下迟到副作用 | 吞掉停止失败、旧新实例并存、错误状态被报告为成功、退出后任务继续副作用 | Rust owner/Swift 集成测试 |
| 7 | 运行中公网 IPv4 与 ECS（阶段 2 交接） | fake 双端点来源、受管规则同步和取消/超时；模拟 `KeepAlive` 断线恢复 | 阶段 2 冻结后，来源一致且同步成功才进入恢复；不一致、私网、不可用、同步失败或取消均 fail-closed | 绕过同步直接重连、双端点不一致仍写规则、旧来源循环重试或其他隧道受影响 | 阶段 2 Step 0 与实施证据 |
| 8 | 启动收敛和退出（阶段 2 交接） | 隔离配置、受管 label 集合、正常退出/信号退出/下次启动；不扫描真实进程 | 阶段 2 冻结后，Rust owner 只处理配置中的 `launchd` label；启动后可重新查询状态；不依赖 app pidfile，不操作无关 label | 残留受管任务、无目标批量 bootout、pidfile 误杀或状态报告不一致 | 阶段 2 Step 0 与实施证据 |

## 验证与回滚边界

- Step 0 只执行当前源码核对、GitNexus impact、临时目录和 fake runner；不执行真实 `launchctl`、SSH、ECS 或用户隧道。
- 阶段 1 生产实现必须分为可回滚的独立提交；任何 fake fixture 失败、状态倒灌、停止失败未阻断、来源不确定或跨隧道影响都阻断合入并回滚当前阶段提交。
- 实现前后均运行相关专项测试、`swift test`、适用的 `cargo test`、`git diff --check` 和治理检查；提交前再执行 GitNexus `detect_changes()`，确认只影响登记的恢复调用图。
- 不修改 `config.json` Schema、日志事件流、备注字段、真实 plist 或远端安全组；真实应用/隧道验收留待阶段 3，并需单独授权。

## Step 1 准入结论

阶段 1 Step 0 的范围、当前基线、CRITICAL 影响面、8 类样本矩阵、验证方式和回滚边界已落盘；独立准入复核（r2）已明确写出“达到待实施标准”。阶段 1 已转入实施，具体生产实现与验证结果由[阶段 1 实施证据](tunnelpad-stability-stage1-implementation-20260902.md)追加记录。
