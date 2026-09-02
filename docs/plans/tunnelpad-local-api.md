# TunnelPad 本机 HTTP API 服务计划

状态：已完成
当前阶段：-
最后更新：2026-09-02

## 背景

TunnelPad v1 计划曾明确不提供 HTTP API；本计划是 v1 完成后的独立能力，不重新打开 v1 计划。用户希望参考 ModelPad，在 TunnelPad 内嵌一个本机 HTTP 服务，供本机脚本和其他工具查询、控制隧道。

ModelPad 已采用 SwiftNIO 嵌入式 Server、AppDelegate 生命周期管理和本机回环监听。TunnelPad 当前没有 HTTP Server，运行时生命周期由 TunnelManager 和 Rust Core 单一 owner 共同维护，因此本计划必须增加 API 适配边界，不能创建第二个 launchd 或 Rust 生命周期 owner。

依赖计划为 [tunnelpad-stability](tunnelpad-stability.md)、[tunnelpad-rust-migration](tunnelpad-rust-migration.md)、[tunnelpad-log-streaming](tunnelpad-log-streaming.md) 和 [tunnelpad-core-hardening](tunnelpad-core-hardening.md)；它们只提供已完成或正在收敛的生命周期、日志和 Rust owner 边界，状态与推荐顺序以 PLAN_MAP.md 为准。

## 目标

- 增加固定监听地址 127.0.0.1:9998 的本机 HTTP API。
- 提供健康检查、隧道查询、启停重启、日志查看/清空和 OpenAPI 自描述接口。
- 复用 TunnelManager 的配置、状态、日志和生命周期语义。
- 确保 HTTP 请求与 @MainActor 状态门面串行，启停成功响应只在受管操作完成后返回。
- 保持 Rust Core 单一生命周期 owner、现有 launchd 语义、配置 Schema 和日志路径不变。

## 非目标

- 不监听 0.0.0.0、局域网或公网地址。
- 第一阶段不增加鉴权、TLS、反向代理、远程管理或多机同步；信任边界是本机回环访问。
- 不通过 API 新增、修改、删除或重载隧道配置。
- 不通过 API 执行任意 shell/SSH 命令、操作 ECS、接管旧服务或修改 launchd plist。
- 不新增可配置 API 端口，不自动换端口，不在端口冲突时重试。
- 不新增 SSE、WebSocket 或流式日志订阅；日志接口只返回当前纯文本快照。
- 不改变已有稳定性恢复策略、日志事件流、配置格式、隧道 ID 或 launchd label。

## 需求探索

### 已确认事实

- 用户确认服务绑定 127.0.0.1:9998。
- 用户确认第一阶段接口集合：健康、隧道列表/详情、启动、停止、重启、日志读取、日志清空和 OpenAPI。
- 用户确认查询返回安全摘要，不返回命令、探针 URL、本地路径或密钥路径。
- 用户确认启停接口等待操作完成后返回；重复操作返回冲突，而不是并行执行第二次操作。
- 用户确认服务随 TunnelPad App 自动启动，App 退出时停止。
- 用户确认端口被占用时沿用 ModelPad：记录错误，App 继续运行；不换端口、不自动重试。
- 简单字段、错误码、OpenAPI 细节由 Codex 按安全、兼容现有实现的方式确定；高影响边界已由用户确认。

### 暂定假设与验证方式

- 暂定采用 SwiftNIO 2.x 的 NIOCore、NIOPosix、NIOHTTP1 和 NIOFoundationCompat，具体版本以依赖解析结果和隔离构建验证为准。
- HTTP transport 放在 TunnelPadCore，将 TunnelManager 的 @MainActor 调用封装为受控 API backend/adapter；handler 不直接跨 actor 访问 TunnelManager 状态。
- 启停 API 通过新增请求级 typed operation result 门面取得结果；保留现有 UI 调用兼容性，不通过比较全局 lastError 推断单次请求结果。
- 日志清空通过新增 TunnelManager 受控方法和 LogEventStore 原位清空能力完成；保留 watcher、日志路径和隧道配置，不删除日志文件所属资源。
- 启停 API adapter 采用 60 秒有界等待；超时返回 504 `operation_timeout`，不在 HTTP 层重试。底层操作可能继续完成，调用方应先查询状态再决定下一步。

