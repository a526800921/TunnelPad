# ECS 动态 SSH 公网 IP 更新方案

> 性质：设计方案，不是独立计划。当前仅记录思路、边界和推荐实现方式，不代表已经修改 ECS、安全组或 TunnelPad 代码。

## 1. 目标

本机公网 IPv4 发生变化后，自动更新阿里云 ECS 安全组中的 SSH 入方向规则，使普通 SSH 和 SSH 隧道仍能连接 ECS，同时避免每次手工登录阿里云控制台修改白名单。

本方案适用于以下场景：

- 本机通过普通 SSH 连接 ECS；
- 通过 SSH `-L` 访问 ECS 上仅监听回环地址的后台；
- 通过 SSH `-R` 建立反向开发隧道；
- 仍然需要使用 `ssh`、端口转发、SFTP 或 IDE Remote SSH 等标准 SSH 能力。

## 2. 与 Workbench、SSL-VPN 的关系

- Workbench 是 ECS 的备用连接通道，适合在公网 SSH 被安全组拦截时进入 ECS 修复配置；它不负责修改安全组，也不等价于普通 SSH 端口转发。
- 动态安全组方案继续使用公网 SSH，只把来源地址从旧公网 IP 更新为当前公网 IP。
- SSL-VPN 建立的是私网访问链路，不需要维护公网 IP 白名单，但需要额外的 VPN 网关和客户端配置。
- 推荐组合：日常使用动态安全组 + SSH，Workbench 作为故障恢复通道。

## 3. 推荐架构

### 3.1 使用单独的动态 SSH 安全组

推荐为 ECS 新建一个只用于 SSH 的安全组，并在其中只维护一条动态规则：

```text
协议：TCP
端口：22/22
来源：当前公网 IPv4/32
策略：accept
描述：tunnelpad-dynamic-ssh
```

应用安全组中原有的 80/443 等规则保持不动。脚本只操作这个专用安全组，不扫描或删除其他业务规则。

如果暂时不创建单独安全组，也必须给现有安全组中的动态规则设置唯一描述标记，例如 `tunnelpad-dynamic-ssh`，脚本只能操作带有该标记的规则。

### 3.2 脚本运行位置

脚本运行在本机 Mac，不运行在 ECS 上。原因是脚本要获取“本机对外显示的公网 IP”，而 ECS 上获取到的是 ECS 自己的公网 IP。

建议使用 Bash/zsh + 阿里云 CLI + `jq` 实现。脚本本身作为 TunnelPad 的外部辅助命令，后续可由 TunnelPad 在启动 SSH 隧道前调用。

## 4. 执行流程

```text
获取本机公网 IPv4
        ↓
严格校验格式、范围和 /32 CIDR
        ↓
查询专用安全组入方向规则
        ↓
当前动态规则已存在？——是——> 直接成功退出
        ↓ 否
新增当前 IP/32 规则
        ↓
重新查询并确认新规则已存在
        ↓
按规则 ID 删除旧的 tunnelpad-dynamic-ssh 规则
        ↓
允许 SSH 或 TunnelPad 继续启动隧道
```

阿里云 API 对应关系：

- `DescribeSecurityGroupAttribute`：查询安全组和规则；
- `AuthorizeSecurityGroup`：新增入方向规则；
- `RevokeSecurityGroup`：删除旧入方向规则。

阿里云文档说明，VPC 安全组的网卡类型应使用 `intranet`；删除规则时优先使用返回的 `SecurityGroupRuleId`，不要使用模糊条件删除。[查询安全组规则](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describesecuritygroupattribute)、[新增入方向规则](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-authorizesecuritygroup/)、[删除入方向规则](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-revokesecuritygroup)

## 5. 安全和失败边界

### 5.1 必须遵守的安全规则

- 只接受一个合法的公网 IPv4，并转换成 `x.x.x.x/32`；获取到私网地址、IPv6、空值或异常响应时不改安全组。
- 先新增当前规则，再删除旧规则，避免更新中途失去 SSH 入口。
- 只删除描述完全匹配的动态规则；绝不按“所有 22 端口规则”删除。
- 使用本地锁，防止多个定时任务同时更新安全组。
- 日志只记录地域、安全组 ID 的脱敏值、当前 IP、规则 ID 和请求结果，不记录 AccessKey Secret、私钥或完整凭证。
- 如果新增失败，保留旧规则；如果删除旧规则失败，保留新旧两条规则并报警，不能为了清理旧规则而删除新规则。

