# 计划：TunnelPad v1 隧道管理应用

## 背景

本机与 ECS 之间现有两条手工维护的 launchd 常驻 SSH 隧道（ECS 连接信息见 motorcycle-manual-app 仓库 `infra/production/ssh_config`；按本仓库敏感信息红线，ECS 地址不写入本仓库文档）：

- `com.jafish.motorcycle-manual.admin-tunnel`：`-L 127.0.0.1:8081:127.0.0.1:8081`，用于访问 motorcycle-manual-app 个人后台（HTTP Basic + 回环监听）。
- `com.jafish.motorcycle-manual.reverse-ssh`：`-R 127.0.0.1:22022:127.0.0.1:22`，把 ECS 上的 22022 反向转发回本 Mac 22 端口，供外部电脑经 ECS 公网跳板连回本机做远程开发。

两条隧道均为 `~/Library/LaunchAgents` 下的手工 plist（KeepAlive 常驻），没有统一的管理界面。本计划在独立新仓库 TunnelPad 中实现 macOS 菜单栏应用，统一管理这类 SSH 隧道，并接管现有两条隧道。

## 目标

实现 macOS 菜单栏应用 TunnelPad，统一管理本机与 ECS 之间的 SSH 隧道（启动/停止/状态/日志/配置），并接管现有两条手工 launchd 隧道。

## 非目标

- 不管理 ECS 侧任何东西（服务、Caddy、systemd、token）；公网零新增入口。
- 不做隧道类型抽象：v1 的隧道就是"配置里写什么命令跑什么命令"，不内置 ssh 之外的隧道协议。
- 不处理 admin token、不读取私钥内容，配置只引用密钥路径。
- v1 不做本地 HTTP API 和 OpenAPI（ModelPad 有，但隧道场景暂不需要）。
- 不做远程/多机配置同步。

<!-- 需求探索章节：2026-08-29 grilling 已完成，用户已确认结构化结论。 -->
## 需求探索

### 已确认事实

- ModelPad（`/Users/jafish/Documents/work/ModelPad`）是 SPM + SwiftUI（macOS 14+）的 macOS 菜单栏应用：LSUIElement 不进 Dock、直接托管子进程（非 launchd）、config.json 持久化、TCP 端口健康检查、LogBuffer 环形日志、`build_app.sh` 打包 .app、完全退出时停止全部托管进程（2026-08-29 查证其 README 与 PLAN_MAP）。
- 现有两条隧道 plist 均位于 `~/Library/LaunchAgents`，KeepAlive + RunAtLoad：admin-tunnel 使用密钥 `~/.ssh/motorcycle-manual-admin.pem`；reverse-ssh 使用密钥 `~/.ssh/motorcycle-manual-prod.pem`。
- reverse-ssh 用途：外部电脑 → ECS 公网 → 反向隧道 → 本 Mac 22 端口，用于远程开发（用户 2026-08-29 确认）。该隧道此前在 motorcycle-manual-app 仓库无任何文档记载。
- launchd KeepAlive 的自动重连已由真实环境验证：杀掉 ssh 进程后约 13 秒自动恢复（证据：motorcycle-manual-app 仓库 `docs/data-quality/user-document-processing-admin-stage1-ecs-release-20260829.md`）。
- macOS TCC 阻止 launchd 进程读取 `~/Documents`，因此 launchd 执行的命令引用的密钥必须位于 `~/.ssh` 等非 TCC 限制路径。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 技术栈照搬 ModelPad：Swift / SwiftUI / SPM / macOS 14+ / 菜单栏常驻 / `build_app.sh` 打包 | 阶段 1 骨架 `swift build`、`swift test` 通过 |
| 配置持久化在 `~/Library/Application Support/TunnelPad/config.json` | 阶段 1 集成测试覆盖读写与损坏恢复 |
| launchd 执行器的 plist 由 app 生成并存放在 TunnelPad 自己的 Application Support 目录内，运行时 `launchctl bootstrap gui/$(id -u) <path>` / `bootout`，不放入 `~/Library/LaunchAgents`（保证"退出即停、重启不自启"语义纯净） | 阶段 1 用 `launchctl print` 与重启后状态验证 |

