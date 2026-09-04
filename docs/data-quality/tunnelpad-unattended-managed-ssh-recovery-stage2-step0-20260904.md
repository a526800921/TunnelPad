# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 2 Step 0

- 日期：2026-09-04
- 阶段：阶段 2
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 前置：[阶段 1 独立完成复核](tunnelpad-unattended-managed-ssh-recovery-stage1-independent-completion-review-20260904.md)
- 基线类型：当前工作树 Release 构建、Rust/Swift/FFI 兼容回归、隔离 App 产物校验；不把真实信号注入作为阶段 2 的证据

## 目标与边界

阶段 2 只验证阶段 1 实现能进入 Release 产物、保持 Rust/Swift/FFI 兼容，并在隔离目录完成 App 包结构、签名和启动/退出边界验证。阶段 2 不发送 `SIGCONT`、`SIGTERM` 或 `SIGKILL`，不调用真实用户 launchd、SSH、ECS 或远端资源，不覆盖 `dist/TunnelPad.app`，也不读取或修改真实配置、日志和凭证。

阶段 3 才验证真实活动隧道上的纯 `SIGSTOP` 无人工释放闭环；阶段 2 的通过不替代阶段 3 的真实验收。

## 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前 Swift Package 与阶段 1 健康恢复/冷却 fixture | `xcodebuildmcp swift-package test --package-path . --configuration debug` | Swift 全量测试通过，含冷却、取消、代次和多隧道隔离 | 任一测试失败或跳过 | XcodeBuildMCP 测试日志与阶段 2 实施证据 |
| 2 | 当前 Rust workspace 与 FFI differential fixture | `cargo test --manifest-path rust/Cargo.toml` | Rust 全量单元、FFI 和差分测试通过 | 任一测试失败、差分不一致或触碰真实资源 | 终端输出与阶段 2 实施证据 |
| 3 | 当前 `tunnelpad` executable target | `xcodebuildmcp swift-package build --package-path . --target-name tunnelpad --configuration release` | Release target 构建成功 | 编译/链接失败或产物缺失 | XcodeBuildMCP 构建日志 |
| 4 | 当前 Rust release profile | `cargo build --release --manifest-path rust/Cargo.toml` | `rust/target/release/libtunnelpad_core.dylib` 存在 | release 构建失败或动态库缺失 | 终端输出与阶段 2 实施证据 |
| 5 | 临时工作树中的 Release App 目录 | 在唯一临时目录执行 `scripts/build_app.sh --skip-tests`；检查 `plutil -lint`、`codesign --verify --deep --strict`、`@rpath` 和资源文件 | App 包结构、Info.plist、动态库、ECS 资源和 ad-hoc 签名有效；不覆盖仓库 `dist` | 包缺失、签名/Info.plist/动态库校验失败或写入真实路径 | 阶段 2 实施证据与临时构建输出 |
| 6 | 隔离 App 的空配置/虚构隧道 fixture | 使用临时 home 运行 Release 可执行文件，仅读取 UI/API 后退出；不点击启停 | App 能启动、读取隔离配置并退出；无真实 label、SSH、ECS 或远端写入 | 启动失败、串入真实 home、触碰真实隧道或退出残留 | 阶段 2 实施证据 |
| 7 | Rust owner → Swift FFI stop/start 顺序 | `cargo test --manifest-path rust/Cargo.toml` 中 owner/owner_ffi lifecycle fixture；核对 `stop_with_generation` 路由 | stop 未收敛不解锁 ECS/start；SSH 受管路径与非 SSH 旧路径隔离 | 顺序反转、ABI 变化或错误被吞掉 | 阶段 2 实施证据 |
| 8 | 治理与反向引用 | `plan-governance-cli check . --strict-readiness`、`git diff --check`、`rg` 反向引用检查 | 阶段 2 状态、证据、范围和历史文档事实源一致 | ERROR、空白错误、漂移或旧草案重新成为事实源 | 阶段 2 独立完成复核 |

## 验证与失败策略

- Release 验证使用当前工作树的 Swift target、Rust 动态库和临时 App 副本；任何失败只保留构建日志并删除临时副本，不回滚或删除真实用户数据。
- 阶段 2 发现 FFI、签名、资源路径或启动/退出边界问题时，先回到阶段 2 实施范围修复并重新做 GitNexus impact；未通过前不得进入阶段 3。
- 阶段 3 的真实故障注入必须重新建立自己的 Step 0、真实环境回滚边界和独立准入；本文件不授权真实信号。

## 准入判断

阶段 2 的目标、范围、非目标、样本矩阵、验证方式、失败策略和安全边界已冻结，阶段 1 已完成且证据可复现；达到“待实施”标准，等待独立准入复核。
