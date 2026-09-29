# 计划：TunnelPad 单实例运行约束

## 背景

2026-09-29，用户提出“TunnelPad 不得开启多个”。阶段 1 已在 `AppDelegate` 初始化中加入 per-user 文件锁；Swift executable target 编译及测试通过；命令行重复启动已实测，Finder、Launchpad、Spotlight、Dock 和登录项入口由用户确认验收通过。本阶段按“已有实例运行后不留下第二个实例”范围验收完成。

现状静态证据：

- [TunnelPadApp](../../../Sources/tunnelpad/TunnelPadApp.swift) 通过 `NSApplicationDelegateAdaptor(AppDelegate.self)` 接入应用代理，并创建 `WindowGroup`。
- [AppDelegate.applicationDidFinishLaunching](../../../Sources/tunnelpad/AppDelegate.swift) 会安装信号处理器、启动本机 HTTP API、创建菜单栏、显示主窗口，并调用 `restoreAutoStartTunnels()`。
- 本机 API 绑定失败只记录错误，App 继续运行；关闭主窗口也不会退出 App。因此，若系统或命令行启动了第二个进程，它仍可能继续运行自己的菜单栏、窗口和自动恢复逻辑。
- 实施前的基线提交 `832abfc` 未发现应用级锁或重复实例检测；当时仓库内的 `flock` 只用于日志写入互斥。
- 当前实现使用 `~/Library/Application Support/TunnelPad/app-instance.lock` 的内核 `flock`，并在创建 `TunnelManager` 之前获取锁。锁文件残留不代表实例仍在运行；进程退出时内核释放锁。
- 已完成真实 App 的顺序重复启动观察：主实例运行后，`open -a`、`open -n` 和直接运行 app 可执行文件均未留下第二个进程，本机 API 仍只有一个监听者；停止主实例后端口释放，再次启动成功。
- Finder、Launchpad、Spotlight、Dock 和登录项入口已由用户确认验收通过；关窗后重复启动及崩溃/强制结束未做单独故障注入。Codex 运行验收时配置中没有启用 `autoStart` 的隧道。

## 目标

- 当 TunnelPad 主实例已经启动后，同一 macOS 用户会话中的后续启动请求不能留下第二个 TunnelPad 实例。
- 重复启动进程必须在创建管理器、绑定 API、启动菜单栏或自动恢复之前退出；不要求唤醒或激活主实例窗口。
- 主实例正常退出或崩溃后可以重新启动，不需要人工清理陈旧标记。
- 保持现有本机 API、登录自启、菜单栏和隧道自动恢复契约，只消除这些副作用的重复拥有者。

## 非目标

- 不限制不同 macOS 用户账户各自运行 TunnelPad；默认范围是每用户单实例，不是整台机器全局单实例。
- 同时启动请求不纳入本轮独立验收。当前 `flock` 会原子仲裁同一锁文件的获取，但本轮不对登录项启动与手动启动竞速做运行验收。
- 不单独执行关窗和崩溃/强制结束故障注入；本轮验收聚焦在主实例运行期间阻止顺序重复启动，并观察进程停止后锁释放和重新启动。
- 不改变 launchd 隧道、SSH 代理或其他受管子进程的生命周期策略；本需求约束 TunnelPad 图形 App 进程。
- 不调整登录自启开关、隧道 `autoStart`、本机 API 协议或配置 Schema。

## 需求探索

- **建议范围**：以 macOS 用户身份和 TunnelPad 产品身份判定实例，不能只按 `.app` 文件路径判定；同一用户启动不同路径下的同产品副本也应复用主实例。
- **重复启动验收重点**：已有实例运行后，重复启动不能留下第二个 TunnelPad 实例。激活已有窗口是可选体验，不作为本轮阻止第二实例的验收门槛。
- **启动入口验收范围**：Finder、Launchpad、Spotlight、Dock、登录项、`open -a`、`open -n` 和直接运行 `.app/Contents/MacOS/` 下可执行文件；普通打开与强制新进程分别验证。
- 默认范围是每位 macOS 用户；全机跨账户互斥不在本计划范围内。
- 用户已明确同意直接开始实现；当前实现采用 per-user 文件锁，不做已有实例的窗口激活或进程间转交。

