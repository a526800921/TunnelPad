# 计划：TunnelPad 隧道备注说明与列表副标题

- 状态：已完成
- 当前阶段：-
- 最后更新：2026-08-31
- 前置：`tunnelpad-v1`、`tunnelpad-code-quality-refactor` 和 `tunnelpad-rust-migration` 阶段 5 已完成；本计划阶段 0–3 已完成

本计划只处理隧道管理备注字段和左侧列表副标题展示。当前“刷新配置”只重新读取配置并刷新状态、不会重写执行器配置或重启运行中隧道的事实在本计划中作为现状记录，不在本计划内改变；若要让刷新按钮自动应用运行中隧道的新命令、执行器或保活参数，应另立运行时配置热应用计划。

## 背景

当前 `TunnelConfig` 只有 `id`、`name`、`command`、执行器、保活、节流和探针等字段，没有说明隧道用途的管理元数据。左侧列表行在名称下面展示由 id 派生的 launchd label，无法直接说明“这个隧道是做什么用的”。

当前左下角刷新按钮调用 `TunnelManager.reloadConfigAsync()`；该入口后台读取 `config.json`，替换内存配置、裁剪已删除隧道的运行时状态并调用 `refreshAsync()`，不会调用启动/停止/重启生命周期，也不会重新生成并加载 launchd plist。`updateTunnelAsync()` 的现有提示也明确说明：运行中的隧道在下次重启后使用新参数。因此，外部编辑配置后，名称和备注等展示字段可通过刷新立即更新，但运行中执行器参数仍沿用现有的“下次重启生效”语义。

## 目标

- 为每条隧道增加一项用于说明用途的 `remark` 字段，并保持旧 `config.json` 缺少该字段时可以正常读取。
- 在新建和编辑隧道表单的“基本信息”区域提供“备注说明”输入项。
- 在左侧隧道名称下面显示备注；备注为空时保留现有 launchd label 作为兼容兜底，避免旧配置的副标题变空。
- 通过配置序列化、旧配置兼容、表单保存和列表展示测试，证明备注只影响管理展示，不影响隧道启停、探针、日志路径、launchd label 或重连策略。

## 非目标

- 不在本计划内修改“刷新配置”对运行中隧道的应用语义；刷新仍只重新加载配置、刷新状态和探针展示，不隐式停止、重启或重新 bootstrap 隧道。
- 不修改隧道 `id`、launchd label、日志文件名或日志路径。
- 不让备注参与命令解析、执行器选择、`keepAlive`、`throttleInterval`、探针、健康恢复或孤儿进程收敛。
- 不新增 HTTP API、远端同步、备注搜索、排序、Markdown/富文本或多行列表布局。
- 不在本计划完成前修改共享配置模型和 UI；Rust Core 迁移阶段 5 完成后，已按 Rust 配置模型作为正式事实源完成备注实现。
- 不把当前“刷新后需手动重启”现状误写成刷新按钮已经具备热应用能力。

## 需求探索

### 已确认事实

