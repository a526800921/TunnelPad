# 计划：TunnelPad 隧道稳定性与健康恢复

- 状态：已完成
- 当前阶段：-（阶段 0–3 已完成并通过各自独立复核）
- 最后更新：2026-09-02
- 前置：`tunnelpad-v1`、`tunnelpad-code-quality-refactor`、`tunnelpad-rust-migration` 阶段 5 和 `ecs-dynamic-ssh-ip` 阶段 2 已完成并关闭；阶段 0–3 已完成，阶段 2 的四个稳定性切片、真实 App/launchd 生命周期和探针假死触发 ECS 自动恢复均已通过阶段 2 总体独立完成复核；阶段 3 的 Step 0、独立准入和最终发布门禁均已通过

本计划独立处理 TunnelPad 的运行稳定性，不回写 v1 已冻结的探针展示语义，也不与 Rust Core 迁移阶段 5 并行修改执行器、生命周期或探针模块。当前稳定性实现范围先限定为阶段 5 已确认的 `launchd`；未来 `app` 执行器重新开发后，另行补充对应稳定性范围。日志事件流计划阶段 0–3 已完成；稳定性计划阶段 0–3 已完成并关闭，涉及共享模块的后续实现仍需使用单一编辑窗口。

## 背景

当前 TunnelPad 的 `keepAlive` 能处理“受管进程退出后重新拉起”，但探针只在刷新或启停动作中执行，且只更新界面展示。当 SSH 进程仍显示运行、而 TCP 转发或本机映射的 HTTP 服务已经不可用时，现有逻辑不会由探针触发恢复；主窗口隐藏时也没有独立的后台健康监测。

此外，TunnelPad 崩溃后重新启动时，当前启动路径读取有效配置并由后台健康协调器首轮查询配置内 `launchd` 状态；启动/退出切片已固定该只读状态发现边界，不会因为崩溃后仍加载的受管服务而猜测性重复启动。阶段 5 已将当前运行路径收敛为 `launchd`，其系统托管状态可以被重新查询；历史 `app` 执行器及其 pidfile 收敛留待未来 app 计划，不作为本阶段稳定性实现入口。

ECS 动态 SSH 计划已完成“TunnelPad 手动启动/重启前同步公网 IP”，此前该前置只发生在 `TunnelManager` 的显式入口。阶段 2 ECS 自动恢复切片现已把运行中探针失败触发的同步纳入恢复链路，并阻断 `KeepAlive` 绕过同步的窗口；连接中断后不再直接使用未经确认的旧安全组来源重连。

功能图谱审计又发现，配置损坏/半写入、执行器切换停止失败、正常退出与信号退出资源发现不一致，以及 launchd 重启吞掉 `bootout` 错误，都会让配置、状态和实际托管实例分叉。这些问题与稳定性计划共同指向“运行时状态最终必须安全收敛”，本次并入本计划阶段 0 的基线和后续回归矩阵；app `keepAlive` 和 pidfile 语义留待未来 app 计划。

这不是 v1 已验收行为的回归结论，而是下一阶段稳定性能力的缺口。新的行为必须与现有手动停止、删除、退出清理、`keepAlive` 和 `launchd` 语义保持一致，并且在达到重试上限后停止当前隧道，取消该隧道的自动恢复与重试任务，同时保留只读探针监测，避免界面状态和实际生命周期分叉。日志文件事件流仍由独立日志计划负责，Swift/Rust owner 与 parity 仍由 Rust 迁移计划负责。

## 目标

- 对已配置 HTTP 探针的隧道建立与主窗口可见性无关的后台健康监测。
- 识别“进程仍在但隧道实际不可用”的情况，并在连续失败达到阈值后通过现有生命周期边界安全重启。
- 固定、可测试地执行连续失败、退避、最大重试次数和熔断停止语义，避免重启风暴。
- 第 10 次自动恢复仍失败时，停止当前隧道并取消该隧道的自动恢复与重试任务，保留只读探针监测；其他隧道不受影响。
- 保留 `launchd` 进程意外退出时的现有 `keepAlive` 自动拉起能力，并确保手动启动/重启能够重新开启监测、清零失败计数。
- 对 Rust 配置解析失败、`launchd` 重启停止失败和退出清理资源不一致建立 fail-closed 的运行时收敛边界；具体错误分类在阶段 0 冻结。
- 对已接入 ECS 动态 SSH 同步的隧道，覆盖运行期间本机公网 IPv4 变化：在自动重连或健康恢复前确认并同步受管安全组来源，避免 `launchd` 直接重连绕过同步后长期失败。
- 用隔离 fixture、失败注入、`launchd` 测试和受控应用冒烟证明无迟到任务、无状态倒灌和无计划外隧道操作；`app` 执行器测试留待未来计划。

## 非目标

- 不新增 TCP 探测、额外 SSH 探测或第二套凭证/连接通道；健康信号只使用现有 HTTP 探针。
- 不把远端业务服务自身不可用、HTTP 鉴权失败或错误的探针 URL 自动解释成 SSH 网络故障；它们只按探针失败参与本计划的恢复策略。
- 不修改 `config.json` Schema、现有 `probe` 字段含义、`keepAlive` 字段含义、launchd label 或日志路径；不恢复历史 app pidfile 路径，未来 app 计划另行定义。
- 不增加用户可配置的监测周期、失败阈值、退避序列或最大次数；本计划 v1 固定这些策略，未来开放配置需另立计划。
- 不因单条隧道失败而停止、重启或修改其他隧道。
- 不在本计划阶段 0 独立准入前修改稳定性实现，也不在真实用户隧道上做未经批准的故障注入。
- 不在本计划内实现日志文件事件流、日志面板订阅模型、隧道备注字段或 Swift/Rust owner 切换；这些分别由日志事件流、备注和 Rust 迁移计划负责，本计划只验证它们与生命周期边界的交互。
- 不承诺 TunnelPad 进程自身崩溃期间仍能实时监测；当前阶段只验证 `launchd` 状态重新收敛，`app` 孤儿进程安全收敛留待未来 app 计划。
- 不承诺在没有可观察网络/探针事件时即时发现所有公网 IP 变化；检测触发、轮询周期和自动重连接管方式必须先在阶段 0 冻结。
- 不扫描或强制终止不属于配置中 `launchd` label 的任意系统进程；`app` PID 身份校验不在当前阶段范围。

## 需求探索

### 已确认事实

