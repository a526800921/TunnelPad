# TunnelPad 本机 HTTP API 阶段 1 真实环境验收证据

日期：2026-09-02
阶段：阶段 1（已完成）
验收范围：SwiftPM Debug 可执行 App 与签名 Release `.app` 的启动、固定 `127.0.0.1:9998` 监听、接口响应、端口冲突和退出清理

## 验收边界

- 本次使用真实 macOS 环境启动 TunnelPad Debug 可执行目标和签名 Release `.app`，不使用 fake backend 或随机测试端口。
- 当前没有受管隧道，因此不调用真实 start/stop/restart，也不触碰 launchd、SSH、ECS 或标准日志路径。
- 端口冲突使用第二个真实 TunnelPad 实例验证；不修改端口、不配置重试、不修改系统服务。
- Release `.app` 使用仓库现有 `scripts/build_app.sh --skip-tests` 生成；不修改发布配置或 Bundle ID。

## 可复现动作与结果

| ID | 动作 | 预期 | 实际结果 | 判定 |
|---|---|---|---|---|
| R1 | `lsof -nP -iTCP:9998 -sTCP:LISTEN` | 验收前无监听者 | 无输出 | 通过 |
| R2 | `xcodebuildmcp swift-package run --package-path /Users/jafish/Documents/work/TunnelPad --executable-name tunnelpad --configuration debug --background true --timeout 30` | Debug App 启动成功 | 构建成功，PID `36019` | 通过 |
| R3 | `lsof -nP -iTCP:9998 -sTCP:LISTEN` | 只有 `127.0.0.1:9998` 监听 | `tunnelpad` PID `36019` 监听 `127.0.0.1:9998` | 通过 |
| R4 | `curl http://127.0.0.1:9998/api/health`、`/api/tunnels`、`/openapi.json` | 返回 200、JSON、固定路由和回环服务器地址 | health 返回 `{"ok":true}`；列表返回 `{"ok":true,"tunnels":[]}`；OpenAPI 返回 3.1 描述且包含 9 个路由 | 通过 |
| R5 | 请求不存在的隧道详情、启停和日志 | 返回 404 `tunnel_not_found`，不产生业务副作用 | 三类请求均返回 HTTP 404 和 `tunnel_not_found` | 通过 |
| R6 | 启动第二个同配置 Debug App | 第二实例保持运行；首实例继续持有 9998；不换端口、不重试 | 第二实例 PID `36301` 存活；监听者仍只有 PID `36019` | 通过 |
| R7 | 停止 PID `36301`，再次请求 health；再停止 PID `36019`，复查进程和端口 | 冲突实例退出不影响首实例；最终无残留 | 第二实例停止后 health 仍 200；两实例停止后无进程、无 9998 监听 | 通过 |
| R8 | `./scripts/build_app.sh --skip-tests` | 生成 arm64 Release `.app`，包含资源并通过签名校验 | `dist/TunnelPad.app` 构建成功；`Info.plist` lint 通过；ad-hoc `codesign --verify --deep --strict` 通过 | 通过 |
| R9 | 使用 XcodeBuildMCP 启动 `dist/TunnelPad.app`；请求 health/list/detail/logs/OpenAPI；停止 App | Release App 自动启动 API；接口可用；退出释放端口 | PID `37161` 监听 `127.0.0.1:9998`；Bundle ID `com.jafish.tunnelpad.app`；health/list/detail/logs/OpenAPI 分别返回预期结果（HTTP `200`）；停止后无进程、无端口残留 | 通过 |

## 关键观测

真实请求响应包含：

- `GET /api/health`：HTTP `200 OK`。
- `GET /api/tunnels`：HTTP `200 OK`，当前隧道列表为空。
- `GET /openapi.json`：HTTP `200 OK`，描述 `127.0.0.1:9998` 和全部 9 个路由。
- 未知隧道详情、启停、日志：HTTP `404`，统一返回 `tunnel_not_found`。
- 第二实例启动后仍为存活进程，但没有监听 `9998`；首实例继续健康响应，验证了端口冲突不导致 App 退出、不换端口。
- 签名 Release `.app` 的 `CFBundleIdentifier` 为 `com.jafish.tunnelpad.app`，`CFBundleExecutable` 为 `tunnelpad`，`LSUIElement` 为 `true`；真实接口包含现有配置的 `admin-tunnel`、`reverse-ssh` 安全摘要，未执行真实生命周期变更。

## 阶段结论

固定端口的真实 Debug App、签名 Release `.app` 启动、API 基础路由、详情/日志读取、未知 ID 错误、端口冲突和退出清理均通过；阶段 2 独立完成复核已确认阶段 1 完成条件满足。
