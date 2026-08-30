# TunnelPad 功能图谱审计与潜在问题

- 日期：2026-08-30
- 图谱：[功能图谱](../graph/functional.yaml)
- 基线：GitNexus `TunnelPad`，索引提交 `e34bce7`；工作树包含既有未提交 Rust 迁移改动，本审计不将其视为本次图谱变更
- 范围：只读分析，不修改 Swift/Rust 代码，不启停真实隧道

## 审计方法

本次先用 GitNexus 查询业务概念、执行流程和 `TunnelManager`/应用生命周期/执行器调用关系，再用源码、测试与现有治理计划逐条反向核对。图谱只表达已确认的功能关系；“潜在问题”单独记录证据、影响、优先级和建议验证，不把推测直接写成实现事实。

已覆盖的主链路：

```text
配置文件 → 配置管理 → 隧道生命周期 → launchd/app 执行器 → 外部进程
                    ├→ 状态刷新 → 侧栏/菜单栏
                    ├→ HTTP 探针 → 健康结果
                    └→ 日志文件 → 日志面板
应用启动/退出、旧 Agent 接管、运行时状态代次和 Swift/Rust parity 为横切链路
```

图谱校验与影响分析命令：

```bash
plan-governance-cli graph validate .
plan-governance-cli graph impact --from function.config.management --depth 2 .
plan-governance-cli graph impact --from function.tunnel.lifecycle --depth 2 .
plan-governance-cli graph impact --from function.health.probe --depth 2 .
```

## 结论摘要

图谱没有发现一个可以直接判定为“立即必须改代码”的单点故障，但发现 4 个应进入后续准入/回归矩阵的高价值问题，以及 3 个中等风险的设计缺口。最重要的是：配置重载、配置编辑、正常退出和崩溃后启动对“实际托管实例”的收敛边界并不完全一致；在配置异常、停止失败或执行器切换时，UI 配置、状态查询和实际进程可能短暂或持续分叉。

已有稳定性计划已经覆盖“探针后台恢复、10 次熔断、启动 pidfile 收敛”等一部分问题。本报告新增的配置与生命周期交叉边界也属于同一个“实际托管实例安全收敛”问题域，已按用户确认并入稳定性计划的阶段 0 基线、失败注入和后续回归矩阵。

## 高优先级潜在问题

### P1：刷新配置或执行器切换失败后，配置、状态查询和实际实例可能分叉

- 证据：`TunnelManager.reloadConfigAsync()` 直接用 `ConfigStore.load()` 的结果替换内存配置，然后按新配置裁剪运行时状态并刷新；`ConfigStore.load()` 遇到损坏/不兼容文件会把原文件改名并返回空配置。[`TunnelManager.swift`](../../Sources/TunnelPadCore/TunnelManager.swift)；[`ConfigStore.swift`](../../Sources/TunnelPadCore/ConfigStore.swift)
- 证据：`updateTunnelAsync()` 在执行器改变时等待停止旧实例，但忽略 `TunnelOperationOutcome` 的错误，随后仍保存新执行器配置。[`TunnelManager.swift`](../../Sources/TunnelPadCore/TunnelManager.swift)
- 影响：旧 launchd agent 或 app 子进程停止失败时，内存/磁盘已指向新执行器；之后 `status` 可能查询新执行器而不是仍在运行的旧实例，退出清理和健康恢复也可能漏管旧实例。外部编辑产生一次短暂的半写入或损坏 JSON 时，刷新还可能把当前配置替换为空配置。
- 当前状态：代码路径已确认，是否构成用户可见故障还缺隔离失败注入；不是“刷新会自动重启”的问题，而是失败时缺少 fail-closed 收敛。
- 建议：在现有稳定性计划中固定：配置解析失败时保留上一份有效运行配置；执行器切换必须先确认旧实例已停止，失败则不落盘新执行器；外部重载与运行时状态裁剪的原子边界；旧实例残留的可发现性和人工恢复提示。
- 最小验证：fake launchd/app stop 返回失败；旧实例保持 running；执行器切换和刷新后分别检查 config、status、退出清理、pidfile/plist 与实际 fake 调用记录。

### P1：正常退出和信号退出的清理资源集合不同，可能留下 app 孤儿进程