### 范围与非目标

范围（v1）：

- 菜单栏常驻 + 主面板（ModelPad 同款交互）：隧道列表、状态点、启动/停止/重启。
- 每条隧道配置：名称、执行命令（支持脚本路径）、执行器（`launchd` 默认 / `app` 子进程）。
- launchd 模式：app 生成并托管 plist，start/stop 走 `launchctl`，日志 tail plist 指定的日志文件。
- app 模式：直接 spawn 子进程，捕获 stdout/stderr（ModelPad 现有模式）。
- 状态探测：launchd 模式查 launchctl 状态；每条隧道可选配一个探针（如 admin-tunnel 配 `http://127.0.0.1:8081`、期待 401/200）。
- 首次启动迁移：把现有两条隧道（admin-tunnel、reverse-ssh）的命令导入为配置，接管后 bootout 旧 agent；旧 plist 文件保留可回滚。

非目标：见上文"非目标"章节。

### 候选方案与取舍

| 决策点 | 候选 | 结论 |
|---|---|---|
| 项目归属 | A 新独立仓库 / B 并入 ModelPad / C 放入 motorcycle-manual-app | **A 新仓库 TunnelPad**。reverse-ssh 是通用远程开发通道而非 motorcycle-manual 专属；隧道管理与模型进程管理模型不同；治理干净（用户 2026-08-29 确认） |
| 进程托管模型 | A launchd 托管 / B ModelPad 式 app 子进程 / C 混合 | **执行器可配置，默认 launchd**。纯 app 托管在网络闪断后无人拉起 ssh、外部场景有失联风险；launchd 保留 KeepAlive 自动重连保障（用户 2026-08-29 确认） |
| 退出语义 | ModelPad 式"退出即全停" vs launchd 式"退出后常驻" | **退出 TunnelPad = 停止全部隧道（含 launchd 执行器 bootout），与 ModelPad 保持一致**。已知情代价：Mac 重启或 app 未运行时隧道不在线，用户在外部时会失联；app 崩溃时未来得及 bootout，launchd 代理会继续运行（用户 2026-08-29 确认接受） |

### 未决问题

无阻塞当前阶段（阶段 0）的问题。阶段 1 的 UI 布局、配置 schema 字段细节、探针字段在阶段 1 自身准入时补充定义。

### 用户确认的探索结论

2026-08-29 用户确认：新建 TunnelPad 仓库；v1 只做穿透启动/停止管理 + 可配置执行命令；执行器可配置且默认 launchd；退出 app 停止全部穿透；验收口径为"构建 + 全部测试通过；真实接管两条隧道；杀 ssh 进程 → launchd 秒级自动重连；退出 app → launchctl 里代理消失、隧道断开；重启 app → 一键恢复"。

## 不变量

- 公网零新增入口：不改变 motorcycle-manual-app admin 计划冻结的边界"后台只通过 SSH 隧道访问，公网无后台入口"。
- 不处理 admin token、不读取任何私钥内容；配置只引用路径。
- launchd 执行器生成的 plist 与命令引用的路径必须避开 `~/Documents`（TCC 限制），密钥路径使用 `~/.ssh` 下已有副本。
- 退出 TunnelPad = 停止全部隧道（launchd 执行器逐条 bootout；app 执行器 kill 子进程）。
- 迁移接管前旧 plist 必须原样备份，任何时候可回滚到手工 launchd 模式。
- 当前阶段写细，后续阶段写粗；完成时必须记录可验证证据。

## 影响模块或文件

- `Package.swift`、`Sources/`、`Tests/`、`App/`、`scripts/`：新建（阶段 1 起）。
- 仓库外迁移源（只读）：`~/Library/LaunchAgents/com.jafish.motorcycle-manual.admin-tunnel.plist`、`~/Library/LaunchAgents/com.jafish.motorcycle-manual.reverse-ssh.plist`。

## 公共契约变化

