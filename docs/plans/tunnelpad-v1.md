# 计划：TunnelPad v1 隧道管理应用

## 背景

本机与 ECS（47.109.202.254）之间现有两条手工维护的 launchd 常驻 SSH 隧道：

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

v1 引入 TunnelPad 自身的配置文件 schema（`config.json` v1：隧道条目字段、执行器枚举 `launchd|app`）与 launchd 标签约定 `com.jafish.tunnelpad.<tunnel-id>`。无对外 HTTP API。schema 字段细节在阶段 1 准入时定义并记录于本计划。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 迁移基线与现状快照（只读，不改动现有服务） | 治理文档已初始化 | 基线命令可复现、快照文档落盘 | 设计中 |
| 阶段 1 | 应用骨架、配置模型、launchd 执行器、迁移接管与退出语义、最小 UI | 阶段 0 独立复核通过 | `swift test` + launchctl 真实验证 | 设计中 |
| 阶段 2 | app 执行器、状态探针、日志查看与 .app 打包 | 阶段 1 独立复核通过 | `swift test` + 手动验收 | 设计中 |

## 当前阶段

当前阶段为阶段 0（迁移基线与现状快照）。

### 范围

只读采集两条现有隧道的完整迁移基线：plist 原文、launchctl 运行状态、行为探测结果；输出基线快照文档。不修改、不重启、不停止任何现有服务。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 设计中 |
| Step 0 | 现状快照类型（行为迁移基线）；采集矩阵见下方"Step 0 证据"；快照输出 `docs/data-quality/tunnelpad-v1-stage0-baseline-20260829.md` |
| 样本矩阵 | 见"Step 0 证据"节内样本矩阵表 |
| 验证方式 | 样本矩阵命令全部可复现；`python3 scripts/check_plan_governance.py .` 通过 |
| 失败/回滚边界 | 只读观察无回滚需求；任一探测失败如实记入快照文档并登记为当前阻塞项 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | 尚未进行 |

### 实施步骤

1. 采集 admin-tunnel 基线：plist 原文、`launchctl print` 状态、回环 8081 探测。
2. 采集 reverse-ssh 基线：plist 原文、`launchctl print` 状态、ECS 侧 22022 监听探测。
3. 写入基线快照文档 `docs/data-quality/tunnelpad-v1-stage0-baseline-20260829.md`。
4. 运行治理检查，同步 `docs/PLAN_MAP.md` 状态与证据。

### Step 0 证据

类型：现状快照（行为迁移类基线）。样本矩阵：

| 输入或基线 | 可执行命令 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|
| admin-tunnel agent | `launchctl print gui/$(id -u)/com.jafish.motorcycle-manual.admin-tunnel` | agent 存在且 program 为 ssh | agent 未加载 | 基线快照文档 |
| admin 隧道行为 | `curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/admin` | `401` | 非 401 或连接拒绝 | 基线快照文档 |
| reverse-ssh agent | `launchctl print gui/$(id -u)/com.jafish.motorcycle-manual.reverse-ssh` | agent 存在且 program 为 ssh | agent 未加载 | 基线快照文档 |
| 反向隧道 ECS 侧监听 | `ssh -F <repo>/infra/production/ssh_config motorcycle-manual-prod 'ss -tln | grep 22022'`（密钥路径见 motorcycle-manual-app 仓库） | LISTEN `127.0.0.1:22022` | 无监听 | 基线快照文档 |

快照文档落盘前，本阶段不得进入实施。

### 阶段证据

- 待阶段 0 完成后填写：基线快照文档链接。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| - | - | - | - | - | - |

### 验证方式

- 基线快照文档中的全部命令在本机可复现，结果与记录一致。
- `python3 scripts/check_plan_governance.py .` 退出码 0（无 ERROR）。

### 测试覆盖率

阶段 0 无代码，不适用。阶段 1 起要求 `swift test` 全部通过并记录测试数量。

### 完成条件

- 基线快照文档存在且包含样本矩阵全部四行的实际结果。
- `docs/PLAN_MAP.md` 状态、当前阶段、最后更新、证据链接已同步。
- 治理检查通过（无 ERROR）。

## 后续阶段（粗粒度）

- 阶段 1：SPM 骨架 + 菜单栏/主面板最小 UI；`TunnelConfig` 数据模型与 config.json 读写；`launchd` 执行器（plist 生成、bootstrap/bootout、标签 `com.jafish.tunnelpad.<id>`）；迁移导入现有两条隧道并 bootout 旧 agent（旧 plist 先备份）；退出 app 停止全部隧道。准入时补充 config schema 字段、UI 布局、测试矩阵。
- 阶段 2：`app` 执行器（子进程托管，ModelPad 模式）；每条隧道可选状态探针；launchd/app 日志查看；`build_app.sh` 打包 .app 与图标。准入时补充探针语义与打包验证方式。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 待补充 |
| 阶段 | 由 `PLAN_MAP.md` 当前阶段确定 |
| 结论 | 通过 / 未通过 |
| 证据 | 命令、样本或 CI 链接 |
| 复核者 | 姓名或 Agent |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| - | - | - | - | - | - |

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
