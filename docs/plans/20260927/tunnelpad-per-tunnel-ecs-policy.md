# 计划：TunnelPad 逐隧道 ECS 同步策略

## 背景

2026-09-27 用户确认已经直接使用 `10.0.0.2:9998` 访问 Mini，并要求针对“所有 SSH 隧道都触发 ECS 同步”提出解决方案。此前的 [Mini API SSH 隧道记录](../../data-quality/20260927-mac-mini-api-tunnel.md)保留为历史证据，不再以新增该隧道为本计划交付目标。本轮未核验实际监听或修改机器配置。

当前源码只根据可执行文件末段是否为 `ssh` 决定 ECS 前置。目标为局域网机器或非阿里云服务器也会调用同一套同步流程；配置中没有逐隧道关闭入口。该行为来自旧 ECS 集成范围，本计划明确演进其适用条件，不重开已完成计划。

用户随后明确授权阶段 1 实现，指定旧配置缺字段保持 `disabled`；阶段 2 又授权 MacBook 受控部署。真实连接的启停与 motorcycle 本地转发已验证；`8081/admin` 探针未通过，本轮没有直接观测到云端安全组写入。

## 目标

- 将 SSH 连接能力与 ECS 安全组同步解耦，以逐隧道显式策略决定是否访问 ECS。
- 关闭策略的隧道不因启动、重启、自动恢复或启动交接触发 ECS 子进程、云端查询、公网 IP 探测或资源锁等待；缺少 ECS 配置、凭据或工具也不影响它。
- 显式设置 `required` 的 ECS 隧道保留同步、安全失败阻断、事务互斥和持续恢复行为；旧配置缺字段按用户最新要求关闭同步。
- 普通 SSH 保留进程收敛、健康监测、断线重试及手动停止语义，不因关闭 ECS 而失去恢复能力。

## 非目标

- 不改变 Mini API 的监听地址、鉴权或用户当前访问方式，不再实施历史 API SSH 隧道方案。
- 不自动从地址、网段、Host 别名、SSH config 或 ProxyJump 推断云厂商；不通过 shell 包装绕过 SSH 识别。
- 不引入任意前置命令、多云插件、多套 ECS 资源配置或凭据存储；开启者仍使用既有仓库外 ECS 配置。
- 不改变云端同步事务、受管规则范围、Rust 生命周期 owner 或远端端口清理的授权条件。

## 需求探索

推荐使用显式枚举 `ecsSyncPolicy`，界面呈现为“连接前同步阿里云 ECS 安全组”的开关。关闭表示完全不参与 ECS 流程；开启表示前置成功后才能连接。不开设“自动识别”选项。

当前同步器只有一份全局 ECS 目标配置：`TUNNELPAD_CONFIG_FILE` 指向的仓库外文件提供地域、安全组 ID 和阿里云 CLI profile；受管规则描述固定为 `tunnelpad-dynamic-ssh-managed`，入方向 TCP `22/22`，来源为本机当前公网 IPv4 的 `/32`。因此 `required` 只表示使用这套**同一安全组、同一端口**的同步，不提供每条隧道独立的目标或规则描述。仅当隧道确实连接该安全组保护下的 ECS SSH 22 端口时才应开启；SSH Host 别名、跳板或端口转发关系无法由 App 可靠验证，界面/操作说明须明确此限制。多安全组或不同 SSH 端口属于后续独立能力，不能通过多次开启此开关冒充支持。

2026-09-27 用户进一步指定：**旧配置缺少字段时也保持 `disabled`**。新建与旧配置均默认关闭；原来依赖 ECS 同步的旧 SSH 项必须由用户明确改为 `required`。升级运行环境前应盘点这些项，并在受控维护窗口先停止、确认收敛，再显式启用；不自动猜测或暗中迁移。

## 不变量

- Rust 继续负责配置持久化与生命周期，Swift 负责界面和既有前置编排，遵循 [ADR-0001](../../adr/0001-rust-core-single-owner.md)。
- 策略关闭只移除 ECS 依赖；不能跳过可信状态读取、受管进程身份、bootout 收敛、代次校验和恢复退避。
- 策略开启时维持现有 fail-closed 语义；同步失败或不确定不能当作成功继续启动。
- `autoStart`、`keepAlive`、`forceRemotePortCleanup` 与本策略各自独立；不通过关闭 ECS 顺便开启清理权限。
- 不记录凭据、私钥、云 API 原始响应；不承诺取消能撤回已经提交的云端请求。