- 左下角刷新按钮位于 `MainPanelView`，动作是 `Task { await manager.reloadConfigAsync(); rescanLegacyAgents() }`，帮助文案为“重新加载 config.json”。[MainPanelView.swift](../../Sources/tunnelpad/MainPanelView.swift)
- `reloadConfigAsync()` 只加载并替换配置、裁剪运行时状态，然后调用 `refreshAsync()`；没有调用 `start`、`stop`、`restart` 或 launchd plist 写入流程。[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)
- 编辑保存路径明确提示运行中的隧道在下次重启后使用新参数；切换执行器时只停止旧执行器实例，不会把普通参数修改自动重启。[TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)
- `TunnelConfig` 使用手写 `Codable` 解码器，已有 `executor`、`keepAlive`、`throttleInterval` 和 `probe` 的缺省兼容模式，适合追加可选备注字段。[TunnelConfig.swift](../../Sources/TunnelPadCore/TunnelConfig.swift)
- `TunnelSidebarRow` 当前在隧道名称下显示 `tunnel.launchdLabel`；新建和编辑表单共用 `TunnelFormState`，基本信息区目前只有名称输入。[TunnelDetailComponents.swift](../../Sources/tunnelpad/TunnelDetailComponents.swift)；[TunnelFormState.swift](../../Sources/tunnelpad/TunnelFormState.swift)；[TunnelSettingsSheet.swift](../../Sources/tunnelpad/TunnelSettingsSheet.swift)；[NewTunnelSheet.swift](../../Sources/tunnelpad/NewTunnelSheet.swift)
- 当前 HEAD 为 `90dba27b582411c6c836233cc3d1319c03593001`，工作树干净；Rust Core 阶段 5 已完成并由 Rust 作为配置读写、schema 校验和生命周期的唯一 owner。本计划不把 Rust 迁移历史改动归入备注功能，也不覆盖既有提交。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| 配置字段名采用 `remark`，类型为非可选 `String`，缺失时解码为 `""`；编码时写出该字段 | 旧 JSON、带中文/emoji/引号的备注和空备注进行编码/解码 round-trip；确认旧配置不报错且字段值稳定 |
| 表单保存前去除备注首尾空白；备注为空时保存为空字符串，不阻塞隧道保存 | 新建/编辑表单 fixture 覆盖普通备注、首尾空白和空值；检查持久化结果及验证错误 |
| 左侧副标题使用备注的一行截断展示；空备注回退到现有 launchd label | 组件表示层测试或受控应用冒烟覆盖有备注、空备注和旧配置三种输入；确认不改变名称、执行器徽标和状态圆点 |
| 备注作为管理元数据，不触发运行时生命周期变化 | 保存备注、外部改备注后刷新、保存前后比较 fake executor 调用记录；预期无 stop/start/restart/bootstrap/bootout 额外调用 |
| `remark` 的追加不会破坏 Rust/Swift 配置 parity | Rust Core 迁移阶段 5 完成后，以 Rust 配置 owner 为准；实施时用同一组旧/新 JSON 执行 Rust schema 与 Swift 表单适配差分检查 |

### 范围与非目标

本计划覆盖 `config.json` 的单条隧道备注字段、Swift 配置模型的兼容解码、新建/编辑表单绑定、左侧列表副标题和对应测试。备注只服务于识别和管理隧道，不进入执行器配置或运行时状态机。

“刷新配置”在本计划中只作为可验证的现状边界：外部修改备注后，刷新可以更新列表展示；外部修改 command、executor、keepAlive 或节流参数后，运行中的隧道仍需手动重启才能使用新参数。改变这一边界属于另一个需要单独定义安全重启、失败回滚和状态一致性的计划。

### 候选方案与取舍

| 方案 | 取舍 | 结论 |
|---|---|---|
| 复用 `name` 或把用途写入 launchd label | 不新增字段，但名称和系统标识语义混杂，且会影响现有标识/日志关联 | 不采用 |
| 新增必填 `remark` | 展示信息完整，但破坏旧配置和现有新建流程，备注不应成为启动前置条件 | 不采用 |
| 新增可选 `remark` 字符串 | 向后兼容，旧配置可直接读取；空值有明确 UI 兜底 | **采用** |
| 备注有值时完全隐藏 launchd label | 符合副标题用途，但失去当前可见的系统标识，旧配置和排障习惯不一致 | 不作为首选 |
| 备注优先、空值回退 launchd label | 新配置直接表达用途，旧配置和空备注仍有可识别副标题 | **采用** |
| 借刷新配置自动重启所有受影响隧道 | 能立即应用参数，但会引入批量重启、失败回滚、用户正在使用的连接被打断等运行时风险 | 不纳入本计划 |

### 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 配置字段内部名称 | 使用 `remark`，UI 文案为“备注说明” | 否 | 按推荐方案记录，实施前可调整 |
| 备注有值时是否保留 launchd label | 备注作为副标题；无备注时回退 launchd label | 否 | 按推荐方案记录，实施前可调整 |
| 何时实施配置模型变更 | Rust Core 迁移阶段 5 已完成并确定 Rust 为配置事实源；阶段 0 已完成准入 | 否 | 已进入阶段 1 实施 |

### 用户确认的探索结论

2026-08-30 用户要求：在左侧隧道列表名称下面展示说明当前隧道用途的备注，并在隧道配置中增加备注说明字段。当前刷新配置只更新配置文件/内存和状态，不自动应用运行中执行器新参数的事实单独保留；本计划不把刷新热应用作为隐含需求。