### 5.2 现有宽泛规则的处理

如果当前某个已关联安全组中仍有 `TCP 22 / 0.0.0.0/0`，动态规则不会产生实际的安全限制。实施前需要人工确认并关闭这条宽泛规则；脚本不能自动删除未知来源的规则。

### 5.3 Workbench 作为恢复手段

当脚本误配、RAM 权限失效或公网 IP 服务不可用时，通过 Workbench 进入 ECS，恢复安全组规则或检查 SSH 服务。这样动态白名单脚本不会成为唯一管理入口。

## 6. 凭证方案

不要让脚本复用具备 `AliyunECSFullAccess` 的长期高权限身份。建议创建专用 RAM 用户或专用凭证，只用于动态 SSH 安全组。

脚本通常只需要以下动作：

- `ecs:DescribeSecurityGroupAttribute`；
- `ecs:AuthorizeSecurityGroup`；
- `ecs:RevokeSecurityGroup`。

如果脚本通过实例 ID 自动发现安全组，还需要 `ecs:DescribeInstances`；更简单、更稳定的方式是把安全组 ID作为本地配置，而不是每次自动发现。

凭证只保存在本机阿里云 CLI 的凭证配置或外部凭证命令中，不放入 TunnelPad 仓库、配置样例、日志或提交。`AliyunECSFullAccess` 可以暂时用于验证，但正式使用前应换成专用最小权限身份。阿里云也提供了通过条件限制高危安全组规则的方式，例如禁止创建 `0.0.0.0/0` 来源规则。[安全组 RAM 权限限制](https://help.aliyun.com/zh/ecs/user-guide/prohibit-ram-users-from-creating-high-risk-security-group-rules)

## 7. 自动触发方式

### 推荐：SSH 前置同步

在执行 SSH 或启动隧道前调用一次更新脚本：

```text
更新安全组公网 IP
  → 成功后执行 ssh
  → 失败则不启动隧道，并提示使用 Workbench
```

这种方式不会长期在后台运行，也不会在网络切换时频繁调用 ECS API，适合个人使用。

### 可选：macOS launchd 定时执行

如果希望完全自动，可用 `launchd` 每 5～10 分钟执行一次。脚本必须具备幂等性：当前 IP 没有变化时不调用新增/删除接口。

不建议第一版直接在 TunnelPad UI 中保存或管理阿里云 AccessKey。UI 集成应只负责调用外部同步脚本，或改用 macOS Keychain/外部凭证命令，避免把云凭证放进 TunnelPad 的普通 JSON 配置。

## 8. 与 TunnelPad 的结合方式

当前 TunnelPad v1 只管理 SSH 隧道生命周期，不直接管理 ECS 资源。因此推荐分两层：

1. 独立的 `update-ecs-ssh-ip` 辅助命令负责安全组同步；
2. TunnelPad 启动隧道前调用该辅助命令，成功后再启动 SSH。

第一版也可以先手工执行同步命令，再由 TunnelPad 启动隧道。后续如果需要 UI 集成，再增加“同步公网 IP”按钮和启动前置检查，但这属于凭证管理和 TunnelPad 配置模型的扩展。

## 9. 本地配置示意

配置应放在仓库外，例如 `~/.config/tunnelpad/ecs-ssh-ip.env`，只保存非秘密参数：

```text
ALIBABA_REGION_ID=cn-chengdu
ECS_SECURITY_GROUP_ID=<专用动态 SSH 安全组 ID>
SSH_RULE_DESCRIPTION=tunnelpad-dynamic-ssh
PUBLIC_IP_ENDPOINT=https://api.ipify.org
SSH_PORT=22
```

不把实例公网 IP、AccessKey、Secret、SSH 私钥内容写入仓库。安全组 ID可以作为本机配置项保存；如果脚本通过实例 ID发现安全组，则实例 ID同样只放在本机配置中。

## 10. 结论

当前推荐落地顺序是：

1. 确认 ECS 当前关联的安全组和 22 端口规则；
2. 创建或选定专用动态 SSH 安全组；
3. 用专用 RAM 凭证验证查询、新增、删除三类 API；
4. 实现“先新增、后删除、失败保留旧规则”的本机脚本；
5. 先作为 SSH/TunnelPad 启动前置命令使用；
6. 稳定后再考虑用 launchd 定时执行或接入 TunnelPad UI。

该方案不新增 SSL-VPN 网关，保留普通 SSH、端口转发和现有 TunnelPad 使用方式；Workbench 作为安全恢复通道继续保留。
