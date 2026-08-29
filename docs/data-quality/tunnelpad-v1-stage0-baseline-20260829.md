# TunnelPad v1 阶段 0 迁移基线快照（2026-08-29）

- 采集时间：2026-08-29 16:12–16:17 CST
- 采集环境：macOS（darwin 25.6.0 arm64），用户 `jafish`（`id -u` = 501，launchd 域 `gui/501`）
- 采集者：ZCode Agent（实施轮次）
- 性质：**只读观察**。未修改、未重启、未停止任何现有服务；未读取任何私钥内容。
- 脱敏说明：按 TunnelPad 仓库敏感信息红线（ECS 地址不入仓库），本文档中 ECS 主机地址统一脱敏为 `<ECS>`；真实地址见磁盘上的 plist 原文与 motorcycle-manual-app 仓库 `infra/production/ssh_config`（本仓库只引用路径）。

## 结论摘要

样本矩阵四项全部符合预期：两条 launchd agent 均已加载且 `state = running`，program 为 `/usr/bin/ssh`；admin 隧道回环探测返回 `401`（HTTP Basic 生效）；ECS 侧反向隧道监听 `127.0.0.1:22022` 存在。无阻塞项，基线可用于阶段 1 迁移设计。

## 样本矩阵执行结果

对应专项计划"Step 0 证据"样本矩阵，逐行实测：

| # | 命令 | 预期结果 | 实际结果 | 判定 |
|---|---|---|---|---|
| 1 | `launchctl print gui/$(id -u)/com.jafish.motorcycle-manual.admin-tunnel` | agent 存在且 program 为 ssh | 退出码 0；`state = running`，`program = /usr/bin/ssh`，`pid = 73448`，`runs = 2`，`last exit code = 0`，`properties = keepalive \| runatload \| inferred program` | 通过 |
| 2 | `curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/admin` | `401` | 输出 `401`，退出码 0 | 通过 |
| 3 | `launchctl print gui/$(id -u)/com.jafish.motorcycle-manual.reverse-ssh` | agent 存在且 program 为 ssh | 退出码 0；`state = running`，`program = /usr/bin/ssh`，`pid = 8664`，`runs = 7126`，`last exit code = 255`，`properties = keepalive \| runatload \| inferred program` | 通过 |
| 4 | `ssh -F /Users/jafish/Documents/work/motorcycle-manual-app/infra/production/ssh_config motorcycle-manual-prod 'ss -tln \| grep 22022'` | LISTEN `127.0.0.1:22022` | `LISTEN 0  128  127.0.0.1:22022  0.0.0.0:*`，退出码 0（stderr 另有 OpenSSH 后量子密钥交换 WARNING，与隧道功能无关） | 通过 |

命令 2 说明：本机配置了系统代理，回环探测必须加 `--noproxy '*'`，否则会被系统代理拦截（计划与交接均已有此提示，实测确认）。

## admin-tunnel 基线

### plist 原文

来源：`/Users/jafish/Library/LaunchAgents/com.jafish.motorcycle-manual.admin-tunnel.plist`（仓库外，只读读取）。`root@47.109.202.254` 按红线脱敏为 `root@<ECS>`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jafish.motorcycle-manual.admin-tunnel</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-i</string>
        <string>/Users/jafish/.ssh/motorcycle-manual-admin.pem</string>
        <string>-o</string>
        <string>IdentitiesOnly=yes</string>
        <string>-o</string>
        <string>BatchMode=yes</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>ConnectTimeout=10</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=accept-new</string>
        <string>-N</string>
        <string>-T</string>
        <string>-L</string>
        <string>127.0.0.1:8081:127.0.0.1:8081</string>
        <string>root@<ECS></string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>/Users/jafish/Library/Logs/motorcycle-manual-admin-tunnel.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/jafish/Library/Logs/motorcycle-manual-admin-tunnel.log</string>
</dict>
</plist>
```

### launchctl 运行状态（关键字段）

- `state = running`，`pid = 73448`（2026-08-29 15:38 启动，`ps` 证实），`runs = 2`，`last exit code = 0`
- `properties = keepalive | runatload | inferred program`；`minimum runtime = 10`（对应 plist `ThrottleInterval=10`）
- stdout/stderr 同写 `/Users/jafish/Library/Logs/motorcycle-manual-admin-tunnel.log`

### 日志观察（只读）

日志尾部有多条 `Can't open user config file /Users/jafish/Documents/work/motorcycle-manual-app/infra/production/ssh_config: Operation not permitted`，文件 mtime 为 2026-08-29 15:37:38；而当前磁盘 plist 与实时进程参数（`ps` 核对）均不含 `-F`，且 15:38 启动后无新增报错。即：历史某版 plist 曾让 launchd 下的 ssh 读取 `~/Documents` 内 ssh_config，被 macOS TCC 拒绝，后续版本已移除该参数。这正面印证了计划不变量"launchd 执行器引用的路径必须避开 `~/Documents`"。