## 公共契约变化

拟对 `config.json` 的 `tunnels[]` 增加字段：

```json
{
  "id": "admin-tunnel",
  "name": "后台隧道",
  "remark": "用于后台管理访问",
  "command": ["/usr/bin/ssh", "-N"]
}
```

- `remark`：字符串，默认值 `""`。
- 手写解码器使用 `decodeIfPresent(String.self, forKey: .remark) ?? ""`；缺少该字段的旧配置继续有效。
- Swift `Codable` 编码会写出 `remark`，因此新保存的配置包含该字段；不要求对旧文件做一次性迁移。
- 备注不参与 `id`、launchd label、日志路径、plist、PID、探针和生命周期状态的派生。
- 如果 Rust Core 迁移的正式配置事实源与此字段方案不一致，必须先更新本计划和迁移文档，再进入实现；不得只修改一侧。

## 影响模块或文件

- 配置契约与 owner：`Sources/TunnelPadCore/TunnelConfig.swift`、`rust/tunnelpad-core/src/lib.rs`、`rust/tunnelpad-core/src/apple_json.rs`、`rust/tunnelpad-core/src/owner.rs`
- 表单与列表：`Sources/tunnelpad/TunnelFormState.swift`、`Sources/tunnelpad/TunnelSettingsSheet.swift`、`Sources/tunnelpad/NewTunnelSheet.swift`、`Sources/tunnelpad/TunnelDetailComponents.swift`
- 测试与差分：`Package.swift`、`Tests/TunnelPadCoreTests/TunnelConfigTests.swift`、`Tests/TunnelPadCoreTests/TunnelManagerTests.swift`、`Tests/TunnelPadCoreTests/TunnelRemarksTests.swift`、`Tests/TunnelPadCoreTests/DifferentialHarnessTests.swift`、`rust/differential/fixtures/config-store.json`
- 治理证据：`docs/PLAN_MAP.md`、`docs/data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md`

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 固定刷新现状、备注字段契约、兼容与 UI 兜底边界 | 用户提出备注字段和列表副标题目标 | 只读源码核对、旧/新 JSON 样本设计、治理检查 | 已完成 |
| 阶段 1 | 实现 Rust 配置模型与 Swift `TunnelFormState` 的备注字段和双表单保存 | 阶段 0 独立准入通过；Rust Core 迁移阶段 5 已完成 | Rust schema/Swift 适配 parity、旧配置解码、新建/编辑保存测试 | 已完成 |
| 阶段 2 | 实现左侧列表副标题并验证刷新后的展示更新 | 阶段 1 模型和表单测试通过 | 有备注、空备注、旧配置、外部刷新和不触发生命周期测试 | 已完成 |
| 阶段 3 | 受控应用验收、反向引用和发布门禁收口 | 阶段 2 独立复核通过 | `swift test`、适用的 `cargo test`/差分、构建、AX/应用冒烟和治理检查 | 已完成 |

## 当前阶段

### 范围

阶段 0–3 已完成：`remark` 配置字段由 Rust owner 读写，Swift UI 负责双表单绑定和左侧副标题展示；已覆盖旧配置缺省、Unicode/引号 round-trip、新建/编辑表单保存、刷新边界和生命周期隔离。不修改真实配置，不重启或停止真实隧道。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 阶段 0 已完成现状源码快照、Rust owner 前置和兼容边界核对；阶段 1–3 均已完成实现、验证和独立收口复核 |
| 样本矩阵 | 7 行，覆盖刷新边界、旧配置、新备注、空备注、表单保存、执行器调用隔离和治理反向引用；均已执行并在阶段证据中记录 |
| 验证方式 | Rust 单测、Swift 单测、Rust/Swift 差分、表单 fixture、受控 UI/AX 冒烟、生命周期隔离和治理检查 |
| 失败/回滚边界 | 备注保存/展示失败不得改变隧道生命周期；按独立提交回滚 Rust/Swift 备注改动，不覆盖既有迁移提交；刷新热应用不在本计划内 |
| 当前阻塞项 | 本计划无；全仓严格治理检查另有 ECS 计划的状态漂移，属于并行计划，不改变本计划完成结论 |
| 最新独立准入复核 | 2026-08-31：阶段 3 通过，达到本计划完成标准 |

