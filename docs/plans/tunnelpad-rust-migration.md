# 计划：TunnelPad Rust Core 迁移

- 状态：实施中
- 当前阶段：阶段 2
- 最后更新：2026-08-30
- 前置：`tunnelpad-v1`、`tunnelpad-ui-refinements` 与 `tunnelpad-code-quality-refactor` 已完成；本计划只在现有 Swift 行为基线上设计 Rust Core 的渐进替换

当前说明：用户已确认迁移边界为“保留 SwiftUI/AppKit 菜单栏与窗口 UI，逐步用 Rust 替换 `TunnelPadCore`”，并确认以“C ABI 主路径 + Swift Core 可回退”作为默认 bridge 方案（sidecar IPC 为备选）。阶段 0、阶段 1 均已通过独立准入复核；阶段 2（Rust Core 组件 parity + 差分测试）达到待实施标准并进入实施。本计划不直接修改现有 Swift 行为，不接管真实用户隧道。

## 背景

TunnelPad 当前是 SwiftUI/AppKit + SwiftPM 的 macOS 菜单栏应用。Swift UI 层已经具备主窗口、菜单栏、表单、日志和窗口可见性轮询；`TunnelPadCore` 承担配置、launchd/app 执行器、探针、日志、迁移接管、启停编排和退出清理。内部 Swift 重构已经完成，适合把 Rust 迁移作为独立的后续计划，避免把“内部优化”和“语言替换”混在同一条回归链路中。

## 目标

- 保留现有 SwiftUI/AppKit UI、菜单栏入口、可观察状态和用户操作方式。
- 分阶段用 Rust 替换 `TunnelPadCore` 的内部实现，首轮不改变配置格式、隧道启停、删除、迁移接管、探针、日志和退出即停语义。
- 建立稳定、可测试的 Swift↔Rust 内部边界；迁移期间保留可独立回滚的 Swift 实现。
- 用 fake executor、隔离 demo 隧道和差分测试证明 Rust 实现与当前 Swift Core 的行为等价，再考虑接入真实 App。
- 保持 macOS `.app` 打包、`LSUIElement` 菜单栏常驻和现有发布流程可复现。

## 非目标

- 第一轮不重写 SwiftUI/AppKit UI，不引入 Tauri、Slint 或其他 Rust UI 框架。
- 不修改 `config.json` schema、launchd label、日志/pidfile 路径、SSH 命令参数、探针状态语义或退出即停语义。
- 不在阶段 0–3 自动操作 `admin-tunnel`、`reverse-ssh` 或其他真实用户隧道。
- 不把 Rust 迁移与 ECS 动态 SSH 公网 IP 同步计划合并。
- 不在没有差分证据和独立准入复核的情况下删除 Swift Core 或切换真实生产路径。

## 需求探索

### 已确认事实（2026-08-30 查证）

- 用户确认采用“保留 SwiftUI/AppKit，只替换 `TunnelPadCore`”的迁移范围。
- 用户确认采用“C ABI 主路径 + Swift Core 可回退”的默认 bridge 方案；sidecar IPC 仅作为 C ABI 原型不满足安全或契约门槛时的备选。
- 当前仓库没有 `Cargo.toml`、Rust 源码或 Rust target；现有产品目标见 [Package.swift](../../Package.swift)。
- 当前 Swift Core 已完成内部职责拆分；现有行为契约由 [TunnelPad v1 计划](tunnelpad-v1.md)、[界面优化计划](tunnelpad-ui-refinements.md) 和 [代码质量重构计划](tunnelpad-code-quality-refactor.md) 共同约束。
- 当前自动化基线为 `swift test` 74/74；Debug/Release 构建和 `.app` 签名校验已通过。当前工作树已清理，Rust 实施可从独立、可复现的提交基线开始；74/74 与 Release 构建已在 HEAD `64e126fa` 复验（见阶段 0 基线证据）。
- 本机已安装 `rustc 1.96.0` 与 `cargo 1.96.0`；当前 Swift 为 Apple Swift 6.3.3，目标为 arm64 macOS。

### 已确认决策（2026-08-30）