- 证据：正常退出由 `AppDelegate.applicationShouldTerminate()` 遍历当前 `config.tunnels`，对 launchd 执行 `bootout`，对 app 执行内存中的 `appExecutor.shutdownAll()`；信号退出的 `Shutdown.stopAllManagedTunnels()` 则从磁盘配置读取，并按 pidfile 终止 app。[`AppDelegate.swift`](../../Sources/tunnelpad/AppDelegate.swift)；[`Shutdown.swift`](../../Sources/TunnelPadCore/Shutdown.swift)
- 影响：如果 app 执行器内存上下文已经丢失、配置刚被重载/替换、或 pidfile 与当前上下文不一致，正常退出路径可能没有覆盖所有仍由 TunnelPad 创建的 app 子进程；反过来信号路径也可能因配置损坏而只得到空配置。这样会破坏“退出即全停”和下次启动收敛的闭环。
- 当前状态：现有 v1 证据覆盖了正常 demo 退出和 pidfile 信号路径，但没有覆盖“上下文缺失/配置异常/实例残留”交叉组合。
- 建议：统一退出清理的资源发现与结果汇总；至少把 pidfile 收敛作为正常退出后的补偿检查，并对每条隧道记录“已停止、未发现、停止失败、身份不明”而不是只返回条数。该建议必须保留稳定性计划中 PID 身份校验和不误杀边界。
- 最小验证：启动 app 隧道后模拟 owner 内存上下文缺失、配置读取失败和 stale pidfile，再分别走菜单退出、SIGTERM/SIGINT、下次启动；确认匹配进程被收敛、无关 PID 不被触碰、状态与日志可解释。

### P1：pidfile 只按 PID 发送信号，PID 复用时存在误杀边界

- 证据：`Shutdown.killByPidfile()` 读取 PID 后仅调用 `kill(pid, 0)` 判断存在，再直接 `kill(pid, signalNumber)`；没有校验可执行文件、命令行、启动时间或 owner。[`Shutdown.swift`](../../Sources/TunnelPadCore/Shutdown.swift)
- 影响：系统重启或进程退出后 PID 被复用时，启动收敛/信号退出可能向无关进程发送 SIGTERM。
- 当前状态：这是当前实现的明确安全缺口；稳定性计划已经把“可执行文件/命令行匹配，身份不明不发信号”列为阶段 0 不变量，但尚未实现和独立验证。
- 建议：沿用稳定性计划的保守收敛方案；不要通过“PID 存在即杀”扩展清理范围。补充 PID 复用、命令行变化、身份查询失败和 pidfile 损坏样本。

### P1：launchd 重启吞掉 bootout 错误，可能把失败伪装成可继续 bootstrap

- 证据：`TunnelLifecycleCoordinator.restartSync()` 对 launchd 的 `bootout` 使用 `try?`，无论 bootout 是否因权限、通信或其他错误失败，都会继续写 plist 并调用 `bootstrap`。[`TunnelLifecycleCoordinator.swift`](../../Sources/TunnelPadCore/TunnelLifecycleCoordinator.swift)
- 影响：旧服务仍在时，后续 bootstrap 可能失败、重复/旧实例可能继续运行，返回的错误只反映后续步骤，无法告诉用户停止旧实例本身失败；健康恢复和手动重启共用该边界时会放大状态歧义。
- 当前状态：代码路径已确认；已有迁移回滚中“忽略 not-found”与此不同，不能用迁移语义为普通重启吞错做兜底。
- 建议：区分“服务本来就未加载”的可接受结果与其他 bootout 错误；非预期错误应停止重启流程并返回可诊断结果，必要时补状态复查。
- 最小验证：bootout 返回 not-found、权限/runner 失败、bootstrap 失败三组 fixture，分别检查调用顺序、返回文案和旧服务是否仍被认为 running。

## 中等优先级潜在问题

### P2：探针按全局串行执行，一条慢探针会拖延其他隧道

- 证据：`ProbeCoordinator.run()` 按 `probes` 顺序逐条 `await service.check()`；同一个 coordinator 负责一轮全部探针。[`ProbeCoordinator.swift`](../../Sources/TunnelPadCore/ProbeCoordinator.swift)
- 影响：某个 HTTP 目标达到超时上限时，其他隧道的健康结果和后续恢复判断会被延迟；后台监测计划若直接复用该全局串行器，可能把单隧道故障扩散成全局监测延迟。
- 建议：稳定性实现阶段明确“每隧道独立任务”还是“共享协调器并发”；若保持串行，必须把最大单次探针耗时和跨隧道延迟写入完成条件。优先验证任务取消、配置重载和窗口隐藏时是否仍能及时停止。

### P2：日志和状态各自轮询，面板可见时存在重复 IO 与重绘触发源

- 证据：主面板可见时每 5 秒 `refreshAsync()`；`LogView` 另有每 2 秒 `LogTail.lastLines()`，且两者都绑定主窗口可见性。 [`MainPanelView.swift`](../../Sources/tunnelpad/MainPanelView.swift)；[`LogView.swift`](../../Sources/tunnelpad/LogView.swift)
- 影响：日志面板打开时，状态/探针和日志分别周期读取；多个面板或切换隧道时如果旧任务取消不及时，可能出现额外文件 IO、无效读取和内容更新时序复杂。当前日志内容未变时已避免写状态，但仍然会进行读取。
- 当前状态：日志事件流计划已明确要移除固定 Timer，并覆盖打开/关闭、切换隧道和迟到事件；该问题已有计划承接。
- 建议：在日志事件流计划验收时额外记录“同一日志无新增内容期间读取次数”和“切换后旧日志事件是否写入新隧道面板”，不要只验收画面看起来会刷新。