### 实施步骤

1. 在 Rust `TunnelConfig` 和 Apple JSON renderer 中追加 `remark`，缺省为空字符串且新保存配置显式写出。
2. 在 Swift `TunnelConfig`、`TunnelFormState` 和新建/编辑表单中追加备注绑定，保存前去除首尾空白。
3. 补齐 Swift/Rust 旧配置兼容、Unicode round-trip、表单保存和配置字段不影响 launchd 派生值的测试。
4. 阶段 1 通过后进入阶段 2，实现备注优先、launchd label 兜底的列表副标题，并验证外部刷新只更新展示。
5. 阶段 2 通过后完成受控应用冒烟、差分/回归、治理检查和独立完成复核。以上步骤已全部完成，具体结果见[阶段 1–3 实施证据](../data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md)。

### Step 0 证据（阶段 1–3）

基线类型：前置阶段完成后的实现基线。阶段 0 已确认左下角刷新只调用 `reloadConfigAsync()`/`refreshAsync()`，不重写 plist 或重启运行中的隧道；实施前的 Swift 与 Rust `TunnelConfig` 均未有 `remark`；Rust Core 阶段 5 已完成并作为配置读写、schema 校验和生命周期唯一 owner。2026-08-31 在干净 HEAD `90dba27b582411c6c836233cc3d1319c03593001` 完成独立准入复核，阶段 1 的代码影响范围和回滚边界已固定。

