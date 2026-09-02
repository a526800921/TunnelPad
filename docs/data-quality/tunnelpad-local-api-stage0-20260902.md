# TunnelPad 本机 HTTP API 阶段 0 基线证据

日期：2026-09-02
基线类型：新公共 API 的现状源码快照、参考实现对照和协议样本基线。

## 结论摘要

当前 TunnelPad 尚未实现 HTTP API Server，也没有监听 9998 的进程。ModelPad 已有可复用的实现形态：SwiftNIO 嵌入式 HTTP Server，由 AppDelegate 在应用启动时启动、退出时停止，绑定失败只记录错误并继续运行 App。

本次需求已由用户确认：TunnelPad 服务只绑定 127.0.0.1:9998；第一阶段只提供健康、隧道查询、启停重启、日志和 OpenAPI；不开放配置写入、任意命令、ECS 或旧服务接管。

## 可复现的现状检查

### 1. TunnelPad 当前没有 API Server

命令：

~~~bash
rg -n "APIServer|NIOHTTP1|ServerBootstrap|HTTPServerRequestPart|NWListener|HTTP API Server" Sources Tests Package.swift
~~~

结果：退出码 1，没有匹配。当前 Package.swift 也没有 SwiftNIO 依赖。现有 HTTP 相关代码只用于隧道状态探针，不是对外 HTTP 服务。

### 2. 9998 当前没有监听者

命令：

~~~bash
lsof -nP -iTCP:9998 -sTCP:LISTEN
~~~

结果：退出码 1，没有监听进程。

### 3. 现有 TunnelManager 接口边界

- TunnelManager 是 @MainActor 门面，公开 config、statuses、probeResults、busyIDs 和 tunnel(id:)。
- 已有 startAsync、stopAsync、restartAsync，但返回 Void，失败写入 lastError；不能直接把“没有抛错”解释为 API 操作成功。
- 已有 logSession(for:) 和 refreshLog(for:)，返回 LogSnapshot，日志内容是受限纯文本快照。
- 当前没有公开的清空单条隧道日志门面，新增日志 API 必须通过 TunnelManager 的受控方法接入，不能让 HTTP handler 直接操作路径或 LogEventStore 私有状态。

### 4. ModelPad 参考实现

- ModelPad/Sources/ModelPadCore/API/APIServer.swift 使用 SwiftNIO 绑定 127.0.0.1:9999，路由包括健康、列表、详情、启停、日志和 OpenAPI。
- ModelPad/App/Sources/AppDelegate.swift 在 applicationDidFinishLaunching 中调用 apiServer.start()；失败只 print 错误，App 继续启动；退出阶段对 Server 执行 best-effort stop。
- ModelPad 的 API 摘要不返回 command、workDir 和 env，本计划沿用敏感字段不泄露原则。

### 5. 影响分析

对 TunnelManager 做上游 GitNexus 影响分析：

~~~text
target: TunnelManager
direction: upstream
risk: CRITICAL
impactedCount: 130
direct: 81
depth 2: 40
depth 3: 9
modules: TunnelPadCore, TunnelPadCoreTests
~~~

因此实现阶段必须采用独立 API 适配边界，并与当前 tunnelpad-core-hardening 及已完成稳定性/日志行为保持单一编辑窗口；不得把 HTTP handler 直接散落到 Rust owner、UI 或真实 launchd 路径。

## 协议样本基线

以下样本是阶段 0 的待执行契约 fixture；服务尚未实现，当前不把样本响应伪造为已通过结果。

~~~bash
curl -i http://127.0.0.1:9998/api/health
curl -i http://127.0.0.1:9998/api/tunnels
curl -i http://127.0.0.1:9998/api/tunnels/reverse-ssh
curl -i -X POST http://127.0.0.1:9998/api/tunnels/reverse-ssh/start
curl -i -X POST http://127.0.0.1:9998/api/tunnels/reverse-ssh/stop
curl -i -X POST http://127.0.0.1:9998/api/tunnels/reverse-ssh/restart
curl -i http://127.0.0.1:9998/api/tunnels/reverse-ssh/logs
curl -i -X POST http://127.0.0.1:9998/api/tunnels/reverse-ssh/logs/clear
curl -i http://127.0.0.1:9998/openapi.json
~~~

这些请求只能在隔离 fixture 或用户明确指定的本机服务窗口执行；不能以真实隧道操作替代阶段 0 契约测试。

## 阶段 0 边界

- 本证据只固定现状和已确认需求，不表示 API 已实现。
- 当前工作树中用户已有的 Rust Core、PLAN_MAP.md 和 tunnelpad-core-hardening 变更不属于本计划，保留原状。
- 实现前还必须完成 API 适配方式、错误返回、同步等待上限、日志清空门面和测试 fixture 的独立准入复核。
