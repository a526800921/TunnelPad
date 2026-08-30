# 计划：TunnelPad Rust Core 迁移

- 状态：实施中
- 当前阶段：阶段 5
- 最后更新：2026-08-30
- 前置：`tunnelpad-v1`、`tunnelpad-ui-refinements` 与 `tunnelpad-code-quality-refactor` 已完成；阶段 0–4 已完成，阶段 5 已进入 owner 切换实施

当前说明：用户已确认保留 SwiftUI/AppKit 菜单栏与窗口 UI，Rust 通过进程内 C ABI 成为唯一 Core owner。阶段 4 的 shadow bridge 已完成；阶段 5 将先覆盖 `launchd` 和 `config.json` owner，隐藏并移除当前 `app` 执行器路径。验证完成后删除旧 Swift Core，不保留同一 App 内的 Swift fallback；真实验证按用户授权的隧道逐条进行。

## 背景

TunnelPad 当前是 SwiftUI/AppKit + SwiftPM 的 macOS 菜单栏应用。Swift UI 层已经具备主窗口、菜单栏、表单、日志和窗口可见性轮询；`TunnelPadCore` 承担配置、launchd/app 执行器、探针、日志、迁移接管、启停编排和退出清理。内部 Swift 重构已经完成，适合把 Rust 迁移作为独立的后续计划，避免把“内部优化”和“语言替换”混在同一条回归链路中。

## 目标

- 保留现有 SwiftUI/AppKit UI、菜单栏入口、可观察状态和用户操作方式。
- 分阶段用 Rust 替换 `TunnelPadCore` 的内部实现，首轮不改变配置格式、隧道启停、删除、迁移接管、探针、日志和退出即停语义。
- 建立稳定、可测试的 Swift↔Rust 内部边界；迁移期间允许旧 Swift 代码暂存到验证完成，但最终删除，不作为运行时回滚路径。
- 用 fake executor、隔离 demo 隧道和差分测试证明 Rust 实现与当前 Swift Core 的行为等价，再考虑接入真实 App。
- 保持 macOS `.app` 打包、`LSUIElement` 菜单栏常驻和现有发布流程可复现。

## 非目标

- 第一轮不重写 SwiftUI/AppKit UI，不引入 Tauri、Slint 或其他 Rust UI 框架。
- 不修改 `config.json` schema、launchd label、日志/pidfile 路径、SSH 命令参数、探针状态语义或退出即停语义。
- 阶段 0–4 不自动操作真实用户隧道；阶段 5 仅在用户明确授权后对指定隧道做受控验证。
- 不把 Rust 迁移与 ECS 动态 SSH 公网 IP 同步计划合并。
- 不在阶段 5 自身 Step 0、差分证据和独立准入复核完成前删除 Swift Core 或切换真实生产路径。

## 需求探索

### 已确认事实（2026-08-30 查证）

- 用户确认采用“保留 SwiftUI/AppKit，只替换 `TunnelPadCore`”的迁移范围。
- 阶段 0–4 用户确认并验证“C ABI 主路径 + Swift Core 可回退”；阶段 5 用户确认继续采用进程内 C ABI，但验证完成后不保留 Swift fallback，sidecar 不纳入本次实施。
- 阶段 0 的历史快照曾记录仓库没有 `Cargo.toml`、Rust 源码或 Rust target；该事实已被阶段 1–4 的 Rust 产物取代，现有 Swift 产品目标仍见 [Package.swift](../../Package.swift)。
- 当前 Swift Core 已完成内部职责拆分；现有行为契约由 [TunnelPad v1 计划](tunnelpad-v1.md)、[界面优化计划](tunnelpad-ui-refinements.md) 和 [代码质量重构计划](tunnelpad-code-quality-refactor.md) 共同约束。
- 阶段 0 的历史自动化基线为 `swift test` 74/74；Debug/Release 构建和 `.app` 签名校验已通过，且已在 HEAD `64e126fa` 复验（见阶段 0 基线证据）。阶段 4 增加 shadow bridge 测试后，当前 `swift test` 门禁为 80/80。
- 本机已安装 `rustc 1.96.0` 与 `cargo 1.96.0`；当前 Swift 为 Apple Swift 6.3.3，目标为 arm64 macOS。

### 已确认决策（2026-08-30）

