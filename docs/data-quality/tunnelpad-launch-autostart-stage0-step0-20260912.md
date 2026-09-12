# 阶段 0 Step 0 基线证据：开机自启与隧道自动恢复

- 日期：2026-09-12
- 基线：`4797bec`（main，工作树仅含本计划治理文档）
- 记录者：ZCode（实施者，自验）
- 结论：基线成立，C0–C4 样本形状与竞态清单固定，阶段 1–3 可按路线图准入。

## 现状快照（运行观察，只读）

- 生产 App 运行中：`dist/TunnelPad.app`（pid 84684，自周日运行）；未做任何重启/干预，避免影响真实隧道。
- 本机 API `GET /api/tunnels`（127.0.0.1:9998）返回 3 条隧道：`admin-tunnel` = `not_loaded`、`reverse-ssh` = `not_loaded`、`motorcycle-local-docker` = `running`；`busy` 均为 false。
- `launchctl print gui/$(id -u)` 中 `com.jafish.tunnelpad` 标签计数为 2（与两条 `not_loaded`/`running` 的组合一致，加载状态不跨 App 重启保留）。
- 登录项：全工程无 `SMAppService`/LoginItem 调用（`grep -rn "SMAppService\|loginItem"` 零命中），推断注册状态为 `notRegistered`；系统侧登录项列表需图形界面确认，不在本基线用自动化断言。

## 现状快照（代码事实）

- `Sources/tunnelpad/AppDelegate.swift` `applicationDidFinishLaunching`：仅安装信号处理器、启动 API 服务、创建菜单栏、显示主窗口；无任何隧道启动调用。
- `Sources/TunnelPadCore/TunnelManager.swift`：无启动恢复/批量拉起入口；`start(_:)`/`startAsync(_:)` 为手动入口，内置 busy 保护与 SSH 的 ECS 前置同步。
- 配置契约：`Sources/TunnelPadCore/TunnelConfig.swift`（手写 `Codable`，`decodeIfPresent` 缺省兼容）与 `rust/tunnelpad-core/src/lib.rs`（serde `#[serde(default)]`）；持久化形状由 `rust/tunnelpad-core/src/apple_json.rs` 对齐 Swift `JSONEncoder(.sortedKeys + prettyPrinted)`；差分入口 `Tests/TunnelPadCoreTests/DifferentialHarnessTests.swift` case `config-store` ↔ `rust/tunnelpad-core/tests/differential.rs`，fixture `rust/differential/fixtures/config-store.json`。
- 基线测试：`swift test` 145/145 通过（2026-09-12，含本计划前的弹窗修复）；Rust/差分以各阶段实施时的运行输出为准。

## C0–C4 契约样本形状（阶段 1 差分/单测输入）

- **C0 旧配置缺字段**：`{"version":1,"tunnels":[{"id":"web","name":"web","command":["/usr/bin/ssh","-N"]}]}` → 两侧解码成功，`autoStart` 视为 `false`，保存后补写 `"autoStart" : false`。
- **C1 显式 false**：同上但含 `"autoStart":false` → 解码与保存行为与 C0 等价。
- **C2 显式 true**：`"autoStart":true` → 两侧解码为 true，保存保留 `"autoStart" : true`。
- **C3 非法类型**：`"autoStart":"yes"` → 两侧均按损坏配置拒绝（走既有 recoveredFrom 路径），错误语义一致。
- **C4 version 不变**：`version=2` 拒绝（fixture 已有 `bad-version`），新增字段不改变 version 检查。
- 键序约定：保存输出为 Swift `sortedKeys` 字母序，tunnel 键序为 `autoStart, command, executor, id, keepAlive, name, probe, remark, throttleInterval`（`autoStart` 排最前）；Rust `apple_json.rs` 同步。

## 竞态与恢复边界清单（阶段 3 准入输入）

| 编号 | 场景 | 预期 |
|---|---|---|
| R1 | App 崩溃后重启，launchd 作业仍在运行 | 首轮状态发现为 `running` → 跳过，不重复启动 |
| R2 | 恢复时该隧道 busy（其他操作在途） | 复用 start 入口的 busy 门禁，本条不启动、不阻断其他条 |
| R3 | SSH 隧道 ECS 前置同步 fail-closed（网络未就绪） | 该条启动失败、`lastError` 可见，其余继续；无重试循环 |
| R4 | `autoStart=false`（含缺省） | 永不参与恢复 |
| R5 | 恢复入口被重复触发（窗口/菜单栏再次刷新） | 每次进程生命周期只执行一次 |
| R6 | 状态发现失败（snapshot 异常，状态未知） | fail-closed：全部跳过，不盲目启动 |

## Step 0 样本

- 命令：`curl -s http://127.0.0.1:9998/api/tunnels`；`launchctl print gui/$(id -u) | grep -c com.jafish.tunnelpad`；`grep -rn "SMAppService\|loginItem" Sources`（零命中）。
- 预期/失败判定：如上"现状快照"；若后续复验时隧道状态不同（用户手动操作所致），以"启动流程无隧道启动调用"的代码事实为基线锚点。
- 输出位置：本文件。

## 复核

- 方式/风险：自验；低风险（纯基线观察与样本固定，无生产代码变更）。
- 结论：通过（2026-09-12，实施者自验）。