## 不变量

- 已有实例启动后，后续启动不得初始化第二套本机 API、菜单栏、窗口或 `autoStart` 恢复；重复进程不得以 API 端口冲突后继续运行作为防重方案。
- 锁目录或锁文件不可访问时，进程不得退化为无锁启动并产生第二套副作用；错误应写入日志并失败退出。
- 同一锁文件上的锁获取由内核原子仲裁；同时启动竞速不纳入本轮独立验收。
- 正常退出、崩溃和强制结束后，主实例资格应可恢复，不遗留需要人工删除的永久锁。
- 不把实例锁状态写入隧道配置，也不记录凭据或私钥。

## 影响模块或文件

| 位置 | 预期关注点 |
|---|---|
| [AppDelegate.swift](../../../Sources/tunnelpad/AppDelegate.swift)、[TunnelPadApp.swift](../../../Sources/tunnelpad/TunnelPadApp.swift) | 主实例仲裁时机、重复进程退出路径、API/菜单栏/窗口/自动恢复的启动门禁 |
| 用户可观察验收矩阵 | 已运行实例下的顺序重复启动、退出后重启、崩溃后的锁释放、启动副作用只执行一次 |
| [PLAN_MAP.md](../../PLAN_MAP.md) | 本专项计划状态、阶段和依赖 |

实施前对 `AppDelegate.init`、`applicationDidFinishLaunching`、`applicationShouldTerminate` 和 `TunnelManager.init` 执行 GitNexus impact；动态 AppKit 回调的结果为 `UNKNOWN`，不能按零 caller 视为无影响。文本搜索确认 AppDelegate 由 `@NSApplicationDelegateAdaptor(AppDelegate.self)` 注册；`shutdownAsync` 的 upstream impact 为 LOW，并显示由 `applicationShouldTerminate` 调用。该生命周期范围按高影响处理，并已完成一次独立只读复核。

项目功能图谱当前无法校验：`plan-governance-cli graph validate .` 报告多个已有证据路径不存在，导致本次 `graph impact` 无法运行。本轮不修复无关图谱条目，也不将该失败解释为无影响。

## 公共契约变化

不改变配置、HTTP API 或 launchd 隧道契约。新增的 App 进程行为如下：

| 情况 | 预期行为 |
|---|---|
| 当前用户没有运行 TunnelPad | 本次启动取得唯一主实例资格并完成既有初始化 |
| 当前用户已有 TunnelPad | 重复启动被阻止，最终不留下第二个实例；新进程不启动 API、菜单栏或自动恢复。激活主窗口可作为附加体验 |
| 主实例正常退出、崩溃或被强制结束 | 下次启动可取得资格，不需手工删除锁文件或重启系统 |
| 锁目录或锁文件无法访问 | 记录错误并失败退出，不能继续启动第二套应用服务 |
| 两个启动请求同时发生 | `flock` 提供原子锁获取；本轮不单独验收此场景 |

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | 确认实例范围、重复启动体验并记录源码基线 | 本次需求 | 冻结已运行实例下重复启动的用户验收范围及失败/恢复边界 | 已完成 |
| 阶段 1 | 实现唯一主实例和重复启动拦截 | 阶段 0 决策收敛、Step 0 齐备、用户明确授权实施 | 静态检查、独立生命周期复核、顺序重复启动验收；API 只有一个实例拥有 | 已完成 |

## 当前阶段

### 范围