| 决策点 | 结论 |
|---|---|
| UI 边界 | 保留 SwiftUI/AppKit、`AppDelegate`、`MenuBarController`、主窗口、表单和日志视图 |
| 首轮替换范围 | Rust 逐步替换 `TunnelPadCore` 的配置、执行器、探针、日志、迁移和生命周期实现 |
| 兼容要求 | 外部功能和可观察行为保持正常；任何行为变化另开计划，不以迁移名义静默改变 |
| 真实隧道边界 | 阶段 0–3 只读审计、fake/fixture 和隔离 demo；真实隧道需用户明确授权并单独记录 |
| 默认 bridge 方案 | 阶段 0–4 使用进程内 C ABI + Swift Core 回退；阶段 5 已确认继续使用进程内 C ABI，但验证完成后删除 Swift Core，sidecar 不纳入本次实施 |

### 阶段 5 用户确认的决策（2026-08-30）

| 决策点 | 结论 |
|---|---|
| 最终架构 | SwiftUI/AppKit 作为 UI 外壳；Rust Core 作为唯一生命周期 owner；Swift 只保留 UI、表单临时状态、FFI 适配和状态展示 |
| 进程边界 | 继续使用进程内 C ABI，不引入 Rust sidecar；跨边界使用 UTF-8 JSON 和 opaque Rust handle |
| 配置 owner | Rust 负责 `config.json` 的读取、解析、保存和 schema 校验；Swift 不再作为持久化事实源 |
| 状态与并发 | Rust handle 持有运行时状态和后台任务；同隧道串行、不同隧道可并行；Swift 只读取状态快照 |
| 生命周期范围 | 本阶段只实现 `launchd`；`app` 执行器入口、实现和配置分支移除，未来需要时另立计划 |
| App 退出 | 退出 TunnelPad 时由 Rust 停止全部受管 `launchd` 隧道；关闭窗口不停止；退出后取消全部 Rust 任务 |
| 回滚 | 不保留同一 App 内的 Swift fallback，也不把旧版本运行时回滚作为本计划要求；验证失败直接修复 Rust |
| 真实验证 | 已授权先验证 `admin-tunnel`，再验证其他当前配置中的 `launchd` 隧道；每次只操作明确目标 |

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
| Rust Core 的并发模型与 Swift async 映射 | 影响取消、busy、状态顺序和退出清理 | 阶段 1/5 | 阶段 1–4 历史契约为 Swift 并发；阶段 5 已确认改为 Rust handle owner，具体 API 待 Step 0 冻结 |
| FFI/IPC DTO、错误码和版本策略 | 影响兼容性与回滚 | 阶段 1 | 已冻结（ABI v1，见「阶段 1 契约冻结」） |
| Rust 最低工具链、静态链接和 arm64 发布矩阵 | 影响 CI/本机发布 | 阶段 1/4 | 工具链与静态链接已固定（1.96.0 / aarch64-apple-darwin / staticlib）；CI 与发布矩阵留阶段 4 |
| Rust 时间戳与 Swift 本地时区语义 | 影响损坏配置留档、迁移备份文件名和 app 日志时间 | 阶段 4 Step 0 | 用户已确认 Rust 跟随 Swift 的本地时区；实现完成并由固定 UTC/CST/PST-PDT 样本复核 |
| Swift Core 保留窗口和最终删除条件 | 影响回滚与维护成本 | 阶段 5 | 已确认：验证完成后删除，不保留 App 内 fallback |
| 阶段 5 owner API 与状态快照的具体函数列表 | 影响 ABI 版本、线程安全和 Swift 适配层 | 阶段 5 Step 0 | 原型已冻结，生产适配与独立复核待完成 |

## 不变量与安全边界

- `config.json` version/schema、隧道 ID 规则、launchd label、日志/pidfile 路径保持不变。
- `start`、`stop`、`restart`、`remove`、迁移接管、探针、日志和退出即停的成功/失败语义保持不变。
- 迁移期间同一隧道只能有一个生命周期 owner；不得让 Swift 与 Rust 同时启动、停止或重启同一实例。
- Rust 不读取或记录私钥、AccessKey、AccessKey Secret 或完整敏感环境变量；测试使用 fake 数据。
- 阶段 0–3 不执行真实 launchd bootout/bootstrap、真实 app 子进程接管或配置删除；隔离 demo 必须使用独立目录和唯一 ID。
- 任何差分结果不一致、取消/退出顺序不一致或失败回滚不一致，都暂停切换并保留 Swift 实现。

