# ECS 动态 SSH 公网 IP 同步：阶段 0 写权限审查

日期：2026-08-29
性质：官方 RAM 授权模型的设计审查；不是写入授权、写接口调用或受控实跑证据。

## 已确认事实

- 用户确认 Workbench 可用，恢复通道通过。
- [AuthorizeSecurityGroup 官方授权信息](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-authorizesecuritygroup) 将 `ecs:AuthorizeSecurityGroup` 标为全部资源 `*`；可用条件键仅为 `ecs:SecurityGroupIpProtocols` 和 `ecs:SecurityGroupSourceCidrIps`。
- 该授权模型不能限制目标安全组，也不能限制 SSH 端口。动态来源地址随本机网络变化，不能用预先固定的来源 CIDR 作为可用的长期限制。
- [RevokeSecurityGroup 官方授权信息](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-revokesecuritygroup) 可精确授权到单个安全组，且官方建议按规则 ID 删除；但这不能降低新增规则接口的全资源权限。

## 用户确认的架构取舍

用户确认：不增加 FC 或其他中央受控执行器；改由新专用 RAM 身份在本机直接调用 ECS API，同步当前 SSH 来源 IPv4。用户接受 `ecs:AuthorizeSecurityGroup` 不能按目标安全组或 SSH 端口缩小的已知 IAM 范围。

这不等于该权限变成资源级最小权限。风险控制改由以下本机边界承担：固定受控目标、仅 TCP SSH、严格校验一个公网 IPv4 `/32`、规则描述归属、先新增并查询确认后才删除已验证的旧规则、唯一 `ClientToken`、本地互斥锁与 Workbench 恢复通道。

用户报告已保存策略修正：`AuthorizeSecurityGroup` 为全部资源范围，读取与 `RevokeSecurityGroup` 保持目标安全组范围。后续本机实跑已实际验证 `AuthorizeSecurityGroup` 可用，并新增后查询确认一条受管规则；详见[项目外受控实跑](ecs-dynamic-ssh-ip-stage0-controlled-run-20260829.md)。本次未调用 `RevokeSecurityGroup`，未删除既有规则。