- 当前 `ProbeService` 对配置 URL 执行 HTTP GET，默认超时 3 秒，按期望状态码返回满足、不满足或失败三态；它本身不执行启停。[ProbeService.swift](../../Sources/TunnelPadCore/ProbeService.swift)
- 当前 `TunnelManager.runProbes()` 由同步/异步刷新路径调用，结果只写入运行时展示状态；现有阶段证据明确登记“探针只影响展示、无后台轮询”。[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)；[v1 阶段 2 证据](../data-quality/tunnelpad-v1-stage2-features-20260829.md)
- 当前主窗口的状态刷新任务每 5 秒运行一次，但只在主窗口可见时运行；这不能作为常驻稳定性监测的所有者。[MainPanelView.swift](../../Sources/tunnelpad/MainPanelView.swift)
- 阶段 5 删除前，`AppDelegate.applicationDidFinishLaunching` 只安装信号处理、创建菜单栏控制器并显示窗口；`TunnelManager.init` 只加载配置，历史启动路径没有调用 `Shutdown.killByPidfile` 或等价的 app 孤儿收敛流程。当前运行路径不再提供 app pidfile 收敛。[AppDelegate.swift](../../Sources/tunnelpad/AppDelegate.swift)；[Shutdown.swift](../../Sources/TunnelPadCore/Shutdown.swift)
- 阶段 5 删除前，v1 的 app 执行器 `status` 只查询进程内存中的 `contexts`，不会从 pidfile 恢复上下文；该问题已移出当前 `launchd` 稳定性范围，未来 app 计划重新定义。
- `launchd` 执行器将 `keepAlive` 写入 plist，由 launchd 观察受管进程生命周期；历史 app 的 termination handler/`throttleInterval` 语义保留在 v1 计划，未来 app 计划重新定义。[LaunchdPlistRenderer.swift](../../Sources/TunnelPadCore/LaunchdPlistRenderer.swift)；[TunnelPad v1 计划](tunnelpad-v1.md#app-执行器语义)
- `reloadConfigAsync()` 会直接接受 `ConfigStore.load()` 的结果并裁剪运行时状态；配置损坏时 `ConfigStore.load()` 会留档原文件并返回空配置。该恢复语义尚未证明适合运行中的配置刷新。[ConfigStore.swift](../../Sources/TunnelPadCore/ConfigStore.swift)；[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)
- 阶段 5 删除前，`updateTunnelAsync()` 的执行器切换和 `restartSync()` 的停止结果曾是本计划的失败注入基线；当前实现已由 Rust owner 统一生命周期边界，本计划阶段 0 需基于现有代码重新冻结失败分类。[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)；[Rust owner](../../rust/tunnelpad-core/src/owner.rs)
- ECS 动态 SSH 阶段 2 当前只在 `TunnelManager` 的显式 start/restart 前执行同步；运行中的 `launchd` `KeepAlive` 自动重连直接执行 SSH，不会回调 `TunnelManager`。该边界来自已完成 ECS 计划的实现与真实 App 验收。[ECS 动态 SSH 计划](ecs-dynamic-ssh-ip.md)；[LaunchdPlistRenderer.swift](../../Sources/TunnelPadCore/LaunchdPlistRenderer.swift)
- 阶段 5 删除前，正常退出与信号退出使用不同的 app/pidfile 资源发现路径；当前运行路径统一由 Rust owner 按配置中的 `launchd` label 清理，启动/退出切片已验证两条路径共享同一 owner，历史差异只保留为迁移背景。[AppDelegate.swift](../../Sources/tunnelpad/AppDelegate.swift)；[Shutdown.swift](../../Sources/TunnelPadCore/Shutdown.swift)
- 现有 v1 和代码质量重构计划已冻结手动停止、删除、退出清理、过期任务保护和探针展示兼容边界；本计划是行为增强，不替代这些事实源。[TunnelPad v1 计划](tunnelpad-v1.md)；[代码质量重构计划](tunnelpad-code-quality-refactor.md)
- Rust Core 阶段 5 已完成实现并已提交；本计划不覆盖 owner 切换实现。阶段 1 已按本计划自身准入门禁重新核对共享生命周期模块影响面并完成；阶段 2 的 Rust 生命周期增强仍须遵守本计划阶段路线和独立复核。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 已配置 HTTP 探针可以代表本机通过隧道访问目标服务的可用性 | 隔离本机 HTTP fixture + 隧道生命周期 fake executor；确认期望状态码、连接拒绝和超时分别进入预期状态 |
| 连续 3 次失败比单次失败更能避免瞬时抖动误重启 | 失败序列 fixture：单次失败后成功不触发重启；连续三次失败只触发一次恢复流程 |
| Rust `launchd` 生命周期是健康重启的安全边界 | 对 fake `launchd` 注入 bootstrap/bootout 结果，确认重启不绕过手动停止、删除和退出代次保护 |
| 后台监测可以独立于主窗口运行且不会产生重复监测任务 | 应用生命周期与取消测试：窗口隐藏、配置重载、手动停止、删除和退出后只保留合法任务或无任务 |
| 退避四级加第 10 次熔断足以限制重启风暴 | 状态机 fixture 验证 `10 秒 → 30 秒 → 60 秒 → 5 分钟封顶`、累计 10 次后停止当前隧道并取消该隧道任务 |
| app 孤儿进程收敛 | 当前 app 执行器已从阶段 5 范围移除；待未来 app 计划重新定义 |
| 配置损坏或外部半写入不应清空当前有效运行配置 | 隔离 `ConfigStore` 损坏/半写入 fixture；验证原文件留档、当前有效配置和运行实例不会被错误裁剪，并保留可恢复提示 |
| `launchd` 重启必须先确认旧实例收敛 | fake `launchd` 注入 stop/bootout 失败、not-found 和 bootstrap 失败；验证失败时不提交不一致的新配置，并有状态复查 |
| 正常退出、信号退出和崩溃后启动应覆盖同一组 `launchd` 资源 | 隔离配置读取失败和受管 label 缺失；验证匹配实例收敛、无关 label 不操作、结果可解释 |
| `launchd` keepAlive 应使用冻结且可解释的配置语义 | 修改命令/keepAlive 后注入状态变化；比较旧快照与当前有效配置两种候选语义，冻结一种并验证代次取消 |
| 运行中公网 IPv4 变化应在自动重连前触发来源确认/同步 | 隔离注入来源变化、探针失败/SSH 断线和 `launchd` KeepAlive 重连序列；确认同步成功后才恢复当前隧道，且其他隧道不受影响 |
| ECS 同步失败时自动恢复必须 fail-closed | 注入规则读取失败、双端点不一致和云端写入失败；确认不发起新的 SSH 重连、不无限重试旧来源，并沿用退避/熔断边界 |

### 范围与非目标

本计划覆盖两类稳定性边界：一是“本机 TunnelPad 已配置 HTTP 探针的单条 `launchd` 隧道”的后台健康恢复；二是配置重载、应用退出、崩溃后启动和 `launchd` 生命周期重启过程中的运行时安全收敛。无探针隧道继续使用进程存活与既有 `keepAlive` 语义。健康恢复对 `keepAlive=false` 的隧道只记录和展示失败，不自动重启。熔断只作用于当前隧道，其他隧道继续独立运行。

本计划还覆盖已启用 ECS 动态 SSH 前置同步的 SSH 隧道：运行期间检测到本机公网 IPv4 变化、探针失败或 SSH 断线时，必须把“受管安全组来源同步”纳入自动恢复链路，确保 `launchd` 的自动重连不再绕过该同步。无 ECS 配置的隧道不进入该分支，来源探测失败或结果不一致时按 fail-closed 处理。

本次并入的问题只处理“配置、状态、实际托管实例最终一致且失败可解释”的运行时边界；日志文件事件流、日志面板订阅/轮询模型仍由日志事件流计划负责，备注字段仍由备注计划负责，Swift/Rust owner 与 parity 仍由 Rust 迁移计划负责。

### 候选方案与取舍

| 方案 | 取舍 | 结论 |
|---|---|---|
| 只观察进程退出 | 与现有 v1 完全一致，但无法处理进程假死或转发失效 | 保留为无探针/兼容路径，不足以完成本计划 |
| HTTP 探针 + 后台监测 + 有界恢复 | 能验证本机业务路径，复用现有探针和生命周期边界；需要新增运行时状态机与取消保护 | **采用** |
| 新增 TCP/SSH 探测 | 覆盖面更广，但会引入端口语义、凭证、误判和额外连接管理 | 不纳入本计划 |
| 无限固定间隔重启 | 实现简单，但可能造成重启风暴和远端服务压力 | 不采用 |
| 固定退避 + 10 次熔断 | 可预测、易测试；熔断后需人工重新启动 | **采用** |
| app 启动 pidfile 收敛 | 当前 app 执行器已从阶段 5 范围移除；未来 app 计划重新定义 | 延后 |
| 将配置/生命周期失败收敛并入稳定性计划 | 与健康恢复、孤儿进程、取消代次共享“实际实例最终一致”的安全边界；会扩大阶段 0 矩阵，但避免再拆分一套运行时 owner | **采用** |
| 只在手动启动/重启时同步 ECS 来源 | 实现简单，但运行中 IP 变化后 `launchd` 自动重连仍会绕过同步并持续失败 | 作为当前已完成 ECS 计划的基线，不足以满足稳定性目标 |
| 健康恢复协调器在自动重连前调用既有 ECS 同步命令 | 复用既有双端点校验、受管规则和安全组写入边界；触发点固定为现有后台 HTTP 探针失败并进入自动恢复前，不新增全局公网 IP 轮询；仍需处理与 `KeepAlive`、手动停止和退避任务的竞态 | **用户已确认，阶段 2 Step 0 固定并验证** |
| 为每条 SSH `launchd` 命令增加同步 wrapper | 能覆盖 launchd 直接重连，但会改变 plist/命令边界、资源分发和失败可观测性 | 暂不采用；若需采用必须另行更新范围与回滚方案 |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| Rust Core 迁移阶段 5 完成后再实施稳定性运行时变化 | Rust Core 阶段 5 已完成 `launchd` owner 切换；稳定性阶段 0–3 已按自身 Step 0、准入和完成复核推进并完成门禁收口 | 是（曾阻塞阶段 2 实施，不阻塞阶段 1 收尾） | 已完成前置（2026-08-31） |
| 配置文件损坏/半写入时如何处理当前有效运行配置 | 保留上一份有效配置并只报错，禁止因刷新直接裁剪运行时状态 | 否 | 已冻结并在阶段 1 完成 |
| 执行器切换停止失败是否允许保存新执行器 | 当前配置枚举仅支持 `launchd`，本阶段不存在可执行的 `launchd`/`app` 切换；未来 app 执行器计划必须先冻结“旧实例停止成功或明确未加载才提交新执行器”的语义 | 否 | 延后至未来 app 执行器计划 |
| 外部刷新删除仍加载的隧道如何提交候选配置 | 先停止并复核待删除的旧 `launchd` label；全部达到 `notLoaded` 后才替换 owner 配置；任一失败保留旧配置；同 ID 参数修改仍等下次显式重启 | 否 | 配置重载切片已完成 |
| `launchd` 自动恢复任务的配置代次 | 读取当前有效 Rust 配置，并用配置/操作代次阻止旧任务回写 | 否 | 已冻结并在阶段 1 完成 |
| 正常退出与信号退出的清理结果如何统一 | 统一资源发现、身份校验和结果分类；保留 PID 不明不发信号的安全边界 | 否 | 启动/退出切片已完成验证 |
| 运行中公网 IPv4 变化由什么事件触发检测 | 复用现有 10 秒后台健康协调器；仅在 HTTP 探针失败累计到自动恢复尝试前触发 ECS 同步，不新增全局公网 IP 轮询 | 否 | ECS 自动恢复切片已完成验证 |
| 自动重连前由谁调用 ECS 同步 | SSH 自动恢复由当前健康恢复协调器先调用 Rust `stop`，确认受管 label 返回 `notLoaded` 后复用既有 ECS 前置适配器；同步成功才调用 Rust `start`，失败不启动；普通隧道继续使用 `restart` | 否 | ECS 自动恢复切片已完成验证 |
| IP 变化但 ECS 同步失败时是否允许 `KeepAlive` 继续拉起 | 不允许新的 SSH 重连；本次恢复失败进入现有可诊断退避/熔断，且不得无限重试旧来源 | 否 | ECS 自动恢复切片已完成验证 |

### 用户确认的探索结论

2026-08-30 用户确认：建立独立的 TunnelPad 稳定性计划，目标包括进程仍运行但隧道不可用/假死的场景；健康信号只使用现有 HTTP 探针；后台监测不依赖主窗口是否可见；连续失败 3 次后触发恢复；恢复退避固定为 10 秒、30 秒、60 秒、5 分钟封顶；最多自动重试 10 次，第 10 次仍失败后停止当前隧道，停止该隧道的自动重试和自动恢复任务但保留只读探针监测，其他隧道不受影响；手动启动/重启后恢复监测并清零；策略固定，不新增配置字段或设置项；本计划等待 Rust Core 阶段 5 完成，后续仍按本计划自身准入推进。当前阶段只实现 `launchd`，未来 `app` 执行器另立计划。

2026-08-30 用户补充确认：TunnelPad 崩溃后下一次启动必须检测并安全清理 app 执行器的孤儿进程；该需求已因阶段 5 当前移除 app 执行器而延后，未来 app 计划重新定义时再恢复。

2026-08-30 根据功能图谱审计结果，用户确认将以下运行时问题并入本稳定性计划：配置损坏/半写入导致的状态分叉、`launchd` 执行器停止失败、正常退出与信号退出清理不一致，以及 launchd 重启吞掉 `bootout` 错误。`app` 执行器自动重启、pidfile 和孤儿进程问题因阶段 5 当前明确移除 app 范围，留待未来 app 计划。日志轮询问题仍归日志事件流计划；Swift/Rust owner 与 parity 问题仍归 Rust Core 迁移计划。本次合并只扩大稳定性计划的阶段 0 基线、失败注入和回归范围，不改变阶段 1 的实施前置条件。

2026-08-31 用户要求将“运行中本机公网 IPv4 发生变化”补充到本计划：当前 ECS 同步只覆盖 TunnelPad 显式启动/重启，`launchd KeepAlive` 自动重连可能绕过同步并继续使用旧安全组来源；稳定性计划需设计运行中变化的发现、受管规则同步、自动重连前置和失败恢复边界。该需求先作为阶段 0 待冻结事项记录，不预设轮询周期、wrapper 或其他实现方案。

2026-09-01 用户确认日志事件流计划与本计划的共享边界；日志计划阶段 0–3 现已完成，稳定性计划重新开始阶段 0。涉及 `TunnelManager`、`TunnelRuntimeState`、主面板和共享测试目录的稳定性实现改动必须串行，日志计划不再作为稳定性阶段 0 的前置条件。

2026-09-02 用户进一步明确第 10 次失败后的运行语义：当前隧道进程停止，取消该隧道的自动重试和自动恢复；保留只读探针监测以持续反映停止状态，其他隧道继续独立运行。手动启动/重启后清零并恢复自动恢复资格。

2026-09-02 用户确认阶段 2 的 ECS 运行时同步触发方案：复用现有 10 秒后台 HTTP 探针作为唯一触发入口；当 SSH 隧道的探针失败累计到自动恢复尝试前，先调用既有 `update-ecs-ssh-ip` 同步/校验当前公网 IPv4，成功后才允许进入 Rust `restart`；同步失败、超时、取消或结果无法分类时阻断本次 SSH 重连并沿用现有退避/熔断。阶段 2 不新增独立的全局公网 IP 轮询、配置字段或 ECS API 实现；`launchd KeepAlive` 不得绕过该前置边界，具体拦截方式仍需阶段 2 Step 0 固定。

2026-09-02 经评估冻结阶段 2 的 ECS 自动恢复顺序：SSH 隧道进入自动恢复时，健康恢复协调器先通过现有 Rust owner 执行 `stop`/`bootout`，只有返回 `notLoaded` 才运行既有 ECS 同步；同步成功后再通过同一操作代次执行 `start`/`bootstrap`。停止失败、状态仍已加载、同步失败、超时、取消或结果无法分类时均不启动 SSH，本次失败沿用既有退避/熔断；非 SSH 隧道保留原有 `restart` 路径。该方案不改变 plist 的原始 SSH 命令、`KeepAlive` 字段、Rust C ABI 或配置 Schema。

### 本次并入范围的阶段 0 冻结要求

- 配置解析失败或外部半写入不得无提示地把当前有效运行配置裁剪成空配置；具体保留、留档和恢复文案需由隔离 fixture 冻结。
- 执行器切换、launchd 重启和退出清理必须区分“已停止/未加载”和“停止失败/身份不明”，失败时不得把新配置或成功状态提前提交给 UI。
- 正常退出、信号退出和崩溃后启动必须以同一组配置中的 `launchd` 受管资源为目标；app pidfile 清理留待未来 app 计划。
- `launchd` 自动恢复必须读取当前有效 Rust 配置，并由配置代次、操作代次和取消机制阻止过期任务回写状态。
- 对纳入 ECS 动态 SSH 同步的隧道，任何自动重连前必须有“当前来源已确认或同步失败已 fail-closed”的可观察结果；不得让 `KeepAlive` 绕过该边界无限重试旧来源。

## 不变量

- `ProbeConfig` 仍是可选的；未配置探针的隧道不进入健康恢复状态机。
- 单条隧道最多存在一个有效的健康监测/恢复协调实例；配置重载、手动停止、删除和退出必须使旧任务失效。
- 探针满足期望状态码时清零连续失败数和退避级别；不满足状态码、连接错误和超时均按一次失败计数。
- 只有 `keepAlive=true` 且非手动停止/删除/退出路径，才允许健康失败触发自动恢复。
- 失败 3 次触发一次恢复尝试；恢复尝试最多 10 次，等待时间按固定退避序列执行，超过第四级后以 5 分钟为上限。
- 第 10 次恢复仍未使探针恢复时，当前隧道必须进入已停止/人工处理状态，并取消该隧道所有后续探针、延迟重启和恢复任务；不得留下迟到任务重新拉起它。
- 手动启动或重启当前隧道会清除熔断状态、失败计数和退避状态；手动停止不会被后台任务重新拉起。
- 健康恢复不得改变其他隧道的进程、配置、探针结果或操作代次。
- 既有 `launchd` 进程意外退出后的 `keepAlive` 语义继续有效；健康恢复不得绕过 Rust `launchd` 生命周期边界。
- 当前阶段不执行 app pidfile 启动收敛；未来 app 计划必须单独冻结 pidfile 身份校验和不误杀边界。
- `launchd` 任务仍由 launchd 负责状态和进程托管；当前阶段不按 pidfile 逻辑扫描或终止进程，app pidfile 收敛留待未来 app 计划。
- 不在日志、计划、测试输出或错误文案中记录私钥、AccessKey、完整远端凭证或其他敏感内容。

## 影响模块或文件

- `Sources/TunnelPadCore/ProbeService.swift`
- `Sources/TunnelPadCore/ProbeCoordinator.swift`
- `Sources/TunnelPadCore/TunnelManager.swift`
- `Sources/TunnelPadCore/LaunchCtlExecutor.swift`
- `Sources/TunnelPadCore/LaunchdPlistRenderer.swift`
- `Sources/TunnelPadCore/Shutdown.swift`
- `Sources/TunnelPadCore/TunnelPaths.swift`（保持当前日志路径派生；不恢复历史 pidfile 路径）
- `Sources/TunnelPadCore/TunnelRuntimeState.swift`
- `Sources/tunnelpad/AppDelegate.swift`
- `Sources/tunnelpad/MainPanelView.swift`
- `Sources/tunnelpad/TunnelDetailComponents.swift`
- `Tests/TunnelPadStabilityTests/`（本计划后续新增的独立测试目录；迁移差分 harness 仍由 Rust 迁移计划负责）
- `rust/tunnelpad-core/`（Rust Core 迁移阶段 5 owner 切换完成后承载稳定性实现；当前先按 `launchd` 边界核对）
- `docs/data-quality/`
- `docs/PLAN_MAP.md`

实现时必须先对上述符号执行 GitNexus upstream impact 分析；任何 HIGH/CRITICAL 结果都要在修改前记录并重新确认范围。提交前必须执行 GitNexus `detect_changes()`，确认只影响稳定性计划声明的模块和执行流。

## 公共契约变化

当前计划不新增公共 API、HTTP API、`config.json` 字段或迁移文件。`probe`、`expectedStatuses` 和 `keepAlive` 的现有序列化与兼容语义保持不变；历史 app 的 `throttleInterval`/pidfile 语义不属于当前实现，未来 app 计划需重新冻结兼容和身份校验边界。

新增的失败计数、退避级别、恢复尝试次数、熔断状态和取消令牌均属于运行时内部状态，不落盘、不跨进程持久化。若后续需要让用户配置这些策略，必须另立计划并重新进行 Schema、UI、兼容性和回滚评估。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定健康恢复、配置一致性、资源收敛、状态契约、失败/回滚边界和实施门禁 | 用户确认结构化探索结论 | 只读审计、隔离 fixture 设计、现有测试与治理检查 | 已完成 |
| 阶段 1 | 实现后台监测、`launchd` 状态收敛（含 `bootout` fail-closed）、配置 fail-closed 基线与单隧道健康恢复状态机 | 阶段 0、阶段 1 Step 0 与阶段 1 独立准入均已通过；Rust Core 迁移阶段 5 已完成 | 状态机、配置异常、取消、代次、成功清零和 `launchd` 停止失败测试 | 已完成 |
| 阶段 2 | 完善启动/退出收敛、ECS 运行中同步、跨层状态一致性与配置重载收敛 | 阶段 1 初始实现与单元/契约测试通过；ECS 自动恢复、启动/退出、跨层一致性和配置重载切片已完成，真实 App 受控验收已覆盖启动/退出、崩溃发现和探针假死恢复 | fake `launchd`、故障注入、退出清理、ECS 双端点、迟到任务、配置候选提交和真实 App 受控验收 | 已完成 |
| 阶段 3 | 隔离 demo 与受控应用验收、文档和发布门禁收口 | 阶段 2 独立复核通过；阶段 3 Step 0 与独立准入已完成 | `swift test`、`cargo test`（适用时）、构建、AX/应用冒烟和治理检查 | 已完成 |

## 阶段 0 收尾记录

### 范围

阶段 0 只做稳定性缺口的现状确认、最小可观察复现、配置与生命周期安全收敛基线、启动孤儿进程收敛基线、状态机契约和后续实现门禁设计。不修改 Swift/Rust 稳定性实现，不修改配置，不启停真实用户隧道，不创建新的 Schema 字段；运行中公网 IPv4 变化只记录候选检测、同步和恢复契约，不在本阶段实现。日志事件流计划阶段 0–3 已完成；稳定性计划阶段 0 已完成，阶段 1 若进入共享实现必须使用单一编辑窗口串行合入。

### 阶段 0 复核快照

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 基线类型已确定为“缺陷现状快照 + 隔离最小复现”；探针/刷新、launchd owner、退出清理和 ECS 启动前置的只读基线已落盘，现状基线 4 项 Swift 与 1 项 Rust 测试、后续实现契约 6 项 Swift 测试均已通过；阶段 0 独立准入已通过 |
| 样本矩阵 | 12 行，覆盖现有探针/刷新边界、配置异常、`launchd` 生命周期失败、进程保活、假死复现、失败状态机、运行中公网 IPv4 变化与 ECS 同步、单隧道隔离和治理检查；app 范围留待未来计划 |
| 验证方式 | 只读源码核对、隔离 fixture、现有测试清单、后续失败回归测试和 `plan-governance-cli check . --strict-readiness` |
| 失败/回滚边界 | 阶段 0 不改变运行状态；实现阶段按独立提交回滚，不覆盖 Rust Core 阶段 5 完成后的既有工作树改动；任何真实隧道误操作立即停止该场景 |
| 当前阻塞项 | 无；Rust Core 阶段 5、日志计划阶段 0–3 和本计划阶段 0 独立准入均已完成；阶段 1 另有自己的 Step 0 和准入门禁 |
| 最新独立准入复核 | 2026-09-01：达到“待实施”标准；阶段 0 已完成，阶段 1 仍需自己的 Step 0 和独立准入；见[契约 fixture 独立准入复核](../data-quality/tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md) |

### 实施步骤

1. 记录当前工作树、源码/测试边界和 Rust Core 阶段 5 完成后的迁移状态，不将既有未提交改动归入本计划。
2. 补充不操作真实用户隧道的最小复现：进程保持存活且 HTTP 探针连续失败；配置半写入或损坏；`launchd` 停止失败。
3. 冻结健康恢复状态机以及启动孤儿收敛的输入、身份校验、计数、退避、熔断、手动恢复和取消语义。
4. 冻结配置 fail-closed、`launchd` 重启错误分类、统一退出清理资源集和自动恢复配置快照语义。
5. 设计 `launchd` fake/fixture 矩阵以及失败边界；app 执行器留待未来计划。
6. 复核 Rust Core 迁移阶段 5 的完成证据和实际边界，重新核对共享影响面，再申请本计划阶段 1 准入。

### Step 0 证据

基线类型：缺陷修复与架构探索结合的现状快照。当前已查证的替代基线是：`ProbeService` 只执行 HTTP GET；`TunnelManager` 只在刷新/启停路径调度探针；主面板 5 秒刷新受窗口可见性限制；当前有效配置全部使用 `launchd`，其 `keepAlive` 由 launchd 负责；配置损坏时 `ConfigStore.load()` 会返回空配置；launchd 重启存在停止结果未阻断后续流程的路径；正常退出与信号退出使用不同的资源发现方式；ECS 动态 SSH 同步只在 `TunnelManager` 显式 start/restart 前执行，`launchd` KeepAlive 自动重连不经过该前置。上述事实由源码、v1 阶段 2 证据、代码质量重构计划、ECS 动态 SSH 计划和本次功能图谱审计共同锚定。

Step 0 的可执行现状基线现已包括：“配置损坏/半写入时当前读取退化为空配置”和“launchd 重启吞掉 bootout 错误后继续 bootstrap”；“进程仍存活、探针连续失败且现有逻辑不触发恢复”的当前缺口也已由隔离测试记录。上述测试均使用临时目录、fake lifecycle 或脚本化 launchd，不得杀掉或修改真实用户隧道。阶段 0 的健康恢复状态机、配置/操作代次、取消和 ECS 运行中同步契约已由仅测试 fixture 固定并通过独立准入；生产接入留待阶段 1。

### 隔离 fixture 设计与当前基线

阶段 0 后续 fixture 统一使用以下注入边界，不扩展生产 API，也不连接真实隧道：

- 探针使用 `ProbeService.Performer` 注入固定的成功、非期望状态码、超时和连接失败序列；生命周期使用 `RustLifecycleOwner` fake 记录每次 start/stop/restart/remove/shutdown 调用及隧道 id。
- launchd 失败场景使用 `ProcessRunning`/fake launchd 记录 `bootout`、`bootstrap` 和 `print` 的输入输出，分别区分成功、明确 not-found、停止失败和 bootstrap 失败；当前 Rust 基线已复现 restart 在 bootout 出错后继续 bootstrap，fixture 不调用真实 `/bin/launchctl`。
- 配置异常场景使用隔离 `TunnelPaths` 和临时 `config.json`，保留一份有效运行配置快照，再注入坏 JSON、半写入和留档失败；验证 reload 失败时的内存配置、运行时状态、留档结果和提示语。
- ECS 场景只注入公网 IP 双端点结果、受管规则同步结果和取消/超时结果；验证自动恢复在来源未确认或同步失败时 fail-closed，不输出凭证或完整公网响应。

最小验收序列固定为：假死序列 `running + [fail, fail, fail]`、恢复成功序列 `[fail, fail, fail, success]`、第 10 次恢复失败序列、手动 stop/start 与迟到任务序列、配置代次变化序列，以及公网 IP 变化→规则同步→自动重连序列。每个序列都必须记录调用顺序、当前隧道 id、generation/取消结果和其他隧道未被修改；仅有全量测试通过不能替代这些行为证据。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前工作树与 Rust Core 阶段 5 完成后的基线 | `git rev-parse HEAD && git status --short && git diff --stat` | 记录 HEAD、既有未提交文件和稳定性计划边界；不把日志基线测试或其他既有改动归入本计划 | 输出缺失、误覆盖既有 diff 或出现未声明的稳定性代码改动 | 阶段 0 证据文档 |
| 2 | 现有探针与刷新实现 | `rg -n 'runProbes|ProbeService|Task\.sleep|isMainWindowVisible' Sources Tests --glob '*.swift'`；只读核对 v1 阶段 2 证据 | 复现“探针只展示、刷新受窗口可见性限制、无健康恢复调用”的现状 | 找不到事实源、源码与证据矛盾或出现未登记行为变化 | 阶段 0 证据文档 |
| 3 | launchd 进程退出保活基线 | `cargo test --manifest-path rust/Cargo.toml`；静态核对 `LaunchdPlistRenderer.swift` 与 Rust owner | 当前 `launchd` keepAlive 和状态查询边界可复现；历史 app keepAlive 不纳入当前范围 | 测试触碰真实用户隧道、出现旧 app 执行器路径或当前 launchd 语义不一致 | 阶段 0 证据文档 |
| 4 | 隔离假死最小复现 | `swift test --filter StabilityStage0BaselineTests`；使用 fake Rust owner、本机隔离 URL 和 `ProbeService.Performer` | 2 项测试通过：连续 3 次探针失败均保持为 `ProbeResult.failed`；`TunnelManager` 当前探针路径不调用 start/stop/restart/remove/shutdown，明确现有恢复缺口 | 测试触碰真实 launchctl/SSH、结果依赖主窗口，或出现生命周期调用 | 阶段 0 证据文档；`Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift` |
| 5 | 状态机候选契约 | `swift test --filter StabilityStage0ContractTests`；失败序列、十次失败序列和成功清零 fixture | 固定 3 次失败阈值、10/30/60/300 秒退避、成功清零、第 10 次熔断后停止并继续监测 | 计数漂移、成功不清零、熔断后仍拉起、其他隧道被修改 | 阶段 0 证据文档；`Tests/TunnelPadCoreTests/StabilityStage0ContractTests.swift` |
| 6 | `launchd` 生命周期隔离 | fake `launchd` 注入 bootstrap/bootout 结果；不调用真实 `launchctl` 或 SSH | `launchd` 遵守生命周期边界，其他隧道不受影响 | 出现真实外部副作用、跨隧道操作或迟到任务 | 阶段 0 证据文档；阶段 1–2 契约测试 |
| 7 | 配置异常安全边界 | `swift test --filter StabilityStage0BaselineTests`；隔离 `ConfigStore` 损坏/半写入 fixture | 已复现当前坏 JSON/半写入会留档并返回空配置；该结果记录为待修复缺口，阶段 1 再验证有效配置保留、运行时不裁剪和错误可恢复 | 测试触碰真实配置、归档原文丢失，或把当前缺陷误写成目标行为 | 阶段 0 证据文档；`Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift` |
| 8 | `launchd` 重启失败边界 | `cargo test --manifest-path rust/Cargo.toml stage0_baseline_restart_continues_after_bootout_error`；fake `launchd` 注入停止失败 | 已复现当前 bootout 错误被忽略且继续 bootstrap；阶段 1–2 再验证失败时阻断后续流程、状态可诊断 | 真实 `launchctl` 被调用，或基线测试不能证明 bootout 错误被吞掉 | 阶段 0 证据文档；`rust/tunnelpad-core/src/owner.rs` |
| 9 | 退出清理资源一致性 | 隔离配置读取失败和受管 label 缺失；分别走正常退出、信号退出和下次启动 | 各路径覆盖同一组 `launchd` 资源；无关 label 不操作；结果分类一致 | 受管任务残留、配置异常导致清理为空或成功状态虚报 | 阶段 0 证据文档；阶段 1–2 回归测试 |
| 10 | `launchd` 自动恢复配置代次 | `swift test --filter StabilityStage0ContractTests`；注入配置有效/无效候选和旧代次结果 | 有效候选才替换当前配置；解析失败保留当前有效配置；旧任务不能回写过期状态 | 自动恢复使用未声明配置、迟到任务倒灌或其他隧道受影响 | 阶段 0 证据文档；`Tests/TunnelPadCoreTests/StabilityStage0ContractTests.swift` |
| 11 | 运行中公网 IPv4 变化与自动重连 | `swift test --filter StabilityStage0ContractTests`；注入公网 IP 双端点、规则同步成功/失败序列 | 自动重连前确认来源一致且同步成功；不一致、私网、不可用或同步失败均 fail-closed | 直接重连绕过同步、旧规则持续重试、双端点不一致仍写入、或其他隧道被修改 | 阶段 0 证据文档；`Tests/TunnelPadCoreTests/StabilityStage0ContractTests.swift` |
| 12 | 治理与反向引用 | `plan-governance-cli check . --strict-readiness`；`git diff --check`；`rg -n 'tunnelpad-stability|健康恢复|运行时配置|稳定性|keepAlive|探针|孤儿进程|pidfile|公网 IPv4|ECS 动态 SSH|草案为准|以草案为事实源|详见草案' docs` | 计划链接、状态、依赖和关键术语一致；无新增治理 ERROR；旧草案不成为事实源 | 计划未被索引、重复定义、状态漂移或出现空白错误 | `docs/PLAN_MAP.md` 与阶段 0 证据文档 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 需求探索/计划建立 | 用户确认独立稳定性计划、HTTP-only、3 次失败、固定退避、最多 10 次并熔断停止；Rust Core 阶段 5 先完成 `launchd` owner，稳定性实现仍等待本计划自身准入 | 本计划“需求探索”与 `docs/PLAN_MAP.md` | 进行中 | Codex |
| 2026-08-30 | 功能图谱审计合并 | 根据功能图谱审计，将配置异常、`launchd` 执行器/重启失败和退出清理一致性纳入本计划阶段 0；app 执行器与 pidfile 语义留待未来计划；日志事件流与 Rust owner/parity 保持原计划边界 | [功能图谱审计](../data-quality/tunnelpad-functional-graph-review-20260830.md)；本计划“需求探索” | 进行中 | Codex |
| 2026-09-01 | 阶段 0 当前代码基线 | 只读核对探针/刷新、launchd 状态与 bootout、Rust owner、正常/信号退出、配置损坏处理和 ECS 启动前置；确认稳定性实现代码未混入并行日志基线 | [阶段 0 基线证据](../data-quality/tunnelpad-stability-stage0-20260901.md) | 通过（隔离故障注入与独立准入尚待完成） | Codex |
| 2026-09-01 | 阶段 0 假死现状最小复现 | 新增 `StabilityStage0BaselineTests`；2/2 通过，确认连续三次探针失败仅产生失败结果，当前 `TunnelManager` 不调用生命周期恢复；未修改生产实现 | [阶段 0 基线证据](../data-quality/tunnelpad-stability-stage0-20260901.md)；`Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift` | 通过（仅完成现状缺口，不代表恢复状态机已实现） | Codex |
| 2026-09-01 | 阶段 0 配置/生命周期故障基线 | `StabilityStage0BaselineTests` 增至 4/4，复现坏 JSON 与半写入会留档并返回空配置；新增 Rust `stage0_baseline_restart_continues_after_bootout_error`，复现 restart 吞掉 bootout 错误后继续 bootstrap；未修改稳定性生产逻辑 | [阶段 0 基线证据](../data-quality/tunnelpad-stability-stage0-20260901.md)；`Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift`；`rust/tunnelpad-core/src/owner.rs` | 通过（目标 fail-closed 行为留待阶段 1–2） | Codex |
| 2026-09-01 | 阶段 0 契约 fixture 补齐 | 新增 6 项仅测试契约 fixture：健康恢复、成功清零、keepAlive、隧道隔离/手动停止、代次取消、配置 fail-closed、ECS 双端点 fail-closed；6/6 通过，未修改生产恢复逻辑 | [阶段 0 基线证据](../data-quality/tunnelpad-stability-stage0-20260901.md)；`Tests/TunnelPadCoreTests/StabilityStage0ContractTests.swift` | 通过（等待新的独立准入复核） | Codex |
| 2026-09-02 | 阶段 1 初始生产实现 | 接入固定 10 秒后台健康监测、单隧道恢复状态机、配置有效候选保留、手动操作取消/清零、第 10 次失败停止和 Rust `bootout` fail-closed；停止后保留只读监测；未混入启动/退出收敛或真实 ECS/应用验收 | [阶段 1 实施证据](../data-quality/tunnelpad-stability-stage1-implementation-20260902.md)；`Sources/TunnelPadCore/HealthRecovery.swift`；`Sources/TunnelPadCore/TunnelManager.swift`；`rust/tunnelpad-core/src/owner.rs` | 进行中 | Codex |
| 2026-09-02 | 阶段 2 ECS 自动恢复切片实现 | SSH 自动恢复采用 `stop → preflight → start`，要求 stop 返回 `notLoaded`；ECS 前置失败后仍沿用有界恢复代次；非 SSH 保留 `restart`；5 项专项、123 项 Swift 全量和 Rust 51+1 回归通过 | [阶段 2 ECS 自动恢复切片实施证据](../data-quality/tunnelpad-stability-stage2-ecs-recovery-implementation-20260902.md)；`Sources/TunnelPadCore/ECSPreStart.swift`；`Sources/TunnelPadCore/TunnelManager.swift`；`Tests/TunnelPadCoreTests/StabilityStage2Tests.swift` | 通过（切片完成；阶段 2 后续切片已补齐） | Codex |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 只读治理检查 | 新计划写入前执行 `plan-governance-cli check . --strict-readiness`，既有仓库检查通过并保留一项既有 warning | 命令输出；本计划尚未落盘时的基线 | 通过 | Codex |
| 2026-09-01 | 并行计划边界与阶段 0 基线 | 日志/稳定性阶段 0 改为可并行推进；阶段 1 共享模块串行；完成稳定性当前代码基线证据，并执行普通、严格、停滞检查和空白检查 | [阶段 0 基线证据](../data-quality/tunnelpad-stability-stage0-20260901.md)；`plan-governance-cli check .`；`plan-governance-cli check . --strict-readiness`；`plan-governance-cli check . --stale-days 10`；`git diff --check` | 通过（保留预期共享目标 WARNING） | Codex |
| 2026-09-01 | 阶段 0 fixture 回归 | 执行 `swift test --filter StabilityStage0BaselineTests`（4/4）、`swift test --filter StabilityStage0ContractTests`（6/6）、`cargo test --manifest-path rust/Cargo.toml stage0_baseline_restart_continues_after_bootout_error`（1/1）、全量 `swift test`（109/109）和全量 `cargo test --manifest-path rust/Cargo.toml`（51 个 Rust 单元测试 + 1 个差分测试）；日志计划已完成，稳定性仍未引入后台恢复生产实现 | `Tests/TunnelPadCoreTests/StabilityStage0BaselineTests.swift`；`Tests/TunnelPadCoreTests/StabilityStage0ContractTests.swift`；`rust/tunnelpad-core/src/owner.rs`；命令输出 | 通过（阶段 0 已通过独立准入，阶段 1 自身 Step 0 尚待完成） | Codex |
| 2026-09-01 | 阶段 0 独立准入复核 | 独立只读复核确认目标/范围/安全边界和现状基线充分，但状态机、代次取消、ECS 运行中同步 fixture 尚未执行；阶段 0 未达到待实施标准 | [独立准入复核](../data-quality/tunnelpad-stability-stage0-independent-review-20260901.md) | 未通过（保留在阶段 0 设计中） | Codex（独立只读复核） |
| 2026-09-01 | 阶段 0 独立准入复核 | 复核确认目标/范围/非目标、12 行矩阵、6 项契约 fixture、验证/回滚边界和共享影响均满足阶段 0 准入；阶段 0 达到“待实施标准”并关闭 | [契约 fixture 独立准入复核](../data-quality/tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md) | 通过 | Codex（独立只读复核） |
| 2026-09-02 | 阶段 1 初始实现验证 | `swift test --filter StabilityStage1Tests`（7/7）、全量 `swift test`（116/116）、全量 `cargo test --manifest-path rust/Cargo.toml`（51 个 Rust 单元测试 + 1 个差分测试）、治理普通/严格/停滞检查和 `git diff --check` 均通过；GitNexus `detect_changes()` 报告 `TunnelManager` 枢纽变更为预期高影响，待阶段 1 完整行为验收 | [阶段 1 实施证据](../data-quality/tunnelpad-stability-stage1-implementation-20260902.md)；命令输出；GitNexus 变更范围检查 | 通过（阶段 1 仍在实施） | Codex |
| 2026-09-02 | 阶段 1 独立完成复核 | 补齐人工 start 后重新恢复、删除时取消排队恢复任务；阶段 1 专项 9/9、全量 Swift 118/118、Rust 51+1、治理普通/严格/停滞检查、`git diff --check` 和 GitNexus `detect_changes()`（83 个变更符号、26 个受影响符号、`critical`）均通过；阶段 1 完成边界与阶段 2 交接项已分离 | [阶段 1 独立完成复核](../data-quality/tunnelpad-stability-stage1-independent-completion-review-20260902.md)；[阶段 1 实施证据](../data-quality/tunnelpad-stability-stage1-implementation-20260902.md) | 通过（阶段 1 已完成） | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 ECS 自动恢复切片验证 | `swift test --filter StabilityStage2Tests`（5/5）、阶段 1 专项（9/9）、ECS 前置集成（12/12）、全量 Swift（123/123）、全量 Rust（51+1）、普通/严格/停滞治理检查和 `git diff --check` 均通过；GitNexus `detect_changes()` 报告 TunnelManager hub 预期高风险 | [阶段 2 ECS 自动恢复切片实施证据](../data-quality/tunnelpad-stability-stage2-ecs-recovery-implementation-20260902.md)；命令输出 | 通过（切片完成；启动/退出和跨层切片待后续） | Codex |
| 2026-09-02 | 阶段 2 启动/退出资源收敛切片 Step 0 与准入 | 固定启动首轮只读状态发现、shutdown 单入口关闭、逐条 bootout 继续清理和状态复核；`CoreOwner.shutdown` upstream impact 为 CRITICAL，已限定修改边界 | [启动/退出切片 Step 0](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-step0-20260902.md)；[启动/退出切片独立准入复核](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-review-20260902.md) | 通过（达到待实施标准；尚未实现） | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 启动/退出资源收敛切片实施 | 启动首轮无面板状态发现、snapshot 失败无副作用、shutdown 单入口、单条 bootout 失败后继续清理和成功状态复核已实现；专项 7/7、Swift 125/125、Rust 53+1 回归通过 | [启动/退出切片实施证据](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-implementation-20260902.md)；`rust/tunnelpad-core/src/owner.rs`；`Tests/TunnelPadCoreTests/StabilityStage2Tests.swift` | 通过（切片完成；跨层切片随后单独完成） | Codex |
| 2026-09-02 | 阶段 2 跨层状态一致性切片实施 | 统一状态读代次与生命周期失效代次；快照应用保留 busy 状态；健康探针结果通过同一门禁后才更新 UI/恢复状态；专项 11/11、Swift 129/129、Rust 53+1 回归通过 | [跨层一致性切片实施证据](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-implementation-20260902.md)；`Sources/TunnelPadCore/TunnelManager.swift`；`Tests/TunnelPadCoreTests/StabilityStage2Tests.swift` | 通过（切片实现完成；阶段 2 后续切片已补齐） | Codex |
| 2026-09-02 | 阶段 2 配置重载资源收敛切片实施 | Rust owner 配置重载先校验候选，再对删除 label 执行停止/状态复核；失败保留旧 owner 配置；新增隧道不自动启动，同 ID 参数不自动重启；CfgR-1–CfgR-9、Rust 62+1 和 Swift 129 回归通过 | [配置重载切片实施证据](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-implementation-20260902.md)；`rust/tunnelpad-core/src/owner.rs` | 通过（切片完成；阶段 2 后续切片已补齐） | Codex |
| 2026-09-02 | 阶段 2 配置重载资源收敛切片独立完成复核 | 独立核对候选校验、删除 label 停止/复核/提交顺序、同 ID 参数兼容语义、CfgR-1–CfgR-9、Rust 62+1、Swift 129、治理和 App 冒烟边界 | [配置重载切片独立完成复核](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-completion-review-20260902.md)；`plan-governance-cli check . --strict-readiness`；`git diff --check`；GitNexus `detect_changes()` | 通过（仅关闭该切片；阶段 2 整体仍在实施） | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 跨层状态一致性切片独立完成复核 | 独立核对 C1–C3/C7 迟到结果反证、busy 状态保护、配置/删除/退出失效边界、非目标范围、专项与全量回归、治理和 GitNexus 变更范围 | [跨层一致性切片独立完成复核](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-completion-review-20260902.md)；`plan-governance-cli check . --strict-readiness`；`git diff --check`；GitNexus `detect_changes()` | 通过（仅关闭该切片） | Codex（独立只读复核） |

| 2026-09-02 | 阶段 2 真实 App 受控验收 | 关闭旧版 App，重新构建并启动当前 `dist/TunnelPad.app`；启动状态发现未猜测性拉起 `not_loaded` 隧道；最新 App 正常退出后进程和两个受管 label 均无残留；未启动或故障注入真实 SSH 隧道 | [阶段 2 真实 App 受控验收](../data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md)；XcodeBuildMCP stop/launch 输出；`scripts/build_app.sh --skip-tests`；`codesign --verify --deep --strict` | 通过（无运行中隧道子场景；阶段 2 整体仍在实施） | Codex |
| 2026-09-02 | 阶段 2 真实运行中隧道与 App 崩溃恢复验收 | 真实 ECS/IP 只读前置成功；`admin-tunnel` 启动后 HTTP `401` 探针通过；受控 `SIGTERM` 后 `launchd` 从 PID `10260` 重拉起 PID `10320`；真实 `bootout` 后 label/端口/PID 收敛；App `SIGKILL` 后隧道 PID `10411` 保持不变，重启 App 能发现原 label，正常退出后两个受管 label 均为 `not_loaded` | [真实 App 受控验收追加记录](../data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md#追加验收真实运行中受管隧道与-app-崩溃恢复)；`scripts/update-ecs-ssh-ip --check`；XcodeBuildMCP stop/launch 输出；真实 `launchctl`/`curl`/SSH 日志 | 通过（当前 `launchd`/App 运行生命周期场景；ECS 自动恢复业务闭环见下一条记录） | Codex |
| 2026-09-02 | 阶段 2 真实探针假死与 ECS 自动恢复验收 | 对真实 `admin-tunnel` SSH PID `15035` 做身份校验后发送 `SIGSTOP`，探针失败累计 3 次；健康协调器执行 `stop → ECSPreStartChecker.checkAsync → start`，脚本日志出现 `mode=sync` 与 `already_current`，新 PID `15710` 恢复并返回 HTTP `401`；清理后 App、label、PID 和端口均无残留 | [真实 App 受控验收追加记录](../data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md#追加验收http-探针假死触发-ecs-自动恢复)；`$HOME/.config/tunnelpad/ecs-ssh-ip.log`；真实 `launchctl`/`curl`/SSH 日志 | 通过（ECS 自动恢复真实业务闭环；阶段 2 总体复核见下一条） | Codex |
| 2026-09-02 | 阶段 2 总体独立完成复核 | 四个稳定性切片、真实 App/launchd 生命周期、探针假死触发 ECS 自动恢复、Swift/Rust 回归、ECS 只读前置、签名、治理和环境清理均独立核对通过 | [阶段 2 总体独立完成复核](../data-quality/tunnelpad-stability-stage2-independent-completion-review-20260902.md) | 通过（阶段 2 已完成；阶段 3 保持设计中） | Codex（独立只读复核） |
| 2026-09-02 | 阶段 3 Step 0 与独立准入 | 固定隔离 demo、受控应用、Release 产物和治理门禁样本矩阵；阶段 2 真实业务证据不再重复故障注入；当前工作树回归、demo、Release 签名和真实 App 启动/退出均通过 | [阶段 3 Step 0 证据](../data-quality/tunnelpad-stability-stage3-step0-20260902.md)；[阶段 3 独立准入复核](../data-quality/tunnelpad-stability-stage3-independent-review-20260902.md) | 通过（达到待实施标准） | Codex（独立只读复核） |
| 2026-09-02 | 阶段 3 最终门禁与独立完成复核 | 隔离 demo 3/3、Swift 129/129、Rust 62+1、Release 构建/签名、真实 App 启动/退出、资源清理和治理门禁均通过 | [阶段 3 独立完成复核](../data-quality/tunnelpad-stability-stage3-independent-completion-review-20260902.md) | 通过（阶段 3 已完成；稳定性计划整体已完成） | Codex（独立只读复核） |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代独立准入复核。

### Attestation 说明

本计划完成快照沿用 `docs/attestations/<plan>.json` 兼容格式。阶段 0–3 已完成并保留独立复核；如需要机器可验证的完成快照，使用治理 CLI 生成并保留独立复核状态。

### 验证方式

阶段 0 使用只读源码核对、功能图谱影响分析、隔离最小复现、配置异常 fixture、现有 `launchd` keepAlive 回归测试、失败序列状态机 fixture 和治理检查。阶段 1–2 使用注入式 fake `launchd` 验证停止/重启失败分类、退出清理和配置提交边界，并在用户授权窗口完成真实 App/launchd 生命周期和 ECS 恢复闭环验收；阶段 3 在隔离 demo 和受控应用冒烟中验证发布产物、资源边界和最终治理门禁。app 执行器留待未来计划。

完成全计划时至少运行并记录：

- `swift test`；若 Rust Core 迁移后的事实源适用，则同时运行 `cargo test` 和迁移差分测试。
- 稳定性专项测试，覆盖单次失败、连续三次失败、成功清零、退避四级、第 10 次熔断、`launchd` 状态收敛、手动恢复、手动停止、删除、退出和窗口隐藏。
- 配置/生命周期一致性专项测试，覆盖配置损坏或半写入、`launchd` `bootout` 错误、正常退出与信号退出资源发现，以及 `launchd` 自动恢复配置代次；app pidfile 和自动重启留待未来计划。
- ECS 动态 SSH 变化专项测试，覆盖运行中公网 IPv4 变化、规则已是最新、规则同步失败、双端点不一致、SSH 断线后自动重连和手动恢复；验证自动重连不会绕过来源确认或无限重试旧来源。
- 隔离 demo 应用冒烟，确认 `launchd` 的重启/停止状态、日志和 UI 展示一致，且其他隧道不受影响。
- `git diff --check`、`plan-governance-cli check .`、`plan-governance-cli check . --strict-readiness`，以及提交前 GitNexus `detect_changes()`。

### 测试覆盖率

当前没有为本计划新增覆盖率证据。完成阶段 1–2 后以专项测试矩阵和 `swift test`/`cargo test` 输出记录关键状态机、执行器分支、取消代次和回滚边界；若项目引入行覆盖率工具，再补充百分比和关键模块覆盖情况，不以全量测试通过替代状态机分支覆盖。

### 阶段 1 完成条件

- 当前执行器 `launchd` 范围内的后台监测、单隧道健康恢复状态机、配置 fail-closed 和 Rust `bootout` fail-closed 已接入生产协调路径。
- 连续 3 次失败、10/30/60/300 秒固定退避、最多 10 次恢复、第 10 次失败停止当前隧道并保留只读监测、成功清零和人工 start/restart 重置均有生产路径隔离证据。
- `keepAlive=false`、手动停止、删除、恢复并发、代次/取消、弱引用监测生命周期和单隧道隔离均有反证或代码核对；不引入新的配置字段，不操作真实隧道、SSH、ECS 或 `launchctl`。
- 配置无效候选不会替换当前有效配置；Rust `bootout` 非“未加载”错误会阻断后续 bootstrap；阶段 1 的专项、全量回归、治理检查和独立完成复核通过。
- 启动/退出收敛、ECS 运行时同步和跨层状态一致性明确列为阶段 2，不作为阶段 1 完成前置。

### 完成条件

- 阶段 0 Step 0 现状快照和假死最小复现已落盘，且不操作真实用户隧道。
- 阶段 1–2 的状态机、后台监测、`launchd` 接入、取消和代次保护测试通过；app 执行器不在当前验收范围。
- 连续 3 次失败、固定退避、最多 10 次、第 10 次停止并取消当前隧道任务、手动恢复和成功清零均有可复现证据。
- `keepAlive=false`、手动停止、删除、退出和其他隧道隔离边界均有反证测试。
- `launchd` 崩溃/退出后的状态重新收敛有证据，且不依赖 app pidfile；app pidfile 收敛留待未来计划。
- 配置损坏/半写入不会无提示清空当前有效运行配置；当前 `launchd` 重启失败不会提交或报告不一致状态；未来 app 执行器切换语义留待独立计划；正常退出、信号退出和启动收敛的资源发现与结果分类有回归证据。
- `launchd` 自动恢复的配置快照/代次语义已冻结，旧任务不能回写过期状态。
- 运行中公网 IPv4 变化的发现触发、ECS 规则同步 owner、自动重连前置、同步失败的 fail-closed 和与退避/熔断的交互均已冻结并有可复现证据。
- 隔离 demo 与受控应用验收通过，未产生计划外 Schema、真实隧道或敏感数据变化。
- 最新独立准入/完成复核明确通过，`PLAN_MAP.md`、阶段证据、测试证据和状态同步。
- 治理普通检查和严格准入检查通过；提交前 `detect_changes()` 只报告本计划预期影响。

## 当前阶段

### 范围

当前阶段已结束，计划状态为已完成。阶段 0–3 已完成并关闭；阶段 3 的 Step 0、独立准入和最终发布门禁均已通过；未来 `app` 执行器仍不在本计划范围内。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | [阶段 3 Step 0 证据](../data-quality/tunnelpad-stability-stage3-step0-20260902.md)已固定隔离 demo、Release 产物、受控应用和治理门禁矩阵；阶段 2 的 Step 0 与四个切片证据已完成并仅作为前置引用 |
| 样本矩阵 | 已登记：Rust/Swift 回归、Release 构建与签名、隔离 `demo-*` 生命周期、当前 `launchd` 受控 App 启动/退出、资源清理和治理反向引用；不重复注入真实用户隧道 |
| 验证方式 | 阶段 3 采用当前工作树回归、隔离 demo、Release 包校验和受控 App 冒烟；阶段 2 的真实 ECS/launchd 闭环只引用已完成的独立验收证据 |
| 失败/回滚边界 | 隔离 demo 只能使用虚构 ID 和临时路径；Release 或 App 门禁失败时不触碰真实配置/日志/label/ECS，只回滚阶段 3 产物或文档 |
| 当前阻塞项 | 无；阶段 3 最终发布门禁已通过，未来 `app` 进程语义仍是非目标 |
| 最新独立准入复核 | [阶段 3 独立准入复核](../data-quality/tunnelpad-stability-stage3-independent-review-20260902.md)已通过，阶段 3 达到待实施标准 |

### 阶段 3 Step 0

阶段 3 Step 0 已固定隔离 demo、Release 产物、受控 App 和治理门禁的输入、命令、预期、失败判定与回滚边界，证据见[阶段 3 Step 0](../data-quality/tunnelpad-stability-stage3-step0-20260902.md)。本 Step 0 不代表阶段 3 已达到待实施标准。

## 阶段 2 收尾摘要

### 阶段 2 Step 0

阶段 2 Step 0 采用“架构探索基线 + 缺陷安全边界”类型，已固定当前后台探针、ECS 前置适配器、`launchd KeepAlive` 直启路径、Rust 生命周期 owner 和退出清理路径；同时记录用户确认的 ECS 触发方案以及经评估冻结的 bootout-first 阻断顺序。证据见[阶段 2 Step 0 基线](../data-quality/tunnelpad-stability-stage2-step0-20260902.md)。

阶段 2 的 ECS 自动恢复、启动/退出资源收敛、跨层状态一致性和配置重载资源收敛切片均已完成自己的 Step 0、独立准入、实现和独立完成复核，不能互相替代。真实 `admin-tunnel` 的运行中 bootout、KeepAlive 重拉起、App 崩溃后重启发现、正常退出清理和探针假死触发 ECS 自动恢复已追加验收；阶段 2 总体独立完成复核已通过，本次真实环境限制和证据见[真实 App 受控验收](../data-quality/tunnelpad-stability-stage2-real-app-acceptance-20260902.md)。

### 阶段 2 配置重载资源收敛切片

该切片已完成 Step 0、独立准入、实现和独立完成复核。切片固定保留现有“同 ID 参数修改只保存、下次显式重启生效”的语义；外部刷新删除隧道时，必须先逐条停止并复核待删除的旧 `launchd` label，全部达到 `notLoaded` 后才替换 Rust owner 配置，任一失败则保留旧配置。详细边界见[切片 Step 0](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-step0-20260902.md)、[独立准入复核](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-review-20260902.md)、[实施证据](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-implementation-20260902.md)和[独立完成复核](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-completion-review-20260902.md)。

### 阶段 2 启动/退出资源收敛切片

该切片已完成 Step 0、独立准入、实现、专项验证和独立完成复核。启动后通过现有后台协调器读取配置内 `launchd` 状态；退出时由同一 Rust owner 逐条尝试并复核 `bootout`，单条失败不截断其他隧道，且 shutdown 只允许单入口执行。详细边界见[切片 Step 0](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-step0-20260902.md)、[独立准入复核](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-review-20260902.md)、[实施证据](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-implementation-20260902.md)和[独立完成复核](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-completion-review-20260902.md)。

### 阶段 2 跨层状态一致性切片

该切片已完成 Step 0、独立准入、实现、专项验证和独立完成复核。实现让异步 Rust 快照、健康探针和恢复结果在手动启停、配置变化、删除和退出后接受统一的结果门禁，保留 busy 状态，禁止旧结果倒灌 UI 或推进恢复状态。详细边界见[切片 Step 0](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-step0-20260902.md)、[独立准入复核](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-review-20260902.md)、[实施证据](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-implementation-20260902.md)和[独立完成复核](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-completion-review-20260902.md)。

## 阶段 1 收尾

### 阶段 1 完成摘要

| 字段 | 内容 |
|---|---|
| 完成状态 | 已完成；只关闭阶段 1，不改变阶段 2 已完成、阶段 3 设计中的状态 |
| 完成范围 | `launchd` 后台健康监测、固定恢复状态机、配置 fail-closed、操作/恢复代次与取消保护、手动 stop/start/restart 语义、删除迟到任务保护，以及 Rust `bootout` fail-closed |
| 固定策略 | 连续 3 次失败触发恢复；退避 10/30/60/300 秒封顶；最多 10 次；第 10 次失败停止当前隧道并保留只读监测；成功或人工 start/restart 清零 |
| 隔离验证 | 阶段 1 专项 9/9；最终全量 Swift/Rust、治理检查、空白检查和变更范围检查见[阶段 1 独立完成复核](../data-quality/tunnelpad-stability-stage1-independent-completion-review-20260902.md) |
| 明确留待阶段 2 | 启动/退出收敛、ECS 运行中同步和跨层状态一致性；不把这些未实现项计入阶段 1 缺口 |

### 阶段 1 Step 0

阶段 1 的 Step 0 证据见[阶段 1 Step 0 证据](../data-quality/tunnelpad-stability-stage1-step0-20260902.md)，记录了生产实现前基线、`TunnelManager`/`TunnelRuntimeState`/`RustLifecycleOwner`/`ProbeCoordinator` 的 upstream impact、共享编辑边界，以及 fake `launchd`、fake 探针、隔离配置和 ECS 双端点矩阵。它是阶段 1 的历史准入证据，不替代阶段 2 自己的 Step 0。

阶段 1 已完成 Step 0、独立准入、生产实现和独立完成复核；详细实施结果见[阶段 1 实施证据](../data-quality/tunnelpad-stability-stage1-implementation-20260902.md)。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-02 |
| 阶段 | 阶段 3 |
| 结论 | 通过（达到“待实施标准”） |
| 证据 | [阶段 3 Step 0](../data-quality/tunnelpad-stability-stage3-step0-20260902.md)；[阶段 3 独立准入复核](../data-quality/tunnelpad-stability-stage3-independent-review-20260902.md)；阶段 2 总体独立完成复核已通过 |
| 复核者 | Codex（独立只读复核） |

## 最新独立完成复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-02 |
| 阶段 | 阶段 3 |
| 结论 | 通过（阶段 3 已完成；稳定性计划整体已完成） |
| 证据 | [阶段 3 独立完成复核](../data-quality/tunnelpad-stability-stage3-independent-completion-review-20260902.md)；隔离 demo、Release 产物、受控 App、阶段 2 前置、Swift/Rust、治理和环境清理通过 |
| 复核者 | Codex（独立只读复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-01 | 阶段准入复核 | 阶段 0 | 未通过（未达到待实施标准） | [上一轮独立准入复核](../data-quality/tunnelpad-stability-stage0-independent-review-20260901.md)；健康恢复状态机、配置/操作代次与取消、ECS 运行中同步 fixture 尚未执行 | Codex（独立只读复核） |
| 2026-09-01 | 阶段准入复核 | 阶段 0 | 通过（达到“待实施标准”） | [契约 fixture 独立准入复核](../data-quality/tunnelpad-stability-stage0-independent-review-contract-fixtures-20260901.md)；阶段 0 目标/范围、12 行矩阵、6 项契约 fixture、验证/回滚边界和共享影响复核均通过 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 1 | 未通过（未达到“待实施标准”） | [阶段 1 独立准入复核](../data-quality/tunnelpad-stability-stage1-independent-review-20260902.md)；复核时 `PLAN_MAP` 尚未登记阶段 1 证据，且计划将生产接入测试列为当前阻塞项；两项已整改，待重新复核 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 1 | 通过（达到“待实施标准”） | [阶段 1 独立准入复核（r2）](../data-quality/tunnelpad-stability-stage1-independent-review-20260902-r2.md)；Step 0、8 行矩阵、影响复核、验证/回滚边界、共享日志边界和当前准入状态均通过 | Codex（独立只读复核） |
| 2026-09-02 | 阶段完成复核 | 阶段 1 | 通过（已完成） | [阶段 1 独立完成复核](../data-quality/tunnelpad-stability-stage1-independent-completion-review-20260902.md)；完成边界、9/9 专项、118/118 Swift、Rust 51+1、治理和变更范围均通过；阶段 2 保持设计中 | Codex（独立只读复核） |
| 2026-09-02 | 切片完成复核 | 阶段 2 | 通过（启动/退出资源收敛切片已完成） | [启动/退出资源收敛切片独立完成复核](../data-quality/tunnelpad-stability-stage2-lifecycle-reconciliation-independent-completion-review-20260902.md)；当前代码、启动/退出失败注入、专项与全量回归、治理和变更范围独立核对通过；阶段 2 整体仍保留跨层一致性后续切片 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 2 | 通过（达到“待实施标准”） | [ECS 自动恢复切片独立准入复核](../data-quality/tunnelpad-stability-stage2-ecs-recovery-independent-review-20260902.md)；本结论仅覆盖 bootout-first、`notLoaded` 门禁、ECS fail-closed、影响分析、验证/回滚边界，后续阶段 2 切片不在范围内 | Codex（独立只读复核） |
| 2026-09-02 | 切片完成复核 | 阶段 2 | 通过（跨层状态一致性切片已完成） | [跨层状态一致性切片独立完成复核](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-completion-review-20260902.md)；当前代码、C1–C3/C7 迟到结果反证、busy 状态保护、专项与全量回归、治理和变更范围独立核对通过；阶段 2 整体仍保留真实受控应用和后续配置/执行器边界 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 2 | 通过（达到“待实施标准”） | [跨层状态一致性切片独立准入复核](../data-quality/tunnelpad-stability-stage2-cross-layer-consistency-independent-review-20260902.md)；本结论仅覆盖异步快照/探针结果门禁、busy 状态保护、迟到结果失效和 C1–C8 验证边界；后续已由该切片实施证据和独立完成复核闭环 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 2 | 通过（达到“待实施标准”） | [配置重载资源收敛切片独立准入复核](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-review-20260902.md)；本结论仅覆盖候选校验、删除 label 的停止/复核/提交顺序、同 ID 参数修改兼容语义和 CfgR-1–CfgR-9 验证边界 | Codex（独立只读复核） |
| 2026-09-02 | 切片完成复核 | 阶段 2 | 通过（配置重载资源收敛切片已完成） | [配置重载资源收敛切片独立完成复核](../data-quality/tunnelpad-stability-stage2-config-reload-reconciliation-independent-completion-review-20260902.md)；候选失败保留旧 owner 配置、删除 label 先停止/复核、同 ID 参数不自动重启；CfgR-1–CfgR-9、Rust 62+1、Swift 129、治理和 App 冒烟边界均通过 | Codex（独立只读复核） |
| 2026-09-02 | 阶段完成复核 | 阶段 2 | 通过（已完成） | [阶段 2 总体独立完成复核](../data-quality/tunnelpad-stability-stage2-independent-completion-review-20260902.md)；四个切片、真实 App/launchd 生命周期、真实探针假死触发 ECS 自动恢复、Swift/Rust、治理和环境清理均通过；阶段 3 保持设计中 | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 3 | 通过（达到“待实施标准”） | [阶段 3 独立准入复核](../data-quality/tunnelpad-stability-stage3-independent-review-20260902.md)；Step 0、隔离 demo/Release/App/治理矩阵、验证/回滚边界和阶段 2 前置均通过 | Codex（独立只读复核） |
| 2026-09-02 | 阶段完成复核 | 阶段 3 | 通过（已完成） | [阶段 3 独立完成复核](../data-quality/tunnelpad-stability-stage3-independent-completion-review-20260902.md)；隔离 demo 3/3、Release 构建/签名、受控 App 启动/退出、Swift/Rust、治理和环境清理均通过 | Codex（独立只读复核） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 稳定性计划后续范围 | 阶段 0–3 已完成并关闭；未来 `app` 执行器、pidfile 身份校验和孤儿进程收敛另立计划 | 否 | 稳定性计划已关闭 |

## 风险和回滚

- HTTP 探针可能代表的是目标业务服务，而不是 SSH 链路本身；错误 URL、鉴权策略变化或远端服务停机可能触发恢复。通过只支持现有 HTTP 探针、要求期望状态码显式配置、连续失败阈值和最多 10 次熔断降低误判。
- launchd 自身也有 `KeepAlive` 和节流语义；健康恢复若绕过 Rust `launchd` lifecycle coordinator，可能与手动停止发生竞态。所有恢复必须通过统一生命周期边界，并以 generation/取消令牌阻止迟到任务。
- 退避或计数状态若按全局维护，可能把一条隧道的故障传播到其他隧道。状态必须按 tunnel id 隔离，并用多隧道 fixture 反证。
- PID 可能被系统复用；启动收敛不得仅凭 pidfile 中的整数发送信号，必须先做进程身份校验，无法确认时保守告警并保留人工处理。
- 当前阶段不处理 app 子进程；未来 app 计划必须重新定义其安全停止语义。
- 外部编辑器可能在保存期间产生短暂半写入；配置刷新必须采用 fail-closed 语义，避免用一次解析失败替换当前有效运行配置或裁剪托管状态。
- 当前配置仅支持 `launchd`，不存在本阶段可执行的执行器切换；未来 app 执行器计划仍需冻结旧实例停止结果、提交顺序和失败回滚。启动/退出切片已为当前 `launchd` 退出清理补充逐条失败分类和状态复查。
- 自动重启若读取旧快照会继续使用用户已修改前的命令；若直接读取新配置又可能绕过操作代次。两种语义必须先冻结，再实现。
- 正常退出、信号退出和启动收敛若各自维护资源发现逻辑，修复一条路径可能使另外两条路径继续残留；启动/退出切片已让正常退出和信号退出共享同一 Rust owner，真实 `admin-tunnel` 的运行中 bootout、App 崩溃后隧道保持和重启发现已通过单条真实场景验收，多隧道异常组合仍以隔离 fixture 为准。
- Rust Core 阶段 5 已完成，共享 owner 的阶段 1 upstream impact 已登记；阶段 1 已接入 Swift 侧协调路径，并已将 Rust `bootout` 非预期失败改为 fail-closed；阶段 2 的四个当前切片、无运行中受管隧道的真实 App 验收、单条运行中 `admin-tunnel` 的真实 App/launchd 生命周期验收、探针假死触发 ECS 自动恢复验收和阶段 2 总体独立完成复核均已完成，当前仅保留阶段 3 门禁和后续执行器边界。
- 日志事件流计划阶段 0–3 已完成；稳定性计划阶段 0–1、阶段 2 四个当前切片、无运行中受管隧道的真实 App 验收、单条运行中 `admin-tunnel` 真实生命周期验收和探针假死触发 ECS 自动恢复验收已完成。后续若修改 `TunnelManager`、`TunnelRuntimeState`、主面板或共享测试目录，可能产生行为互相覆盖；必须保留单一编辑窗口并按 `PLAN_MAP.md` 串行合入。
- 若实现导致误重启、状态倒灌或无法可靠熔断，按阶段独立提交回滚稳定性实现，保留 `config.json` 和既有 TunnelPad v1 运行契约；不得用配置重写或删除真实 plist 作为回滚手段。
- 任何真实用户隧道验收只允许在用户明确指定、可观察、可恢复的窗口内进行；发现 stop/bootout、删除或退出清理异常时立即停止该场景并保留配置。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad v1 隧道管理应用](tunnelpad-v1.md)
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)
- [v1 阶段 2 功能与验收记录](../data-quality/tunnelpad-v1-stage2-features-20260829.md)
- 当前仓库暂无与本计划对应的 ADR 或 migration 文件；若实施中产生持久架构决策或兼容迁移，先补充对应文档，再更新本节。