## 影响模块或文件

- 现有 Swift Core：`Sources/TunnelPadCore/TunnelManager.swift`（迁移目标与兼容门面）；`Sources/TunnelPadCore/` 其余生命周期实现本阶段不接管。
- Shadow bridge：`Sources/TunnelPadCore/RustCoreShadow.swift`。
- Shadow bridge 测试：`Tests/TunnelPadCoreTests/RustCoreShadowTests.swift`。
- Rust 配置时间戳：`rust/tunnelpad-core/src/config_store.rs`。
- Rust 执行器调用方：`rust/tunnelpad-core/src/app_executor.rs`。
- Rust Core crate 配置：`rust/tunnelpad-core/Cargo.toml`。
- Rust workspace 配置：`rust/Cargo.toml`。
- Rust 依赖锁定：`rust/Cargo.lock`。
- ABI 不兼容 fixture：`rust/fixtures/incompatible-core/`。
- Release 打包脚本：`scripts/build_app.sh`（动态库复制、install name 和签名）。
- 阶段证据：`docs/data-quality/tunnelpad-rust-migration-stage4-step0-20260830.md`。
- 计划状态与索引：`docs/PLAN_MAP.md`。

## 公共契约变化

本计划不改变用户可见或磁盘公共契约。Swift `TunnelManager` 继续作为 UI 门面；Rust bridge 的 DTO、错误分类、取消和版本协议属于内部契约，必须在阶段 1 冻结并由兼容测试覆盖。若必须修改 config schema、launchd 语义或 UI/AX 行为，先暂停本计划并另建行为变更计划。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 迁移基线、行为契约、边界与候选连接方式冻结 | 用户确认迁移范围 | Swift/Rust 工具链、现有测试/构建、调用边界、风险和安全样本 | 已完成 |
| 阶段 1 | 最小 bridge/sidecar 原型与 DTO/错误/取消契约 | 阶段 0 独立准入复核通过 | FFI/IPC 原型、Swift 兼容调用、发布链接样本 | 已完成 |
| 阶段 2 | Rust Core 组件 parity：配置、ID、命令、执行器、探针、日志、迁移、退出 | 阶段 1 契约冻结 | fake executor、故障注入、差分测试 | 已完成 |
| 阶段 3 | 隔离 demo 生命周期与 shadow/differential 回归 | 阶段 2 组件 parity 通过 | demo 启停/重启/删除/退出、取消竞态、产物清理 | 已完成 |
| 阶段 4 | SwiftUI App shadow 接入 Rust Core，保持 Swift 回退 | 阶段 3 独立复核通过 | Release `.app`、AX 冒烟、demo 实机与回退 | 已完成 |
| 阶段 5 | `launchd` Rust Core owner 切换、配置 owner 切换、Swift Core 删除 | 用户确认阶段 5 架构；阶段 5 自身 Step 0 和独立准入复核 | fake/差分、真实 `admin-tunnel` 首条验证、其他 `launchd` 隧道、Release/AX、退出清理 | 实施中 |

## 当前阶段

阶段 5（Rust Core owner 切换）目前处于实施中。最终形态是 SwiftUI/AppKit UI 外壳 + 进程内 Rust Core；Rust 负责配置、状态、`launchd` 生命周期、并发和后台任务，Swift 只负责 UI/FFI 适配。阶段 5 当前只覆盖 `launchd`，`app` 执行器未来另立计划。

### 目标与范围

- 扩展现有 C ABI 为长期 Rust Core handle、JSON 命令、JSON 状态快照和明确错误结果。
- Rust 负责 `config.json` 的读取、解析、保存和 schema 校验；保留 version 1 磁盘格式，不自动迁移用户配置。
- Rust 负责当前阶段的 `launchd` 启动、停止、重启、删除、状态查询、配置刷新和退出清理。
- Rust handle 持有运行时状态和后台任务；同一隧道的命令串行，不同隧道可并行；过期任务不得回写状态或重新启动实例。
- Swift `TunnelManager` 收缩为 `ObservableObject` UI 门面：提交命令、读取快照、展示错误，不再拥有生命周期或持久化事实。
- 隐藏并移除当前 `app` 执行器入口、实现和配置分支；未来需要 `app` 时另立计划。
- 在用户授权下先验证 `admin-tunnel`，再验证其他当前配置中的 `launchd` 隧道；验证完成后删除旧 Swift Core。

