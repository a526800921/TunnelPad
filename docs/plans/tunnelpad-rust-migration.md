# 计划：TunnelPad Rust Core 迁移

- 状态：设计中
- 当前阶段：阶段 0
- 最后更新：2026-08-30
- 前置：`tunnelpad-v1`、`tunnelpad-ui-refinements` 与 `tunnelpad-code-quality-refactor` 已完成；本计划只在现有 Swift 行为基线上设计 Rust Core 的渐进替换

当前说明：用户已确认迁移边界为“保留 SwiftUI/AppKit 菜单栏与窗口 UI，逐步用 Rust 替换 `TunnelPadCore`”。阶段 0 基线执行已完成，当前等待独立准入复核；本计划仍不直接修改现有 Swift 实现，不接管真实用户隧道。

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
- 当前仓库没有 `Cargo.toml`、Rust 源码或 Rust target；现有产品目标见 [Package.swift](../../Package.swift)。
- 当前 Swift Core 已完成内部职责拆分；现有行为契约由 [TunnelPad v1 计划](tunnelpad-v1.md)、[界面优化计划](tunnelpad-ui-refinements.md) 和 [代码质量重构计划](tunnelpad-code-quality-refactor.md) 共同约束。
- 当前自动化基线为 `swift test` 74/74；Debug/Release 构建和 `.app` 签名校验已通过。最新工作树仍包含未提交的 Swift/UI、ECS 文档和 fixture 改动，Rust 实施前必须选择性提交或创建干净分支。
- 本机已安装 `rustc 1.96.0` 与 `cargo 1.96.0`；当前 Swift 为 Apple Swift 6.3.3，目标为 arm64 macOS。

### 已确认决策（2026-08-30）

| 决策点 | 结论 |
|---|---|
| UI 边界 | 保留 SwiftUI/AppKit、`AppDelegate`、`MenuBarController`、主窗口、表单和日志视图 |
| 首轮替换范围 | Rust 逐步替换 `TunnelPadCore` 的配置、执行器、探针、日志、迁移和生命周期实现 |
| 兼容要求 | 外部功能和可观察行为保持正常；任何行为变化另开计划，不以迁移名义静默改变 |
| 真实隧道边界 | 阶段 0–3 只读审计、fake/fixture 和隔离 demo；真实隧道需用户明确授权并单独记录 |

### 候选连接方式与取舍

| 方案 | 说明 | 优点 | 风险/代价 | 当前结论 |
|---|---|---|---|---|
| Rust 静态/动态库 + C ABI Swift wrapper | Rust 在进程内提供 Core，Swift 保留 `TunnelManager` 门面与 UI | 性能和状态调用直接；不增加运行时子进程；最接近当前架构 | FFI DTO、内存所有权、错误/并发边界需要严格冻结 | **推荐先做最小原型** |
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
| C ABI wrapper 与 sidecar IPC 最终选型 | 决定进程边界、协议和打包方式 | 阶段 0–1 | 待最小原型比较 |
| Rust Core 的并发模型与 Swift async 映射 | 影响取消、busy、状态顺序和退出清理 | 阶段 1 | 未冻结 |
| FFI/IPC DTO、错误码和版本策略 | 影响兼容性与回滚 | 阶段 1 | 未冻结 |
| Rust 最低工具链、静态链接和 arm64 发布矩阵 | 影响 CI/本机发布 | 阶段 1/4 | 未冻结 |
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
| 阶段 0 | 迁移基线、行为契约、边界与候选连接方式冻结 | 用户确认迁移范围 | Swift/Rust 工具链、现有测试/构建、调用边界、风险和安全样本 | 设计中 |
| 阶段 1 | 最小 bridge/sidecar 原型与 DTO/错误/取消契约 | 阶段 0 独立准入复核通过 | FFI/IPC 原型、Swift 兼容调用、发布链接样本 | 设计中 |
| 阶段 2 | Rust Core 组件 parity：配置、ID、命令、执行器、探针、日志、迁移、退出 | 阶段 1 契约冻结 | fake executor、故障注入、差分测试 | 设计中 |
| 阶段 3 | 隔离 demo 生命周期与 shadow/differential 回归 | 阶段 2 组件 parity 通过 | demo 启停/重启/删除/退出、取消竞态、产物清理 | 设计中 |
| 阶段 4 | SwiftUI App 可选接入 Rust Core，保持一键回退 Swift | 阶段 3 独立复核通过 | Release `.app`、AX 冒烟、demo 实机与回滚 | 设计中 |
| 阶段 5 | 观察窗口、Swift Core 收缩或删除（可选） | 阶段 4 用户验收与独立复核通过 | 真实隧道经明确授权的分批验证、发布和回滚 | 粗粒度 |

## 当前阶段

当前阶段为阶段 0（迁移基线与接口原型）。阶段 0 只完成设计、基线和候选方案比较，不创建 Cargo 工程，不接入 Swift 构建，不操作真实隧道。

### 目标与范围

- 固定 Swift 当前行为、配置/执行器/退出/迁移契约和 UI 保留边界。
- 固定 Rust 工具链、架构、构建产物和发布约束。
- 用最小、可回滚的原型验证 C ABI wrapper 与 sidecar IPC 的可行性，不冻结尚未验证的 DTO 或并发实现。
- 明确阶段 1 的独立准入条件、失败策略和回滚方式。

### 非目标

