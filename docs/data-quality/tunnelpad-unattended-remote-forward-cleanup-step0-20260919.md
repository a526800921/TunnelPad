# TunnelPad 无人值守远端转发清理 Step 0（2026-09-19）

## 触发与现场事实

- 用户确认远端端口继续使用 `18080`；该端口由 ECS Caddy 的生产反向代理入口消费。
- 公网 IP 变化后，ECS 旧 `sshd` 仍长期持有 `127.0.0.1:18080`。TunnelPad 已按 `0/5/10/30/60/60…` 秒持续恢复且 `/32` 同步成功，但新 SSH 因端口占用持续失败。
- 现场手工精确停止旧监听进程后，新 SSH 自动接管并保持稳定，证明既有重试链在端口释放后可以恢复。
- ECS 为 Linux 6.6、Python 3.11.6，支持 `os.pidfd_open` 与 `signal.pidfd_send_signal`。

## 用户决策与授权边界

- 保持 `-R 127.0.0.1:18080:127.0.0.1:8080` 和 Caddy 配置不变。
- 新增逐隧道布尔配置 `forceRemotePortCleanup`，默认 `false`。只在用户显式开启时启用强制清理。
- 用户明确要求给当前 `motorcycle` 隧道开启：该远端端口只能由该隧道占领；恢复时不检查公网 IP、进程归属、UID、可执行文件或 SSH 会话，只要有进程监听目标 TCP 端口就强制结束。
- 强杀范围是远端该端口的全部 TCP `LISTEN` socket（IPv4/IPv6、任意绑定地址）的全部 owner PID，而不是只匹配 `127.0.0.1` 或 `sshd`。这意味着误占 `18080` 的其他服务也会被杀，属于该配置的明确产品语义。
- 不安装常驻 ECS 服务、不改 `sshd_config`；关闭配置后保持现有行为，不执行远端端口清理。

## 执行链

1. 仅对 `autoStart + keepAlive + SSH + forceRemotePortCleanup=true` 的无人值守启动/异常恢复生效。
2. 既有 Rust owner 先 `bootout` 本地作业，并有界确认 launchd 为 `notLoaded`；未确认时不执行远端清理。
3. **共享阶段**继续按 ECS `launchResource` 合并 `/32` 同步结果。同步失败时不清理、不 bootstrap。
4. **逐隧道阶段**从 SSH 命令解析唯一 `-R` 的远端端口和 SSH destination。每条隧道独立执行；同一规范化 `(host,user,port)` 只串行，不共享其他隧道的成功结果。
5. 通过受限的独立 SSH 调用把同版 Python helper 从 stdin 送入 ECS。helper 枚举该端口全部 TCP 监听 socket 和全部 owner PID，为每个 PID 打开 pidfd，并用 `pidfd_send_signal(SIGKILL)` 立即强杀。
6. helper 在发送信号前再次确认 pidfd 对应进程仍持有目标监听 socket，防止 PID 复用误伤；不检查进程类型、UID、peer 或业务归属。
7. 等待和重查由本机 owner 编排，远端 helper 不 sleep、不 fork、不留后台任务。确认端口无任何监听后才 bootstrap 新 SSH。
8. 清理失败、权限不足、端口被持续抢占、SSH/资源缺失、超时或取消时 fail-closed：不启动新隧道，按既有最高 60 秒退避无限重试，不熔断停机。

## SSH 与输入边界

- 原命令首项必须精确为 `/usr/bin/ssh`；必须恰好存在一个分离形式的 `-R`，其远端监听端口为 `1…65535`，且只有一个 destination、没有 remote command。
- 当前受支持的原命令参数限定为独立的 `-N/-T/-4/-6/-v/-vv/-vvv`，带单值的 `-i/-p/-l/-L/-R`，以及当前生产命令使用的安全 `-o` 项。
- 明确拒绝 `-F/-J/-S/-W/-D`、合并短参数、多个 destination、remote command，以及 `ProxyCommand/ProxyJump/LocalCommand/RemoteCommand/ControlMaster/ControlPath/ControlPersist` 等执行入口。
- 清理调用固定使用 `/usr/bin/ssh -F /dev/null`，强制 `BatchMode=yes`、`ClearAllForwardings=yes`、`PermitLocalCommand=no`、`RequestTTY=no`、有界连接参数；不复制任何转发参数或用户远端命令。
- helper 只接收封闭 action 和已验证十进制端口；不把用户字符串拼入 shell，不把 host、密钥路径、原始 stderr 或公网 IP写入日志。

## 取消、竞态与预算