### 范围与非目标

本计划只覆盖固定回环地址上的本地控制 API 和其测试/文档。配置编辑、远程访问、鉴权升级、ECS 操作、任意命令和流式传输均留待独立计划。

### 候选方案与取舍

| 方案 | 取舍 | 决策 |
|---|---|---|
| SwiftNIO 嵌入 App，复用 TunnelManager backend | 与 ModelPad 一致；无需第二个进程；必须处理 @MainActor 和 NIO event loop 边界 | 采用 |
| 独立 CLI/API helper 进程 | 可隔离 HTTP transport，但引入进程发现、授权、生命周期和第二套 owner 风险 | 不采用 |
| HTTP handler 直接调用 Rust Core/launchctl | 会绕过 TunnelManager 的 busy、代次、ECS 前置、恢复和错误语义 | 禁止 |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| SwiftNIO 依赖的最终版本和 Package.resolved 变化 | 使用与 ModelPad 相同的 SwiftNIO 2.x 依赖范围，并用隔离构建锁定解析结果 | 否 | 已确定，阶段 1 隔离构建验证 |
| API backend 的 typed operation result 形态 | 由 TunnelManager 提供请求级受控结果，API adapter 只消费结果，不读取全局 lastError | 否 | 已确定 |
| 启停 HTTP 请求的具体超时时间 | 60 秒有界等待；超时返回 504 `operation_timeout`，不重试，底层操作按原语义继续收敛 | 否 | 已确定 |
| 日志清空是否只清空文件/快照而保留 watcher | 原位清空、版本单调递增、watcher 保留，配置和隧道不受影响 | 否 | 已确定 |

### 用户确认的探索结论

2026-09-02，用户确认：采用本机回环 127.0.0.1:9998；第一阶段提供健康、隧道查询、启停重启、日志和 OpenAPI；启停等待完成；查询只返回安全摘要；服务随 App 启停；端口冲突沿用 ModelPad 的“记录错误、App 继续运行、不重试、不换端口”语义。用户同时授权 Codex 自行确定简单字段和错误格式，只在高影响决策上继续请求确认。

## 不变量

- API Server 只能绑定 127.0.0.1:9998，构造函数不得让生产 App 改成公网或局域网地址。
- AppDelegate 是服务生命周期 owner；TunnelManager/Rust Core 仍是隧道生命周期 owner；API 不直接执行 launchctl、SSH 或 Rust FFI。
- 所有 API 启停、状态读取和日志操作必须经过受控 backend，并遵守 TunnelManager 的 MainActor、busy、代次、ECS 前置和恢复取消语义。
- 同一隧道同一时间最多一个 API/UI/自动恢复生命周期操作；API 重复操作返回 409 operation_in_progress，不得排队或并行。
- API 成功响应不泄露 command、探针 URL、路径、环境变量、密钥或完整错误中的本地敏感信息。
- 配置文件、launchd plist、隧道 ID、日志路径和现有健康恢复策略不因 API 接入而改变。
- 端口绑定失败不得让 App 启动失败，不得自动选择其他端口，不得无限重试。
- 阶段 N 完成不自动准入下一阶段；API 实现必须在自身 Step 0、fixture、验证方式和独立复核通过后开始。

## 影响模块或文件

- Package.swift 引入 SwiftNIO 依赖及 Core target 产品。
- Package.resolved 记录 SwiftNIO 依赖解析结果。
- Sources/TunnelPadCore/API/ 新增 API Server、DTO、路由、错误和 OpenAPI 生成/序列化边界。
- Sources/TunnelPadCore/LogEventStore.swift 增加受控的原位日志清空。
- Sources/TunnelPadCore/TunnelManager.swift 仅在 typed operation result 或日志清空受控门面确有必要时修改；不得复制生命周期实现。
- Sources/tunnelpad/AppDelegate.swift 创建 backend，自动启动/停止 API Server，并沿用 ModelPad 端口冲突容错。
- Sources/tunnelpad/API/ 将 TunnelManager 的 MainActor 状态适配为 API backend。
- Tests/TunnelPadCoreTests/APITests/ 新增随机端口的 HTTP 契约、路由、安全字段、冲突和生命周期 fixture；不得使用固定 9998 运行并行测试。
- Tests/TunnelPadCoreTests/ 补充 API 与 TunnelManager 受控门面之间的并发/错误回归测试，保持现有稳定性和日志测试边界。
- docs/PLAN_MAP.md 治理状态和证据索引。
- docs/plans/tunnelpad-local-api.md 专项计划事实源。
- docs/data-quality/tunnelpad-local-api-stage0-20260902.md 阶段 0 基线证据。
- docs/data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md 阶段 0 独立准入复核。
- docs/data-quality/tunnelpad-local-api-stage1-implementation-20260902.md 阶段 1 实施证据。
- docs/data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md 阶段 1 真实 Debug/Release App、固定端口冲突和退出清理验收证据。
- docs/data-quality/tunnelpad-local-api-stage2-step0-20260902.md 阶段 2 最终验收 Step 0 证据。
- docs/data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md 阶段 2 独立完成复核。