## 影响模块或文件

| 位置 | 拟议调整 |
|---|---|
| [Swift TunnelConfig](../../../Sources/TunnelPadCore/TunnelConfig.swift)、[Rust 配置](../../../rust/tunnelpad-core/src/lib.rs) | 枚举、缺失兼容、校验、JSON 往返和跨层差分 |
| [TunnelFormState](../../../Sources/tunnelpad/TunnelFormState.swift)、[TunnelSettingsSheet](../../../Sources/tunnelpad/TunnelSettingsSheet.swift)及共用表单 | 新建默认关闭，编辑显示有效值，保存保留策略 |
| [ECSPreStart](../../../Sources/TunnelPadCore/ECSPreStart.swift) | 同步、异步、启动检查、只读漂移检查共同使用策略；关闭时在资源查找之前返回 |
| [TunnelManager](../../../Sources/TunnelPadCore/TunnelManager.swift) | 队列资源获取、健康恢复、启动交接、故障监测候选及配置重载解耦 |
| [LaunchRecoveryCoordinator](../../../Sources/TunnelPadCore/LaunchRecoveryCoordinator.swift) | 运行配置比较纳入策略，取消旧代次，普通 SSH 不等待 ECS 资源 |
| Rust owner / Swift RustCoreClient 边界 | 确认新字段不在保存、读取、快照中丢失；增加策略能力校验，拒绝不支持字段的旧动态库组合 |
| Swift/Rust 配置及恢复测试、README 和操作说明 | 覆盖缺失/显式策略、所有入口、升级与降级行为 |

当前阶段的精确文件范围供治理 drift 检查使用：

- `README.md`
- `Sources/TunnelPadCore/`
- `Sources/tunnelpad/`
- `Tests/TunnelPadCoreTests/`
- `rust/include/`
- `rust/smoke/`
- `rust/tunnelpad-core/src/`
- `docs/PLAN_MAP.md`
- `docs/data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md`
- `docs/data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md`

阶段 1 已恢复 GitNexus 索引，编辑前取得相关符号 impact；核心生命周期符号为 CRITICAL/HIGH，最终变更图仍为 `critical`。具体范围和验证见[阶段 1 证据](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md)。

## 公共契约变化

现行配置来源为上述 Swift/Rust 类型，未发现独立配置 Schema。本节承载拟议契约，尚未实现；配置顶层 `version=1` 保持兼容读取，降级限制见风险和回滚。

### 字段和兼容规则

| 输入 | 有效行为 |
|---|---|
| SSH + `"ecsSyncPolicy": "disabled"` | 完全跳过 ECS 相关操作 |
| SSH + `"ecsSyncPolicy": "required"` | 延续现有 ECS 同步与失败阻断 |
| SSH + 缺失字段 | 等效 disabled；不再自动同步 ECS |
| 非 SSH + 缺失字段或 disabled | 不参与 ECS |
| 非 SSH + required | 拒绝无效组合，不静默忽略明确要求 |
| 未知枚举、null、类型错误 | 拒绝候选配置；重载保留既有有效运行配置，不默认为 disabled |

新建 UI 项以及项目内新建样例均显式写 `disabled`；需要 ECS 时用户主动开启。手写文件缺字段同样为 disabled；读取缺失字段不自动写盘，编辑保存使用界面显示的明确策略。命令从 SSH 改为非 SSH 且策略仍 required 时，界面提示用户关闭，不能静默清除。

Rust 与 Swift 对字段缺失和显式 null 必须保持一致；不能直接用会把二者合并的可选解码而漏掉 null 校验。HTTP 启停接口无需新增参数，使用 owner 中的隧道配置；若配置出现在返回数据中，必须保持字段序列化一致，不能宣称所有 API 响应字节不变。

### 执行路径

统一计算有效 ECS 策略，所有 ECS 入口使用同一判定；入口拦截与 checker 内防御共同保证关闭项零调用。