| 决策点 | 结论 |
|---|---|
| UI 边界 | 保留 SwiftUI/AppKit、`AppDelegate`、`MenuBarController`、主窗口、表单和日志视图 |
| 首轮替换范围 | Rust 逐步替换 `TunnelPadCore` 的配置、执行器、探针、日志、迁移和生命周期实现 |
| 兼容要求 | 外部功能和可观察行为保持正常；任何行为变化另开计划，不以迁移名义静默改变 |
| 真实隧道边界 | 阶段 0–3 只读审计、fake/fixture 和隔离 demo；真实隧道需用户明确授权并单独记录 |
| 默认 bridge 方案 | C ABI 进程内 bridge 为主路径，Swift Core 保留为可切换回退；sidecar IPC 作为失败时的备选（2026-08-30 用户确认） |

### 候选连接方式与取舍

| 方案 | 说明 | 优点 | 风险/代价 | 当前结论 |
|---|---|---|---|---|
| Rust 静态/动态库 + C ABI Swift wrapper | Rust 在进程内提供 Core，Swift 保留 `TunnelManager` 门面与 UI | 性能和状态调用直接；不增加运行时子进程；最接近当前架构 | FFI DTO、内存所有权、错误/并发边界需要严格冻结 | **已确认默认路径；先做最小原型** |
| Rust sidecar + 本地 IPC | Rust 独立进程，通过 Unix socket/JSON 等协议提供 Core | 进程隔离强；Rust 崩溃不直接拖垮 UI；跨语言边界直观 | 子进程生命周期、协议版本、启动/退出和打包复杂；与现有 app 执行器语义容易混淆 | 作为备选原型 |
| Rust 全量 UI 重写 | UI 与 Core 一起迁移到 Rust 框架 | 单语言 | macOS 原生菜单栏/窗口行为变化大，回归面和发布风险最高 | 本计划非目标 |

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| C ABI wrapper 可以完整表达当前 `TunnelConfig`、`TunnelStatus`、`ProbeResult`、错误分类和异步操作结果 | 阶段 1 最小 FFI 原型 + Swift 兼容测试；无法表达时保留 sidecar 方案 |
| Rust 可以复现 `/bin/launchctl`、app 子进程、pidfile、日志尾读和探针行为 | 阶段 2 fake executor/fixture；不调用真实用户隧道 |
| Swift `TunnelManager` 可以继续作为唯一 UI 状态门面 | 阶段 3 差分测试与隔离 demo 生命周期，禁止双重控制同一隧道 |
| Rust 产物可纳入现有 arm64 `.app` 打包和 ad-hoc 签名流程 | 阶段 1/4 发布构建样本矩阵 |

### 未决问题

| 问题 | 影响 | 计划处理阶段 | 状态 |
|---|---|---|---|
| C ABI 原型是否满足安全、契约和发布门槛 | 决定是否继续主路径或启用 sidecar 备选 | 阶段 0–1 | 已验证：5 项门槛全部通过（见阶段 1 证据），sidecar 未触发 |
| Rust Core 的并发模型与 Swift async 映射 | 影响取消、busy、状态顺序和退出清理 | 阶段 1 | 已冻结（Swift 拥有并发，见「阶段 1 契约冻结」） |
| FFI/IPC DTO、错误码和版本策略 | 影响兼容性与回滚 | 阶段 1 | 已冻结（ABI v1，见「阶段 1 契约冻结」） |
| Rust 最低工具链、静态链接和 arm64 发布矩阵 | 影响 CI/本机发布 | 阶段 1/4 | 工具链与静态链接已固定（1.96.0 / aarch64-apple-darwin / staticlib）；CI 与发布矩阵留阶段 4 |
| Swift Core 保留窗口和最终删除条件 | 影响回滚与维护成本 | 阶段 4/5 | 未冻结 |

## 不变量与安全边界