v1 引入 TunnelPad 自身的配置文件 schema（config.json v1，定义见"技术方案（阶段 1 冻结，继续有效）"章节：隧道条目字段、执行器枚举 `launchd|app`）与 launchd 标签约定 `com.jafish.tunnelpad.<tunnel-id>`。无对外 HTTP API。阶段 2 可向 schema 追加可选字段（如探针），保持向后兼容。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 迁移基线与现状快照（只读，不改动现有服务） | 治理文档已初始化 | 基线命令可复现、快照文档落盘 | 已完成 |
| 阶段 1 | 应用骨架、配置模型、launchd 执行器、迁移接管与退出语义、最小 UI | 阶段 0 独立复核通过 | `swift test` + launchctl 真实验证 | 已完成 |
| 阶段 2 | app 执行器、状态探针、日志查看与 .app 打包 | 阶段 1 独立复核通过 | `swift test` + 手动验收 | 设计中 |

## 阶段 0 记录（已完成，2026-08-29）

- 证据事实源：[tunnelpad-v1-stage0-baseline-20260829.md](../data-quality/tunnelpad-v1-stage0-baseline-20260829.md)（含样本矩阵四项实测、两条 plist 脱敏原文、launchctl 关键状态、日志观察）。
- 结论：两条旧 agent 均 `state=running`；admin 回环探测 `401`；ECS 侧 `LISTEN 127.0.0.1:22022`；无阻塞项。
- 迁移输入要点：两条命令选项集合不同（admin-tunnel 多 `ConnectTimeout=10`）、`ThrottleInterval` 分别为 10/15、日志路径与 stdout/stderr 分文件方式不同；admin-tunnel 历史 TCC 报错印证 launchd 不可读 `~/Documents`；reverse-ssh `runs=7126` 证明 KeepAlive 重拉长期真实生效。

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-29 | 实施 | 阶段 0 四项基线采集完成，快照文档落盘，无阻塞项 | 基线快照文档 | 完成 | ZCode Agent（实施轮次） |

## 技术方案（阶段 1 冻结，继续有效）

#### config.json Schema v1

路径 `~/Library/Application Support/TunnelPad/config.json`：

```json
{
  "version": 1,
  "tunnels": [
    {
      "id": "admin-tunnel",
      "name": "admin-tunnel",
      "command": ["/usr/bin/ssh", "…（等价于旧 plist ProgramArguments，原样保存）…"],
      "executor": "launchd",
      "keepAlive": true,
      "throttleInterval": 10
    }
  ]
}
```

字段定义：

- `version`（int，常量 1）：schema 版本；非 1 拒绝加载并进入损坏恢复流程。
- `tunnels[].id`（string，必填，`[a-z0-9-]+`）：派生 launchd 标签 `com.jafish.tunnelpad.<id>` 与 plist 文件名。
- `tunnels[].name`（string，必填）：显示名。
- `tunnels[].command`（string 数组，必填，非空，首元素为可执行路径）：等价于 plist `ProgramArguments`，原样保存不规范化。
- `tunnels[].executor`（enum `launchd|app`，默认 `launchd`）：阶段 1 已实现 `launchd`；`app` 在阶段 2 实现。
- `tunnels[].keepAlive`（bool，默认 true）：写入生成 plist 的 `KeepAlive`。
- `tunnels[].throttleInterval`（int 秒，默认 10）：写入生成 plist 的 `ThrottleInterval`。

派生约定（不进 schema）：生成 plist 存放 `~/Library/Application Support/TunnelPad/launchd/com.jafish.tunnelpad.<id>.plist`（保证退出即停、重启不自启，不进 `~/Library/LaunchAgents`）；日志路径 `~/Library/Logs/TunnelPad/<id>.log`（stdout 与 stderr 同文件，避开 TCC 限制路径）；生成 plist 固定 `RunAtLoad=true`、`ProcessType=Background`；不写 `EnvironmentVariables`。阶段 2 可向 schema 追加可选字段（如探针），保持向后兼容。

#### 执行器语义（launchd）

- start：写 plist → `launchctl bootstrap gui/$(id -u) <plist 路径>`（`RunAtLoad` 使其立即运行）。
- stop：`launchctl bootout gui/$(id -u)/com.jafish.tunnelpad.<id>`。
- restart：bootout 后 bootstrap。
- status：`launchctl print gui/$(id -u)/com.jafish.tunnelpad.<id>`，输出含 `state = running` 即运行中；命令失败视为已停止；其余 state 原样展示。

