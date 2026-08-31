# TunnelPad Rust Core 迁移阶段 5 Step 0 基线

- 日期：2026-08-30
- 阶段：阶段 5
- 类型：行为迁移与真实 `launchd` 受控基线
- 结论：Step 0、阶段 5 实施、删除后回归、最终反向引用审计和独立收尾复核均已完成
- 关联计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)

## 当前配置基线

通过本机 `~/Library/Application Support/TunnelPad/config.json` 的非敏感字段核对：

| 隧道 | 执行器 | keepAlive | HTTP 探针 | 当前状态 |
|---|---|---:|---|---|
| `admin-tunnel` | `launchd` | true | 已配置，期望状态 `200,401` | running |
| `reverse-ssh` | `launchd` | true | 未配置 | running |

当前 `app` 配置条目数为 `0`。两条隧道均存在生成的 launchd plist；当前没有 app pidfile 残留。

## 受控真实验证

验证对象仅为 `admin-tunnel`，已获得用户明确授权；`reverse-ssh` 未执行启停操作。

| 步骤 | 结果 |
|---|---|
| 记录初始状态 | `admin-tunnel` running，旧 PID 为 `23904`；`reverse-ssh` running，PID 为 `23915` |
| 对目标执行 bootout | 成功；目标进入 not-loaded |
| 检查旧进程 | PID `23904` 已不再存活 |
| 对目标执行 bootstrap | 成功；目标恢复 running |
| 检查新进程 | 新 PID 为 `97472`，进程仍存活 |
| 检查非目标隧道 | `reverse-ssh` 仍为 running，PID 未变化 |
| HTTP 探针 | 返回 `000`，错误类型为连接失败/拒绝；尚未分类为 Rust 迁移可接受的已知基线 |

本次历史闭环证明了当前 Swift launchd 路径可以完成一次受控停止和重启；Rust owner 的直接验证见下节。该历史探针结果为连接失败，不能覆盖后续 Rust owner 验证中返回的配置期望状态 `401`。

## owner 原型、生产适配与 Release 验证（2026-08-30）

已完成 Rust owner 原型，并接入 Swift `TunnelManager` 的生产初始化路径，验证阶段 5 的
opaque handle、UTF-8 JSON 命令、配置 owner、launchd 生命周期和并发边界：

- Rust owner 实现：[owner.rs](../../rust/tunnelpad-core/src/owner.rs)；C ABI 扩展：[owner_ffi.rs](../../rust/tunnelpad-core/src/owner_ffi.rs)；头文件声明：[tunnelpad_core.h](../../rust/include/tunnelpad_core.h)。
- 原型函数为 `tp_core_abi_version`、`tp_core_create`、`tp_core_command`、`tp_core_shutdown`、`tp_core_destroy` 和 `tp_core_last_error`；旧 `tp_*` ABI v1 未改变。
- `cargo test --manifest-path rust/Cargo.toml`：51 个 Rust 单测 + 1 个差分测试全部通过；新增 fake `launchd` owner 矩阵覆盖 status、start、stop、restart、remove、shutdown 的成功序列、未加载语义、命令失败和 spawn 失败，以及 generation 失配前置拒绝、取消即时失效、正在运行子进程终止和 restart bootstrap 取消。
- `./rust/scripts/smoke.sh`：Rust release 构建、上述测试、Swift C ABI smoke、arm64 产物和 ad-hoc 签名校验全部通过；Swift smoke 覆盖 owner 创建、空配置 snapshot、shutdown 和释放断言。
- `swift test`：80/80 通过；新增 `RustCoreClientTests` 3 项，覆盖真实 release dylib 的 snapshot、shutdown 后 owner closed、`app` 配置 fail-closed 和取消 generation 后不触发 launchd。
- `./scripts/build_app.sh`：Rust release、Swift 测试、Swift release、动态库复制、`@rpath`、ad-hoc 签名和 `Info.plist` 校验全部通过。
- Rust shutdown 已修复：未加载的 launchd 服务先由 owner 判定为 `notLoaded`，不再把真实 `launchctl` 的 `No such process` 误报为退出失败。
- 生产退出路径已切换：`TunnelManager` 暴露绑定同一 Rust handle 的 `Shutdown.OwnerHandle`，`AppDelegate` 将其交给 SIGTERM/SIGINT handler；默认无 owner 的工具入口也只创建 Rust owner。旧 Swift 生命周期/app 执行器已从生产代码和差分 fixture 删除，`MigrationService` 使用的 `LaunchCtlExecutor` 仅保留迁移接管兼容路径。
- Rust FFI shutdown 现在返回并校验实际停止数量；Swift manager 关闭路径和信号句柄共用该结果通道。
- fixture 明确验证：version=1 配置读写、`app` 配置拒绝且不自动转换、JSON 生命周期结果、同隧道串行、不同隧道并行，以及 shutdown 后拒绝新命令。