### 非目标

- 不引入 Rust sidecar，不改为 Unix Socket/IPC 架构。
- 不保留同一 App 内的 Swift fallback；阶段 5 完成后不维护旧 Swift Core。
- 不实现 `app` 执行器；不保留 `ExecutorKind.app` 的当前运行路径，不自动把 app 配置转换成 `launchd`。
- 不改变 `config.json` version=1、隧道 ID、launchd label、日志/pidfile 路径、SSH 命令参数和“退出即停”语义。
- 不在本阶段实现备注字段、健康恢复策略或日志事件流；这些计划在 Rust owner 完成后按各自准入推进。
- 不进行未经用户明确授权的真实隧道批量操作、远端配置修改或凭证变更。

### Step 0 证据

类型：行为迁移与架构 owner 切换基线。阶段 4 已完成的 ABI/动态库/Release/AX 证据作为 Rust 产物基线；本阶段新增本机配置、真实 `launchd` 状态和受控启停证据见[阶段 5 Step 0 证据](../data-quality/tunnelpad-rust-migration-stage5-step0-20260830.md)。

已确认的本机基线：当前配置包含 `admin-tunnel` 和 `reverse-ssh` 两条隧道，均为 `launchd`；没有 `app` 配置。对 `admin-tunnel` 的一次受控 bootout/bootstrap 闭环成功，旧 PID 已退出，新 PID 正常运行，`reverse-ssh` 保持运行；配置的 HTTP 探针当次返回连接失败，需要在 Rust owner 切换前完成原因分类或明确记录为已知基线。

已完成的 Step 0 证据：owner ABI/配置/并发隔离原型、Swift FFI 适配、Rust/Swift smoke、48 个 Rust 单测 + 1 个差分测试、Swift 80/80、fake `launchd` 成功/未加载/命令失败/spawn 失败矩阵、generation 失配前置拒绝和 cancel/生命周期锁串行化、Release `.app` 构建与签名；生产信号处理已绑定 `TunnelManager` 持有的同一 Rust owner 句柄，未再创建第二套 Swift 生命周期 owner；细节见[阶段 5 Step 0 证据](../data-quality/tunnelpad-rust-migration-stage5-step0-20260830.md)。尚缺 Rust 后台 worker、可中断取消语义、隐藏 app 入口后的 UI/AX 回归、真实 Rust owner 验证、隔离 app/AX/退出操作复核和阶段 5 独立准入复核。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 现有 ABI v1、阶段 4 动态库与 Release 打包基线 | `cargo test --manifest-path rust/Cargo.toml`；`swift test`；`./scripts/build_app.sh` | 阶段 4 产物和回归门禁保持通过 | 任一现有门禁失败或产物缺失 | cargo/Swift/build 输出 |
| 2 | 当前 version=1 配置、缺省字段、非法 JSON/版本和无 `app` 配置样本 | Rust 配置 owner 隔离 fixture；与现有 JSON 做语义差分 | Rust 读写保持 version=1 语义，错误 fail-closed，不改写非法输入 | 字段丢失、静默降级或 Swift/Rust 语义不一致 | 阶段 5 config fixture |
| 3 | fake `launchd` 的 start/stop/restart/remove/status/shutdown 命令序列 | Rust Core handle 集成测试 | 每条命令只产生预期 launchctl 调用、结果和状态快照 | 重复调用、错误吞掉、状态先于系统结果提交 | 阶段 5 lifecycle fixture |
| 4 | 同隧道并发命令、取消和迟到任务；不同隧道并行 | Rust `begin`/`cancel` 代次命令与并发 fixture | 同隧道串行、跨隧道隔离、过期命令不触发系统调用 | 双重生命周期调用、状态倒灌或其他隧道受影响 | 阶段 5 concurrency fixture |
| 5 | 用户已授权的 `admin-tunnel` 当前 launchd 实例 | 记录状态 → bootout → 确认旧 PID 消失 → bootstrap → 查询状态/探针 | 目标隧道安全收敛并恢复运行，其他隧道不受影响 | 未卸载、旧 PID 残留、启动失败或业务基线未分类 | 阶段 5 真实验证记录 |
| 6 | 用户配置中的其他 `launchd` 隧道 | 每条隧道单独状态查询和受控重启 | 每条隧道只有一个 owner，状态和命令结果一致 | 非目标隧道被操作、状态错误或异常未报告 | 阶段 5 真实验证记录 |
| 7 | Swift UI 门面、隐藏 app 入口、App 退出 | `swift test`、Release `.app`、AX 冒烟、受控退出 | UI 可用，Swift 不直接读写配置/调用 launchctl，退出停止全部受管隧道 | UI 回归、计划外 Swift 生命周期调用或退出遗留任务 | Swift/AX/阶段 5 证据 |
| 8 | Rust owner 验收后的源码树 | `rg`/GitNexus 反向引用审计、构建和治理检查 | 旧 Swift Core 与 app 执行器代码已删除，无调用方残留 | 仍有旧 owner、死分支或计划外行为路径 | Git diff/治理输出 |