对 TunnelManager 的 GitNexus upstream impact 为 CRITICAL，影响 130 个上游符号（直接 81 个），涉及 TunnelPadCore 与 TunnelPadCoreTests。实现前若修改 TunnelManager、AppDelegate 或共享日志方法，必须对精确符号重新执行 upstream impact，并把结果追加到阶段证据；不得把该结果解释为无影响。

## 公共契约变化

### 服务地址

~~~text
http://127.0.0.1:9998
~~~

HTTP 请求使用 UTF-8 JSON；无请求体的 POST 允许省略 Content-Type。响应统一使用 application/json，除非未来另立 spec。

### 路由

| 方法 | 路径 | 语义 |
|---|---|---|
| GET | /api/health | API Server 自身健康检查，不代表任何隧道业务健康 |
| GET | /api/tunnels | 返回全部隧道安全摘要 |
| GET | /api/tunnels/:id | 返回一条隧道安全摘要 |
| POST | /api/tunnels/:id/start | 同步等待受控启动完成 |
| POST | /api/tunnels/:id/stop | 同步等待受控停止完成 |
| POST | /api/tunnels/:id/restart | 同步等待受控重启完成 |
| GET | /api/tunnels/:id/logs | 返回日志纯文本快照 |
| POST | /api/tunnels/:id/logs/clear | 清空指定隧道日志，不改变配置或隧道生命周期 |
| GET | /openapi.json | 返回当前 API 的 OpenAPI 3.1 JSON 描述 |

### 隧道摘要

查询和启停成功响应中的摘要字段固定为：

~~~json
{
  "id": "reverse-ssh",
  "name": "生产 SSH 隧道",
  "remark": "连接 ECS",
  "executor": "launchd",
  "keepAlive": true,
  "throttleInterval": 10,
  "status": "running",
  "pid": 12345,
  "busy": false,
  "probe": {
    "enabled": true,
    "status": "satisfied",
    "httpStatus": 200
  }
}
~~~

probe 的 status 使用 disabled、unknown、satisfied、unexpected、failed；没有 HTTP 状态码时省略 httpStatus。不返回 command、探针 URL、日志路径、环境变量、密钥、原始错误原因或其他本地路径。

### 启停响应

成功响应：

~~~json
{
  "ok": true,
  "operation": "start",
  "tunnel": {
    "id": "reverse-ssh",
    "status": "running",
    "pid": 12345,
    "busy": false
  }
}
~~~

操作完成前 API 不返回成功。响应中的 status 是操作结束后重新读取的受控状态，不把 HTTP 200 当作“请求已排队”。

### 日志响应

~~~json
{
  "ok": true,
  "tunnelId": "reverse-ssh",
  "version": 12,
  "status": "available",
  "text": "日志内容..."
}
~~~

status 为 available、missing 或 error；error 不携带本地路径和原始系统错误详情。日志读取沿用现有每条隧道的有界文件/快照策略，不新增流式订阅。

### 错误响应和状态码

~~~json
{
  "ok": false,
  "error": {
    "code": "operation_in_progress",
    "message": "隧道当前正在执行其他操作"
  }
}
~~~

首期固定以下错误码：

| 场景 | HTTP | code |
|---|---:|---|
| 路由不存在 | 404 | not_found |
| 隧道不存在 | 404 | tunnel_not_found |
| 请求方法/路径参数无效 | 400 | invalid_request |
| 同一隧道已有生命周期操作 | 409 | operation_in_progress |
| 启停、日志读取或清空失败 | 500 | operation_failed / log_failed |

