# TunnelPad

TunnelPad 是一个 macOS 菜单栏应用，用于统一管理本机与服务器之间的 SSH 隧道：启动、停止、重启、状态查看、日志查看、配置刷新和旧 LaunchAgent 接管。

## 当前状态

- v1 隧道管理、菜单栏入口、`launchd` 生命周期、配置 v1 和 Rust Core 迁移已完成。
- ECS 动态 SSH 公网 IP 同步阶段 2 已完成：SSH 隧道执行启动/重启前，App 会调用 `.app/Contents/Resources/update-ecs-ssh-ip`，同步受管安全组规则后再调用 Rust Core。
- 稳定性与健康恢复、日志事件流仍处于阶段 0 设计中；当前尚未实现运行中公网 IP 变化的自动恢复，也未实现事件驱动日志采集。
- 计划状态与阶段依赖以 [`docs/PLAN_MAP.md`](docs/PLAN_MAP.md) 为准。

## 主要能力

- 菜单栏和主窗口管理多条 `launchd` SSH 隧道。
- Rust Core 作为配置、生命周期、运行时状态、并发和退出清理的唯一 owner；SwiftUI/AppKit 负责界面和 FFI 适配。
- HTTP 探针检查并展示隧道健康结果。后台健康恢复策略已登记在稳定性计划，尚未进入实现阶段。
- 读取每条隧道的 `launchd` 日志文件并在详情页查看。
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
- [Rust Core 唯一生命周期 owner ADR](docs/adr/0001-rust-core-single-owner.md)
- [TunnelPad 功能图谱](docs/graph/functional.yaml)

## 安全提示

- 不要把阿里云凭证 CSV、CLI 配置文件、AccessKey、Secret、SSH 私钥或真实公网 IP 提交到仓库。
- ECS 同步只维护描述明确的受管 SSH `/32` 规则，其他安全组规则不在操作范围内。
- 发现安全组规则、凭证或隧道状态异常时，先停止当前操作，并按计划中的失败与恢复边界处理。
