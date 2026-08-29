# ECS 动态 SSH 公网 IP 同步：阶段 0 本机预检

日期：2026-08-29  
性质：只读本机配置与工具基线；不是云端安全组验证或项目外受控实跑证据。

## 范围与安全边界

- 未读取、复制或解析现有 `AliyunECSFullAccess` 凭证 CSV。
- 未连接 ECS，未调用阿里云 API，未创建或修改 RAM 用户、AccessKey、安全组或规则。
- 未输出主机地址、用户、密钥路径、账户 ID、安全组 ID、实例 ID 或公网 IP。

## 样本结果

| 样本 | 只读命令或动作 | 结果 | 结论 |
|---|---|---|---|
| 目标 SSH 配置来源 | 检查现有生产 SSH 配置文件是否存在，并仅列出 `Host` 声明 | 存在一个目标别名：`motorcycle-manual-prod` | 后续阶段 0 使用该别名做配置与实连验证。 |
| 跳板/代理配置 | `ssh -G -F <现有生产 SSH 配置> motorcycle-manual-prod`，仅抽取 `proxyjump` 与 `proxycommand` | 两项均未输出 | 配置层未发现跳板或代理指令；尚非实际网络路径证明，受控实跑时必须执行 SSH 实连。 |
| OpenSSH | `ssh -V` | OpenSSH 10.3p1 / LibreSSL 3.3.6 | 已可执行后续 `ssh -G` 与 SSH 实连验证。 |
| JSON 工具 | `command -v jq` | `/usr/bin/jq` | 已满足后续脚本解析依赖之一。 |
| 阿里云 CLI | `command -v aliyun` | 未找到 | 阶段 0 云端验证前需要安装；当前未安装任何依赖。 |

## 未通过项与下一步

1. 新专用 RAM 身份、其最小权限策略与命名 CLI profile 尚未建立。
2. 尚未确定受控实跑的地域、专用动态 SSH 安全组和 Workbench 恢复路径。
3. 尚未读取云端规则，故尚未确认安全组关联关系、宽泛 SSH 规则或实际公网出站 IP。
4. 在上述项完成前，不得调用任何安全组写接口。
