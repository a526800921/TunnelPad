# TunnelPad 无人值守阶段 1 评审整改证据（2026-09-19）

## 结论与治理边界

- 整改基线：`2271e06f71b6a9b2235651ba27fab8c26a958d97` 之后的当前工作树。
- 既有独立结论：[无人值守端到端风险复核](../reviews/tunnelpad-unattended-end-to-end-review-20260919.md)与[合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)首轮“不通过”均是有效历史，不修改、不覆盖。三项 P1 和一项 P2 已由实施者按“发现 → 修复 → 验证”完成修复自验；同一复核者后续返回的 `READY` 仅保留为补充只读核对，不作为第二次独立门禁。
- 本记录性质：实施者对既有发现的正式修复自验与验证证据。阶段 1 代码门禁已经解除，但本记录不替代阶段 2 真实验收。
- 用户要求避免重复独立复核并按风险分流执行：普通整改与机械门禁由实施者自验；全部高影响修复和证据收口后，只对合并后的生命周期/云端前置边界做一次独立复核。两个专项计划在该门禁及阶段 2 真实验收前继续保持“实施中”。
- 本轮未启动或停止真实 TunnelPad App/隧道，未修改 ECS 安全组，隔离打包没有覆盖 `dist/TunnelPad.app`。

## 既有 R1–R15 整改对照