- `config.json` version/schema、隧道 ID 规则、launchd label、日志/pidfile 路径保持不变。
- `start`、`stop`、`restart`、`remove`、迁移接管、探针、日志和退出即停的成功/失败语义保持不变。
- 迁移期间同一隧道只能有一个生命周期 owner；不得让 Swift 与 Rust 同时启动、停止或重启同一实例。
- Rust 不读取或记录私钥、AccessKey、AccessKey Secret 或完整敏感环境变量；测试使用 fake 数据。
- 阶段 0–3 不执行真实 launchd bootout/bootstrap、真实 app 子进程接管或配置删除；隔离 demo 必须使用独立目录和唯一 ID。
- 任何差分结果不一致、取消/退出顺序不一致或失败回滚不一致，都暂停切换并保留 Swift 实现。

## 影响模块或文件

- 现有 Swift Core：`Sources/TunnelPadCore/`（迁移目标与兼容门面）。
- Swift UI：`Sources/tunnelpad/`（首轮保留，只允许增加 bridge 适配，不改变用户操作契约）。
- 预期新增：`Cargo.toml`、`rust/` 或等价 Rust workspace、Swift bridge/DTO、Rust 单元/集成测试。
- 构建与发布：`Package.swift`、`scripts/build_app.sh`、`App/Resources/Info.plist`（只在发布阶段接入 Rust 产物）。
- 验证与证据：`Tests/TunnelPadCoreTests/`、Rust tests、`docs/data-quality/`、本计划和 `docs/PLAN_MAP.md`。

## 公共契约变化

本计划不改变用户可见或磁盘公共契约。Swift `TunnelManager` 继续作为 UI 门面；Rust bridge 的 DTO、错误分类、取消和版本协议属于内部契约，必须在阶段 1 冻结并由兼容测试覆盖。若必须修改 config schema、launchd 语义或 UI/AX 行为，先暂停本计划并另建行为变更计划。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 迁移基线、行为契约、边界与候选连接方式冻结 | 用户确认迁移范围 | Swift/Rust 工具链、现有测试/构建、调用边界、风险和安全样本 | 已完成 |
| 阶段 1 | 最小 bridge/sidecar 原型与 DTO/错误/取消契约 | 阶段 0 独立准入复核通过 | FFI/IPC 原型、Swift 兼容调用、发布链接样本 | 已完成 |
| 阶段 2 | Rust Core 组件 parity：配置、ID、命令、执行器、探针、日志、迁移、退出 | 阶段 1 契约冻结 | fake executor、故障注入、差分测试 | 实施中 |
| 阶段 3 | 隔离 demo 生命周期与 shadow/differential 回归 | 阶段 2 组件 parity 通过 | demo 启停/重启/删除/退出、取消竞态、产物清理 | 设计中 |
| 阶段 4 | SwiftUI App 可选接入 Rust Core，保持一键回退 Swift | 阶段 3 独立复核通过 | Release `.app`、AX 冒烟、demo 实机与回滚 | 设计中 |
| 阶段 5 | 观察窗口、Swift Core 收缩或删除（可选） | 阶段 4 用户验收与独立复核通过 | 真实隧道经明确授权的分批验证、发布和回滚 | 粗粒度 |

## 当前阶段

当前阶段为阶段 2（Rust Core 组件 parity）。阶段 1 已通过独立完成复核（2026-08-30），阶段 2 达到待实施标准并进入实施。阶段 2 只在 `rust/` 与新增 Swift 差分 harness 中工作，不修改既有 Swift 行为，不操作真实隧道。阶段 1 证据见[阶段 1 证据](../data-quality/tunnelpad-rust-migration-stage1-20260830.md)；冻结契约见下文「契约冻结记录」章节。

### 目标与范围

- 在 `rust/tunnelpad-core` 内实现与 Swift `TunnelPadCore` 组件对等的纯逻辑与注入式执行器：
  - 配置：ConfigStore 读写与损坏恢复（损坏留档 `config.json.corrupt-<timestamp>`、重建空配置、保存编码对齐）
  - ID：TunnelID slug 生成与冲突追加 `-2/-3`、launchd label 前缀
  - SSH 命令：`-v` 精确增删（不碰 `-vv`）、isSSH/hasVerboseFlag 语义
  - plist：LaunchdPlistRenderer 渲染（以 Swift 实现为准逐字段对齐）
  - 执行器：LaunchCtlExecutor（bootstrap/bootout/status 解析）与 AppProcessExecutor（pidfile start/stop/restart/status）——全部通过注入 fake runner，不触碰真实 launchctl/SSH
  - 探针：ProbeService 判定逻辑（satisfied/unexpected/failed），HTTP 传输注入（fake 传输）
  - 日志：LogTail 尾部读取（含结尾换行处理）
  - 迁移：LegacyImporter/MigrationService 接管逻辑（fake 文件布局）
  - 退出：stop-all 编排语义（fake 执行器）
