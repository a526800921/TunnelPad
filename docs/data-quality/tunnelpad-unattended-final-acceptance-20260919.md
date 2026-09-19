# TunnelPad 无人值守恢复最终验收（2026-09-19）

## 验收范围

本记录同时作为以下两个计划的阶段 2 最终用户验收证据：

- [TunnelPad 无人值守 SSH 异常恢复与孤儿清理](../plans/tunnelpad-unattended-ssh-recovery-and-orphan-cleanup.md)
- [TunnelPad 无人值守 ECS 公网 IP 漂移同步与断线恢复](../plans/tunnelpad-unattended-ecs-ip-drift-recovery.md)

验收使用已部署的新 Release App；`motorcycle-local-docker` 保持远端转发端口 `18080`，并仅对该隧道开启默认关闭的 `forceRemotePortCleanup`。本轮不新增代码改动，也不重复发起独立复核；阶段 2 复用既有独立设计/实现复核及其修复自验证据。

## 真实操作与时间线

用户在真实环境切换公网 IP/受管安全组来源后，没有点击 TunnelPad 的启动或重连按钮：

| 本地时间 | 观测 |
|---|---|
| 22:37:48 | 旧 SSH 连接被远端关闭，TunnelPad 记录断线。 |
| 22:37:49 | 单一恢复链开始处理：先收敛旧实例，再检查/同步 ECS `/32`，最后启动新 SSH。 |
| 22:37:52 | 新日志代理 PID `22770` 进入运行态。 |
| 22:37:53 | 新 SSH PID `22773` 启动。 |
| 22:38:11 | 连续健康采样确认恢复；从旧连接关闭到确认恢复约 23 秒。 |

## 验收结果

| 检查项 | 结果 |
|---|---|
| ECS 受管 `/32` | 只读检查返回 `stage=complete`、`category=success`、`sanitizedCode=synchronized`。 |
| 本机旧实例 | 旧代理 PID `20371` 已不存在；launchd 当前作业为 `running`，由新代理 PID `22770` 接管。 |
| 本机 SSH | 仅新 SSH PID `22773` 存活；未发现旧 SSH 与新 SSH 并行。 |
| ECS 旧监听 | 旧远端 sshd PID `172162` 已不存在。 |
| ECS 当前监听 | `127.0.0.1:18080` 仅由新远端 sshd PID `172208` 监听。 |
| 数据路径 | ECS 本机访问 `127.0.0.1:18080/` 返回 HTTP 404；这表示隧道数据路径已连通，只是目标服务没有该路由。 |
| 重试行为 | 恢复后未出现新的转发错误、2 秒重试风暴或需要人工干预的停止状态。 |

## 复核基线复用

- SSH 进程树、launchd 身份和远端排他端口清理沿用[远端清理独立设计复核](../reviews/tunnelpad-unattended-remote-forward-cleanup-independent-review-20260919.md)及[修复自验](tunnelpad-unattended-remote-forward-cleanup-remediation-20260919.md)。独立复核的 5 项 P1 已按“发现 → 修复 → 验证”闭环，历史 `NOT READY` 记录保留。
- ECS 同步、共享资源串行化、配置事务、退出清理和持续恢复沿用[合并独立复核](../reviews/tunnelpad-unattended-stage1-consolidated-review-20260919.md)、[阶段 1 修复自验](tunnelpad-unattended-stage1-review-remediation-20260919.md)及[运行期退避修复自验](tunnelpad-unattended-runtime-backoff-remediation-20260919.md)。
- 自动化门禁沿用同一交付范围内已通过的 Swift 205 项、Rust 111 项、ECS fixture 18 项、监督脚本 9 项、远端 helper 2 项、Release 构建/签名及真实 ECS 隔离端口强杀验证。

## 用户验收与收口

用户在查看上述真实切换后的连接状态后，明确同意计划收口。阶段 2 的核心完成条件已经满足：断线后自动进入恢复链，先同步 ECS `/32`，再清理排他端口旧监听并重连；最终没有孤儿或并行 SSH，且不需要人工点击。

长期无人值守运行仍应作为日常运行监测持续观察，但它不再作为本次计划关闭的阻塞项；如后续出现新反例，按新的事实重开或新建立项，不改写本次验收记录。

结论：两个计划均可标记为“已完成”。
