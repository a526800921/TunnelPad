# 计划：TunnelPad 开机自启与隧道自动恢复

## 背景

2026-09-12 需求确认：TunnelPad 目前不支持开机自动启动，App 启动时也不会拉起任何隧道。重启电脑后所有隧道都处于停止状态，必须手动打开 App 并逐条启动。

现状事实（2026-09-12 工作树核对）：

- 全工程无 `SMAppService`/LoginItem 实现；`applicationDidFinishLaunching`（`Sources/tunnelpad/AppDelegate.swift`）只安装信号处理器、启动本机 API 服务和菜单栏，不启动隧道。
- App 正常退出时由 Rust owner 停止全部受管 launchd 隧道；launchd plist 位于 `~/Library/Application Support/TunnelPad/launchd/`，不在 launchd 标准扫描目录，登录时不会被自动加载，`RunAtLoad: true` 在无人 bootstrap 时不生效。
- 已启动隧道具备意外退出后的 launchd `KeepAlive` 自动重连（按 `ThrottleInterval` 节流）；该保活只在隧道成功启动过一次后有效。
- 配置契约现状：schema version `1`，Rust Core 是配置唯一 owner（ADR-0001）；`TunnelConfig` 两侧均有"追加带默认值可选字段"的成熟先例（`remark`、`probe`），且两侧解码均忽略未知字段——旧 App 读取含新字段的配置安全。

## 目标

1. **开机自启**：提供"登录时自动启动 TunnelPad"开关（菜单栏入口），基于系统 `SMAppService.mainApp`，状态可见、可在系统设置中管理。
2. **隧道自动恢复**：为每条隧道提供显式的"随 App 启动自动拉起"标记（`autoStart`，默认关闭）；App 启动并完成首轮状态发现后，自动调用现有启动路径拉起已标记且未运行的隧道。

## 非目标

- 不实现 `app` 执行器（既有非目标，仍另立计划）。
- 不提供"恢复上次运行集合"的隐式状态持久化方案（采用显式 per-tunnel 标记，见需求探索）。
- 不为启动恢复增加自动重试循环（网络未就绪等启动期失败保持单次尝试 + 手动启动兜底，见需求探索）。
- 不通过本机 HTTP API 暴露或修改 `autoStart`、登录项状态（API 继续不提供配置读写）。
- 不自动处理 `SMAppService` 的系统级审批（`requiresApproval` 时只跳转系统设置，由用户确认）。
- 不改变"新增隧道不自动启动""同 ID 参数修改不自动重启"等既有不变量（CfgR 系列）。

## 需求探索

已确认决定（2026-09-12，用户授权"设计一下"范围内自主收敛，实施前可在此追加取舍）：

- **per-tunnel `autoStart` 而非"恢复上次运行状态"**：显式意图跨重启确定，不需要额外的运行状态文件；"上次在跑"不等于"下次要跑"（例如退出前故意停掉的隧道不应复活）。字段演进完全复用 `remark`/`probe` 先例，`version` 保持 `1`。
- **启动恢复失败不自动重试**：登录期网络可能未就绪，ECS 前置同步 fail-closed 时启动会失败；按项目 fail-closed 与能耗边界（后台健康监测计划），恢复只做单次尝试，失败原因经 `lastError` 可见，`KeepAlive` 在成功启动后自然接管崩溃重连。
- **恢复入口必须过首轮状态发现门禁**：App 崩溃后重启的场景里，launchd 作业可能仍在运行（稳定性阶段 2 已建立启动首轮状态发现）；恢复只对发现后状态为 `notLoaded`/`notRunning` 的隧道调用启动，已运行实例不重复启动。
- **登录项用 `SMAppService.mainApp`**：系统设置可管理、无自定义 launchd 登录项 plist；目标平台 macOS 14 可用（API 13+）。

## 不变量