阶段 1：当主实例已经启动后，阻止顺序启动的第二个 TunnelPad 实例。用户已明确可直接开始实现；当前代码在 `AppDelegate.init()` 中先取得 per-user `flock`，已有实例持锁时第二进程以成功状态直接退出，避免创建 `TunnelManager`、启动 API、菜单栏或自动恢复。并发锁竞争由原子锁处理，但不作为本轮独立验收范围。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 阶段状态 | 已完成 |
| 复核策略 | 风险分流 |
| Step 0 | 本文“Step 0 证据”：实施前源码基线、影响分析与用户确认的顺序重复启动验收范围 |
| 样本矩阵 | 本文“用户可观察验收” |
| 验证方式 | 按验收矩阵确认第二实例不产生 App 服务副作用，并完成适用的生命周期独立复核 |
| 失败/回滚边界 | 第二实例必须在创建管理器、绑定 API、启动菜单栏和自动恢复之前退出；不得进入会停止全部受管隧道的正常退出清理 |
| 当前阻塞项 | 无 |
| 下一动作 | 无；本阶段按顺序重复启动范围完成 |
| 最新阶段复核 | 独立只读复核已完成；详见“最新阶段复核” |

### 实施步骤

1. 采用 per-user 范围；按用户澄清，将“已有实例运行后不能留下第二个实例”作为重复启动门槛，激活现有窗口不作为必需条件。
2. 用户已明确同意直接开始；已记录顺序重复启动源码基线，并对 AppDelegate 初始化、启动回调及退出回调执行 GitNexus impact。`UNKNOWN` 已通过应用代理注册和源码调用搜索确认其系统回调边界。
3. 在 `AppDelegate.init()` 先打开并以 `flock(LOCK_EX | LOCK_NB)` 获取用户 Application Support 目录中的锁，再创建 `TunnelManager`；锁被占用时关闭新描述符并退出，不进入正常 App 终止清理。
4. 静态检查锁持有与退出副作用；真实运行验收覆盖 `open -a`、`open -n`、直接可执行文件及用户确认的 Finder、Launchpad、Spotlight、Dock、登录项顺序启动入口。进程停止后锁释放并可再次启动；不单独验收并发竞速、关窗和崩溃/强制结束故障注入。
5. 生命周期变更已完成一次独立只读复核；复核发现的文档状态漂移已修复，由实施者自验。Swift executable target 编译和全量测试已通过；真实 App 的命令行入口顺序重复启动与进程停止后重启通过，用户确认五种 GUI/登录项入口验收无问题。本阶段按用户聚焦的顺序重复启动目标完成；关窗及异常结束恢复没有单独做故障注入。

### Step 0 证据

- 只读基线 HEAD：`832abfc`；开始时工作树干净。
- `AppDelegate.applicationDidFinishLaunching` 启动 API、菜单栏、窗口及 `restoreAutoStartTunnels()`；关闭窗口不退出 App。API 绑定错误只打印后继续。
- `TunnelPadApp` 通过 `@NSApplicationDelegateAdaptor` 注册 `AppDelegate`。
- 对 `flock`、PID 文件、应用级实例锁、重复实例唤醒及 `applicationShouldHandleReopen` 的定向文本搜索未发现应用级实现；已发现的 `flock` 位于 `LogEventStore`，只保护日志写入。
- GitNexus upstream impact 对 `applicationDidFinishLaunching` 返回 `UNKNOWN`，0 callers；文本搜索已确认系统代理注册入口。功能图谱校验因现有缺失引用失败，不能产生本次功能 impact 结果。
- 当前 diff 在 `AppDelegate.init()` 中获取 `app-instance.lock` 的 `flock`，锁在 `TunnelManager` 初始化之前；已有进程持锁时第二进程立即正常退出。
- `xcodebuildmcp swift-package test --package-path . --configuration debug` 已编译 `tunnelpad` executable target，并执行 222 项 Swift 测试：221 通过、0 失败、1 跳过。跳过项要求设置 `TUNNELPAD_TEST_LAN_IP` 才能覆盖真实局域网 socket。
- 阶段 0 记录时尚未运行真实 App；后续顺序重复启动与用户入口验收证据见“最近实施/验证记录”。Finder、Launchpad、Spotlight、Dock、登录项已通过用户验收；关窗和异常结束后的恢复仍待验收。