| 路径 | disabled | required |
|---|---|---|
| UI/API 手动 start、restart，同步与异步入口 | 直接进入既有受管生命周期流程 | 先同步，失败阻断 |
| App 自动启动队列 | 不解析 ECS resource，不占 ECS 令牌，不进入云认证重试 | 现有资源互斥、同步和退避 |
| 健康探针、launchd 异常、PID 变化后的恢复 | 保留旧实例收敛和重试，跳过 ECS 子步骤 | 收敛 → 同步 → 恢复 |
| 启动交接的一次性 IP 漂移检查 | 不进入 ECS 候选集合 | 保留只读检查及适用恢复 |
| 没有任何 required 项的会话 | 不启动 ECS 检查、不解析云配置 | 不适用 |

将“受管 SSH 恢复候选”与“需要 ECS 的候选”分开，不能把 `unattendedRecoveryCandidates` 整体改成只返回 required，也不能让 `requiresAutomaticRecoveryQuiescence` 或 `ECSIPDriftChecking` 的存在决定普通 SSH 是否受监测。保留首份配置的无人值守资格、手动停止排除及现有恢复计数契约。关闭项恢复失败后仍须有后续调度，不能因跳过 ECS 丢失已卸载实例的重试。

`forceRemotePortCleanup=true` 的受管清理是独立步骤，即使 disabled 也按原有明确配置执行；不能因 ECS 提前返回漏掉它，也不能为普通 `-L` 隧道默认开启。当前远端清理方法与 `LaunchPreflightChecking` 放在同一协议，实施时须拆出独立的受管清理能力或等价的明确调用路径：启动队列和健康恢复均先按配置执行适用清理，再启动 SSH；清理失败仍阻断本次启动并按原恢复策略重试，但不得为取得清理能力而调用 ECS 资源解析、`--check` 或同步。混合队列中 ECS 失败、缺配置或锁等待不能阻塞普通 SSH。

### 配置变更与在途操作

策略属于运行配置：变更时失效旧代次、取消并等待相关在途前置收敛后提交新配置；失败时保留旧配置并明确报告失败。新策略成功提交后不得产生旧策略的新请求，迟到结果不得更新新代次状态。Swift 的运行配置比较、Rust 配置事务以及磁盘重载必须遵守同一规则；仅变更策略不改变 launchd plist 身份，不能指望旧身份收敛代码自动停止正在运行的实例。

对已有云事务只做既有受控取消/收敛，不额外开启同步来“完成关闭”。已提交请求仍可能在云端落地；未完成 journal 保留给以后获准的 required 操作按原事务规则处理，不能删除、伪报回滚或由 disabled 项续作。

从 disabled 改为 required 前，必须确认该隧道 `notLoaded` 且旧受管 SSH 已收敛；若仍运行或状态不可信，拒绝保存/重载候选，保留旧配置并提示先停止该隧道。成功提交 required 后，仍由用户下一次显式启动或原本已具备资格的自动启动路径执行 ECS 前置；策略切换本身不直接发云请求或复活手动停止项。此规则同时适用于 UI 保存、API 所用配置和手工编辑后的重载，不能仅在表单中拦截。

从 required 改为 disabled 时，先收敛在途 ECS 前置与恢复任务，再提交策略；已运行且身份未变化的 SSH 不因这次切换重启。新策略只约束提交后的新请求，已提交的云端请求按前段的事务说明处理。队列候选失效、配置重载与删除继续遵循既有运行配置变更规则。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 方案、源码基线与验收边界 | 用户要求解决方案 | 路径覆盖、兼容与回滚文档自验 | 已完成 |
| 阶段 1 | 策略与所有运行入口解耦 | 明确实现授权；本阶段 Step 0、impact 与样本就绪 | Swift/Rust、假云、隔离恢复；收敛后一次 high 独立复核 | 已完成 |
| 阶段 2 | 配套 Release 与使用验收 | 阶段 1 完成；实际构建、替换及隧道操作授权明确 | 普通 SSH 零 ECS 调用、已有 ECS 不退化、回滚演练 | 实施中 |

## 当前阶段

### 范围