#### 迁移接管流程（已执行完成，保留作回滚参照）

1. 扫描 `~/Library/LaunchAgents` 下 Label 前缀为 `com.jafish.motorcycle-manual.` 的旧 plist，列出待接管项。
2. 导入：`ProgramArguments` → `command`（原样）；`id`/`name` 取 Label 末段；`keepAlive=true`；`throttleInterval` 取旧 plist 值（缺省 10）。
3. 备份：旧 plist 移动到 `~/Library/Application Support/TunnelPad/migration-backup/`。
4. bootout 旧 agent → bootstrap 新 agent（标签 `com.jafish.tunnelpad.<id>`）→ 验证 `state=running`；失败自动回滚（bootout 新、备份移回 `~/Library/LaunchAgents`、bootstrap 旧）。

回滚到手工模式：把 migration-backup 内对应 plist 移回 `~/Library/LaunchAgents`，`launchctl bootstrap gui/$(id -u) <plist>`。

#### 退出语义（冻结）

正常退出（菜单退出 / Cmd+Q，`applicationShouldTerminate`）与 SIGTERM/SIGINT（`Shutdown` 信号路径，直接读 config.json）同语义：先对全部 launchd 执行器隧道逐条 bootout（单条失败不阻塞其余与退出），再结束进程。已知边界（已知情确认）：app 崩溃时无法 bootout，agent 继续运行；下次启动 app 可重新纳管。

## 阶段 1 记录（已完成，2026-08-29）

- 证据事实源：[tunnelpad-v1-stage1-takeover-20260829.md](../data-quality/tunnelpad-v1-stage1-takeover-20260829.md)。
- 结论：两条隧道经 UI 接管至 `com.jafish.tunnelpad.*`，命令逐字等价、行为探测（curl 401 / ECS LISTEN 22022）接管前后一致；杀 ssh 进程 1 秒自动重连；退出即停两条路径（菜单正常退出 + SIGTERM）均实测通过；重启 app 一键恢复两次实测通过。`swift build` 零告警、`swift test` 29 用例全通过。
- 实施中发现并修复：SIGTERM 信号处理闭包继承 `@MainActor` 隔离导致 `dispatch_assert_queue` 崩溃（bootout 未执行）；已移入 nonisolated `Shutdown.installSignalHandlers()` 并复测通过。
- 旧 plist 备份于 `~/Library/Application Support/TunnelPad/migration-backup/`；`~/Library/LaunchAgents` 已无旧 plist。
- 跨仓库同步项已执行：motorcycle-manual-app `user-document-processing-admin.md` 追加托管方变更记录（commit `e4f2c4b`）。

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-29 | 实施 | 阶段 1 代码完成：SPM 骨架（TunnelPadCore + tunnelpad）、config.json v1、launchd 执行器、迁移接管（备份先行+失败回滚）、退出语义（正常退出+SIGTERM）、菜单栏与主面板 UI；`swift build` 零告警，`swift test` 29 用例全部通过 | swift build/test 输出（阶段证据文档收录） | 完成 | ZCode Agent（实施轮次） |
| 2026-08-29 | 实施 | 真实接管两条隧道 + 杀 ssh 重连（1s）+ 退出即停（双路径，含 SIGTERM 崩溃修复）+ 重启恢复（两次）全部实测通过，线上状态恢复为 TunnelPad 托管运行 | 阶段证据文档 | 完成 | ZCode Agent（实施轮次） |

## 当前阶段

当前阶段为阶段 2（app 执行器、状态探针、日志查看与 .app 打包）。

### 范围（粗粒度，准入时细化）

- `app` 执行器：子进程托管（ModelPad 模式），捕获 stdout/stderr。
- 每条隧道可选状态探针（如 admin-tunnel 探 `http://127.0.0.1:8081` 期待 401/200）。
- launchd/app 日志查看（tail plist 指定日志文件）。
- `build_app.sh` 打包 .app 与图标（LSUIElement 菜单栏纯常驻行为在此落实）。