### 阶段证据

- 本文“Step 0 证据”记录实施前只读源码、GitNexus 和功能图谱核对；本次阶段 1 代码及审阅结果另见最近记录。
- 本文“用户可观察验收”列出各启动入口；真实运行已覆盖 `open -a`、`open -n`、直接运行可执行文件，以及进程停止后再次启动。用户另确认 Finder、Launchpad、Spotlight、Dock 和登录项入口均验收通过；关窗及异常结束恢复尚未分别执行。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-09-29 | 需求与源码基线 | 建立单实例运行计划；核对 AppDelegate 启动入口、自动恢复、副作用和现有单实例搜索结果 | 本文 Step 0；功能图谱 impact 因现有引用失效未能运行 | 设计中；未修改代码 | Codex |
| 2026-09-29 | 启动入口矩阵扩展 | 按用户追问，将 Finder、Launchpad、Spotlight、Dock、登录项、`open -a`、`open -n` 和直接运行可执行文件明确列为验收入口 | 本文用户可观察验收 | 计划更新；未运行 App | Codex |
| 2026-09-29 | 重复启动范围澄清 | 用户确认重点是已有 TunnelPad 启动后不能再启动第二个；同时启动竞速暂不处理，激活现有窗口不作为门槛 | 本文目标、非目标和用户可观察验收 | 范围收窄；代码实施仍待授权 | Codex |
| 2026-09-29 | 阶段 1 单实例实现与独立复核 | 在 `AppDelegate.init()` 获取 per-user `flock` 后才创建 `TunnelManager`；锁已被占用时第二进程直接成功退出。独立审阅未发现代码缺陷，指出并发范围描述与锁行为、计划状态与实现不同步；文档已修正 | `Sources/tunnelpad/AppDelegate.swift`；独立复核结果；本计划“最新阶段复核” | 代码静态复核通过；构建、测试和真实 App 验收待执行 | Codex / 独立复核者 |
| 2026-09-29 | 阶段 1 Swift Package 测试与编译修复自验 | 首轮测试发现 `Darwin.flock` 与同名结构体解析冲突；改为项目既有 Swift 调用形式 `flock(...)` 后重跑全量 Swift Package 测试，app executable target 编译通过 | `xcodebuildmcp swift-package test --package-path . --configuration debug`；[AppDelegate.swift](../../../Sources/tunnelpad/AppDelegate.swift)；测试日志：222 项执行，221 通过、0 失败、1 跳过（缺少 `TUNNELPAD_TEST_LAN_IP`） | 编译通过；测试通过；真实 App 启动行为仍待验收 | Codex |
| 2026-09-29 | 阶段 1 真实 App 顺序重复启动验收 | 将 Release `.app` 打包到隔离临时目录，未覆盖 `dist/TunnelPad.app`。首实例启动后依次执行 `open -a`、`open -n` 和直接运行 app 可执行文件；每次都只保留首实例 PID 92526，`127.0.0.1:9998` 只有该实例监听。停止首实例后监听消失，再启动成功并由 PID 93425 监听；随后停止该实例。验收配置 `autoStart` 隧道数为 0 | `scripts/build_app.sh --skip-tests`（设置隔离 `TUNNELPAD_DIST_DIR`）；`xcodebuildmcp macos launch/stop`；`open -a`；`open -n`；直接执行 `Contents/MacOS/tunnelpad`；进程表与 `lsof` 观察 | 三个命令入口的顺序重复启动通过；停止后释放监听并可再次启动。Finder/Launchpad/Spotlight/Dock、登录项、关窗、正常退出及崩溃/强制结束恢复尚未分别验收；自动恢复调用次数未埋点 | Codex |
| 2026-09-29 | 阶段 1 GUI 与登录项入口用户验收 | 用户确认 Finder、Launchpad、Spotlight、Dock 和登录项启动路径均已实测，符合单实例预期、没有问题 | 用户本轮确认；与前述 Release App 命令行顺序重复启动验收合并记录 | 五种入口由用户验收通过；关窗后重复启动及崩溃/强制结束恢复未单独验收；自动恢复调用次数未埋点 | 用户 |

