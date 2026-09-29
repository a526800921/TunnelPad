# TunnelPad 自动恢复清理 SSH 选项修复（2026-09-29）

## 结论

清理器现在能安全处理 TunnelPad 实际 SSH 命令中的 `UserKnownHostsFile`、`GlobalKnownHostsFile` 与 `ConnectTimeout`。此前解析器不接受这些选项，清理前置步骤因此以 `ecs_local_cleanup_command_unsupported` 中止，自动恢复无法继续。代码、测试和 Release App 已构建通过；Mac mini 更新及运行验收待完成。

## 故障证据

- Mac mini 的配置启用了自动启动和恢复前强制清理远端 `-R` 端口。
- 当前 SSH 命令包含 `UserKnownHostsFile`、`GlobalKnownHostsFile`、`ConnectTimeout`，以及 `BatchMode`、`StrictHostKeyChecking`、`ServerAliveInterval` 等已支持选项。脱敏只读检查确认：用户级名单为引号包围的含空格路径，目标是可写普通文件且父目录可写；全局名单使用 `/dev/null`；超时是整数。这里只记录形状，不记录用户路径或其余选项值。
- 日志中曾出现 `ecs_local_cleanup_command_unsupported`；受限解析失败后，清理按 fail-closed 规则中止，不会跳过清理而启动新 SSH。
- 检查时 Mac mini 当前隧道状态为运行中。这表示该次状态快照下服务已恢复，不抵消此前清理解析失败的记录。

## 修复范围

- `SSHCommand.remotePortCleanupTarget` 按 OpenSSH 引号和空白规则解析 known-hosts 路径列表，并在清理 SSH 参数中原样传递。含空格的引号路径受支持；反斜线、未闭合引号、OpenSSH `%` token 与环境变量展开拒绝，避免路径校验与 SSH 实际读取位置不一致。
- 用户级名单中的 `none`、词法规范化后指向 `/dev/null` 的路径，以及已有的非普通文件均拒绝。符号链接会解析后检查目标：指向普通文件的链接可用，指向设备或悬空的链接拒绝。显式用户级名单至少需要一个可写普通文件，或一个父目录可写的新文件目标。
- 可写性门槛检查用户名单的**首项**，因为 OpenSSH 将 `accept-new` 新主机密钥写入首个用户级 known-hosts 文件；后续项可写不能弥补首项无法持久保存的问题。真实 Mini 首项是可写普通文件，父目录也可写。
- 全局名单只读；按 Mac mini 现有配置允许 `/dev/null`，但不能关闭用户级持久记录。OpenSSH 的 built-in 用户级默认仍受 `accept-new` 保护。
- `ConnectTimeout` 只接受非负整数用于配置形状校验，不传递原值；清理连接仍固定使用 8 秒，并受最多 10 秒的外层进程期限约束。
- SSH 参数继续采用默认拒绝。`ProxyCommand`、`KnownHostsCommand`、`ControlMaster`、`ControlPath`、`ControlPersist` 和其他未列入允许表的参数仍会被拒绝。
- 主机密钥验证继续使用 `accept-new` 或显式 `yes`。OpenSSH 文档说明 `accept-new` 会记录新密钥并拒绝已知主机的密钥变更，`UserKnownHostsFile=none` 会忽略用户 known-hosts 文件：[OpenBSD ssh_config(5)](https://man.openbsd.org/ssh_config.5)。

## 影响与独立复核

- 修改前 GitNexus 对 `SSHCommand.remotePortCleanupTarget` 的上游影响为 `MEDIUM`，结果精确：5 个直接调用者、2 条受影响流程，涉及 `cleanupRemotePort` 与 `remotePortCleanupResource`。
- 初次独立安全复核指出 `none` 与 `/dev/null` 可关闭持久主机密钥记录。现已拒绝这些值、增加路径规范化和文件类型检查，并覆盖对应回归用例。
- 独立复核确认已无阻断项。校验路径与 SSH 打开文件之间仍存在短暂 TOCTOU 窗口；它要求本机另一个进程能在这段时间替换文件路径。不存在的新目标文件仍需允许，以支持首次写入。

## 自动化验证

| 验证项 | 结果 |
|---|---|
| `SSHCommandTests` | 主机密钥文件安全边界、设备/普通/悬空符号链接，以及 SSH 复用和危险选项拒绝均有覆盖 |
| `TunnelPadCoreTests` | 227 项通过，0 失败，1 项跳过 |
| Release App 构建 | `arm64` Release 构建、Info.plist 检查、ad-hoc 签名和签名校验通过；可执行文件 SHA-256：`e53b4db3100d03f81101079bd3beb3d1ee5416f478bbf8db74b45d25a0b24a72` |
| `git diff --check` | 通过 |
| GitNexus `detect_changes(scope: all)` | 完整结果：28 个变更符号、8 个受影响流程、5 个源码/文档文件，风险级别 `HIGH`；受影响流程集中在远端端口清理。独立复核已确认本次修补无阻断项 |
| `plan-governance-cli check . --strict-readiness` | 通过 |

## Mac mini 部署与验收

Mac mini 部署前预检已通过：远端源码工作区干净、分支为 `main`，HEAD 为 `53a8a2c`；旧 App 的 `/api/health` 正常，1 条隧道状态为 `running`。旧 App 已完整备份到 `/tmp/TunnelPad.app.pre-ssh-options-20260929`，备份可执行文件 SHA-256 为 `d7054b4788c4b505aa0eb67383f0a4d44608203d7e8dc9103b1d7a318d583c8d`。代码推送后，在保留该副本的前提下受控退出旧 App，再从更新后的 `dist/TunnelPad.app` 启动。退出旧 App 会短暂停止由它管理的隧道。验收记录至少包括：新进程使用已发布构建、自动恢复日志不再出现该解析拒绝事件、API 与隧道状态恢复为运行中。配置保持原样，不输出选项值。

## 回滚

- 发布前保留 Mac mini 原有 `TunnelPad.app` 副本；若新版本启动或隧道验收失败，恢复该副本并记录失败证据。
- 代码回滚可恢复到本次提交之前的版本；不会修改 SSH 配置、known-hosts 内容或 ECS 设置。
