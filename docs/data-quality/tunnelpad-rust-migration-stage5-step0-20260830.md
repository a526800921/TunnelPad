# TunnelPad Rust Core 迁移阶段 5 Step 0 基线

- 日期：2026-08-30
- 阶段：阶段 5
- 类型：行为迁移与真实 `launchd` 受控基线
- 结论：Step 0 尚未达到待实施标准
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
- 生产退出路径已切换：`TunnelManager` 暴露绑定同一 Rust handle 的 `Shutdown.OwnerHandle`，`AppDelegate` 将其交给 SIGTERM/SIGINT handler；默认无 owner 的工具入口也只创建 Rust owner，旧 Swift executor 仅保留在 DEBUG 历史差分 fixture 中。
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

该结果证明 Rust owner 已对当前两条真实 `launchd` 隧道完成状态读取和重启闭环，并对 `admin-tunnel` 完成业务探针闭环；仍不代表阶段 5 已完成。当前仍缺少 app 入口删除后的 UI/AX 回归、隔离 app/AX/退出操作复核和阶段 5 独立准入复核。

## Release App AX 只读复核（2026-08-30）

对当前运行中的 Release App 执行了只读 AX 树检查，未点击控件、未退出 App、未停止或重启隧道。AX 树可见主窗口、`admin-tunnel`/`reverse-ssh` 列表项、`launchd` 标签、运行中 PID、启动/停止/重启按钮、日志区域、滚动区域及自动滚动控件；这证明当前 UI 门面仍可被辅助功能树观察到。

该检查不是隔离环境的启动/退出操作，也不能替代隐藏 app 入口后的 UI/AX 回归；隔离 App 的 AX 启动、退出清理和残留进程复核仍待完成。

## 真实 Release App 退出清理验证（2026-08-30）

对当前 Release App 发送一次受控 `SIGTERM` 后，TunnelPad 进程退出；随后只读检查两个受管 `launchd` label 均已不存在。该结果验证了真实 Release App 的信号退出路径复用 Rust owner shutdown，并按既定契约停止全部受管隧道；不涉及远端配置或凭证变更。

该验证使用真实用户 home 和真实受管 label，不能替代隔离 App 的启动/AX/退出复核。

## Step 0 尚缺证据

- 隐藏/删除 app 执行器入口后的 UI/AX 回归；
- 隔离 app 环境的 UI/AX 启动、退出清理和残留进程复核；
- 阶段 5 独立准入复核。