阶段证据只声明仓库内相对路径；最近实施/验证记录采用追加式记录，不能替代适用阶段准入复核。

### Attestation 说明

未采用，不适用。

### 验证方式

已通过 `xcodebuildmcp swift-package test --package-path . --configuration debug` 编译 `tunnelpad` executable target 并执行全量 Swift Package 测试。另运行 `git diff --check` 与 `plan-governance-cli check .`。真实 Release App 顺序验收中，首实例运行后依次用 `open -a`、`open -n` 和直接可执行文件请求第二次启动；每次都只观察到一个 TunnelPad PID 和一个 `127.0.0.1:9998` 监听者。停止实例后监听释放，再启动成功。用户确认 Finder、Launchpad、Spotlight、Dock 和登录项启动路径均验收通过。Codex 验收配置 `autoStart` 隧道数为 0，因此没有验证自动恢复调用次数。关窗后重复启动和崩溃/强制结束恢复仍未单独验收；同时启动不单独验收，窗口激活属于附加体验。

### 用户可观察验收

| 场景 | 输入/前置 | 操作 | 可观察结果 | 验证证据 |
|---|---|---|---|---|
| Finder | 当前用户没有 TunnelPad | 从 Finder 打开 `.app` | 只启动一个主实例 | 用户已实测并确认通过 |
| Launchpad | 当前用户没有 TunnelPad | 从 Launchpad 打开 App | 只启动一个主实例 | 用户已实测并确认通过 |
| Spotlight | 当前用户没有 TunnelPad | 从 Spotlight 搜索并打开 App | 只启动一个主实例 | 用户已实测并确认通过 |
| Dock | 当前用户没有 TunnelPad | 点击 Dock 中的 TunnelPad | 只启动一个主实例 | 用户已实测并确认通过 |
| `open -a` 重复打开 | 主实例已完成启动 | 再次执行 `open -a /路径/TunnelPad.app` | 只保留已有进程；API 仍只有一个监听者 | 已验收：PID 92526 保持唯一进程，9998 只有一个监听者 |
| 登录项 | 用户已启用登录时自动启动，当前没有主实例 | 登录 macOS 后观察 TunnelPad | 只启动一个主实例 | 用户已实测并确认通过；自动恢复调用次数未单独计数 |
| UI 常规重复打开 | TunnelPad 已完成启动 | 分别从 Finder、Launchpad、Spotlight、Dock 再次打开 | 不留下第二个实例 | 用户确认这四种入口均已验收通过 |
| 窗口关闭后再次启动 | 主实例仍在菜单栏运行 | 关闭窗口，再次启动 | 不留下第二个实例；是否显示已有窗口作为附加观察 | 本轮不单独验收；关闭窗口不会结束持锁进程 |
| 强制新进程 `open -n` | 主实例已运行 | 通过 `open -n /路径/TunnelPad.app` 再启动 | 新进程退出或转交后退出；API 只有一个监听者 | 已验收：首实例 PID 92526 保持唯一，9998 只有一个监听者 |
| 直接运行可执行文件 | 主实例已运行 | 运行 `.app/Contents/MacOS/` 下 TunnelPad 可执行文件 | 第二个进程立即退出，API 仍只有一个监听者 | 已验收：直接启动命令返回 0；首实例 PID 92526 与唯一监听保持不变 |
| 进程停止后重启 | TunnelPad 主实例已停止 | 再次启动隔离验收 `.app` | 新进程可重新取得锁并启动 API | 已验收：PID 92526 停止后端口释放；再次启动 PID 93425 并监听 9998 |
| 崩溃/强制结束后重启 | 主实例异常结束 | 立即再次启动 App | 不受陈旧锁阻塞；新实例正常启动 | 本轮不做故障注入；锁由内核在进程退出时释放 |