- 差分测试：同一 fixture 输入分别驱动 Swift 差分 harness（新增测试文件）与 Rust 实现，比较状态序列、错误类别、文件副作用（plist/pidfile/config.json 内容等价）。
- Swift 侧仅允许新增差分 harness 文件，不修改既有行为。

### 非目标

- 不接入 SwiftUI App 产品路径（阶段 4）；不删除/收缩 Swift Core。
- 不操作真实隧道、launchd、SSH、网络探针；全部 fake/fixture + 隔离目录。
- 不改变 config.json schema、launchd label、路径规则与现有语义。

### Step 0

类型：组件 parity 基线。基线 = 阶段 1 完成态（HEAD `adfb12e`：ABI v1 契约冻结、rust workspace、`swift test` 74/74、Rust 15 项测试）+ 各组件的 Swift 行为快照（以现有 74 项 Swift 测试与组件源码为准）。

判定口径（2026-08-30 独立复核要求）：

- config.json 差分按“解码后语义等价”判定，不按无 sortKeys 的 Swift `JSONEncoder` 字节比较（实测其键序不确定且转义 `/`）。
- 保存编码（ConfigStore 的 `[.prettyPrinted, .sortedKeys]`）为确定输出但属 Apple 风格（`\/` 转义、`"key" : value` 分隔、2 空格缩进）；Rust 侧字节对齐需自定义序列化格式器，可行性须在阶段 2 早期验证：可行则字节对齐，不可行则该项差分退化为解码后语义等价并单独记录格式差异，不得静默放宽。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | Rust 组件测试 | `cargo test` | 新增组件 parity 测试全过 | 任一失败 | cargo 输出/阶段 2 证据 |
| 2 | 差分 harness | Swift harness 与 Rust harness 在同一 fixture 上运行并对比 | 状态序列/错误类别/文件副作用一致（config.json 按 Step 0 判定口径） | 任一不一致 | 差分报告/阶段 2 证据 |
| 3 | 故障注入 | fake runner 失败/损坏 fixture | 错误类别与恢复路径与 Swift 一致（损坏留档、重建、回滚） | 行为分叉 | 阶段 2 证据 |
| 4 | 既有回归 | `swift test` | 74/74 保持通过 | 任一失败 | 测试输出 |
| 5 | 边界隔离 | `git status`/diff 审计 | 变更只含 `rust/`、新增 Swift harness 文件、docs | 计划外行为改动 | 阶段 2 证据 |

### 验证方式

`cargo test` + 差分 harness 对比 + `swift test` 回归；证据写入 `docs/data-quality` 阶段 2 文档；完成后由独立复核确认 parity 与阶段 3 准入。

### 完成条件

- 9 类组件（配置/ID/SSH 命令/plist/launchd 执行器/app 执行器/探针/日志/迁移+退出）parity 实现并有 cargo 测试覆盖。
- 差分测试在全部 fixture 矩阵上一致（状态序列、错误类别、文件副作用）。
- Swift 既有测试保持 74/74；边界隔离满足。
- 独立复核确认阶段 2 完成且阶段 3 达到待实施标准。

### 失败与回滚边界

任一差分不一致：暂停该组件替换、定位差异后重跑；Rust 代码未接入产品路径，失败不影响 Swift 运行。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| Step 0 | 继承阶段 1 完成态（HEAD `adfb12e`：ABI v1 契约冻结、74/74、Rust 15 项测试）+ Swift 组件行为快照；含两条差分判定口径 |
| 样本矩阵 | 5 行：cargo test、差分 harness、故障注入、既有回归、边界隔离 |
| 验证方式 | `cargo test`、差分 harness 对比、`swift test` 回归与独立复核 |
| 失败/回滚边界 | 差分不一致即暂停该组件替换；Rust 未接入产品路径，失败不影响 Swift 运行 |
| 当前阻塞项 | 无当前阶段阻塞项 |
| 最新独立准入复核 | 2026-08-30 通过（阶段 1 完成复核 + 阶段 2 准入草案复核，见独立复核记录） |

