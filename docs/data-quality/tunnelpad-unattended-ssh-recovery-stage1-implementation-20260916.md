# TunnelPad 无人值守 SSH 异常恢复与孤儿清理：阶段 1 实施证据

日期：2026-09-16

## 范围与结论

本记录覆盖阶段 1 的代码实现、隔离回归、Release 构建和当前运行态部署；不对真实 `motorcycle-local-docker` 注入 SIGTERM/SIGKILL，不把一次运行成功当作真实异常恢复验收。阶段 2 的真实故障注入、恢复窗口、端口释放和用户验收仍未完成。

阶段 1 的技术结果：日志代理异常路径会先清理受管 SSH；SSH 继承 launchd 作业进程组；launchd 顶层按代理身份核验，最后一级 SIGKILL 使用已核验 PGID；代理资源安装到稳定路径，Bundle 资源缺失时 fail-closed，不回退为直启 SSH。

## 实现切片

| 切片 | 实现 | 证据 |
|---|---|---|
| 代理清理 | 统一覆盖正常退出、信号、reader 错误、日志 I/O 错误；SIGCONT→SIGTERM→SIGKILL 有界等待并 `wait` 回收；进程组枚举有容量和完整性检查 | `rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs`；代理隔离测试 4 项 |
| 作业组 | 移除 SSH 自行切换 PGID，令 SSH 继承代理/launchd 作业组；plist 明确 `AbandonProcessGroup=false` | `rust/tunnelpad-core/src/plist_render.rs`；`Sources/TunnelPadCore/LaunchdPlistRenderer.swift` |
| 身份契约 | launchd 顶层 `program`、PID、UID、可执行路径和 PGID 参与身份票据；TERM/CONT 作用于顶层 PID，KILL 作用于已核验 PGID；状态变化 fail-closed | `rust/tunnelpad-core/src/launchctl.rs`；身份变化和 PGID fake fixture |
| 辅助程序 | Release App 打包代理；运行时复制到 `~/Library/Application Support/TunnelPad/bin/tunnelpad-log-proxy` 并设置 0755；资源缺失/不可执行时报本地前置错误 | `scripts/build_app.sh`；Swift/Rust plist renderer 测试 |

## 可复验验证

| 验证 | 结果 |
|---|---|
| `cargo fmt --manifest-path rust/Cargo.toml --all -- --check` | 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 85 passed, 0 failed；包含代理隔离 4 项和 launchctl 身份/PGID 回归 |
| `swift test` | 176 passed, 0 failed |
| `./scripts/build_app.sh --skip-tests` | Release Rust/Swift 构建、App 打包、资源复制、签名和校验通过 |
| `git diff --check` | 通过 |
| `plan-governance-cli check . --strict-readiness` | 通过 |
| GitNexus `detect_changes({scope: "all"})` | 识别 52 个变更符号、8 条受影响流程，风险级别 high；影响集中在 plist 安装/接管、Core shutdown 和 Supervisor 身份边界，属于本计划预期范围 |

## 当前运行态观察

使用新 Release App 平滑替换旧进程后，只读核对当前用户域的 `motorcycle-local-docker`：

- `launchd state = running`，`active count = 1`。
- 顶层 `program` 为稳定路径下的 `tunnelpad-log-proxy`；不是旧 Bundle 的绝对资源路径。
- `ProgramArguments[0]` 为稳定辅助程序；`StandardOutPath`/`StandardErrorPath` 为 `/dev/null`；`AbandonProcessGroup=false`。
- 代理与其 SSH 子进程的 PGID 相同，均由代理作业组 leader 管理。
- 日志文件已有符合 `YYYY-MM-DDTHH:mm:ss.SSS±HHMM [stream]` 的时间戳行；本记录不复制日志正文。
- 本机 API 只读摘要返回 `status = running`、`busy = false`，探针 `status = satisfied`、HTTP `401`（符合该隧道声明的预期状态）。

这些观察证明新包已接管运行态身份和进程组形状，但没有证明真实异常发生后的自动恢复闭环。

## 未完成与停止条件

- O5 的真实 launchd `bootout`/代理 SIGKILL 后代清理仍需隔离 launchd fixture 或阶段 2 受控验证；当前已用本地代理/作业组隔离测试覆盖同组后代清理。
- O7 的 Bundle 移动/资源缺失正向 fixture 仍需补充；生产路径已实现缺失即 fail-closed，不能静默回退。
- O8 真实 `motorcycle-local-docker` 故障注入、自动恢复、18080 转发恢复、端口释放和无孤儿 SSH 尚未执行；执行前必须重新核对目标 PID/PGID、状态和停止条件，并单独记录用户授权。

在上述真实验收完成前，专项计划保持“实施中”。

## 安全边界

验证只使用当前项目、临时本机进程和当前用户域；不记录 SSH 参数、凭据、私钥、完整远端地址或云端响应。清理逻辑只作用于当前代理证明拥有的子进程/进程组，无法证明归属时保持 fail-closed。