## 真实 Rust owner 验证（2026-08-30）

使用临时 C ABI harness 调用当前 Release Rust dylib，固定只允许 `status` 和 `restart` 两个操作，目标固定为 `admin-tunnel`；未读取或输出配置中的 command 内容。

| 步骤 | 结果 |
|---|---|
| Rust owner 读取目标状态 | `admin-tunnel` 返回 `running`，PID `97472` |
| Rust owner 执行目标重启 | owner 返回成功；bootstrap 立即后的瞬态状态为 `xpcproxy`，未作为失败处理 |
| 稳定状态复查 | 约 1 秒后 Rust owner 返回 `running`，新 PID `9390`；`launchctl` 同步观察为 `running` |
| 非目标隧道 | `reverse-ssh` 始终为 `running`，PID `23915` 未变化 |
| 配置探针 | HTTP `401`，属于配置期望状态 `200,401`，因此探针满足 |
| App 进程 | TunnelPad 进程仍存活，未执行退出或重启 App |

随后对当前唯一其他真实隧道 `reverse-ssh` 做同样的单目标验证：Rust owner 读取初始状态为 `running`、PID `23915`；直接重启返回成功，启动瞬态为 `xpcproxy`；约 1 秒后 Rust owner 与 `launchctl` 均稳定为 `running`，新 PID `9573`。复查时 `admin-tunnel` 仍为 `running`、PID `9390`，TunnelPad App 进程仍存活。

该结果证明 Rust owner 已对当前两条真实 `launchd` 隧道完成状态读取和重启闭环，并对 `admin-tunnel` 完成业务探针闭环；阶段 5 独立准入复核已通过，删除后的全量回归与最终反向引用审计仍需完成。

## Release App AX 只读复核（2026-08-30）

对当前运行中的 Release App 执行了只读 AX 树检查，未点击控件、未退出 App、未停止或重启隧道。AX 树可见主窗口、`admin-tunnel`/`reverse-ssh` 列表项、`launchd` 标签、运行中 PID、启动/停止/重启按钮、日志区域、滚动区域及自动滚动控件；这证明当前 UI 门面仍可被辅助功能树观察到。

该检查不是隔离环境的启动/退出操作，也不能替代隐藏 app 入口后的 UI/AX 回归；隔离 App 的 AX 启动、退出清理和残留进程复核见下节。

## 真实 Release App 退出清理验证（2026-08-30）

对当前 Release App 发送一次受控 `SIGTERM` 后，TunnelPad 进程退出；随后只读检查两个受管 `launchd` label 均已不存在。该结果验证了真实 Release App 的信号退出路径复用 Rust owner shutdown，并按既定契约停止全部受管隧道；不涉及远端配置或凭证变更。

该验证使用真实用户 home 和真实受管 label，不能替代隔离 App 的启动/AX/退出复核；隔离复核见下节。