### 验证方式

先完成隔离 Rust Core handle 与 fake `launchd` fixture，再运行 Rust/Swift 差分和现有回归；随后按授权顺序验证 `admin-tunnel` 与其他 `launchd` 隧道，最后进行 Release/AX/退出清理验证。每次代码修改前运行目标符号的 GitNexus upstream impact；提交前运行 `detect_changes()` 和 `plan-governance-cli check .`。

### 测试覆盖率

阶段 5 以 Rust Core handle、配置 owner、`launchd` 命令矩阵、错误/取消/并发、状态快照、退出清理、Swift UI 适配和真实单隧道验证作为覆盖口径。当前已有 Rust 48 个单测 + 1 个差分测试、Swift 80/80、真实 release FFI owner 3 项测试、`rust/scripts/smoke.sh` 和 `build_app.sh` 证据；阶段 5 的后台 worker/可中断取消、真实 Rust owner 和 AX/退出操作仍未完成。

### 完成条件

- Rust owner ABI、配置读写、`launchd` 生命周期、状态快照、并发和退出清理均有隔离测试和差分证据。
- Swift `TunnelManager` 不再作为配置或生命周期事实源；UI/AX 行为保持通过。
- `app` 入口、实现和配置分支已删除，当前配置与启动路径只使用 `launchd`。
- `admin-tunnel` 及其余授权 `launchd` 隧道完成逐条受控验证，HTTP 探针失败基线已分类或修复。
- Release `.app` 构建、签名、启动、启停、退出清理和治理检查通过。
- 独立复核确认阶段 5 完成后，删除旧 Swift Core，不保留 App 内 fallback。

### 失败与回滚边界

阶段 5 不提供 App 内 Swift fallback，也不要求旧版本运行时回滚。Step 0 或实现验证失败时停止扩大真实隧道范围，直接修复 Rust 并重复隔离测试；在所有完成条件满足、独立复核通过前不得删除 Swift Core。删除完成后，Rust owner 的错误按普通缺陷修复，不通过保留 Swift 代码恢复。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| 阶段状态 | 实施中 |
| Step 0 | 当前配置/状态基线、`admin-tunnel` 受控 launchd 闭环、Rust owner/配置/并发隔离原型、Swift FFI 适配、fake launchd 故障矩阵、generation 失配前置拒绝、cancel/生命周期锁串行化和 Release 构建已完成；后台 worker/可中断取消与真实 Rust owner 验证尚未完成 |
| 样本矩阵 | 8 行（6 列）：现有回归、配置 owner、fake launchd、并发、admin-tunnel、其他 launchd、UI/退出、旧 owner 删除审计 |
| 验证方式 | cargo/swift 回归、Rust/Swift 差分、fake launchd、并发/退出 fixture、真实隧道逐条验证、Release/AX 和治理检查 |
| 失败/回滚边界 | 不保留 App 内 Swift fallback；验证失败停止扩大范围并修复 Rust；独立复核通过前不得删除 Swift Core |
| 当前阻塞项 | HTTP 探针连接失败尚未分类；后台 worker/可中断取消、app 入口删除后的 UI/AX 回归、真实 Rust owner 验证、隔离 app/AX/退出操作复核和独立准入复核尚未完成 |
| 最新独立准入复核 | 阶段 4 于 2026-08-30 通过；阶段 5 尚无独立准入复核 |

## 阶段 4 完成摘要

阶段 4 的进程内 shadow bridge、动态库自包含、固定时区、Release/AX 和回退路径证据保留在[阶段 4 Step 0 证据](../data-quality/tunnelpad-rust-migration-stage4-step0-20260830.md)及历史独立复核记录中。阶段 4 的 Swift 唯一 owner 和 fallback 是历史基线，不是阶段 5 的最终架构。

