# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 3 首次验收失败证据

- 日期：2026-09-04
- 阶段：阶段 3
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 结论：未通过；已安全回滚冻结状态，不构成完成证据

## 现场结果

执行前实时核验确认：

- 当前 Release App PID `48118`，目标 `admin-tunnel` label 为 `running`，目标 SSH PID `48482`，UID 与当前用户一致，可执行文件为 `/usr/bin/ssh`。
- 非目标 `reverse-ssh` PID `48495`，故障注入前后均未改变。
- 目标 HTTP 探针原为 `401`；ECS `--check` 成功且未执行写操作。

仅向已核验的目标 PID `48482` 发送一次 `SIGSTOP`，之后 90 秒内只读观察：目标 HTTP 为 `000`，旧 PID 保持冻结，目标 label 仍显示 `running`，非目标 PID 保持 `48495`；程序未进入自动恢复。

## 根因

采样显示 Swift `runHealthProbeCycle` 的 utility 线程全部卡在 `RustCoreClient.status → tp_core_command`。当前 Rust `status_details_checked` 使用无超时的同步 `ProcessRunning.run` 执行 `/bin/launchctl print`；受管 SSH 冻结后该子调用没有返回，健康循环无法完成状态复核，也就无法进入 `recordHealthResult → scheduleRecovery`。

## 回滚与影响

- 由于自动恢复未能接管，按失败回滚边界人工发送一次 `SIGCONT`，目标 HTTP 立即恢复 `401`；该人工操作不计入无人值守通过。
- 未发送 `SIGTERM`/`SIGKILL`，未修改配置、plist、凭证、ECS 规则或远端资源；`reverse-ssh` 未被操作。

## 修复门禁

下一次验收前必须在真实系统 runner 中为 `launchctl print` 增加 2 秒硬超时；超时作为状态未知返回错误，禁止错误地视为 `notLoaded`，但允许上层健康循环继续累计失败并触发受管恢复。需补充 fake/真实 runner 的超时回归，再重建 Release App 并重新执行阶段 3。