| 发现 | 当前整改 | 直接证据 | 状态 |
|---|---|---|---|
| R1 每次 SSH spawn 未统一经过恢复 owner | 无人值守 `autoStart + keepAlive` SSH 的 launchd plist 不再启用 `KeepAlive`；断线由 App 的单一恢复链收敛旧作业、执行 ECS 检查/同步后再启动 | `LaunchdPlistRendererTests.testUnattendedSSHDisablesLaunchdKeepAliveForSingleRecoveryOwner`；Rust `plist_render::tests::unattended_ssh_disables_launchd_keep_alive` | 已实现并自验 |
| R2 明确断线事件可能被三次合成探针输入吞掉 | `HealthRecoveryState.confirmedFailure` 将一次明确断线作为一次独立状态转换；恢复触发不再用三次覆盖式 `record` 凑阈值 | `StabilityStage1Tests.testConfirmedFailureSchedulesOnceAndNeverExhaustsPermanentRecovery`；`IPDriftRecoveryTests.testLaunchdPIDChangeUsesImmediateRecoveryAndSameCleanupChain` | 已实现并自验 |
| R3 稳定代理 PID 被当成连接恢复 | PID 仅作为观察值；有业务探针时只在探针成功后清零，无探针时保留未确认状态并继续监督；失败重试不会因代理 PID 稳定而归零 | `IPDriftRecoveryTests.testLaunchdFailureAfterRestartImmediatelyRunsNextRecovery`、`testAutomaticRecoveryKeepsRetryingPastHistoricalAttemptLimit` | 已实现并自验 |
| R4 loaded/notRunning 作业只观察不修复 | 启动恢复对可信受管的 loaded/notRunning 作业先受管停止，再执行前置并启动；旧 `KeepAlive` plist 在启动期迁移到单 owner 形状 | `LaunchRecoveryIntegrationTests.testLoadedNotRunningAlwaysStopsBeforePreflightAndStart`、`testRunningUnattendedSSHIsQuiescedToInstallSingleRecoveryOwner` | 已实现并自验 |
| R5 curl 代理出口污染来源 IP | curl 首参数加入 `-q`，并显式使用 `--noproxy '*' --proxy ''` | `Tests/fixtures/update-ecs-ssh-ip/fake-curl`；ECS fixture `current-managed-rule` 等 18 项 | 已实现并自验；VPN/TUN 路由差异仍属于阶段 2 环境验收 |
| R6 规则完整匹配遗漏 `SourcePortRange` | 安全规则规范元组要求空源端口范围，并在只读检查、事务续作及幂等接纳中复用 | Rust `rejects_managed_rule_with_restricted_source_port`；shell fixture `restricted-source-port-rejected` | 已实现并自验 |
| R7 被观测 program 反向扩大可信身份 | 受管身份由配置、plist 路径、完整 `ProgramArguments`、可信可执行文件和进程票据导出；观测值只能被核验，不能扩充授权集合 | `managed_stop_rejects_foreign_launchd_program_before_identity_capture`、`managed_stop_rejects_same_executable_with_unmanaged_arguments`、`managed_stop_rejects_same_executable_from_unmanaged_plist` | 已实现并自验 |
| R8 持续输出掩盖直接子进程退出 | 日志代理独立轮询直接子进程，不再依赖日志接收超时才 `try_wait`；退出后的日志排空有界 | `log_proxy::continuous_descendant_output_cannot_hide_direct_child_exit` | 已实现并自验 |
| R9 停止路径可进入无界 wait | bootout、状态复核、信号升级和代理回收均有界；状态查询超时 fail-closed，不以 PID 消失代替 fresh `notLoaded` | `managed_stop_continues_after_bounded_bootout_timeout`、`managed_stop_fails_closed_when_status_times_out_after_bootout_timeout`、`log_proxy::signal_shutdown_reaps_child` | 已实现并自验 |
| R10 共享代理安装临时文件竞态 | 原子写使用唯一临时文件，不同隧道不再共享可截断路径 | `plist_render::tests::concurrent_atomic_writes_do_not_share_temporary_file` | 已实现并自验 |
| R11 自动恢复绕过共享 ECS 资源协调 | 运行期恢复使用独立的共享前置协调器：同资源等待并复用一个结构化结果，不同资源全局最多两个并发；认证结果按资源冷却 300 秒，脱敏分类与 retry hint 进入持续恢复退避/日志 | `IPDriftRecoveryTests.testConcurrentRuntimeRecoverySharesSingleECSPreflightByResource`、`LaunchRecoveryCoordinatorTests.testRuntimePreflightCoordinatorCapsDifferentResources`、`testRuntimePreflightCoordinatorCachesAuthenticationFailureByResource`、`IPDriftRecoveryTests.testAutomaticRecoveryKeepsRetryingPastHistoricalAttemptLimit` | 已实现并完成修复自验；补充只读核对 PASS |
| R12 pending journal 被只读检查误报为 synchronized | `--check` 遇到有效 pending journal 返回稳定的 `transaction_pending`，App 将其纳入需先同步再重连的恢复原因 | `check-pending-transaction` fixture；`Tests/preflight-supervision-test.py` 的 journal 只读断言 | 已实现并自验 |
| R13 延迟 TERM 被误记为代理失败 | 信号驱动的正常停止与 reader 断开共用有界清理，并保留正常退出分类 | `log_proxy::delayed_signal_shutdown_with_reader_disconnect_is_not_a_proxy_failure` | 已实现并自验 |
| R14 登录项错误提示语义缺少可验证边界 | `toggle()` 在读取最新系统状态后恢复本次 register/unregister 错误，保证当前菜单提示可立即读取；后续显式 `refresh()` 清除已展示错误是保留的实际语义 | `LoginItemControllerTests.testRegistrationFailureSurvivesToggleStatusRefreshForImmediateAlert` | 已实现并完成修复自验；补充只读核对 PASS，旧证据表述已纠正 |
| R15 配置编辑复活手动停止隧道 | 单独维护 `manuallyStoppedIDs`；显示和运行时字段编辑都保留用户停止意图，新加入的自动启动项只在下次 App 启动进入冻结候选 | `IPDriftRecoveryTests.testDisplayEditDoesNotReviveManuallyStoppedTunnel`、`testRuntimeEditDoesNotReviveManuallyStoppedTunnel`、`testRuntimeAddedAutoStartTunnelWaitsUntilNextAppLaunch` | 已实现并自验 |

## 实施期间追加的生命周期闭环