错误消息只描述可行动的业务原因，不泄露 command、路径、密钥或原始 stderr。

### OpenAPI

GET /openapi.json 必须描述上述全部路由、参数、状态码、响应字段和回环服务器地址 http://127.0.0.1:9998。OpenAPI 文档不是另一套契约事实源；字段和错误码以本节为准，OpenAPI 由测试校验与之同步。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固化现状基线、API 契约、适配边界、fixture 和失败/回滚策略 | 需求探索已由用户确认 | 现状命令、协议样本、影响分析、独立准入复核 | 已完成 |
| 阶段 1 | 实现 SwiftNIO Server、API backend、App 生命周期接入和契约测试 | 阶段 0 达到待实施标准；精确符号 impact 已完成 | API fixture、TunnelManager/Rust 回归、端口冲突、隔离 App | 已完成 |
| 阶段 2 | 独立完成复核、受控 App 验收和治理收口 | 阶段 1 实施证据完整；阶段 2 Step 0 和独立准入通过 | Release/签名/启动、API 全路由、反向引用和治理检查 | 已完成 |

## 当前阶段

阶段 0–2 均已完成，当前无活动阶段。阶段 0 的需求确认、现状基线、契约、fixture、失败/回滚边界和独立准入复核已完成；阶段 1 的实现/回归与真实 Debug/Release App 验收已完成；阶段 2 的 Step 0、独立完成复核和治理收口已完成。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | [阶段 2 Step 0 证据](../data-quality/tunnelpad-local-api-stage2-step0-20260902.md)：阶段 1 实现、回归、真实 Debug/Release App 和固定 9998 冲突基线齐备 |
| 样本矩阵 | 阶段 0 A0–A9 与阶段 2 B0–B7 均已执行；阶段 1 API/日志专项测试和真实运行证据已落盘 |
| 验证方式 | 随机端口 API contract tests、Swift/Rust 回归、真实 Debug/签名 Release App 固定 9998 启动/冲突/退出、反向引用和最终治理门禁 |
| 失败/回滚边界 | 端口冲突不影响 App；API 代码可整体移除；不回滚 Rust owner、launchd plist、真实隧道或已有日志数据 |
| 当前阻塞项 | 无 |
| 最新独立准入复核 | [阶段 2 独立完成复核](../data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md)；结论为通过，达到待实施标准并完成收口 |

### 实施步骤

1. 对准备修改的精确符号执行 GitNexus upstream impact；若出现 HIGH 或 CRITICAL，维持单一编辑窗口并补齐测试映射。
2. 实现不跨越 Rust owner 的 MainActor backend、typed operation result、60 秒有界等待和原位日志清空。
3. 用随机端口 fixture 完成 API contract、并发冲突、安全字段和 OpenAPI 测试；不使用固定 9998 运行并行测试。
4. 完成 Rust/Swift 回归和 Debug/Release App 生命周期验证；阶段 1 与阶段 2 均通过各自证据和复核后收口。

### Step 0 证据

基线证据已记录，基线类型为“新公共 API 的现状源码快照、参考实现对照和协议样本”。独立准入复核已确认阶段 0 达到待实施标准。

- rg 现状扫描没有找到 TunnelPad API Server、SwiftNIO HTTP pipeline 或监听器。
- lsof -nP -iTCP:9998 -sTCP:LISTEN 当前没有监听进程。
- ModelPad 的 SwiftNIO/APIServer、AppDelegate 启停和端口冲突容错已核对。
- TunnelManager 的 MainActor、生命周期、日志和错误吞吐边界已核对。
- GitNexus TunnelManager upstream impact 为 CRITICAL，上游 130 个符号；该结果不能替代实现后精确符号 impact。

### 样本矩阵