### P2：app keepAlive 的迟到重启可能使用旧配置快照

- 证据：`AppProcessExecutor` 的 termination handler 依据内存 `Context.tunnel` 调用 `start(tunnel)`；`TunnelManager.updateTunnelAsync()` 对命令、保活或节流参数修改不会重启当前实例，而是保留旧运行参数直到下次重启。[`AppProcessExecutor.swift`](../../Sources/TunnelPadCore/AppProcessExecutor.swift)；[`TunnelManager.swift`](../../Sources/TunnelPadCore/TunnelManager.swift)
- 影响：用户已保存新命令或 `keepAlive` 设置后，旧 app 进程异常退出，自动重启可能继续使用旧命令和旧保活策略；这与“运行中的隧道下次重启后使用新参数”的文案如何解释，需要明确。
- 当前状态：更像未冻结的产品语义，而非必然错误；现有稳定性计划要求保留 keepAlive，但没有单独定义“自动重启是否算下次重启并读取最新配置”。
- 建议：在稳定性阶段 0/1 固定并测试一种语义。推荐把意外退出后的自动重启视为生命周期重启，读取当前有效配置，但要在配置代次与取消保护下避免旧任务拉起旧命令；若保留旧快照，则 UI 应明确该边界。

## 治理与架构层问题

### G1：稳定性、日志事件流、备注和 Rust 迁移均触及共享边界，图谱显示实现顺序必须保持串行

- 证据：图谱中 `function.tunnel.lifecycle`、`function.config.management`、`function.app.executor`、`function.health.probe` 同时被多个计划依赖；`docs/PLAN_MAP.md` 已把 Rust 迁移阶段 4 作为后续实现前置，并要求日志/稳定性共享模块串行。
- 影响：如果直接按功能图谱中的“可达”关系并行实施，容易同时修改 `TunnelManager`、生命周期协调器、执行器、运行时状态和侧栏，造成 plan drift 或把一个计划的行为回归误归因于另一个计划。
- 建议：把本图谱作为影响分析入口；实施任何共享符号前先执行 GitNexus upstream impact，严格按 `PLAN_MAP.md` 的顺序推进。Rust 阶段 4 未完成独立复核前，后续三个计划只做阶段 0 文档/fixture。

### G2：Swift/Rust 双实现使“功能图谱正确”不等于“实际 owner 唯一"

- 证据：`function.rust.parity` 同时连接配置管理和隧道生命周期；当前工作树有 Rust shadow bridge 相关未提交改动，Rust 迁移计划阶段 4 仍处于设计/准入边界。
- 影响：同一功能可能存在 Swift 路径、Rust 路径、shadow/differential 路径三套行为；只检查 Swift 源码或只检查单元测试，可能漏掉 owner 切换、错误传播、取消和日志/时区等差异。
- 建议：每个后续功能计划补充“当前 owner、迁移后 owner、shadow 是否可执行、差分样本”四项；在 Rust 阶段 4 独立复核通过前，不把图谱节点的 Rust 关系当成已实现主路径。

## 合并后的实施边界

本轮不新增独立计划。上述运行时配置与安全收敛问题并入现有 `tunnelpad-stability` 的阶段 0，覆盖：

1. 配置损坏/半写入时 fail-closed，保留最后有效运行配置与可恢复提示。
2. 执行器切换的“旧实例停止成功后才提交新配置”事务边界。
3. 正常退出、信号退出、崩溃后启动三条清理路径统一的资源发现与结果分类。
4. launchd restart 的 bootout 错误分类与状态复查。
5. app 自动重启读取旧快照还是最新配置的明确语义。
6. 与稳定性、日志事件流、Rust 迁移的依赖顺序和回滚边界。

本次已更新 `docs/plans/tunnelpad-stability.md` 的范围、未决问题、阶段 0 样本矩阵、验证方式和完成条件，并同步保留在 `PLAN_MAP.md` 的原稳定性计划中；没有创建新计划，也没有修改实现代码。

## 反向引用检查

图谱中的节点证据均指向当前仓库的源码、测试或已启用治理文档；本报告没有把历史草案或 README 作为事实源。需要在后续计划建立/实施前再次搜索以下关键语义，避免与现有事实漂移：

```bash
rg -n 'reloadConfigAsync|updateTunnelAsync|ConfigStore\.load|killByPidfile|restartSync|keepAlive|runProbes|Task\.sleep|isMainWindowVisible|草案为准|以草案为事实源|详见草案' docs Sources Tests
```

## 审计边界

- 本报告不是独立准入复核，不把潜在问题直接标为已修复。
- 没有执行构建、测试、真实 launchctl 操作、真实隧道故障注入或进程终止。
- 本次允许的变更仅限图谱、审计报告和治理索引链接；现有 Rust 迁移及其他工作树改动保持原样。
