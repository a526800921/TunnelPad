# 阶段 1–3 实施证据：开机自启与隧道自动恢复

- 日期：2026-09-12
- 基线：`4797bec`（main）之上的工作树实施；记录者 ZCode（实施者）
- 复核策略：风险分流；阶段 1/3 高影响各做一次独立复核（见同日复核记录），阶段 2 低风险自验

## 阶段 1：autoStart 配置契约与表单开关

改动：

- `rust/tunnelpad-core/src/lib.rs`：`TunnelConfig` 追加 `#[serde(default)] auto_start: bool`（camelCase → `autoStart`）；契约常量 FULL/MINIMAL_CANONICAL 同步；新增 `auto_start_defaults_false_and_rejects_bad_type` 测试。
- `rust/tunnelpad-core/src/apple_json.rs`：保存字节格式 tunnel 首键插入 `"autoStart" : <bool>`（字母序最前）；既有字节测试期望同步。
- `rust/tunnelpad-core/src/owner.rs`：测试构造器补 `auto_start: false`。
- `rust/differential/fixtures/config-store.json`：新增 `auto-start-default`（C0）、`auto-start-false`（C1）、`auto-start-true`（C2）、`auto-start-bad-type`（C3）；C4 由既有 `bad-version` 承载。
- `Sources/TunnelPadCore/TunnelConfig.swift`：`autoStart` 字段、成员 init 默认 `false`、`decodeIfPresent ?? false`、CodingKeys 追加。
- `Sources/tunnelpad/TunnelFormState.swift`：表单字段回填与 `makeTunnel` 携带。
- `Sources/tunnelpad/NewTunnelSheet.swift` / `TunnelSettingsSheet.swift`：「随 App 启动自动拉起」Toggle。
- `Tests/TunnelPadCoreTests/TunnelConfigTests.swift`：`testAutoStartDefaultsAndRoundtrip`（缺省/显式/非法类型/往返）。
- `Tests/TunnelPadCoreTests/DifferentialHarnessTests.swift`：legacy-derive 事件流补 `autoStart` 键（与 Rust serde 全字段序列化对齐）。

验证：`swift test` 通过、`cargo test` 77+1 通过、`bash rust/scripts/differential.sh` 差分 parity 通过；独立复核 8/8 通过（[阶段 1 独立复核](tunnelpad-launch-autostart-stage1-independent-review-20260912.md)），信息性疑问（显式 `null` 双侧不对称）属既有 keepAlive 同形模式，不在本阶段范围。

## 阶段 2：登录自启动（SMAppService 开关）

改动：

- `Sources/tunnelpad/LoginItemController.swift`（新增）：`SMAppService.mainApp` 薄封装；`LoginItemState`（enabled/requiresApproval/notRegistered）映射、`toggle()`、`openSystemSettings()`、注册失败经 `registrationError` 呈现；测试用 `init(state:)` 缝隙不触达系统服务。
- `Sources/tunnelpad/MenuBarController.swift`：菜单新增「登录时自动启动」（勾选态；requiresApproval 时标题带"待系统设置批准"），切换失败弹窗提示，待批准时引导打开系统设置。
- `Tests/TunnelPadCoreTests/LoginItemControllerTests.swift`（新增）：状态映射 4 例 + 开关语义 3 例；不触达真实系统注册。

验证：`swift test` 通过；register/unregister 真实行为不在单测触达（避免污染系统登录项），归入用户登录验收。备注：登录项注册以打包 .app 为载体，`swift run` 裸二进制不适用。

## 阶段 3：启动自动恢复

改动：

- `Sources/TunnelPadCore/TunnelManager.swift`：新增 `restoreAutoStartTunnels()`——幂等标志先置位（单次尝试语义）→ `refreshAsync` → 有界轮询等待首轮状态发现产出（与 init 启动的健康监测首轮快照并发互相失效，`beginStateRead` 共享计数，二者必有一个发布成功；注入参数默认 50×100ms，超时 fail-closed）→ 对 `autoStart=true` 且状态 `notLoaded`/`notRunning` 的候选顺序复用 `startAsync`（busy 保护 + ECS 前置同步内置）。init 追加两个注入参数（测试用）。
- `Sources/tunnelpad/AppDelegate.swift`：`applicationDidFinishLaunching` 末尾 `Task { @MainActor in await manager.restoreAutoStartTunnels() }`，不阻塞面板出现。
- `Tests/TunnelPadCoreTests/TunnelManagerTests.swift`：StubLifecycleOwner 扩展（startedIDs 记录、failStartIDs、statusOverrides、failSnapshot）；R1/R3/R4/R5 由 `testRestoreAutoStartTunnelsHonorsGates` 覆盖，R6 由 `testRestoreAutoStartSkipsAllWhenDiscoveryFails` 覆盖；R2 busy 由 startAsync 既有 `beginOperation` 门禁保证（恢复丢弃 `.inProgress` 结果），无直接专项测试（轻微缺口，复核已记录）。

验证：`swift test` 150/150 通过；恢复专项连跑 5 次 + 复核者复跑 5 次全过；R2 busy 场景与 R3"失败不阻断后续"的顺序性断言偏弱为复核记录的轻微观察，无必须修复项（[阶段 3 独立复核](tunnelpad-launch-autostart-stage3-independent-review-20260912.md)）。

## 范围外工作树改动（非本计划产物，实施期间出现）

工作树含一组本实施未编写的改动：移除主面板全局错误栏（`MainPanelView.messageBar`）、健康恢复的进度/冷却/失败不再写 `lastError`（`TunnelManager` 两处）、`StabilityStage1/2Tests` 配套断言调整。注释口径为"lastError 只供新增/设置弹窗就地展示操作错误"。与 4797bec 的弹窗修复方向一致，全部验证（150/150、两轮独立复核）在含该改动的工作树上通过；归属需工作树所有者确认。影响：自动恢复启动失败的 `lastError` 目前无界面消费方，计划验收场景"错误栏可见"口径待用户确认调整。

## 追加：恢复过程写入 App 事件日志（2026-09-12 用户确认口径后追加）

用户确认"恢复失败输出到日志"后追加实施：

- 新增 `Sources/TunnelPadCore/AppEventLog.swift`：追加式 App 事件日志 `~/Library/Logs/TunnelPad/app.log`（ISO8601 时间戳一行一事件，512 KiB 上限、超限保留较新一半并对齐行首；写失败静默）。`TunnelPaths` 追加 `appEventLogURL`。隧道进程输出与保留策略仍归 launchd/Rust owner，不越界。
- `restoreAutoStartTunnels` 全过程写入：触发、状态发现超时 fail-closed、逐条拉起成功/失败（失败带 startAsync 写入 `lastError` 的完整原因）/正忙跳过/已不存在、完成汇总（成功/失败/跳过/候选数）。
- 测试：`AppEventLogTests`（追加与轮转 2 例）；恢复专项追加 app.log 内容断言（成功行、失败行含原因、汇总行、autoStart=false 不出现、超时行）。`swift test` 152/152 通过。

## 汇总

| 验证项 | 结果 |
|---|---|
| `swift test` | 152/152 通过（含 AppEventLog 2 例与恢复日志断言） |
| `cargo test`（tunnelpad-core） | 77+1 通过 |
| 差分门禁 `rust/scripts/differential.sh` | parity 通过 |
| 恢复专项 flakiness | 实施者 5 次 + 复核者 5 次零失败 |
| 阶段 1 独立复核 | PASS（8/8） |
| 阶段 3 独立复核 | PASS（无必须修复项，3 项轻微观察） |
| `plan-governance-cli check .` | 见计划同步记录 |
