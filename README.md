# TunnelPad

TunnelPad 是一个 macOS 菜单栏应用，用于统一管理本机与服务器之间的 SSH 隧道：启动、停止、重启、状态查看、日志查看、配置刷新和旧 LaunchAgent 接管。

## 当前状态

- v1 隧道管理、菜单栏入口、`launchd` 生命周期、配置 v1 和 Rust Core 迁移已完成。
- ECS 动态 SSH 公网 IP 同步能力已完成；当前源码按每条隧道的 `ecsSyncPolicy` 决定是否在连接前同步，缺字段的旧配置按 `disabled` 处理。新策略的 Release 与真实环境验收见当前专项计划。
- 无人值守 SSH 异常恢复与 ECS IP 漂移恢复已完成：受管 SSH 断线、launchd 状态异常或 PID 变化后先收敛旧实例；仅 `required` 项校验/同步 ECS `/32`，再按需清理远端排他转发端口并重连。
- 稳定性与健康恢复、日志事件流、日志保留与低写放大、后台健康监测能耗、无人值守受管 SSH 收敛恢复以及 Rust Core 风险收敛计划均已完成。
- 当前生产执行器和自动恢复范围固定为 `launchd`；`app` 执行器仍是非目标，未来另立计划。
- 日志优化已完成：正常追加采用增量采集，持久日志达到约 512 KiB 后才批量压缩，压缩后保留最近 2000 个逻辑行；正常 SSH 默认不带独立 `-v`，详细日志可按需开启。
- HTTP API 默认绑定 `127.0.0.1:9998`，可显式启用受限局域网访问；提供隧道状态、启停、重启和日志接口，不提供配置写入或 ECS API。
- 计划状态与阶段依赖以 [`docs/PLAN_MAP.md`](docs/PLAN_MAP.md) 为准。

## 主要能力

- 菜单栏和主窗口管理多条 `launchd` SSH 隧道。
- Rust Core 作为配置、生命周期、运行时状态、并发和退出清理的唯一 owner；SwiftUI/AppKit 负责界面和 FFI 适配。
- HTTP 探针检查并展示隧道健康结果；`launchd` 范围内的后台健康恢复和资源收敛已完成。
- 对 `autoStart + keepAlive` 的 SSH 隧道持续观察 launchd 生命周期；断线、退出或 PID 变化后执行“bootout 收敛 → ECS 前置（仅 `required`）→ 远端端口清理（如启用）→ 启动”恢复链。
- 自动恢复按 `0、5、10、30、60、60…` 秒退避持续重试，不因历史尝试次数耗尽而永久停止；连续两次健康确认后才清零失败历史，用户手动停止则取消自动恢复。
- 本机代理和 SSH 按受管身份、进程组与代次收敛；日志代理异常、I/O 失败和信号退出也必须回收子 SSH。逐隧道 `forceRemotePortCleanup` 默认关闭，只有明确声明远端转发端口为排他资源时才启用。
- 以事件流和增量采集更新日志；面板关闭期间仍保留每条隧道最近 500 条内存日志，持久文件在压缩后保留最近 2000 个逻辑行。
- 通过本机 HTTP API 对外提供受控的状态、生命周期和日志调用。
- 接管旧版 LaunchAgent，提供备份与失败回滚边界。
- 只有 SSH 命令且 `ecsSyncPolicy` 为 `required` 时，启动/重启前才执行 ECS 动态 IP 同步。
- 支持登录自启动（`SMAppService`）与按隧道的「随 App 启动自动拉起」；启动恢复全过程写入 `~/Library/Logs/TunnelPad/app.log`。

## 架构边界

当前生产执行器只有 `launchd`。生成的 plist 位于：

```text
~/Library/Application Support/TunnelPad/launchd/
```

配置和日志默认位于：

```text
~/Library/Application Support/TunnelPad/config.json
~/Library/Logs/TunnelPad/
```

App 退出时会停止由 TunnelPad 管理的 `launchd` 隧道。`config.json` 继续使用 version `1`，不保存 ECS 凭证、私钥或公网 IP。

## 本机 HTTP API

API 服务随 TunnelPad App 启停，默认只监听 `127.0.0.1:9998`。端口被占用时记录启动错误并继续运行 App，不换端口、不重试；App 退出时 API 服务停止。

### 可选：可信局域网直连

在 `~/Library/Application Support/TunnelPad/api.json` 中显式设置监听地址和客户端白名单，重启 App 后生效（退出会停止该 App 管理的隧道，请先确认影响）：

```json
{
  "host": "10.0.0.2",
  "allowedClientIPs": ["10.0.0.30"]
}
```

此例同时监听 `10.0.0.2:9998` 和 `127.0.0.1:9998`，远程只允许源地址 `10.0.0.30`，本机回环仍可用。可在客户端访问 `http://10.0.0.2:9998/api/health`。建议在路由器为两台设备保留 DHCP 地址。

