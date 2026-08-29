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

v1 引入 TunnelPad 自身的配置文件 schema（config.json v1，定义见上方"技术方案（阶段 1 冻结）"章节：隧道条目字段、执行器枚举 `launchd|app`）与 launchd 标签约定 `com.jafish.tunnelpad.<tunnel-id>`。无对外 HTTP API。阶段 2 可向 schema 追加可选字段（如探针），保持向后兼容。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 迁移基线与现状快照（只读，不改动现有服务） | 治理文档已初始化 | 基线命令可复现、快照文档落盘 | 已完成 |
| 阶段 1 | 应用骨架、配置模型、launchd 执行器、迁移接管与退出语义、最小 UI | 阶段 0 独立复核通过 | `swift test` + launchctl 真实验证 | 实施中 |
| 阶段 2 | app 执行器、状态探针、日志查看与 .app 打包 | 阶段 1 独立复核通过 | `swift test` + 手动验收 | 设计中 |

## 阶段 0 记录（已完成，2026-08-29）

- 证据事实源：[tunnelpad-v1-stage0-baseline-20260829.md](../data-quality/tunnelpad-v1-stage0-baseline-20260829.md)（含样本矩阵四项实测、两条 plist 脱敏原文、launchctl 关键状态、日志观察）。
- 结论：两条旧 agent 均 `state=running`；admin 回环探测 `401`；ECS 侧 `LISTEN 127.0.0.1:22022`；无阻塞项。
- 迁移输入要点：两条命令选项集合不同（admin-tunnel 多 `ConnectTimeout=10`）、`ThrottleInterval` 分别为 10/15、日志路径与 stdout/stderr 分文件方式不同；admin-tunnel 历史 TCC 报错印证 launchd 不可读 `~/Documents`；reverse-ssh `runs=7126` 证明 KeepAlive 重拉长期真实生效。

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-29 | 实施 | 阶段 0 四项基线采集完成，快照文档落盘，无阻塞项 | 基线快照文档 | 完成 | ZCode Agent（实施轮次） |

## 当前阶段

当前阶段为阶段 1（应用骨架、配置模型、launchd 执行器、迁移接管与退出语义、最小 UI）。

### 范围

- SPM 骨架：`TunnelPadCore` 库 + `TunnelPad` 可执行目标（SwiftUI MenuBarExtra，macOS 14+）+ `TunnelPadCoreTests`。
- `TunnelConfig`/`AppConfig` 数据模型与 config.json 读写（含损坏恢复）。
- launchd 执行器：生成 plist、`launchctl bootstrap/bootout`、状态查询，标签 `com.jafish.tunnelpad.<id>`。
- 迁移导入与接管：解析旧 plist → 导入配置 → 备份 → bootout 旧 agent → bootstrap 新 agent，失败自动回滚。
- 退出语义：退出 app = 对全部 launchd 执行器隧道逐条 bootout。
- 最小 UI：菜单栏菜单（状态摘要、全部启动/停止、退出）+ 主面板（隧道列表、状态点、每条启动/停止/重启）+ 首启迁移面板。

### 非目标（本阶段）

- `app` 执行器实现、状态探针、日志查看 UI、.app 打包与图标（阶段 2）。
- 不改 ECS 侧任何东西；公网零新增入口；不读取私钥内容。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| Step 0 | 阶段 0 基线快照（`docs/data-quality/tunnelpad-v1-stage0-baseline-20260829.md`）作为迁移行为基线；骨架参照 ModelPad 可运行实现 |
| 样本矩阵 | 见下方"Step 0 证据"节内阶段 1 样本矩阵表 |
| 验证方式 | `swift build` 无错误、`swift test` 全部通过；真实验证矩阵逐项执行并记录证据；治理检查（含 `--strict-readiness`）通过 |
| 失败/回滚边界 | 接管前完成备份才允许 bootout；bootstrap 失败立即回滚（恢复备份 plist + bootstrap 旧 agent）；回滚命令见"风险和回滚" |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | 尚未进行 |

### 实施步骤