阶段 1–3 的实现基线是 `remark` 缺失时解码为 `""`、编码时显式写出；备注只进入配置和 UI 展示，不进入 command、executor、plist、label、日志路径、探针或生命周期调用。隔离样本、配置差分、表单和 AX 证据均已按样本矩阵执行，未以“编译通过”替代行为验证。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前刷新按钮和运行时入口 | `rg -n 'reloadConfigAsync|refreshAsync|下次重启|restart|bootstrap' Sources/tunnelpad/MainPanelView.swift Sources/TunnelPadCore/TunnelManager.swift` | 证实刷新只重载配置/刷新状态；运行参数沿用到下次重启 | 出现隐式重启、plist 重写或源码与现状记录矛盾 | 阶段 0 证据与本计划 |
| 2 | 旧 `config.json`，单条 tunnel 缺少 `remark` | `swift test --filter TunnelConfigTests`；实现阶段追加无 `remark` fixture | 解码成功，`remark == ""`，既有字段不变 | 解码失败、字段变成 nil 或既有默认值漂移 | 配置测试输出与阶段证据 |
| 3 | 新配置含中文、emoji、引号和空备注 | 实现阶段执行配置 round-trip fixture | 编码/解码值保持一致；空备注可保存 | Unicode/引号丢失、round-trip 不一致或保存被无故拒绝 | 配置测试输出 |
| 4 | 新建和编辑表单输入普通备注、首尾空白和空值 | 实现阶段执行 `TunnelFormState` fixture 及表单保存测试 | 备注按约定保存；名称/命令/探针等既有字段不变 | 备注污染其他字段、空备注阻塞保存或旧字段漂移 | 表单测试输出 |
| 5 | 左侧列表有备注、无备注、旧配置三种 tunnel | 实现阶段执行表示层测试或受控应用冒烟 | 有备注显示备注；空备注和旧配置回退 launchd label；状态点和执行器徽标不变 | 副标题为空、显示错误隧道备注或布局导致名称不可见 | UI 测试/AX 冒烟证据 |
| 6 | 隔离临时 home；保存备注及外部修改备注后刷新 | `swift test --filter TunnelManagerTests.testUpdateTunnelPersistsChangesAndClearsDroppedProbe`；`swift test --filter TunnelManagerTests.testReloadConfigPicksUpChangesAndDropsRemovedStatuses`；源码核对 `updateTunnel/reloadConfig` 调用路径 | 配置和列表备注更新；既有命令/探针/重启参数保留；备注与刷新不触发生命周期调用 | 备注变更触发重启、跨隧道调用或刷新修改真实隧道 | TunnelManagerTests 与本计划实施证据 |
| 7 | 计划文档、共享模块和 Rust Core 阶段 5 完成后的干净基线 | `plan-governance-cli check . --strict-readiness`；`git diff --check`；`rg -n 'tunnelpad-tunnel-remarks|remark|备注说明|刷新配置|下次重启|草案为准|以草案为事实源|详见草案' docs` | 新计划已索引，关键语义一致，无新增治理 ERROR，旧草案未成为事实源，Rust owner 前置状态与仓库一致 | 计划未索引、Schema 语义漂移、治理 ERROR 或把历史迁移改动误归入本计划 | `docs/PLAN_MAP.md`、本计划与治理输出 |

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 需求探索/计划建立 | 用户要求左侧列表显示隧道用途备注；确认当前刷新只重载配置和状态、不自动应用运行中执行器参数；本计划独立记录备注 Schema/UI 变化 | 本计划“需求探索”与 `docs/PLAN_MAP.md` | 已完成 | Codex |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-30 | 只读源码核对 | 查证刷新入口、配置解码器、共享表单状态和侧栏行当前实现；未修改代码、配置或运行中隧道 | `MainPanelView.swift`、`TunnelManager.swift`、`TunnelConfig.swift`、`TunnelFormState.swift`、`TunnelDetailComponents.swift`、双表单源码 | 通过 | Codex |
| 2026-08-31 | 阶段 0 基线复验 | 在干净 HEAD `90dba27b582411c6c836233cc3d1319c03593001` 复跑刷新链路、Swift/Rust 配置字段、列表副标题和 owner 事实核对；确认 `remark` 尚未进入实现，Rust Core 阶段 5 已完成；未修改代码、配置或运行中隧道 | `rg -n 'reloadConfigAsync|refreshAsync|下次重启|restart|bootstrap' Sources/tunnelpad/MainPanelView.swift Sources/TunnelPadCore/TunnelManager.swift`；`rg -n 'remark|TunnelConfig' Sources/TunnelPadCore/TunnelConfig.swift rust/tunnelpad-core/src/lib.rs Sources/tunnelpad/TunnelFormState.swift Sources/tunnelpad/TunnelDetailComponents.swift`；`git status --porcelain=v1`；`docs/adr/0001-rust-core-single-owner.md`；`docs/migrations/tunnelpad-rust-owner-cutover.md` | 通过 | Codex |
| 2026-08-31 | 阶段 0 独立准入复核 | 逐条复核目标/非目标、Step 0、7 行样本矩阵、验证方式、失败/回滚边界和反向引用；确认 Rust owner 前置已完成，阶段 1 影响范围可控 | 当前专项计划、`docs/PLAN_MAP.md`、`plan-governance-cli check . --strict-readiness`（目标计划结构无 ERROR；全仓另有 ECS 计划状态漂移） | 通过（阶段 1 可实施） | Codex（独立复核轮次） |
| 2026-08-31 | 阶段 1–3 实施验证 | 完成 Rust/Swift 配置字段、双表单备注、列表副标题、旧配置兼容、Unicode/引号、配置持久化、差分、smoke、release 打包和只读 AX 验证；未触碰真实隧道生命周期 | [阶段 1–3 实施证据](../data-quality/tunnelpad-tunnel-remarks-stage1-3-20260831.md)；当前工作树 `swift test` 82/82（含并行 ECS 测试）；`cargo test --manifest-path rust/Cargo.toml` 50/50；`./rust/scripts/differential.sh`；`./rust/scripts/smoke.sh`；`./scripts/build_app.sh` | 通过 | Codex |

阶段证据采用追加式记录；实施声明不能替代独立准入或完成复核。

### 验证方式

阶段 0 已使用只读源码核对、隔离 JSON 样本设计和治理反向引用检查完成准入。阶段 1–2 已使用 Rust 配置/Swift 表单单元测试、表示层测试、受控应用 AX 冒烟和配置保存回归，证明备注变化不触发生命周期动作；Rust schema 与 Swift 适配差分已通过。真实隧道未被本计划测试操作。

完成全计划时至少运行并记录：