`api.json` 必须且仅包含上述两项；仅支持规范的 RFC1918 IPv4，白名单不能为空（回环模式除外），不接受通配地址、CIDR、公网地址或主机名。缺少文件使用回环默认值；配置损坏、读取失败或任一监听地址绑定失败时停用 API，不自动扩大权限或更换端口。恢复默认可将 `host` 改为 `127.0.0.1`、`allowedClientIPs` 改为空数组，再重启 App。

所有路由在调用 backend 前校验实际 socket 来源和 `Host`，不采信 `Forwarded` / `X-Forwarded-For`；带 `Origin` 或 `Sec-Fetch-Site: cross-site` 的请求被拒绝，不支持跨站网页调用。拒绝返回 `403 access_denied`；全部监听尚未就绪时返回 `503 service_unavailable`，不执行业务操作。OpenAPI 使用相对服务地址 `/`，适用于回环与局域网入口。

这是 **IP 来源限制，不是密码认证，也没有 TLS 加密**。只用于可信局域网；共享/不可信网络应另用加密认证通道，不得映射到公网。允许的 IP 被其他设备占用后也会获得访问能力。来源限制不会覆盖逐隧道 ECS 策略或更改隧道生命周期。

接口清单：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/health` | API 健康检查 |
| `GET` | `/api/tunnels` | 隧道列表和安全摘要 |
| `GET` | `/api/tunnels/{id}` | 隧道详情 |
| `POST` | `/api/tunnels/{id}/start` | 启动隧道 |
| `POST` | `/api/tunnels/{id}/stop` | 停止隧道 |
| `POST` | `/api/tunnels/{id}/restart` | 重启隧道 |
| `GET` | `/api/tunnels/{id}/logs` | 读取日志纯文本快照 |
| `POST` | `/api/tunnels/{id}/logs/clear` | 清空日志快照 |
| `GET` | `/openapi.json` | 获取 OpenAPI 描述 |

示例：

```bash
curl http://127.0.0.1:9998/api/health
curl http://127.0.0.1:9998/api/tunnels
curl -X POST http://127.0.0.1:9998/api/tunnels/admin-tunnel/start
curl http://127.0.0.1:9998/api/tunnels/admin-tunnel/logs
```

启停请求会等待底层操作完成后返回；隧道不存在返回 `404`，已有操作进行中返回 `409`，失败和超时会返回明确错误。隧道列表、详情和操作响应只返回状态、PID、探针结果等安全摘要，不返回命令、探针 URL、本地路径、环境变量、密钥或完整错误中的本地敏感信息；日志接口单独返回对应隧道的有界纯文本快照。

## 构建与测试

要求 macOS 14 或更高版本，并准备 Swift 6、Rust/Cargo 和 Xcode Command Line Tools。

```bash
swift test
cargo test --manifest-path rust/Cargo.toml
./scripts/build_app.sh
open dist/TunnelPad.app
```

`build_app.sh` 会构建 Rust 动态库、运行 Swift 测试、构建 release App、复制图标和 ECS 同步脚本，并执行 ad-hoc 签名校验。仅跳过测试时可使用：

```bash
./scripts/build_app.sh --skip-tests
```

## ECS 动态 SSH 同步

每条隧道可设置 `ecsSyncPolicy` 为 `disabled` 或 `required`。新建隧道和缺少此字段的旧配置均为 `disabled`；旧 ECS 隧道不会自动迁移，升级 App 前应盘点并在停止该隧道、确认旧连接收敛后显式设为 `required`。运行中或状态不可信时，保存/重载 `disabled`→`required` 会被拒绝。该开关只适用于连接**当前全局配置的同一个 ECS 安全组、SSH TCP 22** 的隧道，受管入方向规则描述为 `tunnelpad-dynamic-ssh-managed`；它不按隧道选择安全组，也不适用于其他 SSH 端口。非 SSH 命令不能设置 `required`。

首次配置请参考 [`docs/examples/ecs-ssh-ip.env.example`](docs/examples/ecs-ssh-ip.env.example)，并将实际配置放在仓库外：

```text
~/.config/tunnelpad/ecs-ssh-ip.env
```

阿里云 CLI 的凭证由仓库外 profile/config 管理。TunnelPad 只向同步子进程传递配置路径和白名单环境变量，不读取、复制或持久化 AccessKey、Secret 或私钥内容。

配置文件支持的非秘密键：

| 变量 | 作用 |
|---|---|
| `TUNNELPAD_ALIYUN_CONFIG` | 阿里云 CLI 配置/凭证文件路径（必需） |
| `ALIBABA_PROFILE` | CLI profile 名称，默认 `tunnelpad-ecs-sync` |
| `ALIBABA_REGION_ID` | ECS 地域（必需） |
| `ECS_SECURITY_GROUP_ID` | 目标安全组（必需） |
| `TUNNELPAD_IP_ENDPOINT_1` / `TUNNELPAD_IP_ENDPOINT_2` | 双端点公网 IPv4 探测地址 |

进程级可选覆盖变量包括 `TUNNELPAD_CONFIG_FILE`（覆盖配置文件路径）、`TUNNELPAD_LOCK_DIR`、`TUNNELPAD_LOG_FILE` 和测试/诊断用的 `CURL_BIN`、`ALIYUN_BIN`、`JQ_BIN`、`SHASUM_BIN`、`UUIDGEN_BIN`。App 会自动为子进程补齐 `PATH`、`HOME` 和 `TMPDIR`，其他环境变量不会透传。

独立检查和操作说明见 [`docs/ecs-dynamic-ssh-ip-operations.md`](docs/ecs-dynamic-ssh-ip-operations.md)。Workbench 仅作为 ECS 恢复通道，连接约定见 [`AGENTS.md`](AGENTS.md)。

### 无人值守断线恢复

无人值守恢复只适用于同时开启 `autoStart` 和 `keepAlive` 的 SSH 隧道。只有 `required` 项在 App 启动交接时做一次只读 IP 漂移检查；运行期间不使用固定 5 分钟 IP 轮询，而是观察 launchd 状态和 PID。检测到断线或实例变化后，恢复顺序为：

```text
停止并确认旧 launchd/本机 SSH 收敛
  → 检查并同步 ECS 受管 SSH /32（仅 required）
  → 可选清理 ECS 上的排他远端转发端口
  → 启动新 SSH
  → 连续健康采样确认恢复
