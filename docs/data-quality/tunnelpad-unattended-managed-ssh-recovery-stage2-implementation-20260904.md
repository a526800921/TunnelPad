# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 2 实施证据

- 日期：2026-09-04
- 阶段：阶段 2
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- Step 0：[阶段 2 Step 0](tunnelpad-unattended-managed-ssh-recovery-stage2-step0-20260904.md)
- 结论：Release/FFI/隔离 App 验证完成；不包含真实进程信号或真实活动隧道故障注入

## 执行结果

| 检查 | 命令或操作 | 结果 |
|---|---|---|
| Swift 全量回归 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --configuration debug --output text` | 139/139 通过，0 失败，0 跳过。 |
| Swift Release target | `xcodebuildmcp swift-package build --package-path /Users/jafish/Documents/work/TunnelPad --target-name tunnelpad --configuration release --output text` | Release target 构建成功。 |
| Rust 全量与差分 | `cargo test --manifest-path rust/Cargo.toml` | Rust 72 项单元测试、1 项 differential 测试通过；无失败。包含 FFI roundtrip、owner 顺序、取消和受管 stop fixture。 |
| Rust Release | `cargo build --release --manifest-path rust/Cargo.toml` | release 动态库构建成功。 |
| 临时 Release App | 唯一临时目录 `/tmp/tunnelpad-stage2.Rxfx5b` 执行 `scripts/build_app.sh --skip-tests` | 当前工作树源代码成功组装 `.app`；未覆盖仓库 `dist`。 |
| 包校验 | `plutil -lint`；`codesign --verify --deep --strict`；`otool -D` | `Info.plist` 有效；ad-hoc 签名有效；Rust 动态库 install name 为 `@rpath/libtunnelpad_core.dylib`。 |
| 隔离 App 启停 | `xcodebuildmcp macos launch --app-path /tmp/tunnelpad-stage2.Rxfx5b/project/dist/TunnelPad.app`；随后按临时 PID 使用 `xcodebuildmcp macos stop` | App 启动和退出成功；临时空配置写入 `/tmp/tunnelpad-stage2.Rxfx5b/home`；退出后临时 PID 消失，真实用户 App PID/9998 listener 未受影响。 |
| 资源边界 | 临时 App 使用空 `tunnels` 配置，未点击启停/重启 | 未发送 `SIGCONT`、`SIGTERM`、`SIGKILL`；未调用真实用户隧道、ECS 或远端写接口。 |

## FFI 与生命周期兼容性

- Rust `owner`/`owner_ffi` 现有顺序 fixture 保持通过：stop 未收敛或取消时，不向 Swift 解锁 ECS/start；成功路径仍由既有 Rust owner 返回结果。
- `CoreOwner.stop_with_generation` 只对 SSH 命令使用受管 stop 收敛器，非 SSH 继续旧 bootout 路径；未新增 C ABI、配置字段、HTTP API 或 launchd label。
- Swift 自动冷却、generation、取消、手动操作和多隧道隔离测试随 139 项全量回归通过。

## 阶段 2 边界判断

阶段 2 的 Release target、Rust release 动态库、签名/资源、隔离 App 启停、FFI 顺序和全量回归均通过。验证仅证明当前实现可安全进入 Release/隔离 App，不证明真实活动隧道上的自动信号处置；阶段 3 仍需自己的 Step 0、独立准入和真实无人值守验收。
