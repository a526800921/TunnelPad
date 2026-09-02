# TunnelPad 本机 HTTP API 阶段 1 实施证据

日期：2026-09-02
阶段：阶段 1（已完成）
范围：SwiftNIO 本机 API、TunnelManager 受控 backend、AppDelegate 生命周期接入、日志原位清空和随机端口契约测试

## 已实现范围

- `TunnelAPIServer` 默认绑定 `127.0.0.1:9998`；测试可使用 `port=0`，不改变生产默认值。
- API 只通过 `TunnelAPIBackend` 访问业务；App target 的 `TunnelManagerAPIBackend` 将调用转回 `@MainActor` TunnelManager。
- `startAsync`、`stopAsync`、`restartAsync` 返回请求级 `TunnelOperationResult`；已有 UI 调用仍可忽略返回值。
- 启停 API 使用 60 秒有界等待；超时返回 504 `operation_timeout`，底层任务不由 HTTP 层重复触发。
- 日志通过 `TunnelManager.clearLog` 和 `LogEventStore.clear` 原位清空，保留 watcher、路径、订阅者和配置。
- App 启动时启动 API；绑定失败只记录错误并继续 App；退出时先后台停止 API，再进入既有 Rust Core shutdown。
- 摘要只返回 id、name、remark、executor、keepAlive、throttleInterval、status、pid、busy 和探针分类，不返回 command、URL、路径、环境变量或原始错误。

## 可复现验证

| 项目 | 命令/动作 | 结果 |
|---|---|---|
| API 专项契约 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --configuration debug --filter TunnelAPIServerTests` | 4/4 通过；随机端口覆盖健康、列表、详情、日志、清空、OpenAPI、错误码、冲突、超时和错误方法 |
| 日志清空回归 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --configuration debug --filter LogEventStoreTests` | 11/11 通过；原位截断、版本递增、事件和 watcher 边界通过 |
| Swift 全量回归 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --configuration debug` | 134/134 通过；包含 Core 与 executable target 编译 |
| SwiftNIO 依赖解析 | 上述首次测试的 XcodeBuildMCP build log | `swift-nio` 解析到 2.102.0；无依赖编译错误 |
| 代码图谱刷新 | `node .gitnexus/run.cjs analyze` | Repository indexed successfully；3,979 nodes、11,761 edges、279 flows |
| 变更范围检测 | GitNexus `detect_changes({scope:"unstaged", worktree:"/Users/jafish/Documents/work/TunnelPad"})`；随后刷新图谱并对精确符号执行 upstream impact | 变更检测风险为 CRITICAL；刷新后的精确结果为 `TunnelAPIServer` CRITICAL/101 个上游、`startAsync` HIGH/8、`stopAsync` HIGH/7、`restartAsync` LOW/5、`clearInPlace` HIGH/4、`clearLog` LOW/1、`LogEventStore.clear` LOW/3。影响集中在 API 操作、日志清空、App 启停和既有菜单/健康流程；未直接修改 Rust owner |
| 真实 Debug App 验收 | 通过 XcodeBuildMCP 启动真实 SwiftPM Debug `tunnelpad`；curl 固定端口；启动第二实例验证冲突；停止两个验收实例 | PID `36019` 监听 `127.0.0.1:9998`；health/list/OpenAPI 和未知 ID 错误符合契约；第二实例 PID `36301` 存活但不抢占端口；清理后无进程和端口残留 | [阶段 1 真实环境验收](tunnelpad-local-api-stage1-real-app-acceptance-20260902.md) |

## 尚未完成的阶段 1 门禁

- 已完成真实 SwiftPM Debug App 的启动、固定 9998 路由、未知 ID、第二实例端口冲突和退出清理；未触碰真实隧道、launchd、SSH、ECS 或标准日志路径。
- 签名 `.app`/Release 启停、签名/Info.plist 验收已在[阶段 1 真实环境验收](tunnelpad-local-api-stage1-real-app-acceptance-20260902.md)中通过。
- 阶段 2 独立完成复核已确认阶段 1 完成条件满足；本记录由阶段 2 独立复核和完成快照共同引用。

## 安全与回滚

新增 API、适配器和测试可以整体移除；回滚不涉及 Rust owner、launchd plist、真实隧道或既有日志数据。若固定 9998 被占用，当前生产代码只打印 `[TunnelPad] API 服务启动失败：...`，不换端口、不重试，App 继续启动。