- 配置 `version` 保持 `1`；`autoStart` 为可选字段、缺省 `false`，两侧（Rust/Swift）解码语义一致，缺字段与显式 `false` 行为等价。
- 自动恢复只发生在"App 启动"入口；新增隧道、配置刷新、参数修改路径的启动行为不变。
- 恢复调用复用现有 start 入口：busy 保护、SSH 命令的 ECS 前置同步、日志事件流与状态发现语义不变。
- 启动期单条隧道失败不阻断其他隧道的恢复，也不阻塞窗口/菜单栏出现。
- 完成时必须记录可验证证据。
- 按共享 verification 规范判断风险：低风险自验，高影响（公共契约、生命周期）同范围独立复核一次，修复后自验。

## 影响模块或文件

- `rust/tunnelpad-core/src/lib.rs`：`TunnelConfig` serde 追加 `auto_start`（默认 false）；规范化序列化键序与 Swift `CodingKeys` 对齐；差分 fixture `rust/differential/fixtures/config-store.json`。
- `Sources/TunnelPadCore/TunnelConfig.swift`：手写 `Codable` 追加 `autoStart`；`TunnelManager`：启动恢复入口（复用 start 路径）。
- `Sources/tunnelpad/AppDelegate.swift`：启动流程挂接恢复（在首轮状态发现后执行一次）。
- `Sources/tunnelpad/MenuBarController.swift`：登录自启开关与状态。
- `Sources/tunnelpad/NewTunnelSheet.swift`、`TunnelSettingsSheet.swift`、`TunnelFormState.swift`：`autoStart` 表单开关。
- 测试：`TunnelConfigTests`、`TunnelManagerTests`、`DifferentialHarnessTests`、Rust 侧 config 测试与差分。

## 公共契约变化

- **config.json schema v1 追加可选字段 `autoStart: Bool`（缺省 `false`）**：行为差异为"App 启动时自动拉起 `autoStart=true` 且未运行的隧道"；其他解码、校验、序列化语义不变。
- 契约事实源：Rust owner 实现 `rust/tunnelpad-core/src/lib.rs`（`TunnelConfig` serde 定义与规范化序列化）与 Swift 侧 `Sources/TunnelPadCore/TunnelConfig.swift`；两侧 parity 由差分 harness（`DifferentialHarnessTests` + `rust/differential/fixtures/config-store.json`）承载，不另建 spec。
- 兼容性：旧 App 读取含 `autoStart` 的配置忽略未知字段，行为不变；新 App 读取旧配置按缺省 `false` 处理。无迁移与回滚窗口需求，不建 migration 文档。
- 登录项为系统注册状态（`SMAppService`），不进入配置契约。

<!-- 机器识别的结构化章节标题必须保持固定名称，不要在标题前添加"阶段 1"等编号。 -->
## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | Step 0 基线与契约 fixture 矩阵 | 治理文档已初始化 | Step 0 证据存在 | 已完成 |
| 阶段 1 | 配置契约：`autoStart` 字段与表单开关 | 阶段 0 通过准入 | Rust/Swift 单测 + 差分 parity + 表单冒烟 | 已完成 |
| 阶段 2 | 登录自启动（SMAppService 开关） | 阶段 0 通过准入 | 开关状态机单测 + 真实 App 注册/注销观察 | 已完成 |
| 阶段 3 | 启动自动恢复与真实验收 | 阶段 1、阶段 2 完成 | 专项测试 + 真实登录/重启验收 + Release/治理门禁 | 实施中 |

阶段 2 与阶段 1/3 无实现依赖，可在阶段 0 后并行；阶段 3 依赖阶段 1 的字段落地。

## 当前阶段

### 范围

阶段 3（技术完成，待用户验收）：启动自动恢复 + 真实验收。