### 测试覆盖率

执行 `xcodebuildmcp swift-package test --package-path . --configuration debug`，Swift Package 全量测试执行 222 项：测试通过 221 项、0 失败、1 项因需要 `TUNNELPAD_TEST_LAN_IP` 的真实局域网 socket 测试而跳过；`tunnelpad` executable target 编译通过。测试未启动真实 App，也没有专门实例锁运行用例。真实 Release App 验收覆盖 `open -a`、`open -n`、直接可执行文件三种顺序重复启动，以及停止后端口释放和再次启动。用户已确认 Finder、Launchpad、Spotlight、Dock 和登录项入口通过；关窗和崩溃/强制结束未做单独故障注入，作为非阻塞边界记录；自动恢复调用次数没有运行时埋点。同时启动不单独验收。

### 完成条件

- 用户已确认已有实例启动后的第二次启动不得留下第二个实例；激活窗口为可选体验，同时启动竞速不在本轮范围。
- 阶段 1 实现通过构建及适用测试；实际顺序重复启动入口和用户确认的 UI/登录项入口均通过，API 只有一个实例 owner。
- 一次适用独立复核完成，发现按“发现 → 修复 → 验证”闭环；本轮审阅未发现代码缺陷，计划漂移已由实施者修正。
- 用户可观察的重复启动行为验收通过，`docs/PLAN_MAP.md` 状态和证据同步。

## 最新阶段复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-09-29 |
| 阶段 | 阶段 1 |
| 方式 | 自验 |
| 风险 | 高影响 |
| 风险依据 | App 进程生命周期影响管理器、API、菜单栏、自动恢复与退出清理；锁在 `TunnelManager` 初始化前获取 |
| 结论 | 通过；用户确认 Finder、Launchpad、Spotlight、Dock 和登录项启动路径均已实测且没有问题。关窗及崩溃/强制结束没有单独故障注入，非本轮验收阻塞项 |
| 证据 | 用户本轮确认；本文“最近实施/验证记录”及“用户可观察验收” |
| 复核者 | Codex |

## 阶段复核记录