- `swift test`，覆盖旧配置缺省、新备注 round-trip、表单保存和备注不触发生命周期。
- 适用的 `cargo test` 与 Rust/Swift 适配差分测试，确认 `remark` 的共同配置语义；Rust Core 必须继续作为唯一配置 owner。
- 受控应用冒烟，覆盖新建、编辑、外部配置刷新、左侧副标题、空备注回退和显式重启边界。
- `git diff --check`、`plan-governance-cli check .`、`plan-governance-cli check . --strict-readiness`；若提交代码，提交前再运行 GitNexus `detect_changes()`。

### 测试覆盖率

备注专项新增 5 项 Swift 表示/表单测试；当前工作树全量 Swift 测试 82/82（含并行 ECS 测试）、Rust 单测 50/50、Rust differential 1/1、Swift differential harness 1/1、Rust smoke 和 release `.app` 构建均通过。覆盖缺失字段默认值、Unicode/引号、首尾空白、空备注、已有备注加载、配置持久化、列表优先/兜底和 launchd label 不变；未引入第三方行覆盖率工具。

### 完成条件

- 阶段 0 的刷新现状、备注 Schema、旧配置兼容和列表兜底边界有可复现证据。
- `remark` 缺失的旧配置、普通 Unicode 备注和空备注均可稳定编码/解码；新保存配置结构明确，既有字段不漂移。
- 新建和编辑表单均可保存备注；备注为空时不阻塞保存。
- 左侧列表在有备注时显示备注，无备注时显示原 launchd label；不发生跨隧道串值或状态/徽标回归。
- 保存备注、刷新外部备注只更新配置和展示，不隐式停止、启动、重启或重新 bootstrap 运行中隧道；执行参数仍遵循显式重启边界。
- Rust/Swift 共同配置事实源已确认；若迁移边界变化，相关计划和证据已先同步。
- 受控应用验收、测试证据、治理检查和反向引用一致；最新独立准入/完成复核明确通过。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-31 |
| 阶段 | 阶段 3 |
| 结论 | 通过（达到本计划完成标准） |
| 证据 | 独立核对当前仓库的 Rust/Swift 字段、表单、副标题、差分 fixture、全量测试、smoke、release 包、AX 只读结果、diff 检查、计划索引和反向引用；备注计划无当前阶段错误。全仓 strict-readiness 的剩余错误属于并行 ECS 计划状态漂移，不属于本计划影响范围。 |
| 复核者 | Codex（独立收口复核） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-31 | 阶段准入复核 | 阶段 0 | 通过（达到阶段 1 实施标准） | 当前仓库内容和可复现只读核对证明目标、非目标、Rust owner 前置、Step 0、样本矩阵、验证及回滚边界已明确；目标计划索引同步，未发现草案重新成为事实源。 | Codex（独立复核轮次） |
| 2026-08-31 | 完成复核 | 阶段 3 | 通过（达到本计划完成标准） | 当前仓库内容、Rust/Swift parity、备注专项测试、全量回归、差分、smoke、Release App、只读 AX、治理反向引用和差分范围均已独立核对；备注计划无当前阶段错误。 | Codex（独立收口复核） |

## 风险和回滚

- 新增字段若只修改 Swift 或只修改 Rust，可能造成配置读写和差分不一致；实现前确认单一 owner，迁移 parity 失败时不进入后续阶段。
- 备注内容可能过长或含特殊字符；配置按字符串保存，列表只做一行截断，不把备注拼入 shell、命令、plist 或 label，避免执行语义和注入风险。
- 空备注若直接替换现有 label，会降低旧配置的可识别性；保留 label 兜底，并用旧配置和空值样本验证。
- 将刷新按钮顺手改为自动重启会扩大到运行时生命周期和故障回滚；本计划明确排除该行为，若未来需要必须另建计划并重新评估。
- 若实现导致配置保存失败、列表串值或副作用生命周期调用，按独立提交回滚备注模型/UI 变更，保留原有配置读取和 launchd label 展示；不得删除真实配置、plist 或日志。
- 所有真实隧道验收只允许在用户明确指定、可观察、可恢复的窗口进行；阶段 0 和单元/隔离测试不得操作真实隧道。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad v1 隧道管理应用](tunnelpad-v1.md)
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)
- 当前仓库暂无与本计划对应的 ADR 或 migration 文件；若 Rust Core 迁移或配置 owner 发生持久边界变化，先补充对应文档，再更新本节和 `docs/PLAN_MAP.md`。
