# TunnelPad

TunnelPad 是一个 macOS 菜单栏应用，用于统一管理本机与服务器之间的 SSH 隧道：启动、停止、重启、状态查看、日志查看、配置刷新和旧 LaunchAgent 接管。

## 当前状态

- v1 隧道管理、菜单栏入口、`launchd` 生命周期、配置 v1 和 Rust Core 迁移已完成。
- ECS 动态 SSH 公网 IP 同步阶段 2 已完成：SSH 隧道执行启动/重启前，App 会调用 `.app/Contents/Resources/update-ecs-ssh-ip`，同步受管安全组规则后再调用 Rust Core。
- 稳定性与健康恢复、日志事件流、日志保留与低写放大、后台健康监测能耗、无人值守受管 SSH 收敛恢复以及 Rust Core 风险收敛计划均已完成。
- 当前生产执行器和自动恢复范围固定为 `launchd`；`app` 执行器仍是非目标，未来另立计划。
- 日志优化已完成：正常追加采用增量采集，持久日志达到约 512 KiB 后才批量压缩，压缩后保留最近 2000 个逻辑行；正常 SSH 默认不带独立 `-v`，详细日志可按需开启。
- 本机 HTTP API 已完成：App 启动时绑定 `127.0.0.1:9998`，提供隧道状态、启停、重启和日志接口；不提供远程访问、配置写入或 ECS API。
- 计划状态与阶段依赖以 [`docs/PLAN_MAP.md`](docs/PLAN_MAP.md) 为准。

## 主要能力

- 菜单栏和主窗口管理多条 `launchd` SSH 隧道。
- Rust Core 作为配置、生命周期、运行时状态、并发和退出清理的唯一 owner；SwiftUI/AppKit 负责界面和 FFI 适配。
- HTTP 探针检查并展示隧道健康结果；`launchd` 范围内的后台健康恢复和资源收敛已完成。
- 对已核验的受管 SSH 进程执行无人值守假死收敛；身份不匹配或状态未知时保持 fail-closed，并进入自动冷却重试。
- 以事件流和增量采集更新日志；面板关闭期间仍保留每条隧道最近 500 条内存日志，持久文件在压缩后保留最近 2000 个逻辑行。
- 通过本机 HTTP API 对外提供受控的状态、生命周期和日志调用。
- 接管旧版 LaunchAgent，提供备份与失败回滚边界。
- 对识别为 SSH 的命令，在启动/重启前执行 ECS 动态 IP 同步；非 SSH 命令不触发该同步。

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

API 服务随 TunnelPad App 启停，只监听 `127.0.0.1:9998`。端口被占用时记录启动错误并继续运行 App，不换端口、不重试；App 退出时 API 服务停止。

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

## 相关文档

- [计划索引与依赖](docs/PLAN_MAP.md)
- [ECS 动态 SSH 公网 IP 同步计划](docs/plans/ecs-dynamic-ssh-ip.md)
- [隧道稳定性与健康恢复计划](docs/plans/tunnelpad-stability.md)
- [日志事件流与面板生命周期计划](docs/plans/tunnelpad-log-streaming.md)
- [日志保留与能耗回归修复计划](docs/plans/tunnelpad-log-retention-energy-regression.md)
- [日志低写放大与流式保留计划](docs/plans/tunnelpad-log-write-amplification.md)
- [后台健康监测能耗优化计划](docs/plans/tunnelpad-health-monitor-energy.md)
- [无人值守受管 SSH 收敛恢复计划](docs/plans/tunnelpad-unattended-managed-ssh-recovery.md)
- [本机 HTTP API 计划](docs/plans/tunnelpad-local-api.md)
- [Rust Core 唯一生命周期 owner ADR](docs/adr/0001-rust-core-single-owner.md)
- [TunnelPad 功能图谱](docs/graph/functional.yaml)

## 安全提示

- 不要把阿里云凭证 CSV、CLI 配置文件、AccessKey、Secret、SSH 私钥或真实公网 IP 提交到仓库。
- 本机 HTTP API 无鉴权，安全边界依赖回环监听；不要通过端口转发、代理或其他方式将 `9998` 暴露到局域网或公网。
- ECS 同步只维护描述明确的受管 SSH `/32` 规则，其他安全组规则不在操作范围内。
- 无人值守恢复只处理已核验的 TunnelPad 受管 SSH 进程；身份无法确认、状态未知或 ECS 前置失败时保持 fail-closed，不操作未知进程或远端资源。
- 发现安全组规则、凭证或隧道状态异常时，先停止当前操作，并按计划中的失败与恢复边界处理。