| ID | 输入或基线 | 可执行命令/动作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| A0 | 当前 TunnelPad 源码 | rg -n "APIServer..." Sources Tests Package.swift | 退出码 1，无现有 API Server | 找到现有监听服务或命令误报 | 阶段 0 基线证据 |
| A1 | 当前 9998 端口 | lsof -nP -iTCP:9998 -sTCP:LISTEN | 当前无监听进程 | 已有未知监听者且未完成归属确认 | 阶段 0 基线证据 |
| A2 | 协议路由集合 | 使用随机测试端口启动 fixture Server，逐一请求 9 个路由 | 方法、路径、Content-Type 和 OpenAPI 路由集合匹配本计划契约 | 路由缺失、方法穿透、响应类型错误 | 阶段 1 API contract 测试 |
| A3 | 安全摘要 | 配置含 command、probe URL 和路径的 fake 隧道，调用列表/详情/启停 | 响应包含安全摘要，不包含敏感字段 | 任一敏感字段或原始路径进入 JSON/OpenAPI | 阶段 1 API contract 测试 |
| A4 | 启停成功 | fake backend 返回完成状态；调用 start/stop/restart | API 等待完成后返回 200 和最终摘要 | 提前 200、重复副作用或状态未更新 | 阶段 1 backend/契约测试 |
| A5 | 启停冲突/未知 ID | 并发同 ID 请求；请求不存在 ID | 冲突为 409，未知 ID 为 404，无额外生命周期调用 | 返回成功、并行操作或错误码漂移 | 阶段 1 API contract 测试 |
| A6 | 日志快照/清空 | fake LogSnapshot 覆盖 available/missing/error；调用 logs/clear | 返回纯文本快照；清空只影响日志且版本单调递增 | 泄露路径/原始错误、删除配置或停止 watcher | 阶段 1 日志/manager API 测试 |
| A7 | 服务生命周期 | 真实 Debug/签名 Release App 启动、退出；第二个真实 Debug 实例占用 9998 | 正常自动启停；占用时第二个 App 继续运行且不换端口/重试 | App 启动失败、服务换端口、无限重试或退出残留 | [阶段 1 真实环境验收](../data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md) |
| A8 | 既有行为回归 | cargo test --locked --manifest-path rust/Cargo.toml；xcodebuildmcp swift-package test --package-path . | Rust owner、稳定性、日志和 TunnelManager 回归通过 | 既有测试失败或真实资源被触碰 | 阶段 1/2 证据 |
| A9 | 范围与治理 | plan-governance-cli check .、git diff --check、实现前后 detect_changes() | 变更只覆盖 API/适配/测试/文档，治理无新增 ERROR | 共享计划越界、敏感路径、未声明符号或治理漂移 | 阶段 1/2 证据 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-02 | 需求探索 | 用户确认回环地址、接口集合、同步启停、安全摘要、App 生命周期和端口冲突语义 | 本计划“用户确认的探索结论” | 通过 | Codex |
| 2026-09-02 | 阶段 0 基线 | 确认 TunnelPad 没有 API Server，9998 无监听；ModelPad 参考和 TunnelManager 边界已记录；未修改代码 | 阶段 0 基线证据 | 通过（准入复核待完成） | Codex |
| 2026-09-02 | 阶段 0 独立准入 | 复核需求、基线、9 路由契约、A0–A9 矩阵、失败/回滚边界和 impact；typed result、60 秒超时、原位清空 watcher 已冻结 | [独立准入复核](../data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md) | 通过，达到待实施标准 | Codex（独立只读复核） |

