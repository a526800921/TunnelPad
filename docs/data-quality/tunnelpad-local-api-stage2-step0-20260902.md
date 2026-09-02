# TunnelPad 本机 HTTP API 阶段 2 Step 0 证据

日期：2026-09-02
阶段：阶段 2
基线类型：阶段 1 实现证据、真实 Debug/Release App 运行报告、当前仓库反向引用和最终治理门禁基线

## 目标与边界

阶段 2 只做本机 API 的受控 App/Release 验收、独立复核和治理收口。API 契约、实现、测试和真实运行行为不再扩展；不执行真实隧道启停、日志清空、SSH、ECS 或配置写入。

## 样本矩阵

| ID | 输入或基线 | 可执行命令/动作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| B0 | 阶段 1 API 实现 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --configuration debug` | Swift 全量回归通过，API/日志专项覆盖保留 | 任一测试失败或出现跳过 | 阶段 1 实施证据 |
| B1 | Rust Core owner | `cargo test --locked --manifest-path rust/Cargo.toml` | Rust unit/differential 回归通过 | 生命周期、FFI 或差分测试失败 | 阶段 1 实施证据 |
| B2 | 发布产物 | `./scripts/build_app.sh --skip-tests`；`plutil -lint`；`codesign --verify --deep --strict` | arm64 Release `.app`、Info.plist、资源和签名校验通过 | 构建、资源、Info.plist 或签名失败 | 阶段 1 真实环境验收 |
| B3 | 固定服务地址 | XcodeBuildMCP 启动 `dist/TunnelPad.app`；`lsof -nP -iTCP:9998 -sTCP:LISTEN` | Release App 监听 `127.0.0.1:9998` | 监听地址漂移、端口错误或 App 未启动 | 阶段 1 真实环境验收 |
| B4 | API 全路由/安全字段 | curl health、list、detail、logs、OpenAPI、未知 ID和错误方法；正文敏感内容不落盘 | 200/400/404 与 JSON/OpenAPI 契约一致；摘要不泄露命令、URL、路径和密钥 | 路由缺失、状态码漂移或敏感字段泄露 | 阶段 1 真实环境验收；API 专项测试 |
| B5 | 端口冲突 | 启动第二个真实 Debug 实例；观察两个进程和 9998 listener | 第二实例继续运行，首实例持有端口；不换端口、不重试 | App 因冲突退出、服务换端口或残留重试 | 阶段 1 真实环境验收 |
| B6 | 生命周期清理 | 通过 XcodeBuildMCP 停止验收实例；复查进程和端口 | App 停止后无 TunnelPad 进程和 9998 listener | 进程、listener 或受控资源残留 | 阶段 1 真实环境验收 |
| B7 | 范围与治理 | `git diff --check`；`plan-governance-cli check . --strict-readiness`；GitNexus `detect_changes()`；反向 `rg` | 变更限于 API、适配、测试和治理文档；无治理 ERROR 或旧草案事实源 | 计划外代码/资源、治理失败或反向引用漂移 | 本 Step 0 与独立完成复核 |

## 失败和回滚边界

- 任何 Release/接口/治理失败只停止验收实例，删除或回滚本地 API 接入及其文档，不触碰真实隧道、launchd plist、SSH、ECS 或标准日志数据。
- 端口冲突沿用 ModelPad：App 继续运行但 API Server 不监听，不换端口、不重试。
- 本阶段不以 Release App 的只读状态发现为理由启动 `not_loaded` 隧道，不调用真实 start/stop/restart，也不调用日志清空。

## Step 0 结论

阶段 1 实现、Debug/Release App 真实验收、回归、签名、范围和治理证据已齐备，阶段 2 具备独立复核条件。该 Step 0 不单独替代独立完成复核。
