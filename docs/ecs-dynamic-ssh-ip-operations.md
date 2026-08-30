# ECS 动态 SSH 公网 IP 同步操作说明

本说明对应 [ECS 动态 SSH 公网 IP 同步计划](plans/ecs-dynamic-ssh-ip.md) 的阶段 1。命令是独立的本机前置工具，当前不会被 TunnelPad 启动链路自动调用。

## 首次准备

1. 将 `docs/examples/ecs-ssh-ip.env.example` 复制到仓库外的 `$HOME/.config/tunnelpad/ecs-ssh-ip.env`。
2. 填入仓库外的阿里云 CLI 配置路径、专用 profile、地域和目标安全组完整 ID。不要把 AccessKey、Secret 或该配置文件复制到仓库。
3. 确认本机已有 `curl`、`jq`、`aliyun`、`shasum` 和 `uuidgen`；目标 ECS 的恢复路径仍使用已配置的 Workbench CLI。

## 使用

只读检查（不会写安全组）：

```bash
scripts/update-ecs-ssh-ip --check
```

执行同步：

```bash
scripts/update-ecs-ssh-ip
```

脚本会请求两个中国直连 IPv4 端点。只有两端点返回同一个合法公网 IPv4 时，才会读取目标安全组，并精确识别描述为 `tunnelpad-dynamic-ssh-managed` 的 TCP `22/22` 入方向规则。规则轮换顺序固定为“新增当前 `/32`、查询确认、按旧规则 ID 撤销”；首次同步只新增并确认。

所有其他安全组规则都会保留。日志默认位于仓库外 `$HOME/.config/tunnelpad/ecs-ssh-ip.log`，只记录结果、地址哈希和脱敏规则标识，不记录原始 IP、完整资源 ID、凭证或私钥。

## 失败处理

| 退出码 | 含义 | 处理 |
|---:|---|---|
| 0 | 成功或已是最新；`--check` 读取成功 | 可继续 SSH |
| 2 | 参数、配置或依赖错误 | 检查仓库外配置和本机命令 |
| 3 | 探测失败、IPv4 无效或端点不一致 | 不会写安全组；确认代理/TUN 出口后重试 |
| 4 | 云端读取失败或受管规则多于一条 | 不会写安全组；先在控制台或 Workbench 检查规则归属 |
| 5 | 新增失败或新增后无法确认 | 旧规则保留；确认 profile 权限后重试 |
| 6 | 撤销旧规则失败或最终状态未收敛 | 新旧规则均保留；通过 Workbench 恢复/检查后再重试 |
| 7 | 本地锁冲突 | 确认没有其他同步进程后再重试 |

Workbench 是恢复通道，应按仓库 `AGENTS.md` 中的约定先用 `workbench list ecs` 确认地域和实例，再使用 `workbench connect` 或 `workbench exec`。它不承担本机内网穿透、通用端口转发、SFTP 或 IDE Remote SSH。