| 缺口 | 整改 | 证据 |
|---|---|---|
| reload/remove/shutdown 可能绕过 SSH 精确身份停止 | `CoreOwner` 的 reload、save、stop、restart、remove、shutdown 统一走 `stop_tunnel_checked`；SSH 必须走受管身份停止 | `reload_remove_and_shutdown_use_managed_identity_stop_for_ssh` |
| 运行时命令更新先丢失旧身份 | 配置提交前比较已安装 launchd 身份并先用旧配置停止；失败时保留旧 owner 配置 | `reload_config_stops_changed_runtime_before_commit`、`save_config_stops_old_ssh_identity_before_committing_runtime_change` |
| bootout 后状态超时可能继续发信号或宣告成功 | 任一 fresh 状态错误均 fail-closed；仅 fresh `notLoaded` 构成收敛成功 | `managed_stop_fails_closed_when_status_times_out_after_bootout_timeout` |
| TERM trap 新派生同 PGID 后代可能逃逸一次性快照 | 每次 TERM/KILL 和每轮收敛检查都重新枚举完整受管进程组 | `log_proxy::term_trap_spawned_descendant_is_reenumerated_and_cleaned` |
| App/信号退出在清理失败后仍结束 | App 退出等待 Rust shutdown；失败时拒绝终止并恢复监督。SIGTERM/SIGINT 清理失败后持续限频重试，成功才退出 | `IPDriftRecoveryTests.testFailedShutdownKeepsAppAliveAndResumesUnattendedMonitoring`；`ShutdownTests.testOwnerHandleKeepsCleanupFailureDistinctFromZeroStopped`；Rust `shutdown_failure_allows_retry_of_unconverged_services` |
| 并发配置操作可交错旧身份停止、磁盘提交和 owner 更新 | `CoreOwner.config_transaction` 覆盖 load/save/remove/shutdown 完整事务；内部只按“事务锁 → 稳定顺序 tunnel 锁”取锁 | Rust `config_transaction_serializes_load_behind_in_flight_save`、`config_transaction_serializes_concurrent_saves_across_tunnels`、`config_transaction_serializes_remove_behind_in_flight_save` |
| 清理期间重复退出请求可绕过首次 `.terminateLater` | `ApplicationTerminationGate` 将清理中重复请求保持为 `.terminateLater`；成功后才允许 `.terminateNow`，失败回到可重试状态 | `AppDelegateTerminationTests.testRepeatedTerminationWaitsForSingleCleanup`、`testFailedCleanupAllowsOneFreshRetry` |

## 当前验证结果

| 验证 | 结果 |
|---|---|
| `xcodebuildmcp swift-package test --package-path ...` | 196/196 通过 |
| `cargo fmt --all --check && cargo test --all-targets` | 111/111 通过：Rust lib 97、preflight 6、differential 1、log proxy 7 |
| `bash Tests/update-ecs-ssh-ip-test.sh` | 18/18 fixture 通过 |
| `python3 Tests/preflight-supervision-test.py` | 9/9 通过 |
| Swift Release 构建 | `tunnelpad` target 构建通过 |
| Rust Release 构建 | 通过 |
| 隔离 App 打包 | `/tmp/tunnelpad-stage1-package.R1ot6G/TunnelPad.app` 生成，`plutil` 与 `codesign --verify --deep --strict` 通过；未启动、未覆盖 `dist` |
| GitNexus 索引与变更检查 | 索引刷新成功（6,799 nodes、19,921 edges、560 flows）；最终暂存集的结构化 `detect_changes(scope=staged)` 报告 33 files、505 symbols、336 affected processes、`critical`，`partial=false`、`truncated=false`。索引器另提示全局流程枚举为下界，已用源码、文本搜索和直接测试补核高影响边界 |
| `git diff --check` | 通过 |
| 敏感内容差异扫描 | 未发现 AccessKey Secret、私钥头或常见硬编码凭据形状 |
| `plan-governance-cli check .` | 通过；历史独立失败已由追加式“修复自验”闭环，阶段 2 明确保留为后续阶段门禁 |

## 门禁状态与剩余边界

1. 实施者已对独立发现完成修复自验，四项原发现均有直接回归且受影响全量验证通过；阶段 1 合并代码门禁已经解除。同一复核者的后续只读结果仅作补充证据，不再发起重复独立复核。
2. 阶段 2 仍缺真实登录/重启、真实或等价出口变化、18080 远端释放、孤儿身份扫描和长时间无人值守资源观察。
3. 当前证据证明代码路径、隔离故障矩阵和产物可构建，不证明所有真实网络、VPN/TUN 分流或阿里云外部状态均已验收。
