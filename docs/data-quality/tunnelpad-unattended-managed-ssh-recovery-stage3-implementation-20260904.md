# 阶段 3 实施与真实验收证据：无人值守受管 SSH 收敛恢复

日期：2026-09-04

## 范围

本记录只覆盖用户授权的真实 Release App 验收：目标为活动 `admin-tunnel`，只注入一次已重新核验的受管 SSH PID `SIGSTOP`；观察期间不人工释放、不调用隧道启停 API、不重启 App。`reverse-ssh`、未知进程、配置、凭证和远端 ECS 规则均不在写入范围。

## 实施收口

- 真实 `launchctl print` 增加 2 秒有界查询；成功状态进入受控缓存，超时仍保持未知/失败语义，不让健康循环无限等待。
- 受管停止的 `bootout` 也增加可取消的 2 秒边界；超时后只在身份再次核验通过的前提下进入 `SIGCONT → SIGTERM → SIGKILL`，身份未知或变化时 fail-closed。
- 修正 macOS `proc_pidpath` 返回值的字节长度处理：按有效 UTF-8 字节切片读取，不再把无尾随 NUL 的有效路径误判为身份未知。
- 启动后在有界窗口内重读，只有稳定 `running + PID` 才向上层宣告启动完成。

## 验证证据

| 项目 | 结果 |
|---|---|
| Rust 回归 | 76 项单元测试通过；差分测试 1 项通过 |
| Swift 回归 | 139/139 通过 |
| Release 产物 | Rust release dylib、Swift release App、资源、签名和 codesign 校验通过 |
| 真实前置 | App、目标隧道和非目标隧道均在执行前确认；ECS 只读检查通过，未执行写操作 |
| 故障注入 | 仅对目标 PID 注入一次 `SIGSTOP`，成功观察窗口内无人工 `SIGCONT`、启停请求或 App 重启 |
| 自动收敛 | 约 50 秒内原目标 PID 消失并由 launchd 拉起新 PID `64393`；约 60 秒探针恢复为 HTTP `401/satisfied` |
| 非目标隔离 | `reverse-ssh` 始终保持运行，PID `63343` 未改变；App 进程保持存活 |
| 收尾状态 | 当前 `admin-tunnel` 为 `running`，本机 API 返回 `busy=false`、`401/satisfied` |

## 失败原因与修复

历史首次尝试因无界 `launchctl print` 阻塞健康循环；加入 2 秒状态边界后，另一次尝试暴露了启动时序未形成稳定 PID 缓存的问题，随后补齐启动后有界重读。之后真实验收仍返回“受管进程身份未知”，根因是 `proc_pidpath` 有效长度与 NUL 终止字符串读取方式不匹配，导致当前进程路径被错误判为不可用；修正后补充当前进程身份回归测试，最终真实无人值守验收通过。历史失败记录和人工回滚保留在[阶段 3 失败记录](tunnelpad-unattended-managed-ssh-recovery-stage3-failure-20260904.md)，不计入本次成功验收。

## 安全边界、清理与回滚

- 信号目标始终是执行前重新核验的受管 PID；不按 PID 单独信任，不处理未知或非目标进程。
- 真实窗口未修改配置、plist、凭证或 ECS/远端规则；ECS 仅执行只读前置检查。
- 成功窗口无需人工释放或手动恢复；若失败，回滚仅限目标隧道和本地 App，保留配置与远端资源。