## 隔离 App AX 与退出复核（2026-08-30）

为验证隔离路径，临时加入了仅 DEBUG 编译可见的 `--tunnelpad-home <temp-home>` 参数解析，未使用环境变量；验证结束后已删除该 hook。临时 App 使用唯一 bundle ID、唯一可执行文件名和独立临时 home 构建，未覆盖 `dist/TunnelPad.app`。

最终计入证据的实例：

- 构建：`swift build -c debug --product tunnelpad`；Rust 动态库复制到临时 App 的 `Contents/Frameworks/` 后执行 ad-hoc 签名和 `codesign --verify --deep --strict`。
- 启动：`open -n /tmp/tunnelpad-stage5.B34x7h/TunnelPadStage5Isolated-v3.app --args --tunnelpad-home /tmp/tunnelpad-stage5.B34x7h/home`。
- 隔离配置：仅含一条 `stage5-isolated-b34x7h`，执行器为 `launchd`，唯一 label 为 `com.jafish.tunnelpad.stage5-isolated-b34x7h`，command 为无副作用的 `/usr/bin/true`；未执行启动/停止/重启操作。
- AX 树：通过 bundle ID `com.jafish.tunnelpad.stage5isolated.v3` 读取；可见主窗口、`Stage 5 isolated` 列表项、唯一隔离 label、启动/停止/重启按钮、日志区域、滚动控件，以及隔离日志路径 `/tmp/tunnelpad-stage5.B34x7h/home/Library/Logs/TunnelPad/stage5-isolated-b34x7h.log`；未出现真实 `admin-tunnel`、`reverse-ssh` 或真实日志路径。
- app 入口隐藏回归：静态核对 `TunnelSettingsSheet.swift`、`NewTunnelSheet.swift` 只显示 `launchd（当前阶段唯一支持的执行器）`，`TunnelFormState` 将表单执行器固定为 `.launchd`；同一 AX 树只出现 `launchd`，未出现 app 执行器选择或入口。
- 退出：通过 Computer Use 向该实例发送 `super+q`；随后进程已消失，`gui/501/com.jafish.tunnelpad.stage5-isolated-b34x7h` 不存在，隔离 home 只剩初始 `config.json`，没有 launchd plist、日志或孤儿进程。

排除性说明：前两次尝试使用相同 bundle ID 的临时实例，AX 工具选中了较早实例，因此未计入证据；最终 V3 实例使用唯一 bundle ID/可执行文件名并完成了上述复核。

## 阶段 5 删除后收尾

- 已完成旧 Swift Core、app 执行器实现、`ExecutorKind.app` 配置分支、app/pidfile 差分 fixture 及其测试删除。

删除后回归与审计结果：

- `cargo test --manifest-path rust/Cargo.toml`：Rust 49 个单测、1 个差分测试通过；`rust/scripts/smoke.sh` 全部通过。
- `xcodebuildmcp swift-package test --package-path . --configuration debug --output text`：Swift 64/64 通过；`rust/scripts/differential.sh` 重新生成事件流并通过。
- `cargo fmt --manifest-path rust/Cargo.toml --all -- --check`、`git diff --check`、`scripts/build_app.sh --skip-tests` 均通过；`.app` 的 arm64、动态库、签名和 `Info.plist` 校验通过。
- `node .gitnexus/run.cjs analyze` 重新索引后，旧执行器和差分 fixture 不再出现在有效源码定义中；功能图谱所有 `ref` 均指向现存文件。
- `plan-governance-cli check .` 与 `plan-governance-cli check . --strict-readiness` 均通过；仅保留既有跨计划影响目标 WARNING。

上述结果代表删除实施和删除后验证已完成。2026-08-31，用户在最新打包 App 上确认菜单栏图标和隧道管理无异常；基于当前仓库、上述可复现命令和该实机验证完成独立收尾复核，阶段 5 无未解决阻塞项。