- 恢复入口 `TunnelManager.restoreAutoStartTunnels()`：幂等标志 → 刷新 → 有界等待首轮状态发现（与健康监测启动快照并发互相失效，二者必有一个发布成功；超时 fail-closed）→ 对 `autoStart=true` 且 `notLoaded`/`notRunning` 的候选顺序复用 `startAsync`。
- `AppDelegate.applicationDidFinishLaunching` 末尾挂接，不阻塞面板出现。
- 新增 `AppEventLog`（`~/Library/Logs/TunnelPad/app.log`，追加式限量 512 KiB）：恢复触发、逐条拉起成败（含失败原因）、发现超时 fail-closed 全程写入。
- 专项测试覆盖 R1/R3/R4/R5/R6 与 app.log 内容断言；R2 busy 由 startAsync 既有门禁保证。
- 待验收：真实登录/重启场景（打包 .app）由用户执行；技术验证已全部通过。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| 复核策略 | 风险分流 |
| Step 0 | [阶段 0 基线证据](../data-quality/tunnelpad-launch-autostart-stage0-step0-20260912.md) |
| 样本矩阵 | C0–C4 契约样本 + R1–R6 竞态清单（同上 Step 0 链接） |
| 验证方式 | [阶段 1–3 实施证据](../data-quality/tunnelpad-launch-autostart-stage1-3-implementation-20260912.md) |
| 失败/回滚边界 | 见[风险和回滚](#风险和回滚) |
| 当前阻塞项 | 无 |
| 最新阶段复核 | [最新阶段复核](#最新阶段复核) |

### 实施步骤

1. 补充 Step 0 证据（现状快照 + 基线 fixture）。
2. 申请阶段 0 准入；通过后按路线图推进阶段 1–3，每阶段有自己的 Step 0、验证/完成与失败边界。
3. 实施当前阶段。
4. 运行验证并记录证据。

### Step 0 证据

[阶段 0 基线证据](../data-quality/tunnelpad-launch-autostart-stage0-step0-20260912.md)：运行观察（App 启动不拉起隧道、无登录项代码）、C0–C4 样本形状、R1–R6 竞态清单，2026-09-12 自验通过。

### 阶段证据

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-12 | 阶段 0 Step 0 基线 | 运行观察（启动不拉起隧道、无登录项代码）、C0–C4 样本形状、R1–R6 竞态清单固定 | [阶段 0 基线证据](../data-quality/tunnelpad-launch-autostart-stage0-step0-20260912.md) | 通过；阶段 0 完成 | ZCode（实施者） |
| 2026-09-12 | 阶段 1 实施 | autoStart 双侧契约、apple_json 字节、差分 fixture、表单开关；Swift/Rust/差分全绿 | [阶段 1–3 实施证据](../data-quality/tunnelpad-launch-autostart-stage1-3-implementation-20260912.md) | 通过；阶段 1 完成 | ZCode（实施者） |
| 2026-09-12 | 阶段 1 独立复核 | 8/8 通过；唯一信息性疑问为既有 keepAlive 同形的 null 不对称 | [阶段 1 独立复核](../data-quality/tunnelpad-launch-autostart-stage1-independent-review-20260912.md) | 通过 | 独立只读复核 |
| 2026-09-12 | 阶段 2 实施 | 登录项状态机与菜单开关；映射单测通过，真实注册归用户验收 | [阶段 1–3 实施证据](../data-quality/tunnelpad-launch-autostart-stage1-3-implementation-20260912.md) | 通过；阶段 2 完成（自验） | ZCode（实施者） |
| 2026-09-12 | 阶段 3 实施 | 启动恢复入口与挂接；Swift 150/150，恢复专项 11 次零失败 | [阶段 1–3 实施证据](../data-quality/tunnelpad-launch-autostart-stage1-3-implementation-20260912.md) | 通过；阶段 3 技术完成 | ZCode（实施者） |
| 2026-09-12 | 阶段 3 独立复核 | R1–R6 及六项清单通过，无必须修复项，3 项轻微观察 | [阶段 3 独立复核](../data-quality/tunnelpad-launch-autostart-stage3-independent-review-20260912.md) | 通过（PASS，无必须修复项） | 独立只读复核 |

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-12 | 设计 | 需求确认与方案设计，计划与地图建档 | 本计划 + PLAN_MAP 索引 | 完成 | ZCode（实施者） |
| 2026-09-12 | Step 0 | 现状快照、C0–C4 样本、R1–R6 竞态清单固定 | 阶段 0 基线证据 | 完成（自验） | ZCode（实施者） |
| 2026-09-12 | 实施 | 阶段 1 契约 + 表单；Swift/Rust/差分全绿 | 阶段 1–3 实施证据 | 完成 | ZCode（实施者） |
| 2026-09-12 | 复核 | 阶段 1 独立复核 8/8 通过 | 阶段 1 独立复核 | PASS | 独立只读复核 |
| 2026-09-12 | 实施 | 阶段 2 登录项开关；映射单测通过，真实注册待用户验收 | 阶段 1–3 实施证据 | 完成（自验） | ZCode（实施者） |
| 2026-09-12 | 实施 | 阶段 3 恢复逻辑；Swift 150/150、恢复专项 11 次零失败 | 阶段 1–3 实施证据 | 完成 | ZCode（实施者） |
| 2026-09-12 | 复核 | 阶段 3 独立复核通过，无必须修复项 | 阶段 3 独立复核 | PASS | 独立只读复核 |
| 2026-09-12 | 追加实施 | 恢复失败/成功改写入 App 事件日志 app.log（用户确认口径）；AppEventLog 单测与恢复日志断言通过，Swift 152/152 | 阶段 1–3 实施证据 | 完成（自验） | ZCode（实施者） |
| 2026-09-12 | 下一动作 | 打包 .app 后由用户执行真实登录/重启验收 | 本计划用户可观察验收表 | 等待用户验收 | ZCode（实施者） |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代适用阶段准入复核。

### Attestation 说明

未采用快照，不适用。

### 验证方式

阶段 0 为纯基线：现状快照 + fixture 文件，代码覆盖率不适用。阶段 1–3 验证：`swift test`、`cargo test`、差分门禁 `rust/scripts/differential.sh`、恢复专项重复运行；`plan-governance-cli check .` 随文档同步执行。真实登录/重启验收在用户侧执行（打包 .app）。

### 用户可观察验收

| 场景 | 输入/前置 | 操作 | 可观察结果 | 验证证据 |
|---|---|---|---|---|
| 登录自启 | 打包 .app 运行中 | 菜单栏勾选"登录时自动启动"；系统设置登录项可见 TunnelPad | 重启或注销后登录，TunnelPad 自动出现在菜单栏 | 用户验收记录（待执行） |
| 隧道自动恢复 | 隧道 A `autoStart=true`，B 默认关闭；两者均停止 | 重启电脑（或退出后重新打开打包 .app） | A 自动进入运行态、探针/状态正常；B 保持停止；列表状态与启动日志可查 | 用户验收记录（待执行） |
| 恢复失败可见 | A 指向需 ECS 同步的 SSH 且网络断开 | 启动 App 触发恢复 | A 保持停止、B 不受影响，无重试风暴；失败原因写入 `~/Library/Logs/TunnelPad/app.log`（含成功/跳过明细） | 用户验收记录（待执行） |
| 旧配置兼容 | 不含 `autoStart` 的 v1 config.json | 新版 App 加载并正常增删改启停 | 行为与升级前一致；保存后新字段按表单值写入 | 阶段 1 差分与单测证据 |

技术任务可使用 CLI 输出、文件差异或调用方行为；性能类验收记录环境、负载与窗口；采用用户体验闭环，技术完成待用户接受时保持 `实施中`，`下一动作：等待用户验收`。

### 测试覆盖率

阶段 1 以 Rust/Swift 单测与差分 parity 覆盖契约分支；阶段 2 覆盖状态映射与开关语义（真实 SMAppService 注册归用户验收）；阶段 3 专项测试覆盖恢复门禁与失败边界；纯文档与基线阶段覆盖率不适用。

### 完成条件

- Step 0 证据已记录。
- 当前阶段验证通过。
- `docs/PLAN_MAP.md` 状态和证据已同步。

## 最新阶段复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-12 |
| 阶段 | 阶段 3 |
| 方式 | 独立 |
| 风险 | 高影响 |
| 风险依据 | 生命周期共享逻辑：启动恢复与健康监测/状态发现并发，退出即停语义交互 |
| 结论 | 通过（PASS，无必须修复项） |
| 证据 | [阶段 3 独立复核](../data-quality/tunnelpad-launch-autostart-stage3-independent-review-20260912.md) |
| 复核者 | 独立只读复核 |

## 阶段复核记录

| 日期 | 类型 | 阶段 | 方式 | 风险 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|---|---|
| 2026-09-12 | 阶段完成复核 | 阶段 0 | 自验 | 低风险 | 通过 | [阶段 0 基线证据](../data-quality/tunnelpad-launch-autostart-stage0-step0-20260912.md) | ZCode（实施者） |
| 2026-09-12 | 阶段完成复核 | 阶段 1 | 独立 | 高影响 | 通过（8/8） | [阶段 1 独立复核](../data-quality/tunnelpad-launch-autostart-stage1-independent-review-20260912.md) | 独立只读复核 |
| 2026-09-12 | 阶段完成复核 | 阶段 2 | 自验 | 低风险 | 通过（真实注册归用户验收） | [阶段 1–3 实施证据](../data-quality/tunnelpad-launch-autostart-stage1-3-implementation-20260912.md) | ZCode（实施者） |
| 2026-09-12 | 阶段完成复核 | 阶段 3 | 独立 | 高影响 | 通过（PASS，无必须修复项） | [阶段 3 独立复核](../data-quality/tunnelpad-launch-autostart-stage3-independent-review-20260912.md) | 独立只读复核 |

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 真实登录/重启用户验收 | 用户打包 .app 后按用户可观察验收表执行 | 否 | 待确认 |
| 范围外改动归属 | 工作树含错误栏移除与健康恢复 lastError 调整（非本计划产物），归属需工作树所有者确认后随本计划一并提交或分离 | 否 | 待确认 |
| 范围外改动归属 | 工作树含错误栏移除与健康恢复 lastError 调整（非本计划产物），归属需工作树所有者确认后随本计划一并提交或分离 | 否 | 待确认 |

## 风险和回滚

- **契约风险（阶段 1，高影响→独立复核）**：字段序/序列化 parity 破坏差分。回滚：字段独立可删，两侧 serde/Codable 删除即回到现状；旧配置不受影响。
- **生命周期风险（阶段 3，高影响→独立复核）**：恢复与首轮状态发现、busy 保护竞态导致重复启动或启动风暴。边界：只复用现有 start 入口（内置 busy/发现门禁）、单次尝试、逐条隔离失败；Step 0 固定竞态样本矩阵（沿用稳定性计划 C1–C8 经验）。
- **登录项风险（阶段 2，低风险→自验）**：`requiresApproval` 状态下开关与实际生效不一致。边界：状态展示区分已启用/待批准/未注册，待批准时跳转系统设置。
- **整体回滚**：关闭各开关（取消注册登录项、`autoStart` 全置 false）即恢复现状；字段与注册状态均不影响旧版本 App 读取配置。

## 关联 ADR、迁移、spec 或 issue

- [ADR-0001 Rust Core 单一 owner](../adr/0001-rust-core-single-owner.md)（配置事实源边界）
- [TunnelPad Rust Core 迁移](tunnelpad-rust-migration.md)（配置 owner 职责与 schema 演进方式）
- [TunnelPad 隧道稳定性与健康恢复](tunnelpad-stability.md)（启动首轮状态发现、busy 保护、CfgR 不变量来源）
- [ECS 动态 SSH 公网 IP 同步](ecs-dynamic-ssh-ip.md)（启动前置同步 fail-closed 边界）
- [TunnelPad 后台健康监测能耗优化](tunnelpad-health-monitor-energy.md)（不做启动期重试循环的能耗依据）