## 历史契约冻结记录（阶段 1–4）

以下契约记录阶段 1–4 的 shadow/parity 边界。阶段 5 的 owner 契约以本计划“阶段 5 目标契约”和后续 Step 0 冻结结果为准；其中 Swift 并发 owner、无跨调用 Rust 状态和 `launchd|app` 双执行器范围不再适用于阶段 5。

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

**DTO 与序列化**：阶段 1–4 的 `AppConfig`/`TunnelConfig`/`ProbeConfig`/`ExecutorKind` parity 作为历史基线；阶段 5 保持 version=1 磁盘格式并收缩当前有效执行器为 `launchd`。serde 键序与 Swift `CodingKeys` 声明顺序一致；缺省值语义对齐历史 Swift 解码器；`TunnelStatus`/`ProbeResult` 以 tagged JSON（`"case"`）跨边界表达，pid 可空（has_pid 标志）。

**所有权与错误传递**：`tp_*` 返回的 `char*` 由 Rust 分配、只能由 `tp_string_free` 释放一次、禁止 `free()`；调用方字符串仅借用；返回 NULL 表示失败并伴随 last-error；成功调用清除错误。

**并发、取消与退出映射（门槛 4 的冻结方案）**：

- Swift 继续拥有全部并发：Rust 只提供同步 C ABI 函数，Rust 侧不启动线程、无跨调用状态（除 last-error 槽位）。
- 启停调用路径与现状一致：`TunnelManager`（@MainActor）→ `Task.detached` → 同步执行器调用；阶段 2+ 中同步执行器逻辑替换为 Rust 调用，busy/`operationGenerations` 门禁保留在 Swift。
- 取消语义：Swift Task 取消后废弃结果并清理 busy；Rust 调用与现状的同步 launchctl 调用一样不可中断但原子、幂等——与现有行为等价。
- 单一 owner：生命周期操作的 owner 门禁保留在 Swift busyIDs；Rust 不自行发起任何 launchctl/SSH/pidfile 操作。
- 退出清理：`Shutdown` 信号路径与正常退出继续在 Swift 侧串行直调执行器（后续替换为 Rust 函数），"退出 = 停止全部托管隧道"语义不变。

**工具链与链接**：Rust 1.96.0（rustc/cargo），target `aarch64-apple-darwin`（本机 arm64）；`staticlib` 产物经 swiftc 直链 + ad-hoc 签名校验；`Cargo.lock` 随仓提交。CI 与发布矩阵（x86_64、universal2）留阶段 4。

## 阶段 5 目标契约

**Core handle**：Rust 提供长期存在的 opaque handle；handle 持有配置、运行时状态、每隧道操作代次和后台任务。Swift 不保存第二份可执行 Core 状态。

**阶段 5 代次命令**：owner 增加 `begin {id}` 和 `cancel {id, generation}` 命令；`start`、`stop`、`restart`、`remove` 可携带可选 `generation`。Swift 在启动异步生命周期操作前向同一 owner 申请代次，后续 Rust 命令在取得隧道锁前及每个可能触发系统副作用的边界检查代次；失配返回追加错误码 `STALE_OPERATION=13`，不得调用 `launchctl`、写 plist 或修改配置。旧的不带 generation 命令仅保留给同步兼容测试，正式 Swift facade 始终携带 owner 代次。

**C ABI 数据形态**：命令参数、配置结果、状态快照和错误使用合法 UTF-8 JSON；返回字符串继续由 Rust 分配、由 `tp_string_free` 释放。owner API 的函数集合、ABI 版本和错误码扩展必须在阶段 5 Step 0 的隔离原型中冻结，不得直接把阶段 1 的无状态函数当成完整 owner API。

**状态同步**：Rust 不向 Swift 注册回调；Swift 通过命令结果和状态快照读取 Rust 状态。Swift 的轮询只更新 UI，不拥有重试、生命周期或取消语义。

**配置事实源**：Rust 负责 `config.json` 的读取、解析、保存和 schema 校验；version=1 磁盘格式保持不变，阶段 5 只接受 `launchd` 执行器。配置文件中出现 `app` 时不自动转换，当前阶段不提供 app 执行能力。