- 本地 wrapper 使用 `exec /usr/bin/ssh … < helper.py`，使现有有界监督器直接拥有 SSH PID；取消/超时后不会遗留本地 wrapper 或远端延迟任务。
- pidfd 用于消除“核验后 PID 被复用”的竞态；若 pidfd 不可用，不降级为普通 `kill PID`。
- 强杀后以新的短 SSH 调用确认端口；如果有新进程再次监听，同一轮可在总预算内再次枚举并强杀，超过预算则失败并交给下一次退避重试。
- `/32` 同步最多 30 秒，逐隧道强杀和确认最多 20 秒；失败后的调度仍为 `0/5/10/30/60/60…`。

## 样本矩阵

| 样本 | 输入/注入 | 预期 | 失败判定 |
|---|---|---|---|
| R1 | 配置关闭 | 不建立清理 SSH、不发信号 | 默认行为被扩大 |
| R2 | 配置开启且端口无监听 | `listener_absent`，允许 bootstrap | 阻止启动或误杀 |
| R3 | `sshd` 独占目标端口 | pidfd SIGKILL，确认释放后启动 | 仍检查 IP/归属导致拒绝 |
| R4 | 非 `sshd`、不同 UID 或不同 peer 占端口 | 同样 pidfd SIGKILL | 因归属检查跳过 |
| R5 | IPv4/IPv6、多 socket、多 PID监听同端口 | 枚举并强杀全部 owner，确认端口为空 | 只杀一个 PID 后启动 |
| R6 | PID 在枚举后复用 | pidfd/监听复核阻止向新进程发错信号 | 使用普通 `kill PID` |
| R7 | 进程持续抢占端口 | 在 20 秒预算内重查；超时后不启动并重试 | 无限循环或带占用启动 |
| R8 | 本地未确认 `notLoaded` 或 `/32` 同步失败 | 不执行强杀 | 旧本地隧道仍运行时杀远端 |
| R9 | helper、Python、pidfd、认证或 Release 资源缺失 | 结构化失败，继续退避 | 降级或绕过清理 |
| R10 | 同 ECS 不同端口两条隧道 | IP 同步可共享，各端口各清理一次 | 清理结果跨隧道复用 |
| R11 | 相同远端键并发恢复 | 串行执行，每次都重新确认 | 并行强杀或复用旧结果 |
| R12 | 在强杀前、强杀后、最终确认前取消 | 取消后无远端延迟动作 | helper 后台继续杀进程 |
| R13 | 危险 SSH 参数、多个目标或 remote command | fail-closed，信号列表为空 | 危险参数进入清理连接 |
| R14 | 配置 JSON 不含新字段 | 解码为 `false`，兼容旧配置 | 旧配置自动开启强杀 |
| R15 | UI 开启/关闭并保存 | 精确持久化布尔值并显示风险说明 | 配置丢失或无风险提示 |

## 独立复核历史与本次决策

2026-09-19 已完成本交付范围唯一一次 `medium` 独立设计复核，结论 `NOT READY`，无 P0、5 项 P1：共享结果误复用、端口归属不足、PID 复用、远端延迟动作、SSH 参数边界不完整。

- 共享/逐隧道拆分、pidfd、远端单动作和 SSH 显式允许列表按复核要求修复。
- “归属不足”不再以技术推断解决：用户新增显式、默认关闭的强杀配置，并确认 `motorcycle` 的 `18080` 是排他端口，接受误占该端口的任何进程都会被强杀。这是有意的产品权限，不得静默应用到其他隧道。
- 按治理规则不重复发起同范围独立复核；实现者在代码和测试完成后追加“修复自验”，保留原 `NOT READY` 历史结论。

## 预计文件与验证

- `Sources/TunnelPadCore/TunnelConfig.swift` 与 Rust 配置模型：新增默认关闭字段并保持 Swift/Rust JSON parity。
- Tunnel 表单：新增明确风险文案的开关。
- `Sources/TunnelPadCore/ECSPreStart.swift`、`TunnelManager.swift`、`SSHCommand.swift`：共享同步后逐隧道清理、串行键和受限参数解析。
- `scripts/tunnelpad-remote-forward-cleanup`、`scripts/tunnelpad-remote-forward-helper.py`、`scripts/build_app.sh`：exec wrapper、pidfd 强杀 helper 和 Release 打包。
- 覆盖 R1–R15；运行 Swift/Rust 全量、ECS IP fixture、Python/shell 隔离测试、Release 构建、`git diff --check`、GitNexus `detect_changes --scope all` 与治理严格检查。

## 失败与回滚

- 任一清理未确认端口为空时保持 `notLoaded`，不 bootstrap；无限重试仍以 60 秒为上限间隔。
- 关闭单条隧道的 `forceRemotePortCleanup` 即停止远端强杀；代码回滚删除逐隧道清理和 helper，不改变 `18080`、Caddy、ECS `sshd_config` 或其他隧道。
- 真实 ECS 验收必须再次确认目标为 `motorcycle` 的 `18080`，但开启后不再检查占用进程归属，这是用户明确要求的行为。