阶段 2 目标为 MacBook 受控替换和用户可观察验收。用户指定仅 `motorcycle-local-docker` 显式启用 required，并已授权部署；Mac mini 不在本次范围。用户在设置页保存时发现 ECS 策略字段丢失，现已修复写盘器并重新部署 MacBook；真实 UI 的立即重开与刷新后重开均保留选择。验收后用户再次选中 motorcycle 的 `required`，当前落盘 `ecsSyncPolicy=required`、`autoStart=true`，其他旧项仍缺字段（等效 disabled）。`8081/admin` 业务探针尚待另行复验。真实 ECS 写入不作为本次部署的必要步骤。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 实施中 |
| 复核策略 | 风险分流 |
| Step 0 | [阶段 2 Step 0](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md) |
| 样本矩阵 | [验证矩阵](#验证方式)与[阶段 2 Step 0](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md)中的部署样本 |
| 验证方式 | 隔离 Release、签名/ABI、配置备份、真实 App/API/隧道状态与回滚边界 |
| 失败/回滚边界 | [风险和回滚](#风险和回滚) |
| 当前阻塞项 | motorcycle 健康探针/8081 业务服务 |
| 下一动作 | 复验 8081/admin 业务探针，再等待用户体验验收 |
| 最新阶段复核 | [当前复核](#最新阶段复核) |

### 实施步骤

1. 阶段 1 代码、假云测试与独立复核发现已闭环；阶段 2 复用同范围独立基线。
2. MacBook 原 App/配置备份，确认受管隧道未加载后正常退出旧 App；仅 `motorcycle-local-docker` 配置 required，替换并启动新 App。
3. 验证真实 App/API、策略、普通 SSH 零 ECS 调用与状态保留；不主动启动 motorcycle。失败按 Step 0 回滚，结果写入阶段 2 记录。

### Step 0 证据

- 只读基线 HEAD：`775a2b2`；开始时工作树仅有两份未跟踪历史记录：`docs/data-quality/20260927-mac-mini-api-tunnel.md`、`docs/data-quality/20260927-mac-mini-app-deployment.md`。本轮保留原内容。结束检查时另出现未跟踪的 `docs/data-quality/20260927-mac-mini-lan-api.md`，非本轮创建或编辑，未纳入方案验证。
- `SSHCommand.isSSH` 仅比较可执行文件末段；`ECSPreStartChecker.check/checkAsync/checkLaunch/checkCurrentState` 仅按 SSH 分流，未检查目标主机或逐隧道策略。
- `TunnelManager` 的启动候选资源获取、`runInitialIPDriftCheck`、`runCoordinatedRecoveryPreflight` 及 `canRetryQuiescedRecovery` 均存在 ECS 耦合；`startLaunchdFailureMonitoring` 还依赖 ECS checker 类型。
- `TunnelConfig` 的 Swift/Rust 定义无 ECS 策略字段；`matchesLaunchRuntime` 需要纳入有效策略变化。
- 以上为源码可观察基线，未执行同步脚本、构建或运行测试，不冒充隔离运行结果。

### 阶段证据

- 本文 Step 0 与字段、路径矩阵；原问题证据见背景链接。
- `docs/data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md`：阶段 1 实施与验证证据。
- `docs/data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md`：阶段 2 MacBook 部署基线与回滚边界。
- `docs/data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-deployment.md`：MacBook 实际部署、备份和运行验收边界。
- `docs/data-quality/20260927-ecs-policy-save-loss-regression.md`：设置页策略丢失的复现、修复与 MacBook UI 验收。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-27 | 方案落档 | 核对源码并提出逐隧道策略，未进行非文档改动 | 本文 Step 0 | 设计中 | Codex 主代理 |
| 2026-09-27 | 方案复查 | 补齐运行中 disabled→required 的前置门禁及远端清理与 ECS 解耦；仅文档修订 | [配置变更](#配置变更与在途操作)、[验证矩阵](#验证方式) | 设计中 | Codex 主代理 |
| 2026-09-27 | ECS 目标边界复查 | 明确 required 共用单一安全组与 TCP 22 受管规则；仅文档修订 | [需求探索](#需求探索)、[验证矩阵](#验证方式) | 设计中 | Codex 主代理 |
| 2026-09-27 | 阶段 1 实施与修复 | 用户授权后实现逐隧道策略，旧配置缺字段按 disabled；独立复核四项发现已修复并自验 | [阶段 1 实施证据](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md) | 实施中 | Codex 主代理 |
| 2026-09-27 | 阶段 2 Step 0 | 用户授权 MacBook 部署；motorcycle-local-docker 为唯一 required 项；三条受管隧道均未加载；隔离 Release 签名通过 | [阶段 2 Step 0](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md) | 实施中 | Codex 主代理 |
| 2026-09-27 | 阶段 2 受控部署 | MacBook Release App 已替换并启动；仅 motorcycle-local-docker 配置 required；API 和三条未加载状态通过，真实连接与 ECS 写入未执行 | [阶段 2 部署记录](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-deployment.md) | 实施中 | Codex 主代理 |
| 2026-09-27 | 提交后真实连接验收 | 提交 `42d87d8`；disabled 和 required 实际启动/停止均成功，motorcycle 的 10080/ HTTP 200；用户确认保留的 8081/admin 探针失败，SSH 日志证实目标端口拒绝连接，验收连接已清理 | [阶段 2 部署记录](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-deployment.md#提交后真实连接验收追加2026-09-27) | 实施中 | Codex 主代理 |
| 2026-09-27 | 设置页策略丢失复查 | 用户勾选 ECS 后立即重开及刷新均仍关闭；当前配置仅 autoStart 变化，写盘器未输出 ecsSyncPolicy；即时 UI 状态尚需单独判定，用户要求保留当前配置 | [策略丢失复现与提案](../../data-quality/20260927-ecs-policy-save-loss-regression.md) | 实施中 | Codex 主代理 |
| 2026-09-27 | 策略写盘修复与 MacBook UI 验收 | Rust 写盘器补齐字段，独立只读复核未发现新缺陷；新版立即重开、刷新重开均显示 required，用户随后再次选择 required，当前三条受管隧道未加载 | [策略丢失复现、修复与验收](../../data-quality/20260927-ecs-policy-save-loss-regression.md) | 实施中 | Codex 主代理 |

### 验证方式

下表是阶段 1–2 的完整验收矩阵；已执行项目及剩余缺口逐项记录于[阶段 1 实施证据](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md)，不能把尚未执行的真实环境验收算作通过。

| 编号 | 样本/操作 | 预期与失败判定 |
|---|---|---|
| P1 | 旧 SSH/非 SSH，字段缺失；双语言读写 | 均为 disabled；无关编辑不得暗中开启 ECS |
| P2 | required/disabled/null/未知枚举/类型错/非 SSH required | 双语言一致；无效候选不替换有效配置 |
| P3 | disabled × 手动启动/重启/API/autoStart | spy 记录 ECS resource、check、sync、公网探测调用全部为 0；移走假 ECS 配置不影响启动 |
| P4 | disabled × 探针失败/launchd 退出/PID 变化/长时失败再恢复 | 零 ECS 调用；旧实例先收敛，重试不中断，恢复到有效连接 |
| P5 | 显式 required × 同样入口与缺凭据/同步失败 | 前置成功才启动；失败保留退避与监督，不放宽规则 |
| P6 | required 与 disabled 混合，ECS 锁占用/认证失败 | 普通 SSH 可运行，不等待 ECS 资源；共享资源同步仍互斥 |
| P7 | 策略切换/重载/删除/退出撞在资源解析或同步中；运行中 disabled→required | 旧任务失效与收敛；新代次不被迟到结果污染；运行或状态不可信时拒绝升级策略，停止并确认 notLoaded 后才可保存；不能宣称已提交云请求被撤销 |
| P8 | disabled + 明确远端清理开关；autoStart=false/手动停止 | 启动队列与健康恢复仍调用受管清理，失败阻断本次启动并保留重试；ECS 资源/检查/同步调用为 0，不误扩大自动恢复资格 |
| P9 | UI 新建/编辑、Rust 保存、FFI 快照、旧动态库组合 | 新建关闭、编辑正确显示；字段无丢失；不支持策略的混装拒绝运行 |
| P10 | 回退旧版本与配置恢复演练 | 旧程序不能接管依赖 disabled 保证的隧道；旧 ECS 可按备份恢复 |
| P11 | 多条 required 隧道与不同目标安全组/SSH 端口的配置说明 | 多条 required 共用一套安全组资源与受管描述；界面/文档不宣称逐隧道选择安全组或支持其他端口 |

阶段 1 先定向 Swift/Rust 行为和差分测试，再执行项目要求的受影响回归；命令与通过数如实记录。阶段 2 单独建立隔离 App、普通 SSH 目标与 ECS 桩的可观察基线，不借真实安全组写入验证 disabled；若额外需要真实 ECS 回归，单独核对实际操作授权。

### 用户可观察验收

- 新建普通 SSH 项默认关闭 ECS，在没有 ECS 配置的环境中仍可连接、断线自动恢复。
- 旧 ECS 项缺字段时显示关闭；受控停止并显式开启后，连接与恢复执行既有前置，同步失败有明确原因。
- 关闭一条旧局域网 SSH 项的 ECS 后，其他 ECS 项不受影响；保存不引起无关隧道重启。反向开启 ECS 时，运行中的该隧道须先停止并确认收敛，不能继续以未经过前置的连接运行。
- 技术完成后由用户确认上述体验；待确认时计划保持实施中，下一动作记为等待用户验收。

### 测试覆盖率

阶段 1 已执行配置解析、前置调用 spy、恢复和混合队列测试；尚未采集单独的行覆盖率数据，不能用字段往返测试替代入口零调用与恢复行为验证。

### 完成条件

- Swift/Rust 行为、跨层兼容与所有受影响回归通过；独立只读复核无未解决的高风险发现，治理和链接检查通过。
- 阶段 2 仍需单独准入和真实环境授权；阶段 1 完成不代表部署授权。

## 最新阶段复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-27 |
| 阶段 | 阶段 2 |
| 方式 | 自验 |
| 风险 | 高风险 |
| 风险依据 | 写盘器改变 ECS 门禁持久化，MacBook App 已替换；新增范围完成 high 独立只读复核 |
| 结论 | 未通过：Rust/Swift 串行回归、MacBook UI 保存/立即重开/刷新和用户 required 配置均通过；8081 业务探针仍未通过 |
| 证据 | [策略丢失复现、修复与验收](../../data-quality/20260927-ecs-policy-save-loss-regression.md) |
| 复核者 | Codex 主代理 |

## 阶段复核记录

| 日期 | 类型 | 阶段 | 方式 | 风险 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|---|---|
| 2026-09-27 | 文档自验 | 阶段 0 | 自验 | 低风险 | 通过：仅文档范围与链接自验；不构成代码实施准入 | [文档验证记录](#文档验证记录) | Codex 主代理 |
| 2026-09-27 | 独立完成复核 | 阶段 1 | 独立 | 高风险 | 未通过：发现交接重复检查、表单关闭入口、远端清理测试缺口和授权文案冲突 | [独立复核与修复自验](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md#独立复核与修复自验) | Codex 独立子代理 ecs_policy_review |
| 2026-09-27 | 修复自验 | 阶段 1 | 自验 | 高风险 | 通过：四项发现闭环，Swift 221/221 且 1 项跳过、Rust 回归与 App 构建通过 | [独立复核与修复自验](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md#独立复核与修复自验) | Codex 主代理 |
| 2026-09-27 | 复核基线复用 | 阶段 2 | 自验 | 高风险 | 通过：复用阶段 1 同范围独立复核及四项发现修复自验；本阶段无新代码范围 | [阶段 1 实施证据](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage1.md#独立复核与修复自验) | Codex 主代理 |
| 2026-09-27 | Step 0 自验 | 阶段 2 | 自验 | 高风险 | 通过：MacBook 未加载基线、唯一 required 项、隔离 Release 与回滚步骤已核对；部署结果待验证 | [阶段 2 Step 0](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md) | Codex 主代理 |
| 2026-09-27 | 受控部署自验 | 阶段 2 | 自验 | 高风险 | 通过：签名、单一新进程、localhost API、唯一 required 字段和三条未加载状态；真实连接体验待验收 | [阶段 2 部署记录](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-deployment.md) | Codex 主代理 |
| 2026-09-27 | 真实连接自验 | 阶段 2 | 自验 | 高风险 | 未通过：真实启停与 motorcycle 转发可用；用户确认的 8081/admin 探针背后目标端口拒绝连接 | [阶段 2 部署记录](../../data-quality/20260927-tunnelpad-per-tunnel-ecs-policy-stage2-deployment.md#提交后真实连接验收追加2026-09-27) | Codex 主代理 |
| 2026-09-27 | 策略写盘回归自验 | 阶段 2 | 自验 | 高风险 | 未通过：ECS 策略写盘器丢失字段，即时 UI 状态待查；8081 业务探针仍未通过 | [策略丢失复现与提案](../../data-quality/20260927-ecs-policy-save-loss-regression.md) | Codex 主代理 |
| 2026-09-27 | 策略写盘独立复核 | 阶段 2 | 独立 | 高风险 | 通过：Rust 三文件修复与回读测试未见可证实新缺陷；立即重开需真实 UI 验收 | [策略丢失复现、修复与验收](../../data-quality/20260927-ecs-policy-save-loss-regression.md) | Codex 独立子代理 ecs_save_review |
| 2026-09-27 | 策略写盘修复自验 | 阶段 2 | 自验 | 高风险 | 未通过：Rust/Swift 串行回归、MacBook UI 保存/立即重开/刷新和用户 required 配置均通过；8081 业务探针仍未通过 | [策略丢失复现、修复与验收](../../data-quality/20260927-ecs-policy-save-loss-regression.md) | Codex 主代理 |

### 文档验证记录

2026-09-27：已核对本轮只修改本文及 `docs/PLAN_MAP.md`；本文相对文件链接均存在。`plan-governance-cli check .` 初次通过但提示占位复核与阻塞字段格式问题，已修正文档字段后复查，通过且无警告。后续方案复查发现策略升级时运行连接可绕过前置，以及受管远端清理与 ECS 前置协议耦合；已补充门禁、拆分要求和样本，再次运行治理检查通过。本文提供源码证据与拟议矩阵，不宣称实现测试或独立安全复核通过。代码覆盖率不适用。

## 未决问题

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 阶段 1 独立复核 | 同范围 high 只读复核四项发现由实施者修复并自验 | 否 | 已解决 |
| 真实 ECS 写入验收 | required 实际启动成功，启动前后只读 ECS 检查均为 synchronized；未观测到本轮发生写入，不能把写入路径记为实测通过 | 否 | 待确定 |
| motorcycle 健康探针/8081 业务服务 | 用户确认保留 8081/admin；需恢复 SSH 目标 8081 服务后再验证 HTTP 200/401 | 是 | 未解决 |
| ECS 策略保存/回读丢失 | `apple_json::render_tunnel` 已输出 ecsSyncPolicy；[修复与验收](../../data-quality/20260927-ecs-policy-save-loss-regression.md)覆盖写盘回读、立即重开与刷新重开；用户最终选中 required | 否 | 已解决 |

## 风险和回滚

- **兼容取舍**：用户明确要求缺字段的旧 SSH 项默认关闭 ECS。这会改变旧 ECS 隧道的行为；未显式改为 required 前不能宣称其安全组仍会自动更新，也不能把继续运行旧连接当作迁移验收。
- **能力混装**：旧 Rust 动态库可能忽略并丢弃新字段，必须在启动恢复前校验策略支持能力；仅凭能解码 JSON 不能认定兼容。
- **策略升级时的现有连接**：仅保存字段不能给已运行的 SSH 补做“连接前”检查；disabled→required 的运行中修改必须拒绝并要求先停止，状态不可信时同样拒绝。
- **降级陷阱**：旧 App 不理解 disabled，会重新对 SSH 做 ECS 同步。禁止把带 disabled 语义的工作集直接交回旧版本。回退前在已授权维护窗口停止新增普通 SSH 项、确认相关 launchd 作业未加载，再恢复升级前 App 与配置备份；旧配置不得包含依赖新关闭语义的项。需要继续运行普通 SSH 时修复新版，不用旧版托管替代。
- **回滚不等于撤销云事务**：保留 journal 与既有恢复规则；不删除安全组规则，不清空事务记录来制造干净状态。
- **验证失败**：零调用、旧 ECS 前置、持续恢复、配置/代次一致性任一不通过就不发布。保留证据与工作，不放宽权限或退回命令伪装。
- 阶段 2 部署按 Step 0 备份原 App 和配置；失败先关闭新版，再恢复两者并核对受管 label，不能用旧版运行普通 SSH。

## 关联 ADR、迁移、spec 或 issue

- [ECS 动态 SSH IP](../ecs-dynamic-ssh-ip.md)：本计划收窄其“所有 SSH 均同步”的范围，保留事务安全契约。
- [无人值守启动恢复](../tunnelpad-unattended-launch-recovery.md)、[ECS 漂移恢复](../tunnelpad-unattended-ecs-ip-drift-recovery.md)：复用队列、持续恢复、取消与状态门禁。
- [SSH 异常恢复与孤儿清理](../tunnelpad-unattended-ssh-recovery-and-orphan-cleanup.md)：进程收敛和远端清理不随 ECS 关闭而丢失。
- [Rust owner ADR](../../adr/0001-rust-core-single-owner.md)：保持配置与生命周期单一 owner。