- 不改 Swift 源码、`Package.swift`、`config.json`、launchd plist 或用户配置。
- 不创建或提交 Rust 实现代码。
- 不运行真实隧道启停、迁移接管、删除或 ECS 操作。

### Step 0

类型：架构迁移基线 + 行为契约快照。基线命令和输出摘要见[阶段 0 基线证据](../data-quality/tunnelpad-rust-migration-stage0-20260830.md)。当前 HEAD 为 `b6ffd2232833a2d3e6ef0d894f6cb23fa0448f48`；工作树非洁净，未提交 Swift/UI/ECS 改动必须在 Rust 实施前隔离。当前 Swift 测试 74/74，`rustc`/`cargo` 版本为 1.96.0，最新 `.app` 已通过 Release 构建、`plutil` 和 ad-hoc 签名校验。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前 Git 工作树 | `git rev-parse HEAD && git status --short` | HEAD、未提交范围可复现；明确 Swift/UI/ECS 改动不属于 Rust 实现 | 把未提交改动误当成 Rust 基线 | 阶段 0 证据 |
| 2 | 当前 Swift target | `swift --version && sed -n '1,100p' Package.swift` | Swift 6.3.3、macOS arm64 target、Core + UI + test target 边界明确 | target 或平台边界不明 | 阶段 0 证据 |
| 3 | 当前 Rust 工具链 | `rustc --version && cargo --version` | 工具链可执行，版本记录为 Rust 1.96.0 | 任一命令不可执行或版本无法固定 | 阶段 0 证据 |
| 4 | 当前行为回归 | `swift test` | 74/74 通过 | 任一既有测试失败 | 测试输出/阶段 0 证据 |
| 5 | 当前发布链路 | `swift build -c release`、`./scripts/build_app.sh --skip-tests` | Release 可链接；`.app` 的 plist、签名和 arm64 产物校验通过 | 构建、签名或产物校验失败 | 阶段 0 证据 |
| 6 | Core/UI 边界 | `find Sources -maxdepth 2 -type f` + 计划契约核对 | 配置、执行器、探针、日志、迁移、生命周期和 UI 调用方均有归属 | 漏掉行为 owner 或重复 owner | 阶段 0 证据 |
| 7 | 真实隧道安全 | 只读检查本计划命令与脚本；不执行 launchctl/SSH 操作 | 阶段 0 无真实隧道状态变化、无配置删除 | 产生 bootstrap/bootout/SSH 或删除副作用 | 阶段 0 证据 |

### 验证方式

阶段 0 使用只读仓库审计、Swift 回归、Rust 工具链探测、Release 产物检查和边界表；C ABI 与 sidecar 只做最小隔离原型。完成阶段 0 后，须由独立复核确认“达到待实施标准”，才可进入阶段 1。

### 完成条件

- Swift 当前行为契约、UI 保留边界、Rust Core 替换范围和非目标已写入本计划。
- Step 0 样本矩阵可复现，测试/构建/工具链/安全边界证据已落盘。
- C ABI wrapper 与 sidecar IPC 的比较指标、失败判定和选择门槛明确；未验证的 DTO/并发/版本细节仍标为未决。
- 当前工作树中的无关改动已被列出；Rust 实施入口要求选择性提交或干净 worktree。
- 独立准入复核通过后，阶段 1 才可标记为待实施；本阶段不以实施者声明替代复核。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 设计中，基线已执行，尚未达到待实施 |
| Step 0 | 已固定 Swift/Rust 工具链、74 项测试、Release `.app` 和 Core/UI 边界；证据见阶段 0 基线文档 |
| 样本矩阵 | 7 行，覆盖工作树、Swift/Rust 工具链、回归、发布链路、边界和真实隧道安全 |
| 验证方式 | 只读审计、`swift test`、Release 构建/签名、最小 bridge/sidecar 原型和独立复核 |
| 失败/回滚边界 | 阶段 0 不改实现；任一基线失败则不进入阶段 1；原型只在隔离目录运行 |
| 当前阻塞项 | bridge 选型、DTO/错误/取消协议和干净实施基线尚未冻结；不阻塞本计划设计，阻塞阶段 1 实施 |
| 最新独立准入复核 | 尚未复核；不得标记为待实施 |

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
| 阶段 | 阶段 0 |
| 结论 | 待独立复核（尚未达到待实施标准） |
| 证据 | 计划已写明迁移范围、非目标、Step 0 样本矩阵、候选连接方式、失败/回滚边界；当前 bridge 选型和干净实施基线仍待冻结 |
| 复核者 | 待独立复核者 |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-30 | 计划创建与基线整理 | 阶段 0 | 待独立复核 | Swift/Rust 工具链、74 项 Swift 测试、Release `.app`、Core/UI 边界和安全边界已记录；未冻结 bridge 细节，未开始实现 | 待独立复核者 |

## 关联计划、ADR、迁移、spec 或 issue

- [TunnelPad v1](tunnelpad-v1.md)：配置、执行器、迁移接管和退出语义的现有行为事实源。
- [TunnelPad 界面优化](tunnelpad-ui-refinements.md)：当前 SwiftUI/AppKit 用户操作与 UI/AX 契约。
- [TunnelPad 代码质量重构](tunnelpad-code-quality-refactor.md)：Rust 迁移的前置内部边界与测试基线。
- 当前没有需要新增的 ADR 或磁盘迁移；若 bridge 协议、并发模型或 schema 发生持久决策变化，再单独增加 ADR/migration。
