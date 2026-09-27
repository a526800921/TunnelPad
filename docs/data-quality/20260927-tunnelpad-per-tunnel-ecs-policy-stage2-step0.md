# 逐隧道 ECS 策略阶段 2 Step 0（2026-09-27）

## 本次授权与目标

用户明确要求继续推进，并指定**仅 `motorcycle` 需要手动启用 ECS 同步**，随后授权部署，确认本次目标为 MacBook。当前配置中的精确 ID 为 `motorcycle-local-docker`。本次只部署 MacBook；Mac mini 保持原空配置应用，不迁移隧道。部署时仅给该 ID 写入 `ecsSyncPolicy: required`，其他旧项保留缺字段并按新语义视为 `disabled`。

本次授权覆盖受控 App 替换与上述配置迁移。当前三条受管隧道均未加载；部署不主动启动它们，也不以真实 ECS 写入作为关闭项验收手段。若后续单独启动 `motorcycle-local-docker`，会按 `required` 执行既有 ECS 前置和其已配置的远端端口清理。

## 可观察基线

- 当前主机 `MacBook.local`，arm64；运行中的 App PID 3333，来自项目 `dist/TunnelPad.app`。Mac mini `10.0.0.2:9998` 的 API 健康检查成功，隧道列表为空，但不在此次替换范围。
- MacBook `/api/tunnels` 中 `admin-tunnel`、`reverse-ssh`、`motorcycle-local-docker` 全部为 `not_loaded`；对应三个精确 launchd label 均返回未加载（`launchctl print` 退出码 113）。
- 当前 `config.json` 权限 `0600`，三项均缺 `ecsSyncPolicy`；`motorcycle-local-docker` 的 `forceRemotePortCleanup=true`、`autoStart=false`、`keepAlive=true`。ECS 环境文件存在，未读取或记录凭据内容。
- 阶段 1 Swift 221/221 通过、1 跳过，Rust 99+6+1+7 通过；独立复核四项发现已修复自验。独立目录 `/tmp/tunnelpad-ecs-policy-stage2.LnLhIF/TunnelPad.app` 的 Rust/Swift Release 构建、ad-hoc 签名与严格校验通过；主 App 尚未替换。

## 执行样本与失败边界

1. 先备份原 App 和 `config.json`，记录哈希/权限；替换前再次确认三条受管 label 未加载。旧 App 正常退出并确认 PID 消失后，才替换原路径，防止边运行边覆盖。
2. 仅在备份后原位原子更新 `motorcycle-local-docker` 字段为 `required`；其他配置条目不改变，保持 `0600`。候选配置的 ID 集合、策略和 JSON 类型须复核。
3. 启动新 App，验证实际进程路径和唯一实例、`/api/health`、三条隧道状态、配置策略、API 监听地址、签名与 ABI 2。普通 SSH 在无 ECS 操作条件下仍可手动启动/停止时才算体验验证；若测试会影响既有业务，则单独记录未执行，不伪报通过。
4. 本轮不主动启动 `motorcycle-local-docker`，因此 required 的真实 ECS 写入和远端清理不属于本次通过结论；保留阶段 1 桩测试证据，后续真实连接验收另行记录。
5. 任一步失败即停，保留失败证据；若新版已启动则先正常退出，再恢复备份 App 与配置，确认三条 label 均未加载。旧版会对所有 SSH 执行 ECS 前置，所以不能在旧版下启动普通 SSH 来冒充回滚成功。不得删除 ECS journal 或安全组规则。

## 进入结论

三条受管隧道和精确 label 已确认未加载，隔离 Release 产物已签名校验；本机部署目标和唯一 required 项明确。按受控替换继续，真实 ECS 写入保持未授权且未执行。