## reverse-ssh 基线

### plist 原文

来源：`/Users/jafish/Library/LaunchAgents/com.jafish.motorcycle-manual.reverse-ssh.plist`（仓库外，只读读取）。ECS 地址同样脱敏：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jafish.motorcycle-manual.reverse-ssh</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-i</string>
        <string>/Users/jafish/.ssh/motorcycle-manual-prod.pem</string>
        <string>-o</string>
        <string>BatchMode=yes</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>IdentitiesOnly=yes</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=accept-new</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-N</string>
        <string>-T</string>
        <string>-R</string>
        <string>127.0.0.1:22022:127.0.0.1:22</string>
        <string>root@<ECS></string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>15</integer>

    <key>StandardOutPath</key>
    <string>/Users/jafish/Library/Logs/motorcycle-manual-reverse-ssh.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/jafish/Library/Logs/motorcycle-manual-reverse-ssh.error.log</string>
</dict>
</plist>
```

### launchctl 运行状态（关键字段）

- `state = running`，`pid = 8664`（`ps` 显示启动于 2026-08-28 20:16），`runs = 7126`，`last exit code = 255`
- `properties = keepalive | runatload | inferred program`；`minimum runtime = 15`（对应 `ThrottleInterval=15`）
- stdout `/Users/jafish/Library/Logs/motorcycle-manual-reverse-ssh.log`（0 字节）；stderr `/Users/jafish/Library/Logs/motorcycle-manual-reverse-ssh.error.log`

### 日志观察（只读）

`reverse-ssh.error.log` 累计约 381 KB，内容为大量重复的 `Connection closed by <ECS> port 22`，与 `runs = 7126`、`last exit code = 255` 相互印证：该隧道历史上长期处于"断开 → launchd KeepAlive 重拉"循环；最近一次重连发生在 2026-08-28 20:16（error.log mtime 2026-08-28 20:15:55），此后约 20 小时保持稳定，当前连接可用（样本 4 通过）。这为阶段 1 验收项"杀 ssh 进程 → launchd 秒级自动重连"提供了现状参照：KeepAlive 重拉机制真实生效，但重连节奏受 `ThrottleInterval=15` 约束。

## 密钥文件存在性（不读内容）

| 文件 | 存在 | 权限 |
|---|---|---|
| `/Users/jafish/.ssh/motorcycle-manual-admin.pem` | 是 | 600 |
| `/Users/jafish/.ssh/motorcycle-manual-prod.pem` | 是 | 600 |

两个路径均在 `~/.ssh` 下，符合"TCC 限制路径之外"的不变量要求。

## 对阶段 1 迁移设计的输入

1. **命令等价**：迁移导入必须按 plist `ProgramArguments` 原样生成命令（含选项顺序），不要"规范化"。两条隧道的选项集合并不相同：admin-tunnel 多 `ConnectTimeout=10`，reverse-ssh 无 ConnectTimeout；选项排列顺序也不同。
2. **KeepAlive/RunAtLoad/ThrottleInterval**：现状为 `KeepAlive=true`、`RunAtLoad=true`，ThrottleInterval 分别为 10/15。TunnelPad launchd 执行器生成 plist 时需决定承接语义（阶段 1 准入时定义 schema 字段）。
3. **日志路径**：现状在 `~/Library/Logs/`，admin-tunnel stdout/stderr 同文件、reverse-ssh 分文件。TunnelPad 生成的 plist 日志路径放哪里（沿用 `~/Library/Logs` 还是 TunnelPad Application Support 内）是阶段 1 schema 决策点。
4. **标签**：旧标签 `com.jafish.motorcycle-manual.*`，接管后新标签 `com.jafish.tunnelpad.<tunnel-id>`；bootout 旧 agent 前必须原样备份两个 plist（回滚边界见专项计划）。
5. **`runs = 7126` 说明**：reverse-ssh 长期高频重拉，迁移后首次验收"杀进程自动重连"时，重连延迟下限受 ThrottleInterval 影响，验收口径按计划"秒级"评估。

## 阻塞项

无。阶段 0 全部采集项完成且符合预期。