阶段证据只声明本计划范围内的文档/命令；不覆盖用户已有 Rust Core、PLAN_MAP.md 或 tunnelpad-core-hardening 变更。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-02 | 只读影响分析 | TunnelManager upstream impact 为 CRITICAL，130 个上游符号；确认 API 必须通过 backend 串行化 | GitNexus impact 输出；阶段 0 基线证据 | 通过 | Codex |
| 2026-09-02 | 阶段 0 设计冻结 | 确定 typed operation result、60 秒 API 有界等待、原位清空日志并保留 watcher；不改变 Rust owner 或端口冲突语义 | 本计划“暂定假设与验证方式”；独立准入复核 | 通过 | Codex |
| 2026-09-02 | 阶段 1 精确影响复核 | 刷新图谱后，TunnelAPIServer 为 CRITICAL/101 个上游；startAsync HIGH/8、stopAsync HIGH/7、restartAsync LOW/5、clearInPlace HIGH/4、clearLog LOW/1、LogEventStore.clear LOW/3；影响集中在 API、日志和 App/UI 调用方 | 阶段 1 实施证据；GitNexus upstream impact | 通过但保留高影响告警 | Codex |
| 2026-09-02 | 阶段 1 实施与专项验证 | SwiftNIO Server、backend、AppDelegate 生命周期、typed operation result、原位日志清空和随机端口契约测试已实现；专项 4/4、日志 11/11、全量 134/134 通过 | [阶段 1 实施证据](../data-quality/tunnelpad-local-api-stage1-implementation-20260902.md) | 通过；真实 App 验收已补齐 | Codex |
| 2026-09-02 | 阶段 1 真实环境验收 | 真实 Debug/签名 Release App 监听固定 127.0.0.1:9998；health、列表、详情、日志状态、OpenAPI、未知 ID、第二实例端口冲突和退出清理通过；未触碰真实隧道生命周期 | [阶段 1 真实环境验收](../data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md) | 通过 | Codex |
| 2026-09-02 | 阶段 2 Step 0 | 核对阶段 1 实现、API/日志/Rust/Swift 回归、Release 签名、真实接口、端口冲突、退出清理、失败边界和反向引用矩阵 | [阶段 2 Step 0](../data-quality/tunnelpad-local-api-stage2-step0-20260902.md) | 通过，达到待实施标准 | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 独立完成复核 | 基于当前代码、134/134 Swift、Rust 66+1、Release 签名/启动、固定 9998 实测、治理和反向引用逐项复核；未发现计划外行为 | [阶段 2 独立完成复核](../data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md) | 通过，阶段 2 已完成 | Codex（独立只读复核） |

### Attestation 说明

阶段 0–2 的证据和独立完成复核已通过；使用治理 CLI 创建 `phase_completion` 完成快照。快照 hash 若因后续计划文档编辑变化，必须重新复核，不把 attestation 替代 API 行为验收。

### 验证方式

阶段 0：只读源码、依赖、端口现状核对、协议样本设计、GitNexus impact 和独立准入复核。
阶段 1：随机测试端口的 HTTP contract tests、fake backend/LogSnapshot、Swift 6 并发检查、Rust/Swift 回归、真实 Debug/签名 Release App 固定 9998 启动/冲突/退出验收；不调用真实用户 launchd、SSH、ECS 或标准日志路径。
阶段 2：独立完成复核、API 全路由/安全字段反向核对、既有稳定性/日志生命周期回归、反向引用和最终治理门禁。

阶段 1 实施结果见[阶段 1 实施证据](../data-quality/tunnelpad-local-api-stage1-implementation-20260902.md)，真实 Debug/签名 Release App 验收见[阶段 1 真实环境验收](../data-quality/tunnelpad-local-api-stage1-real-app-acceptance-20260902.md)，阶段 2 收口见[独立完成复核](../data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md)。

实现前必须再次执行：

~~~bash
plan-governance-cli check . --strict-readiness
git diff --check
~~~

实现后必须执行 GitNexus detect_changes；如果比较默认分支，使用 scope compare、base_ref main，确认 API 变更没有扩散到 Rust owner、真实 launchd 或计划外 UI。

### 测试覆盖率

阶段 1 已有 API route、DTO、backend、错误分支和日志清空的专项测试证据；尚未生成覆盖率报告。若生成覆盖率报告，必须说明是否包含测试代码、随机端口 fixture 和 app target，不能用全量测试通过替代公共契约覆盖。

### 完成条件