1. Core：数据模型、ConfigStore、plist 渲染、launchctl 执行器、旧 plist 导入（均配单元测试）。
2. UI：菜单栏菜单、主面板、迁移面板。
3. 真实迁移接管两条隧道并验证行为等价（curl/ss 探测）。
4. 真实验证杀进程重连、退出即停、重启恢复。
5. 证据落盘、跨仓库同步项、治理同步与提交。

### Step 0 证据

类型：行为迁移基线（阶段 0 快照）+ 新项目可执行验收（测试套件）。阶段 1 样本矩阵：

| 输入或基线 | 可执行命令 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|
| 测试套件 | `swift build && swift test` | 构建无错误、全部用例通过（记录用例数） | 任一失败 | 阶段证据文档 |
| config 损坏恢复 | XCTest：损坏 JSON → 改名留档并重建空配置 | 用例通过 | - | 阶段证据文档 |
| plist 生成等价性 | XCTest：config → plist XML → 解析回 ProgramArguments 与 `command` 全等 | 用例通过 | - | 阶段证据文档 |
| 旧 plist 导入 | XCTest：以阶段 0 备份 plist 为 fixture → 导入 `command` 与原文全等 | 用例通过 | - | 阶段证据文档 |
| 真实接管 admin | 接管后 `launchctl print gui/$(id -u)/com.jafish.tunnelpad.admin-tunnel`；旧标签 print 失败；`curl --noproxy '*' 127.0.0.1:8081/admin` 返回 401 | 三项全部满足 | 任一不满足 | 阶段证据文档 |
| 真实接管 reverse | 同上（标签 `reverse-ssh`）；ECS 侧 `ss -tln \| grep 22022` 有监听 | 全部满足 | 任一不满足 | 阶段证据文档 |
| 杀进程自动重连 | `kill <新标签 ssh pid>` 后轮询 `launchctl print` | 60 秒内回到 `running`（受 ThrottleInterval 约束） | 超时未恢复 | 阶段证据文档 |
| 退出即停 | 正常退出 app → 两个新标签 print 失败；curl 8081 拒连；ECS ss 无 22022 监听 | 全部满足 | 任一仍在 | 阶段证据文档 |
| 重启恢复 | 重启 app → 全部启动 → print/curl/ECS ss 探测 | 全部恢复且探测通过 | 任一失败 | 阶段证据文档 |

### 技术方案（阶段 1 冻结）

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
- `tunnels[].executor`（enum `launchd|app`，默认 `launchd`）：阶段 1 仅实现 `launchd`；配置为 `app` 时 UI 标注"阶段 2 支持"并禁止启动。
- `tunnels[].keepAlive`（bool，默认 true）：写入生成 plist 的 `KeepAlive`。
- `tunnels[].throttleInterval`（int 秒，默认 10）：写入生成 plist 的 `ThrottleInterval`。

派生约定（不进 schema）：生成 plist 存放 `~/Library/Application Support/TunnelPad/launchd/com.jafish.tunnelpad.<id>.plist`（保证退出即停、重启不自启，不进 `~/Library/LaunchAgents`）；日志路径 `~/Library/Logs/TunnelPad/<id>.log`（stdout 与 stderr 同文件，避开 TCC 限制路径）；生成 plist 固定 `RunAtLoad=true`、`ProcessType=Background`；不写 `EnvironmentVariables`。阶段 2 可向 schema 追加可选字段（如探针），保持向后兼容。

#### 执行器语义（launchd）

- start：写 plist → `launchctl bootstrap gui/$(id -u) <plist 路径>`（`RunAtLoad` 使其立即运行）。
- stop：`launchctl bootout gui/$(id -u)/com.jafish.tunnelpad.<id>`。
- restart：bootout 后 bootstrap。
- status：`launchctl print gui/$(id -u)/com.jafish.tunnelpad.<id>`，输出含 `state = running` 即运行中；命令失败视为已停止；其余 state 原样展示。

#### 迁移接管流程（逐条执行，任一步失败即停并回滚该条）