**并发与退出**：同隧道命令由 Rust 串行化，不同隧道允许并行；owner 代次失配的过期命令不得改变状态或发起系统调用。用户退出 TunnelPad 时由 Rust 停止全部受管 `launchd` 隧道并取消后台任务；窗口关闭不触发退出。

**安全边界**：Rust 只对配置中明确存在的 `launchd` label 执行操作；不记录私钥、AccessKey、完整命令敏感参数或环境变量。真实隧道验证按用户授权的单条目标执行，禁止无目标批量操作。

## 失败策略与回滚

- 阶段 5 Step 0 或隔离原型失败：停止真实隧道扩大，修复 Rust 契约/实现后重新验证；不把 sidecar 或 Swift fallback 自动引入本阶段。
- 差分测试不一致：暂停 owner 切换，定位状态顺序、错误分类、取消或资源清理差异；Swift 旧代码在删除前只作为未启用的迁移材料，不作为运行时双 owner。
- Release 链接、签名或启动失败：不删除 Swift Core，不进入真实 owner 验证；修复 Rust 构建链路后重新准入。
- 真实隧道验证失败：只停止当前受控范围，记录失败原因并直接修复 Rust；不批量修改远端配置、不修改凭证、不自动转换执行器。
- 阶段 5 所有完成条件和独立复核通过后删除旧 Swift Core；删除后不保留 App 内 fallback，后续缺陷按 Rust 正常修复。

## 验证与测试覆盖口径