| 日期 | 类型 | 阶段 | 方式 | 风险 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|---|---|
| 2026-09-29 | 阶段 0 文档建档自验 | 阶段 0 | 自验 | 低风险 | 通过；需求、基线及索引已同步，阶段 1 未准入 | [专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 0 启动入口矩阵自验 | 阶段 0 | 自验 | 低风险 | 通过；启动入口矩阵已补齐，未运行 App，阶段 1 未准入 | [专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 0 顺序重复启动范围自验 | 阶段 0 | 自验 | 低风险 | 通过；范围已收窄为顺序重复启动防护，同时启动不在范围，未运行 App，阶段 1 未准入 | [专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 1 实现独立复核 | 阶段 1 | 独立 | 高影响 | 通过；未发现代码缺陷；提出两项计划文档修正，交由实施者自验闭环。编译、测试与真实 App 验收仍待完成 | [独立复核记录](../../reviews/20260929-tunnelpad-single-instance-stage1-independent-review.md)；[AppDelegate.swift](../../../Sources/tunnelpad/AppDelegate.swift) | `/root/single_instance_review` |
| 2026-09-29 | 阶段 1 独立复核发现文档修复自验 | 阶段 1 | 自验 | 高影响 | 通过；阶段状态及并发锁语义已同步至专项计划和地图；未重复送独立审阅。编译、测试与真实 App 行为仍待用户验收 | [独立复核记录](../../reviews/20260929-tunnelpad-single-instance-stage1-independent-review.md)；[专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`git diff --check`；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 1 编译错误修复和 Swift Package 全量测试自验 | 阶段 1 | 自验 | 高影响 | 通过；`flock` 调用改用项目既有 Swift 形式后 app target 编译成功；222 项测试中 221 通过、0 失败、1 因缺少 `TUNNELPAD_TEST_LAN_IP` 跳过。真实 App 验收仍待用户执行 | [独立复核记录](../../reviews/20260929-tunnelpad-single-instance-stage1-independent-review.md)；[专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`xcodebuildmcp swift-package test --package-path . --configuration debug`；`git diff --check`；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 1 真实 App 顺序重复启动验收自验 | 阶段 1 | 自验 | 高影响 | 通过；`flock` 调用改用项目既有 Swift 形式后 app target 编译成功；222 项测试中 221 通过、0 失败、1 因缺少 `TUNNELPAD_TEST_LAN_IP` 跳过。Release App 的 `open -a`、`open -n`、直接可执行文件顺序重复启动均只保留一个 PID 和 API 监听；停止后释放并再次启动成功。Finder 等 UI 入口、正常退出、异常结束恢复尚未验收 | [独立复核记录](../../reviews/20260929-tunnelpad-single-instance-stage1-independent-review.md)；[专项计划](tunnelpad-single-instance.md)；[PLAN_MAP](../../PLAN_MAP.md)；`xcodebuildmcp swift-package test --package-path . --configuration debug`；隔离 `scripts/build_app.sh --skip-tests`；`xcodebuildmcp macos launch/stop`；`open -a`、`open -n`、直接可执行文件；进程表与 `lsof`；`git diff --check`；`plan-governance-cli check .` | Codex |
| 2026-09-29 | 阶段 1 用户验收记录自验 | 阶段 1 | 自验 | 高影响 | 通过；用户确认 Finder、Launchpad、Spotlight、Dock 和登录项启动路径均已实测且没有问题。关窗及崩溃/强制结束没有单独故障注入，非本轮验收阻塞项 | 用户本轮确认；本文“最近实施/验证记录”及“用户可观察验收” | Codex |

## 已知非阻塞边界

| 问题 | 推荐方案 | 是否阻塞当前阶段 | 状态 |
|---|---|---|---|
| 关窗与异常结束故障注入 | 本轮不单独执行；后续若扩大生命周期验收范围再补测 | 否 | Finder、Launchpad、Spotlight、Dock、登录项均已由用户验收通过；进程停止后重启已实测。关窗不会终止持锁进程，崩溃/强制结束时由内核释放 `flock` |

## 风险和回滚

- 风险集中在 App 启动、登录项、主窗口激活和进程退出边界。错误地让两个实例都通过启动门禁，会重复启动本机 API、菜单栏及自动恢复；仅依赖 API 端口占用不能阻止其余副作用。
- 同时启动不单独验收；锁本身由内核原子仲裁同一锁文件，当前行为尚未在运行中的 App 实测。
- 文件锁在当前 Release 构建的顺序重复启动中保持互斥；进程停止后端口释放且再次启动成功。未单独执行正常退出、崩溃或强制结束故障注入；锁文件残留本身不阻断重启。
- 锁目录或锁文件无法访问时，当前实现记录错误并以失败状态退出，不能退化为无锁启动。
- 回滚边界：保留可恢复旧 App；若新版本无法启动唯一主实例，退出新实例后按已备份方式恢复旧版。实施计划须细化备份位置和实际 App 替换授权，当前不执行替换。

## 关联 ADR、迁移、spec 或 issue

- [TunnelPad 开机自启与隧道自动恢复](../20260912/tunnelpad-launch-autostart.md)：登录项启动及 `autoStart` 的现有行为边界。
- [TunnelPad 隧道稳定性与健康恢复](../20260830/tunnelpad-stability.md)：App 生命周期和启动状态发现边界。
- [TunnelPad 本机 HTTP API 服务](../20260902/tunnelpad-local-api.md)：API server 的现有端口与生命周期。