```

同步、状态查询、远端清理或启动失败时，恢复任务会按 `0、5、10、30、60、60…` 秒继续尝试，最长等待固定为 60 秒，不会因为失败次数达到上限而自行停下。手动停止、关闭 `keepAlive`、删除隧道或 App 退出会取消对应恢复任务。

配置字段 `forceRemotePortCleanup` 默认是 `false`。设为 `true` 表示该 SSH 命令中 `-R` 指定的远端监听端口由该隧道排他占用：每次重连前，TunnelPad 会通过该 SSH 目标强制结束端口上的全部 TCP 监听进程，不按 IP、UID、进程类型或原会话归属筛选，并在确认端口为空后才启动新连接。该选项只应在端口确实专属于当前隧道时使用。

## 相关文档

- [计划索引与依赖](docs/PLAN_MAP.md)
- [ECS 动态 SSH 公网 IP 同步计划](docs/plans/20260829/ecs-dynamic-ssh-ip.md)
- [逐隧道 ECS 同步策略计划](docs/plans/20260927/tunnelpad-per-tunnel-ecs-policy.md)
- [隧道稳定性与健康恢复计划](docs/plans/20260830/tunnelpad-stability.md)
- [日志事件流与面板生命周期计划](docs/plans/20260830/tunnelpad-log-streaming.md)
- [日志保留与能耗回归修复计划](docs/plans/20260905/tunnelpad-log-retention-energy-regression.md)
- [日志低写放大与流式保留计划](docs/plans/20260905/tunnelpad-log-write-amplification.md)
- [后台健康监测能耗优化计划](docs/plans/20260904/tunnelpad-health-monitor-energy.md)
- [无人值守受管 SSH 收敛恢复计划](docs/plans/20260904/tunnelpad-unattended-managed-ssh-recovery.md)
- [无人值守 SSH 异常恢复与孤儿清理计划](docs/plans/20260919/tunnelpad-unattended-ssh-recovery-and-orphan-cleanup.md)
- [无人值守 ECS IP 漂移同步与断线恢复计划](docs/plans/20260919/tunnelpad-unattended-ecs-ip-drift-recovery.md)
- [无人值守恢复最终验收](docs/data-quality/tunnelpad-unattended-final-acceptance-20260919.md)
- [本机 HTTP API 计划](docs/plans/20260902/tunnelpad-local-api.md)
- [Rust Core 唯一生命周期 owner ADR](docs/adr/0001-rust-core-single-owner.md)
- [TunnelPad 功能图谱](docs/graph/functional.yaml)

## 安全提示

- 不要把阿里云凭证 CSV、CLI 配置文件、AccessKey、Secret、SSH 私钥或真实公网 IP 提交到仓库。
- HTTP API 无用户鉴权，默认安全边界依赖回环监听；局域网只可通过上述显式白名单配置启用。不要用无访问限制的代理/端口转发绕过来源校验，禁止暴露到公网。
- ECS 同步只维护描述明确的受管 SSH `/32` 规则，其他安全组规则不在操作范围内。
- 本机无人值守恢复只处理已核验的 TunnelPad 受管进程；身份无法确认、状态未知或 ECS 前置失败时保持 fail-closed。显式启用 `forceRemotePortCleanup` 是远端例外：目标端口被视为排他资源，端口上的全部监听进程都会被强制结束。
- 发现安全组规则、凭证或隧道状态异常时，先停止当前操作，并按计划中的失败与恢复边界处理。
