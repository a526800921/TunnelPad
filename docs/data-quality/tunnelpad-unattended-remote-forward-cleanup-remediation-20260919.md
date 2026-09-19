# TunnelPad 无人值守远端转发清理修复自验（2026-09-19）

## 结论

远端排他端口强杀已按用户授权实现并完成修复自验。新增配置 `forceRemotePortCleanup` 默认关闭，仅当前 `motorcycle-local-docker` 明确开启。无人值守恢复顺序固定为：

`本地 bootout 并确认 notLoaded → ECS /32 同步 → 强杀远端 -R 端口全部监听进程 → 再次确认端口为空 → bootstrap 新 SSH`

任一步失败都 fail-closed，不启动新 SSH，并继续使用 `0/5/10/30/60/60…` 秒无限重试。技术门禁和本次受控启动通过；计划仍保持“实施中”，后续阶段 2 长时无人值守与用户体验验收不由本记录代替。

## 独立发现闭环

本交付范围唯一一次独立设计复核为[远端转发清理独立设计复核](../reviews/tunnelpad-unattended-remote-forward-cleanup-independent-review-20260919.md)，历史结论 `NOT READY` 保留。本次由实施者按“发现 → 修复 → 验证”闭环，不重复独立复核：

| 独立发现 | 修复 | 验证 |
|---|---|---|
| 共享 ECS 结果会跳过第二条隧道的端口清理 | `/32` 同步继续共享；端口清理由 `RemotePortCleanupCoordinator` 按规范化远端键串行，但每个调用都重新执行 | `testConcurrentRuntimeRecoverySharesSingleECSPreflightByResource`；`testRemotePortCleanupSerializesSamePortWithoutSharingResult` |
| 端口/PID/UID/`sshd` 不能证明归属 | 用户新增默认关闭的显式强杀权限；开启后端口本身就是授权边界，不检查 IP、UID、类型或会话归属 | 配置缺省/roundtrip、表单持久化与 UI 风险文案测试；真实非 `sshd` Python 监听被清理 |
| PID 复用可能误杀 | 每个 owner 先 `pidfd_open`，发信号前重新确认该 pidfd 对应进程仍持有本轮目标监听 inode；不支持 pidfd 时拒绝降级 | `remote-forward-helper-test.py` 的 replacement process 样本确认零信号 |
| 远端等待/升级会在本地取消后继续发信号 | 远端 helper 单次只枚举并立即 SIGKILL，不 sleep、不 fork；等待和重查由本地两个受监督 SSH 调用完成 | helper 源码边界、`SystemECSPreflightProcessRunner` 取消测试、真实 ECS 两次调用分别返回 kill/absent |
| SSH 参数和 shell 边界不完整 | 仅接受精确 `/usr/bin/ssh` 和显式允许列表；清理命令强制 `-F /dev/null`、清空转发并禁止本地命令/TTY；helper 由 stdin 输入，端口为校验后的十进制数 | `SSHCommandTests` 危险参数矩阵及 `ECSPreStartIntegrationTests` 清理调用参数断言 |

## 实现结果

- Swift/Rust 配置模型新增 `forceRemotePortCleanup`，旧 JSON 缺字段时为 `false`；Swift/Rust JSON parity 已更新。
- 新建/编辑表单可配置该字段；开启时显示“会强杀该端口全部监听进程”的红色风险说明。
- `SSHCommand.remotePortCleanupTarget` 从唯一 loopback `-R` 解析远端端口、destination 和受限 SSH 参数；危险参数、多个目标、remote command 或非精确 SSH 可执行路径均拒绝。
- 本地 wrapper 通过 `exec` 交接给受监督 `/usr/bin/ssh`；同版 Python helper 从 stdin 在 ECS 临时执行，不安装远端常驻服务。
- helper 同时读取 `/proc/net/tcp` 与 `/proc/net/tcp6`，枚举目标端口全部 `LISTEN` inode 及全部 owner PID，以 pidfd 发送 `SIGKILL`。
- 本地总清理预算最多 20 秒，每次 SSH 最多 10 秒；收到 `listeners_killed` 后重新连接确认，只有 `listener_absent` 才允许继续。
- Release App 已打包 wrapper/helper 并通过 ad-hoc 签名校验。

## 自动化证据

| 门禁 | 结果 |
|---|---|
| `swift test` | 205 项通过，0 失败；覆盖默认关闭、UI/配置持久化、受限 SSH、清理重查、共享同步/逐隧道清理、同端口串行及恢复顺序 |
| `cargo test --manifest-path rust/Cargo.toml` | 111 项通过，0 失败；含 97 个 Core、6 个 preflight、1 个差分、7 个日志代理测试 |
| `bash rust/scripts/differential.sh` | Swift/Rust 配置与 legacy derive 差分通过 |
| `bash Tests/update-ecs-ssh-ip-test.sh` | 18 个 ECS `/32` 同步 fixture 通过 |
| `python3 Tests/preflight-supervision-test.py` | 9 个监督、锁和取消 fixture 通过 |
| `python3 Tests/remote-forward-helper-test.py` | 2 项通过：IPv4/IPv6 同端口多 PID 全部强杀；PID 复用时不发信号 |
| helper/wrapper/build 脚本语法 | `py_compile` 与 `bash -n` 通过 |
| `scripts/build_app.sh` | Release 编译、205 项 Swift 回归、资源复制和签名校验通过 |
| `git diff --check` | 通过 |

## 真实 ECS 隔离验证

在 ECS 未使用的 `127.0.0.1:48080` 启动临时 Python HTTP 监听 PID `172114`，不触碰生产 `18080`：

1. `ss` 确认 `python3` 正在监听 `48080`。
2. 同版 helper 第一次返回 `listeners_killed`、`killedCount: 1`。
3. 第二次独立 SSH 调用返回 `listener_absent`。
4. `ss` 无该端口监听，`kill -0 172114` 确认进程已不存在。

这证明“非 `sshd`、不检查归属、只按目标端口强杀”和“两次调用确认端口为空”的真实 Linux 路径可用。

## 当前 App 与生产配置观察

- 当前 Release App 从 `dist/TunnelPad.app` 启动，进程路径和两个清理资源均核对通过。
- 用户配置中只有 `motorcycle-local-docker` 为 `forceRemotePortCleanup: true`；`admin-tunnel`、`reverse-ssh` 缺省为关闭。
- 新 App 启动日志：22:30:35 建立 1 条启动恢复候选并发生一次瞬时重试；22:30:42 确认运行并交接健康监测。
- 本地 launchd 作业处于 `running`，PID `20371`；ECS `127.0.0.1:18080` 由新 `sshd` PID `172162` 单独监听。

该观察证明新包、配置和当前启动链已生效，但没有把一次启动观察夸大为长时间无人值守验收。后续仍需用户按阶段 2 场景改变安全组 `/32` 或制造真实断线，观察旧监听被强杀、新 SSH 自动接管且无人工干预。

## 回滚

- 对单条隧道关闭 `forceRemotePortCleanup` 即停止远端端口强杀，其他无人值守恢复行为保持不变。
- 清理失败时系统保持 `notLoaded` 并继续退避重试，不会在目标端口仍被占用时启动新 SSH。
- 代码回滚只需移除逐隧道清理链与 App 内 helper；不修改 `18080`、Caddy、`sshd_config` 或其他隧道。