## 契约冻结记录（阶段 1 冻结，阶段 2+ 事实源）

### 阶段 1 原型门槛与比较指标（阶段 0 冻结）

C ABI 最小原型在阶段 1 必须逐项证明以下门槛；任一不成立即暂停主路径，触发 sidecar IPC 备选评估：

| # | 门槛 | 判定方式 | 失败判定 |
|---|---|---|---|
| 1 | 表达完整性 | C ABI 契约能无损表达 `TunnelConfig`、`TunnelStatus`、`ProbeResult`、错误分类和异步操作结果，且含可扩展的错误码/版本字段 | 任一类型或状态无法无损表达 |
| 2 | 内存与所有权 | 跨边界字符串/缓冲区/句柄有明确分配方与释放方，无双重释放或泄漏；原型含对应测试 | 所有权规则无法静态说清，或测试发现泄漏/双重释放 |
| 3 | Swift 兼容调用 | 独立 Swift 样本可加载 Rust 库、调用全部原型 API 且断言通过（不改动现有产品代码） | 任一 API 调用失败或断言不通过 |
| 4 | 取消/退出映射 | Swift async 取消、busy 与退出清理顺序可在契约层面映射出与现有 `TunnelManager` 语义一致的方案 | 无法给出语义一致的映射方案 |
| 5 | 发布链接样本 | Rust 静态库可链接进 arm64 Release 构建样本，ad-hoc 签名校验通过 | 链接或签名失败且无可行修复 |

比较指标随阶段 1 证据落盘：契约 API 数量与规模、round-trip 测试结果、链接产物与签名校验输出。

### 阶段 1 契约冻结（实施产出，2026-08-30）

以下契约为阶段 2+ 的实施事实源；修改需先更新本节并通过独立复核。

**ABI 版本与演进**：`tp_abi_version() == 1`；只允许追加函数与错误码，破坏性变化必须递增 ABI 版本。C 头文件单一事实源：`rust/include/tunnelpad_core.h`（含 modulemap，Swift 侧 `import CTunnelpadCore`）。

**冻结的 C ABI 函数（6 个）**：

| 函数 | 职责 |
|---|---|
| `tp_abi_version()` | 返回契约版本 |
| `tp_config_parse(input)` | 解析 config.json → 规范化 JSON（键序 = Swift `CodingKeys` 声明顺序的规范形状，不作 JSONEncoder 字节参照）；失败返回 NULL |
| `tp_status_encode(case, has_pid, pid, state)` | `TunnelStatus` → 规范 JSON |
| `tp_probe_result_encode(kind, status, reason)` | `ProbeResult` → 规范 JSON |
| `tp_last_error()` | 最近一次失败的错误 JSON `{"code":N,"message":"..."}`；无则 NULL |
| `tp_string_free(s)` | 释放 `tp_*` 返回的字符串（NULL 安全、只能释放一次） |

**错误码（只允许追加）**：0 OK；1 INVALID_JSON（JSON 非法或必填字段缺失）；2 SCHEMA_VERSION（version != 1）；3 INVALID_ID（id 不满足 `^[a-z0-9-]+$`）；4 INVALID_COMMAND（command 为空或首元素为空）；5 INVALID_ARGUMENT（FFI 参数非法：NULL/非 UTF-8/未知 case）。

**DTO 与序列化**：`AppConfig`（version=1 + tunnels）、`TunnelConfig`（id/name/command/executor/keepAlive/throttleInterval/probe）、`ProbeConfig`（url/expectedStatuses，缺省 `[200]`）、`ExecutorKind`（launchd|app）。serde 键序与 Swift `CodingKeys` 声明顺序一致；缺省值语义对齐 Swift 解码器（executor=launchd、keepAlive=true、throttleInterval=10、probe 缺省省略）；`TunnelStatus`/`ProbeResult` 以 tagged JSON（`"case"`）跨边界表达，pid 可空（has_pid 标志）。