### 非目标（本阶段）

- 见"非目标"章节；不改变阶段 1 已冻结的退出语义与 launchd 标签约定。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 设计中 |
| Step 0 | 待本阶段准入时补充定义（探针语义、app 执行器基线参照 ModelPad） |
| 样本矩阵 | 待本阶段准入时补充定义 |
| 验证方式 | 待本阶段准入时细化（`swift test` + 手动验收） |
| 失败/回滚边界 | 待本阶段准入时补充定义 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | 尚未进行 |

### 实施步骤

待本阶段准入时补充。

### Step 0 证据

阶段 2 尚未完成自身准入：Step 0 类型、样本矩阵、验证方式与完成条件将在准入复核前补充定义于本节。

### 阶段证据

- 待阶段 2 完成后填写。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| - | - | - | - | - | - |

### 验证方式

待本阶段准入时细化。

### 测试覆盖率

阶段 2 起继续要求 `swift test` 全部通过并记录测试数量；覆盖率要求随准入细化。

### 完成条件

待本阶段准入时定义。

## 后续阶段（粗粒度）

- 阶段 2 已进入当前阶段（见"当前阶段"章节）；v1 范围内暂无更后续阶段。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-29 |
| 阶段 | 阶段 1 |
| 结论 | 通过（达到待实施标准） |
| 证据 | 独立复核轮次复跑阶段 0 四条基线命令结果一致；快照嵌入 plist 与磁盘原文脱敏外全等；阶段 1 准入摘要七字段齐备、样本矩阵九行含命令/预期/失败判定/输出位置、Step 0 基线文档存在；`plan-governance-cli check .` 与 `--strict-readiness` 均通过 |
| 复核者 | ZCode Agent（独立复核轮次） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-29 | 阶段 0 完成复核 | 阶段 0 | 通过 | 独立复核轮次复跑四条基线命令（两 agent running、curl 401、ECS LISTEN 22022）与快照一致；嵌入 plist 与磁盘原文脱敏外全等；仓库无 ECS 明文地址；治理检查通过 | ZCode Agent（独立复核轮次） |
| 2026-08-29 | 阶段准入复核 | 阶段 1 | 通过（达到待实施标准） | 准入摘要七字段齐备；样本矩阵九行完整；Step 0 基线快照存在；失败/回滚边界明确（备份先行、bootstrap 失败即回滚）；PLAN_MAP 已同步；治理检查含 `--strict-readiness` 通过 | ZCode Agent（独立复核轮次） |
| 2026-08-29 | 阶段 1 完成复核 | 阶段 1 | 通过 | 独立复核轮次复跑：双新标签 `running`（pid 90512/90517）、curl 401、ECS LISTEN 22022；config `command` 与旧 plist `ProgramArguments` 逐字等价（双隧道）；备份 2 份、`~/Library/LaunchAgents` 零残留；`swift test` 29/29、构建零告警；治理检查含 `--strict-readiness` 通过 | ZCode Agent（独立复核轮次） |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 无 | - | 否 | - |

## 风险和回滚

- 阶段 0 为只读观察，无风险。
- 阶段 1 迁移接管的主要风险：bootout 旧 agent 后若 TunnelPad 自身异常，隧道中断。回滚方式：将备份的旧 plist 恢复到 `~/Library/LaunchAgents` 并 `launchctl bootstrap`，即回到现状；接管前必须完成备份。
- 已知情接受的代价（2026-08-29 用户确认）：TunnelPad 未运行（退出、Mac 重启后）时隧道不在线，外部远程开发场景会失联；app 崩溃时 launchd 代理继续运行属边界行为而非保障。

## 关联 ADR、迁移、spec 或 issue

- motorcycle-manual-app 仓库 `docs/plans/user-document-processing-admin.md`：admin 隧道安全边界事实源；TunnelPad 接管 admin 隧道后需同步其"SSH 隧道使用说明"（跨仓库同步项）。
- motorcycle-manual-app 仓库 `docs/data-quality/user-document-processing-admin-stage1-ecs-release-20260829.md`：KeepAlive 自动重连验证证据引用。
