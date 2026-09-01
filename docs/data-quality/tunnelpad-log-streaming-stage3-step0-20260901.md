# TunnelPad 日志事件流阶段 3 Step 0 证据

- 日期：2026-09-01
- 计划：[TunnelPad 日志事件流与面板生命周期](../plans/tunnelpad-log-streaming.md)
- 阶段：阶段 3
- 基线类型：阶段 2 隔离 App UI 验收 + Rust/Swift 当前工作树回归 + Release 产物校验

## 结论

阶段 2 的受控应用冒烟已通过，日志面板关闭/重开、追加事件、双隧道切换和自动滚动行为均已在隔离 App 中观察。阶段 3 的 Step 0 及最终门禁已通过：Rust owner、Swift 日志存储和 UI 生命周期均使用当前工作树；Release target、Release Rust dylib、签名/Info.plist、全量回归、锁失败重试和治理检查均有可复现证据。当前未触碰真实 TunnelPad 配置、日志、launchd 或 SSH。

## 阶段 3 Step 0 样本矩阵

| 样本 | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| Rust workspace 回归 | 当前 `rust/Cargo.toml` workspace、owner/status/lifecycle/differential fixture | `cargo test --manifest-path rust/Cargo.toml` | 50 个 Rust 单测、1 个差分测试通过；无失败/跳过 | Rust 测试失败、差分不一致或访问真实隧道 | 本文与终端输出 |
| Swift 全量回归 | 当前 Swift Package、日志事件与生命周期 fixture | `xcodebuildmcp swift-package test --package-path .` | 101/101 通过，0 失败，0 跳过 | 任一测试失败或触碰真实资源 | 本文与 XcodeBuildMCP 测试日志 |
| Swift Release target | 当前 `tunnelpad` executable target | `xcodebuildmcp swift-package build --package-path . --target-name tunnelpad --configuration release` | Release target 构建成功 | 编译/链接失败或产物缺失 | 本文与 XcodeBuildMCP 构建日志 |
| Rust Release dylib | 当前 Rust workspace release profile | `cargo build --release --manifest-path rust/Cargo.toml` | `rust/target/release/libtunnelpad_core.dylib` 存在并可用于隔离包 | release 构建失败或动态库缺失 | 本文与终端输出 |
| 隔离 Release App | 临时副本；`TunnelPaths.standard()` 指向 `/tmp/tunnelpad-app-smoke.DCdeuB/home`；虚构 `smoke-a`/`smoke-b`；命令 `/usr/bin/true` | 在临时副本用 `xcodebuildmcp swift-package run --configuration release` 链接当前 Release 可执行文件；组装 `SmokeTunnelPadRelease2.app`；`codesign --verify --deep --strict`；`plutil -lint`；`xcodebuildmcp macos launch/stop` | App 启动成功，AX 显示虚构配置、隔离日志路径和可恢复快照；无启停副作用 | 不能启动、签名/Info.plist 校验失败、串入真实路径或触碰真实隧道 | 本文与临时包验证输出 |
| 阶段 2 UI 证据 | 隔离 debug App 的 `initial-A`、`event-A`、`initial-B` 与追加日志 | Computer Use：追加日志、切换 B、关闭/重开窗口、切换自动滚动并滚动后追加 | 事件即时显示；重开不漏/不重；切换不串；关闭自动滚动时滚动条保持 `0` | UI 状态倒灌、重复/遗漏、窗口关闭导致进程退出或滚动位置被强制改变 | [阶段 2 Step 0](tunnelpad-log-streaming-stage2-step0-20260901.md) |
| 计划/图谱门禁 | 当前工作树治理文档、Graph 和补丁 | `plan-governance-cli check . --strict-readiness`；`plan-governance-cli graph validate .`；`git diff --check` | 治理、图谱和补丁检查通过 | ERROR、图谱无效或空白错误 | 本文与终端输出 |

## 已执行结果（2026-09-01）

- `cargo test --manifest-path rust/Cargo.toml`：50/50 Rust 单测、1/1 差分测试通过；workspace 中兼容 fixture 和 doctest 也无失败。
- `cargo build --release --manifest-path rust/Cargo.toml`：通过。
- `xcodebuildmcp swift-package test --package-path .`：101/101 通过，0 失败，0 跳过；包含锁占用时保留原文件并在解锁后重试的日志裁剪 fixture。
- `xcodebuildmcp swift-package build --package-path . --target-name tunnelpad --configuration release`：Release target 构建成功。
- 隔离 debug App：AX 确认 `Smoke A` 初始快照、A 追加事件、B 切换隔离；关闭窗口后进程保持运行，重开恢复 `initial-A + event-A`；关闭自动滚动并把滚动条设为 `0` 后追加日志，滚动条保持 `0`。
- 隔离 Release App：`codesign --verify --deep --strict`、`plutil -lint` 和 App 启动均通过；AX 显示同一隔离配置和临时日志路径。未点击启动/停止/重启。
- `plan-governance-cli check . --strict-readiness`：通过（仅保留已声明的稳定性共享文件影响 WARNING）；`plan-governance-cli graph validate .`：通过；`git diff --check`：通过。
- 反向引用核对已覆盖专项计划、`PLAN_MAP.md`、阶段 0–3 证据、ADR、关键字段和“草案为准/以草案为事实源/详见草案”旧事实源词；未发现日志计划回退到草案事实源。

## 安全与回滚边界

本阶段只在当前工作树和 `/tmp/tunnelpad-app-smoke.DCdeuB` 临时副本中构建/运行；不覆盖 `dist`，不修改真实用户配置、日志、launchd plist、SSH 或稳定性计划文件。若发布门禁失败，保留已通过的阶段 1/2 代码与证据，先回滚阶段 2 UI session 接入或移除临时 App 包；不删除真实日志、不执行真实隧道控制。

## 阶段准入判断

本 Step 0 的目标、范围、非目标、样本矩阵、验证方式、失败策略和安全边界均已明确；阶段 2 与阶段 3 的独立完成复核已在专项计划中追加。最终治理、图谱、补丁和反向引用检查通过，阶段 3 达到完成标准，日志事件流与面板生命周期全计划已收口。