**所有权与错误传递**：`tp_*` 返回的 `char*` 由 Rust 分配、只能由 `tp_string_free` 释放一次、禁止 `free()`；调用方字符串仅借用；返回 NULL 表示失败并伴随 last-error；成功调用清除错误。

**并发、取消与退出映射（门槛 4 的冻结方案）**：

- Swift 继续拥有全部并发：Rust 只提供同步 C ABI 函数，Rust 侧不启动线程、无跨调用状态（除 last-error 槽位）。
- 启停调用路径与现状一致：`TunnelManager`（@MainActor）→ `Task.detached` → 同步执行器调用；阶段 2+ 中同步执行器逻辑替换为 Rust 调用，busy/`operationGenerations` 门禁保留在 Swift。
- 取消语义：Swift Task 取消后废弃结果并清理 busy；Rust 调用与现状的同步 launchctl 调用一样不可中断但原子、幂等——与现有行为等价。
- 单一 owner：生命周期操作的 owner 门禁保留在 Swift busyIDs；Rust 不自行发起任何 launchctl/SSH/pidfile 操作。
- 退出清理：`Shutdown` 信号路径与正常退出继续在 Swift 侧串行直调执行器（后续替换为 Rust 函数），"退出 = 停止全部托管隧道"语义不变。

**工具链与链接**：Rust 1.96.0（rustc/cargo），target `aarch64-apple-darwin`（本机 arm64）；`staticlib` 产物经 swiftc 直链 + ad-hoc 签名校验；`Cargo.lock` 随仓提交。CI 与发布矩阵（x86_64、universal2）留阶段 4。

## 失败策略与回滚

- 阶段 0/1 原型失败：删除隔离原型或保留在独立分支，Swift Core 不变。
- 差分测试不一致：暂停 Rust 接入，定位状态顺序、错误分类、取消或资源清理差异，回退到 Swift 实现。
- Release 链接或签名失败：不替换 `.app`，保留上一个可运行包；修复构建链路后重新准入。
- 真实隧道验证若经用户授权仍失败：立即停止扩大范围，恢复 Swift owner；不得用迁移脚本批量修复现场。

## 验证与测试覆盖口径