- 阶段 0 的现状基线、9 路由协议矩阵、字段/错误契约、失败/回滚边界和独立准入复核完整。
- 阶段 1 只绑定 127.0.0.1:9998，服务随 App 启停，端口冲突只记录错误且 App 继续运行。
- 9 个接口均有可执行契约测试；OpenAPI 路由、Schema、状态码与本节契约一致。
- 启停操作遵守 TunnelManager busy/MainActor/Rust owner 语义，等待完成后返回；冲突、未知 ID、失败和超时有稳定错误响应。
- 摘要、日志和错误响应不泄露命令、URL、路径、环境变量、密钥或原始 stderr。
- 日志接口只返回受控纯文本快照；清空日志不删除配置、不停止隧道、不改变日志 watcher/路径契约。
- Rust/Swift 既有回归、隔离 App、Release/签名、治理检查、git diff --check 和 GitNexus detect_changes() 通过。
- 独立完成复核确认无计划外行为变化，并同步 PLAN_MAP.md、测试证据和状态。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-02 |
| 阶段 | 阶段 2 |
| 结论 | 通过，达到“待实施”标准并完成收口 |
| 证据 | [阶段 2 Step 0](../data-quality/tunnelpad-local-api-stage2-step0-20260902.md)、[阶段 2 独立完成复核](../data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md)、阶段 1 实现/真实环境证据和本计划完成条件 |
| 复核者 | Codex（独立只读复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-09-02 | 需求探索确认 | 阶段 0 | 通过：用户确认回环监听、第一阶段接口、安全摘要、同步启停、App 生命周期和 ModelPad 端口冲突语义 | 本计划“用户确认的探索结论” | Codex（需求探索轮次） |
| 2026-09-02 | 阶段 0 独立准入 | 阶段 0 | 待复核；当前不得进入实现 | 阶段 0 基线证据、样本矩阵、GitNexus impact | 待补充 |
| 2026-09-02 | 阶段 0 独立准入复核 | 阶段 0 → 阶段 1 | 通过，达到“待实施”标准；阶段 1 可进入实现 | [独立准入复核](../data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md) | Codex（独立只读复核） |
| 2026-09-02 | 阶段准入复核 | 阶段 1 | 通过，达到“待实施”标准 | [阶段 0 独立准入复核](../data-quality/tunnelpad-local-api-stage0-independent-review-20260902.md) | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 Step 0 独立准入复核 | 阶段 2 | 通过，达到“待实施”标准；阶段 2 可进入最终收口 | [阶段 2 Step 0](../data-quality/tunnelpad-local-api-stage2-step0-20260902.md) | Codex（独立只读复核） |
| 2026-09-02 | 阶段 2 独立完成复核 | 阶段 2 | 通过，已完成；无计划外行为变化 | [阶段 2 独立完成复核](../data-quality/tunnelpad-local-api-stage2-independent-completion-review-20260902.md) | Codex（独立只读复核） |

## 风险和回滚

| 风险 | 影响 | 缓解 | 回滚 |
|---|---|---|---|
| 本机任意进程可调用无鉴权 API | 可查询状态或控制本机隧道 | 固定回环监听；不监听局域网/公网；后续远程访问另立计划并重新设计鉴权 | 移除 API Server 启动接入，恢复无 HTTP API |
| HTTP handler 跨 MainActor 直接访问 TunnelManager | 数据竞争、状态倒灌或 Swift 6 编译失败 | 使用受控 backend/adapter；所有状态和生命周期操作在 MainActor 串行 | 回退 adapter/API 文件，不回退 Rust owner |
| 既有 async 方法吞掉错误 | API 错误被误报为成功 | 增加 typed operation result 或等价请求级结果，不读取全局 lastError 猜测 | 回滚 API adapter 和新增受控门面 |
| 启停请求超时但底层操作仍继续 | 调用方重试造成重复操作 | busy/代次保护、有界等待、超时返回未知/失败且不自动重试 | 停止 API 调用，按 UI 观察真实状态；不强制杀进程 |
| 日志清空越过现有 LogEventStore 边界 | 日志 watcher、版本或持久文件异常 | 只通过 TunnelManager 受控方法；fake fixture 验证版本、配置和 watcher 不变 | 移除 clear route，恢复现有 UI 日志路径 |
| 9998 冲突时错误处理不一致 | App 无法启动或服务漂移到未知端口 | 对照 ModelPad：捕获启动异常、记录错误、继续 App，不换端口不重试 | 移除自动启动接入，不修改端口 |
| TunnelManager CRITICAL blast radius 与当前 core-hardening 并行 | 共享状态和测试回归冲突 | 实现前精确 impact；与 core-hardening 保持单一编辑窗口；完成后 detect_changes | 只回滚 API 相关提交/文件，保留其他用户改动 |

## 关联 ADR、迁移、spec 或 issue

- TunnelPad v1 隧道管理应用（历史基线：v1 不含 HTTP API，本计划不修改其历史完成记录）
- TunnelPad 稳定性与健康恢复
- TunnelPad 日志事件流与面板生命周期
- TunnelPad Rust Core 迁移
- TunnelPad Rust Core 风险收敛与覆盖率提升
- ADR-0001：Rust Core 单一生命周期 owner
- ADR-0003：日志事件流、缓存和文件保留边界
- 阶段 0 基线证据
