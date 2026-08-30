# ECS 动态 SSH 公网 IP 同步：阶段 1 实现与验证

日期：2026-08-29
性质：仓库内独立命令的实现证据；不包含 AccessKey、Secret、私钥、原始公网 IP、完整安全组/实例标识或完整规则 ID。

## 实现范围

- 新增 `scripts/update-ecs-ssh-ip`，保持与 TunnelPad UI、`config.json`、启动流程和 launchd 隔离。
- 默认从仓库外 `$HOME/.config/tunnelpad/ecs-ssh-ip.env` 读取非秘密参数，并使用仓库外的专用阿里云 CLI profile。
- 两个阶段 0 已验证的中国直连 IPv4 端点必须返回同一个合法公网 IPv4；否则退出且不调用云端。
- 只管理描述精确为 `tunnelpad-dynamic-ssh-managed` 的入方向 TCP `22/22`、`accept`、`intranet` 规则；所有其他规则保留。
- 规则变更固定为“新增当前 `/32` → 查询确认 → 按旧规则 ID 撤销”，本地 `mkdir` 锁防止并发；日志仅保存地址/资源/规则哈希与状态。
- `--check` 只探测和读取安全组，不执行写操作。

## 可重复 fixture 验证

命令：

```bash
Tests/update-ecs-ssh-ip-test.sh
```

结果：14 个场景全部通过：

1. 当前受管规则幂等；
2. 双端点不一致停止；
3. 私网 IPv4 拒绝；
4. 没有受管规则时首次新增；
5. 旧规则先增后删轮换；
6. 新增响应异常时重新查询并收敛；
7. 新增失败保留旧规则；
8. 撤销失败保留新旧规则；
9. 撤销响应异常时重新查询并收敛；
10. 多条受管规则歧义停止；
11. 云端读取失败停止；
12. 本地锁冲突停止；
13. profile 配置缺失停止；
14. `--check` 只读。

fixture 使用合成 IP、临时配置和模拟 ECS 响应，不调用真实云端。日志断言确认未写入原始 IP；轮换断言确认非受管规则未被删除，撤销参数使用已查询的旧规则 ID；未知新增响应场景确认脚本会重新读取而不是直接假定写入失败。

## 真实只读回归

- 先执行 `workbench list ecs --region cn-chengdu --output json`，确认目标地域存在 1 个运行中 ECS；实例标识不写入本证据。
- 使用仓库外专用 profile 和目标安全组执行：

  ```bash
  scripts/update-ecs-ssh-ip --check
  ```

- 结果：退出码 `0`，双端点探测和安全组读取均成功；终端明确返回“未执行写操作”。本次未调用 `AuthorizeSecurityGroup` 或 `RevokeSecurityGroup`。

## TunnelPad 回归

```bash
swift test
```

结果：现有 Swift 测试 55 项全部通过；阶段 1 未修改 TunnelPad Swift 实现或配置 schema。

## 阶段 1 结论

实现、外部配置示例、操作说明和合成 fixture 已齐备，行为边界与阶段 0 受控实跑一致；现有 Swift 测试也未受影响。阶段 1 尚未接入 TunnelPad 启动链路；阶段 1 独立准入复核已基于仓库内容、测试输出和本次只读回归确认通过，后续阶段需另行准入。
