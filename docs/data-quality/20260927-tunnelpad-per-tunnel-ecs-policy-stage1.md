# 逐隧道 ECS 策略阶段 1 实施证据（2026-09-27）

## 范围与决定

用户已授权按[计划](../plans/20260927/tunnelpad-per-tunnel-ecs-policy.md)实施，并进一步明确：旧 `config.json` 缺少 `ecsSyncPolicy` 时保持 `disabled`。本阶段只修改源码、测试和文档；未替换真实 App、未操作 ECS 或真实隧道。旧 ECS 项升级后须由用户受控停止并显式启用 `required`。

## Step 0 与风险

实施前检查旧源码：所有 SSH 进入 ECS 前置；启动恢复队列在建立前解析 ECS 资源；Swift/Rust 配置均无逐隧道字段。GitNexus 索引恢复后先对 `TunnelConfig`、`TunnelManager`、`ECSPreStartChecker`、启动恢复和 Rust owner 保存/重载做 impact。核心生命周期符号出现 CRITICAL/HIGH，已按高风险实施。最终 `detect-changes --scope all --repo .` 输出 21 个文件、205 个符号、101 个执行流，风险 `critical`，未报告 partial/truncated。

## 实施内容

- Swift/Rust 新增 `ecsSyncPolicy`：缺失或显式 `disabled` 均关闭，只有 SSH + `required` 同步。显式 `null`、未知值、错误类型和非 SSH + `required` 拒绝。
- 手动启停、启动恢复、健康/launchd/PID 恢复、首次 IP 漂移检查按有效策略分流；`forceRemotePortCleanup` 继续独立执行。混合启动队列以单一全局 ECS 资源串行 required 项，不在队列建立前解析云资源，普通 SSH 可以独立启动。
- Swift 运行比较和 Rust owner 配置事务纳入策略；`disabled`→`required` 在提交前要求旧身份已停止并收敛。FFI ABI 提升至 2，旧 dylib 混装失败关闭。
- 新建/编辑 UI 显示显式开关和当前全局安全组、SSH TCP 22 限制；README 记录旧配置迁移边界。

## 验证记录

| 项目 | 命令或样本 | 结果 |
|---|---|---|
| Rust 格式 | `cargo fmt --check`（格式化后） | 通过 |
| Rust 回归 | `cargo test -p tunnelpad-core` | 99 个 lib、6 个 preflight、1 个 differential、7 个 log proxy 测试通过 |
| Rust Release 动态库 | `cargo build -p tunnelpad-core --release` | 构建通过，Swift 使用 ABI 2 动态库测试 |
| Swift 配置 | `xcodebuildmcp swift-package test --package-path … --test-product TunnelPadCoreTests --filter TunnelConfigTests --output text` | 11/11 通过 |
| Swift ECS 前置 | 同命令过滤 `ECSPreStartIntegrationTests` | 17/17 通过；disabled 无脚本/资源仍可启动 |
| Swift IP 漂移与恢复 | 同命令过滤 `IPDriftRecoveryTests` | 10/10 通过 |
| Swift 全量 | 同命令不设 filter | 最终 221 通过、0 失败、1 跳过；包含 disabled SSH 健康恢复、清理与交接 |
| 混合启动队列 | 同命令过滤 `LaunchRecoveryIntegrationTests` | 最终 12/12 通过；required 前置挂起时 disabled 项先启动，disabled 后交接不重复检查 required |
| 运行期恢复 | 同命令过滤 `IPDriftRecoveryTests` | 最终 11/11 通过；disabled 清理成功/失败均无 ECS 资源解析或同步 |
| 表单回退入口 | 同命令过滤 `TunnelRemarksTests` | 6/6 通过；SSH 改非 SSH 后可见关闭入口、关闭后可保存 |
| App target | `xcodebuildmcp swift-package build --package-path … --target-name tunnelpad --configuration debug --output text` | 构建通过 |
| GitNexus 变更分析 | `node .gitnexus/run.cjs detect-changes --scope all --repo .` | `critical`；需独立复核 |
| 治理与差异 | `plan-governance-cli check . --strict-readiness`、`git diff --check` | 均通过；`check . --drift --strict-readiness` 仅提示 PLAN_MAP 说明段变更无法唯一归属索引行 |

首次 Swift 全量运行因既有 ECS 测试未显式声明 `required` 出现失败；已将这些 fixture 明确为 `required`，重新全量通过。首次 Swift 前置测试因 Release dylib 仍为 ABI 1 失败；重建 ABI 2 dylib 后通过。两类失败均未记为最终通过前的隐藏跳过。

## 独立复核与修复自验

同范围独立只读复核由未参与实现的 Codex 子代理 `ecs_policy_review` 以 high 推理强度执行，结论为未通过，并给出四项发现：混合队列 disabled 交接会重复触发其他 required 项只读检查；非 SSH 命令编辑态隐藏 required 开关导致无法关闭并保存；disabled 加远端强制清理缺少管理器级启动/运行期回归；计划背景仍称仅授权文档。复核还确认缺字段 disabled、运行中 disabled→required 门禁和 ABI 旧库拒绝未见额外可证实缺陷。GitNexus 对工作树索引标记 stale，且 CLI 无 `explain`，独立者未宣称 PDG/污点验证。

实施者随后自验闭环：交接改为仅当前 required 候选执行一次只读检查，混合队列按受控顺序验证 disabled 后交接不重复检查；表单保留 required 开关直到用户关闭，新增回退测试；启动队列和运行期恢复的 disabled 清理分别覆盖成功/失败及零 ECS 调用；更新背景授权描述。定向测试、最终 Swift 全量 221 通过/1 跳过、App target 构建通过。未再次派发独立复核；该自验不改写原独立发现和结论。

## 尚未完成

- 最终治理检查与阶段 1 状态同步。
- 阶段 2 隔离 App/真实体验验收、旧 ECS 项盘点及受控升级、真实 ECS 回归或回滚演练。本阶段测试使用假 owner/checker，不能证明真实云环境操作。
