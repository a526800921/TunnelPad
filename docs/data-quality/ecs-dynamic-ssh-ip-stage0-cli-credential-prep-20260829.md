# ECS 动态 SSH 公网 IP 同步：阶段 0 CLI 与凭证准备

日期：2026-08-29  
性质：本机 CLI 准备与凭证处理边界记录；不是身份、权限、安全组或受控实跑的通过证据。

## 范围与安全边界

- 用户确认已新建专用 RAM 用户并配置策略；此记录不将“已配置”视为实际最小权限验证通过。
- 未读取、复制、解析或导入现有 `AliyunECSFullAccess` 凭证 CSV。
- 对新 RAM 用户结果 CSV，先读取列名，随后在用户授权下仅在本机进程内解析一条数据行，尝试初始化隔离 profile；未输出或记录 AccessKey、Secret、密码、手机号、邮箱、账号 ID 或用户主体值。
- 未建立可用 CLI profile，未调用 STS、ECS、RAM 或安全组 API，未创建或修改任何云端资源或规则。
- CLI 配置如后续建立，必须位于仓库外并仅当前用户可读；凭证不得写入本仓库。

## 样本结果

| 样本 | 动作 | 结果 | 结论 |
|---|---|---|---|
| 阿里云 CLI | 通过 Homebrew 安装官方 `aliyun-cli` | 已安装 3.4.11 | 已具备阶段 0 的本机 CLI 前置条件。 |
| 新用户 CSV 结构 | 先查看首行列名，再在本机进程内解析一条数据行以尝试 profile 初始化 | 包含 `UserPrincipalName`、`AccessKeyId`、`AccessKeySecret` 等预期列；无值被输出或记录 | 可在得到目标 RegionId 后重新建立隔离 profile。 |
| profile 创建前置条件 | 用新 CSV 数据行尝试隔离 profile 初始化，再用临时假值验证官方 CLI 行为 | AK mode 必须提供 RegionId；在缺少默认 profile 时先建立自定义 profile 也会失败 | 未确认 RegionId 时未创建 profile，避免写入错误默认地域。 |
| 身份与云端读取 | 未执行 | 无 STS 或 ECS API 调用 | 专用身份、策略有效范围、安全组关联及规则现状均待验证。 |

## 未通过项与下一步

1. 用户提供目标 ECS 的 RegionId 与动态 SSH 安全组 ID（均不是凭证，也不写入仓库）。
2. 仅在本机用新专用凭证建立隔离 profile，并以 `sts GetCallerIdentity` 输出的脱敏结论验证 RAM 用户身份。
3. 用该 profile 对目标安全组执行只读 `DescribeSecurityGroupAttribute`；再检查网卡关联、宽泛 SSH 规则与 Workbench 恢复通道。
4. 上述只读基线全部通过前，继续禁止 `AuthorizeSecurityGroup`、`RevokeSecurityGroup` 和其他写操作。