1. 扫描 `~/Library/LaunchAgents` 下 Label 前缀为 `com.jafish.motorcycle-manual.` 的旧 plist，列出待接管项（不硬编码清单，发现即列出）。
2. 导入：`ProgramArguments` → `command`（原样）；`id`/`name` 取 Label 末段；`keepAlive=true`；`throttleInterval` 取旧 plist 值（缺省 10）。
3. 备份：旧 plist **移动**到 `~/Library/Application Support/TunnelPad/migration-backup/`（移动而非复制：旧文件留在 `~/Library/LaunchAgents` 会在下次登录时随 `RunAtLoad` 与新 agent 双跑，抢端口或抢反向转发）。
4. bootout 旧 agent。
5. bootstrap 新 agent（标签 `com.jafish.tunnelpad.<id>`）。
6. 验证 `state=running`；失败 → 立即回滚（bootout 新、备份移回 `~/Library/LaunchAgents`、bootstrap 旧）并在 UI 标记失败。

UI 触发：首启检测到旧 agent 且配置中无对应隧道 → 迁移面板列出并一键"导入并接管"；之后也可从主面板再次触发。

#### 退出语义

正常退出（菜单退出 / Cmd+Q）先对全部 launchd 执行器隧道逐条 bootout（单条失败记录日志、不阻塞其余与退出），再正常结束进程。已知边界（计划"风险和回滚"已知情确认）：app 崩溃时无法 bootout，agent 继续运行；下次启动 app 时 status 查询可见并可再次管理。

#### 架构

- `TunnelPadCore`：`TunnelConfig`/`AppConfig`（Codable）、`ConfigStore`（读写；损坏时改名 `config.json.corrupt-<ts>` 留档并重建空配置）、`LaunchdPlistRenderer`（plist XML 生成）、`LaunchCtlExecutor`（start/stop/status，`ProcessRunner` 协议注入便于测试）、`LegacyImporter`（旧 plist 解析）、`MigrationService`（备份/bootout/bootstrap/回滚编排）。
- `TunnelPad`（executable）：SwiftUI `MenuBarExtra` + 主面板 + 迁移 sheet；退出前执行停机编排。
- 开发期运行 `.build/debug/tunnelpad`；.app 打包与 LSUIElement 行为在阶段 2 处理。

### 阶段证据

- 待阶段 1 完成后填写：验证证据文档链接（`docs/data-quality/tunnelpad-v1-stage1-takeover-<日期>.md`）。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-29 | 实施 | 阶段 1 代码完成：SPM 骨架（TunnelPadCore + tunnelpad）、config.json v1、launchd 执行器、迁移接管（备份先行+失败回滚）、退出语义（正常退出+SIGTERM）、菜单栏与主面板 UI；`swift build` 零告警，`swift test` 29 用例全部通过 | swift build/test 输出（阶段证据文档收录） | 进行中 | ZCode Agent（实施轮次） |

### 验证方式

- `swift build` 无错误；`swift test` 全部通过并记录用例数。
- 样本矩阵"真实验证"行逐条执行，命令与输出记录于阶段证据文档。
- `plan-governance-cli check .` 与 `--strict-readiness` 均无 ERROR。

### 测试覆盖率

`swift test` 数量与结果记录于阶段证据；Core 关键路径（ConfigStore、PlistRenderer、LegacyImporter、executor 状态解析、迁移回滚编排）必须有用例覆盖。

### 完成条件

- 样本矩阵全部行有证据且通过。
- 两条隧道真实接管完成，验收口径（杀进程重连 / 退出即停 / 重启恢复）实测通过。
- 旧 plist 备份存在于 `migration-backup` 目录，且 `~/Library/LaunchAgents` 下旧 agent 已 bootout。
- `docs/PLAN_MAP.md` 与本计划状态、证据已同步；治理检查通过。
- motorcycle-manual-app 仓库"SSH 隧道使用说明"跨仓库同步项已执行并记录。

## 后续阶段（粗粒度）

- 阶段 2：`app` 执行器（子进程托管，ModelPad 模式）；每条隧道可选状态探针；launchd/app 日志查看；`build_app.sh` 打包 .app 与图标。准入时补充探针语义与打包验证方式。

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