- Swift 回归门禁：阶段 0 历史基线为 74/74；阶段 4 增加 shadow bridge 测试后，当前全量门禁为 80/80，二者均需在对应证据中区分记录。
- Rust 单元/集成门禁：配置 round-trip、ID/命令解析、状态映射、错误/取消、fake executor、探针和日志 tail。
- 差分门禁：同一 fixture 输入下，Swift 与 Rust 的状态序列、错误类别、文件副作用和退出结果一致。
- 发布门禁：arm64 Release `.app`、`Info.plist`、ad-hoc 签名、AX 窗口冒烟和隔离 demo 生命周期。
- 真实隧道不是阶段 0–4 的自动门禁；阶段 5 已获得用户授权，但必须先完成自身 Step 0、隔离验证和独立准入，再按单条隧道建立真实证据。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-30 |
| 阶段 | 阶段 4 |
| 结论 | 通过 |
| 证据 | 独立复跑 cargo 38 个单测 + 1 个差分测试、Release 构建、swift test 80/80、RustCoreShadowTests 5/5（真实 ABI v1、真实 ABI v2、缺失库和解析失败均未跳过）、differential、smoke、Release dylib 的 `@rpath` 自包含依赖/arm64/符号/签名/LSUIElement；静态核对 Swift 唯一生命周期 owner；fresh 只读 AX 树覆盖窗口、列表、状态、启停/重启、日志和滚动控件，未执行真实隧道操作；文档同步后 `plan-governance-cli check . --strict-readiness` 通过 |
| 复核者 | Erdos（独立复核） |

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
| 2026-08-30 | 阶段 2 完成准入复核 | 阶段 2 | 通过 | 独立复跑 HEAD `e599a58`（工作树干净）：differential.sh 全绿（事件流现场重产出，13 fixture/59 用例条目，Swift 真实 Core API 产出 vs Rust 实现）、cargo test 31/31、swift test 75/75、strict-readiness 通过、边界审计无 Sources/ 与既有测试改动；反证证实 harness 非恒真（突变 Rust parse_status → 差分如期失败 → 还原回绿）；逐组件对读语义一致。披露：D1 kill_by_pidfile 语义分叉（随落盘修复）、D2 归一化掩盖 Rust UTC vs Swift 本地时区（阶段 4 前须对齐）、D3 fixture 计数更正为 13/59 | 独立复核 subagent |
| 2026-08-30 | 阶段 3 准入草案复核 | 阶段 3 | 达到待实施标准 | 草案目标/非目标、Step 0（基线 = `e599a58` 复验一致；事实源锚点 TunnelLifecycleCoordinator 同步入口、TunnelManager.removeTunnel 序列经仓库核实）、6 列样本矩阵、验证方式、完成条件、回滚边界齐备，与阶段 2 差分设施/注入式执行器/阶段 1 冻结契约衔接自洽；落盘前提：①矩阵补「输入/基线」列并补「阶段准入摘要」表同步 PLAN_MAP；②首项修复 kill_by_pidfile 对齐 Swift（不得归一化掩盖）；③shutdown-all 差分仅覆盖 app 分支或按组件组合注入 fake launchd，不得驱动真实 launchctl | 独立复核 subagent |
| 2026-08-30 | 阶段 3 独立完成复核 | 阶段 3 | 未通过 | 指定五项门禁均通过，但 takeover 未实现；临时反证确认 shutdown-all 后 stale RestartPlan 仍可执行；Swift race harness 未直接证明迟到计划已创建；工作树边界与真实 launchctl/SSH/用户隧道安全边界核对通过 | 独立复核 |
| 2026-08-30 | 阶段 3 第二轮独立准入复核 | 阶段 3 | 未通过 | 六项门禁通过；takeover 功能与 Rust shutdown-all stale generation 反证通过，但 Swift race 仅以 unexpected-exit 日志断言，删除 asyncAfter 后仍可通过，计划创建证据不足；工作树边界和真实 launchctl/SSH/用户隧道安全边界通过 | 独立复核 |
| 2026-08-30 | 阶段 3 第三轮独立准入复核 | 阶段 3 | 未通过 | differential、cargo test、swift test、smoke、git diff --check 通过；allow-restart 的 Swift asyncAfter 删除突变明确失败，Rust shutdown-all stale-plan 删除 generation 推进突变明确失败，takeover 成功/negative fixture 与 runner 零消费通过；但 strict-readiness 因历史复核字段未同步及 tunnelpad-stability 重复影响目标退出 1 | 独立复核 |
| 2026-08-30 | 阶段 3 治理同步后准入复核补记 | 阶段 3 | 通过 | 第三轮独立复核已确认实现、功能反证和安全边界通过；随后仅修复治理文档同步与稳定性计划测试目录重复声明，`plan-governance-cli check . --strict-readiness` 重跑通过；阶段 4 仍保持设计中，待其自身 Step 0 与独立准入 | 独立复核证据 + Codex 治理复核 |
| 2026-08-30 | 阶段 4 shadow bridge 准入设计独立复核 | 阶段 4 | 未达到待实施标准 | 阶段指针及 Swift 唯一生命周期 owner 边界正确；cargo 37+1、swift 75/75、differential、既有 staticlib smoke、git diff --check 通过；但 strict-readiness 因缺少阶段 4 最新复核记录失败，且当前无 `RustCoreShadow`/`dlopen`/`dlsym`/dylib/Release/AX 实证，Step 0 时区断言缺少独立跨时区期望值，UTC fallback 仍有兼容风险 | 独立复核 |
| 2026-08-30 | 阶段 4 实施后独立准入复核尝试 | 阶段 4 | 待重新复核 | 本地实施验证已补齐上一轮指出的 dylib 工作树绝对路径、真实 ABI v2 fixture、固定时区/DST 样本、shadow 失败即关闭；复核实例在重新执行完整门禁前被中止，不能替代独立通过结论 | 独立复核实例未完成 |
| 2026-08-30 | 阶段 4 实施后独立准入复核补记 | 阶段 4 | 通过 | 独立复跑 cargo 38 个单测 + 1 个差分测试、Release 构建、swift test 80/80、RustCoreShadowTests 5/5（真实 ABI v1、真实 ABI v2、缺失库和解析失败均未跳过）、differential、smoke、Release dylib 的 `@rpath` 自包含依赖/arm64/符号/签名/LSUIElement；静态核对 Swift 唯一生命周期 owner；fresh 只读 AX 树覆盖窗口、列表、状态、启停/重启、日志和滚动控件，未执行真实隧道操作；文档同步后 `plan-governance-cli check . --strict-readiness` 通过 | Erdos（独立复核） |

## 关联计划、ADR、迁移、spec 或 issue

- [TunnelPad v1](tunnelpad-v1.md)：配置、执行器、迁移接管和退出语义的现有行为事实源。
- [TunnelPad 界面优化](tunnelpad-ui-refinements.md)：当前 SwiftUI/AppKit 用户操作与 UI/AX 契约。
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)：Rust 迁移的前置内部边界与测试基线。
- [ADR-0001：Rust Core 作为唯一生命周期 owner](../adr/0001-rust-core-single-owner.md)
- [Rust Core owner 切换迁移说明](../migrations/tunnelpad-rust-owner-cutover.md)
