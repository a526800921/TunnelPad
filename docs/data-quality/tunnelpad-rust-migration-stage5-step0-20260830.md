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

本次闭环证明了当前 Swift launchd 路径可以完成一次受控停止和重启，但尚未证明 Rust owner。HTTP 探针失败必须在 owner 切换前分类或修复，否则不能作为“业务可用性通过”证据。

## owner 原型、生产适配与 Release 验证（2026-08-30）

已完成 Rust owner 原型，并接入 Swift `TunnelManager` 的生产初始化路径，验证阶段 5 的
opaque handle、UTF-8 JSON 命令、配置 owner、launchd 生命周期和并发边界：

- Rust owner 实现：[owner.rs](../../rust/tunnelpad-core/src/owner.rs)；C ABI 扩展：[owner_ffi.rs](../../rust/tunnelpad-core/src/owner_ffi.rs)；头文件声明：[tunnelpad_core.h](../../rust/include/tunnelpad_core.h)。
- 原型函数为 `tp_core_abi_version`、`tp_core_create`、`tp_core_command`、`tp_core_shutdown`、`tp_core_destroy` 和 `tp_core_last_error`；旧 `tp_*` ABI v1 未改变。
- `cargo test --manifest-path rust/Cargo.toml`：42 个 Rust 单测 + 1 个差分测试全部通过。
- `./rust/scripts/smoke.sh`：Rust release 构建、上述测试、Swift C ABI smoke、arm64 产物和 ad-hoc 签名校验全部通过；Swift smoke 覆盖 owner 创建、空配置 snapshot、shutdown 和释放断言。
- `swift test`：79/79 通过；新增 `RustCoreClientTests` 2 项，覆盖真实 release dylib 的 snapshot、shutdown 后 owner closed 和 `app` 配置 fail-closed。
- `./scripts/build_app.sh`：Rust release、Swift 测试、Swift release、动态库复制、`@rpath`、ad-hoc 签名和 `Info.plist` 校验全部通过。
- Rust shutdown 已修复：未加载的 launchd 服务先由 owner 判定为 `notLoaded`，不再把真实 `launchctl` 的 `No such process` 误报为退出失败。
- fixture 明确验证：version=1 配置读写、`app` 配置拒绝且不自动转换、JSON 生命周期结果、同隧道串行、不同隧道并行，以及 shutdown 后拒绝新命令。

该结果只代表 owner 适配与 Release 构建验证通过，不代表阶段 5 已完成。当前仍缺少 Rust owner 的后台任务/取消/过期代次、完整 fake `launchd` 故障矩阵、app 入口删除后的 UI/AX 回归、真实隧道 Rust owner 验证、退出路径独立复核和阶段 5 独立准入复核。

## Step 0 尚缺证据

- owner 原型的最终 ABI 冻结与 Swift 适配层独立复核；
- fake `launchd` 的完整启动、停止、重启、删除、错误注入和 shutdown 矩阵；
- 后台任务、取消和过期任务保护测试；
- 隐藏/删除 app 执行器入口后的 UI/AX 回归；
- Rust owner 版本的 Release 启动、退出清理和独立准入复核；当前只完成构建/签名，尚未在隔离 app 环境执行 UI/AX 启动与退出操作。