- Swift 回归门禁：现有 `swift test` 全量通过，当前基线为 74/74。
- Rust 单元/集成门禁：配置 round-trip、ID/命令解析、状态映射、错误/取消、fake executor、探针和日志 tail。
- 差分门禁：同一 fixture 输入下，Swift 与 Rust 的状态序列、错误类别、文件副作用和退出结果一致。
- 发布门禁：arm64 Release `.app`、`Info.plist`、ad-hoc 签名、AX 窗口冒烟和隔离 demo 生命周期。
- 真实隧道不是阶段 0–3 的自动门禁；只有阶段 4/5 明确授权后才建立独立证据。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-30 |
| 阶段 | 阶段 2 |
| 结论 | 通过：阶段 1 达到完成标准；阶段 2 达到待实施标准（本次复核同时覆盖两者） |
| 证据 | 复核者独立复跑 HEAD `adfb12e`（工作树干净）：`smoke.sh` 全绿（cargo test 15/15、Swift 29 项断言、codesign --verify --strict、arm64 产物）、`swift test` 74/74、`adfb12e` 边界审计 rust/ 全为新增且无既有 Swift 行为改动、头文件与 ffi.rs 6 函数一一对应、错误码与缺省值/id 校验/TunnelStatus/ProbeResult 与 Swift 事实源逐项一致。两条披露随落盘修复：D1 准入摘要与 PLAN_MAP 状态同步；D2 契约键序表述修正（规范形状以 CodingKeys 声明序为准，不作 JSONEncoder 字节参照） |
| 复核者 | 独立复核 subagent |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-30 | 计划创建与基线整理 | 阶段 0 | 待独立复核 | Swift/Rust 工具链、74 项 Swift 测试、Release `.app`、Core/UI 边界和安全边界已记录；未冻结 bridge 细节，未开始实现 | 待独立复核者 |
| 2026-08-30 | 基线复验与暂定方案同步 | 阶段 0 | 待独立复核 | HEAD `64e126fa` 工作树干净，`swift test` 74/74 与 Release 构建复跑通过；首轮基线（HEAD `b6ffd22`、非洁净工作树）保留为历史记录；C ABI 主路径记为暂定默认，待用户确认 | 待独立复核者 |
| 2026-08-30 | 用户确认默认 bridge 方案 | 阶段 0 | 待独立复核 | 用户确认 C ABI 主路径 + Swift Core 可回退为默认方案，sidecar IPC 为备选；阶段 0 剩余准入门槛为独立复核 | 待独立复核者 |
| 2026-08-30 | 阶段 0 完成准入复核 | 阶段 0 | 通过 | 独立复跑 HEAD `64e126fa`（工作树仅 3 个治理文档未提交编辑、无代码改动）、`swift test` 74/74、`swift build -c release` 通过、Swift 6.3.3 arm64、rustc/cargo 1.96.0、无 Cargo.toml/.rs；5 项原型门槛表、默认 C ABI 方案确认与 DTO/并发/版本未决标记逐项核对通过；`plan-governance-cli check .`（含 `--strict-readiness`）通过 | 独立复核 subagent |
| 2026-08-30 | 阶段 1 准入草案复核 | 阶段 1 | 达到待实施标准 | 草案目标/非目标、Step 0（FFI 契约原型基线 = 64e126fa 复验基线 + Rust 1.96.0）、5 行样本矩阵（含 74/74 回归与 git 边界审计）、验证方式、完成条件（引用阶段 0 冻结的 5 项门槛）、失败/回滚边界齐备自洽；落盘时须同步 `PLAN_MAP.md` 并提交未提交的治理文档编辑 | 独立复核 subagent |
| 2026-08-30 | 阶段 1 完成准入复核 | 阶段 1 | 通过 | 独立复跑 HEAD `adfb12e`（工作树干净）：smoke.sh 全绿（cargo test 15/15、Swift 29 项断言、codesign --verify --strict、arm64 产物）、swift test 74/74、adfb12e 边界审计 rust/ 全为新增且无既有 Swift 行为改动、头文件与 ffi.rs 6 函数一一对应、错误码 0-5 与缺省值/id 校验/TunnelStatus/ProbeResult 与 Swift 事实源逐项一致；完成条件 4/4 满足；两条披露随阶段 2 落盘修复：strict-readiness ERROR（阶段准入摘要.准入状态与 PLAN_MAP 同步）、契约键序表述修正（实测 Swift JSONEncoder 无 sortKeys 时键序不确定且转义 /，规范形状以 CodingKeys 声明序为准） | 独立复核 subagent |
| 2026-08-30 | 阶段 2 准入草案复核 | 阶段 2 | 达到待实施标准 | 草案 9 类组件语义锚点与 ConfigStore（corrupt-<timestamp>、prettyPrinted+sortedKeys）/SSHCommand（-v 精确增删）/TunnelID（slug 冲突 -2/-3）等事实源一致，Step 0/5 行样本矩阵/验证方式/完成条件/回滚边界齐备自洽，与阶段 1 冻结契约（注入式执行器、Rust 不发起真实操作）衔接一致；落盘前提：同步修复 D1/D2，并在 Step 0 写明 config.json 差分按解码后语义等价判定、写盘字节对齐基准为 Swift sortedKeys 确定输出（含 \/ 转义的 Apple 风格，serde_json 需自定义格式器，可行性需先行验证） | 独立复核 subagent |

## 关联计划、ADR、迁移、spec 或 issue

- [TunnelPad v1](tunnelpad-v1.md)：配置、执行器、迁移接管和退出语义的现有行为事实源。
- [TunnelPad 界面优化](tunnelpad-ui-refinements.md)：当前 SwiftUI/AppKit 用户操作与 UI/AX 契约。
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)：Rust 迁移的前置内部边界与测试基线。
- 当前没有需要新增的 ADR 或磁盘迁移；若 bridge 协议、并发模型或 schema 发生持久决策变化，再单独增加 ADR/migration。
