# 无人值守端到端风险复核（2026-09-19）

## 结论与范围

结论：**NOT READY，不宜关闭无人值守计划或声称所有断线均能自动恢复。** 没有确认 P0；下面存在需要先修复的 P1。此次是评审，不是实现、部署或真实云端验收。

- 基线：`main`，HEAD `76e137da6ce9edc8f14d556327eef6cf5e708de3`，包含当前未提交的 Swift/Rust、测试和打包差异，以及未跟踪的日志代理、IP 恢复测试与计划。不是只审 HEAD，也不是只审旧报告。
- 主审：Codex；独立云端事务审核：Bacon；独立 Rust/进程生命周期审核：Banach。两域审核均已完成，均建议 NOT READY；主审重新核对了最终引用的源码。
- 本轮未修改产品代码、未重新构建/替换 App、未注册登录项、未启停真实隧道、未修改真实安全组。隔离验证使用内存源码桩、既有 helper/代理和假云；没有以旧全量测试通过替代本轮反证。
- 使用 GitNexus review 查调用与变更范围，使用 plan-governance 将新事实记录在本报告及当前计划，不回写历史验收结论。macOS 验证工具已按 xcodebuildmcp skill 检查入口；本轮未执行新的 App 构建或全量测试。

| 用户关心的链路 | 当前结论 |
|---|---|
| 开机自启 | 实现的是用户登录后启动；未登录、FileVault 解锁、登录项待批准不在现有保证内。注册错误被清除的既有问题仍未修。 |
| 自动连接 | 未加载作业有持续重试；已加载但不运行的 KeepAlive 作业会被启动队列长期只观察，无法保证重新前置、修复并启动。 |
| IP 变化修复 | 普通无 journal 的旧 `/32` 已能识别；探测出口、完整规则属性与 pending 检查仍有缺口。 |
| 异常重连及孤儿清理 | 仍有重启所有权竞争、恢复事件丢失、假稳定清零、身份信任和代理退出/回收缺陷。 |

## P1：应先修复的阻断风险

### R1：自动重启尚未收敛到唯一前置门（设计缺口）

定位：`Sources/TunnelPadCore/TunnelManager.swift:642-660,987-1005,1058-1095`；`rust/tunnelpad-core/src/plist_render.rs:53-69`；`rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs:105-124`。

plist 仍让 launchd KeepAlive 直接重启代理，代理直接 spawn SSH，不经过 ECS 前置。App 每秒检查状态/PID只能事后发现；首次恢复的零延迟不能阻止下一次采样前已经发生的重连。再次故障时又先等待 30/60/300 秒，再进入 stop，而等待期间原 label 仍可能 KeepAlive 重试。这不满足“每次新连接之前先核对/同步”的新承诺。

应让每次 SSH spawn 都受同一个恢复 owner/启动许可约束；确认故障后先收敛旧作业，再等待重试资格。不能仅缩短轮询，也不要求把云 API 塞入日志代理。

### R2：已有探针失败计数会吞掉明确断线事件（新增回归，已反证）

定位：`Sources/TunnelPadCore/TunnelManager.swift:813-826`。

`triggerAutomaticRecovery` 连续三次调用 `record`，每次覆盖 `action`。如果此前已累计 1 或 2 次探针失败，中间产生的 `.schedule` 会被最后的 `.observe` 覆盖；重试计数已经增加，但任务没有创建。

主审从当前文件原样抽取 `HealthRecoveryState`、`triggerAutomaticRecovery` 和 `observeLaunchdFailure`，仅替换外部依赖为无副作用桩，Swift 内存执行输出：

```text
priorProbeFailures=0 scheduled=[1, 2, 3] attemptCounter=3
priorProbeFailures=1 scheduled=[] attemptCounter=3
priorProbeFailures=2 scheduled=[] attemptCounter=3
```

这证明特定混合事件会丢失调度；不是断言所有隧道永远不能恢复，后续其他事件可能偶然补救。应给明确故障独立的状态机输入，一次事件只提交一次状态转换，不用三个合成探针失败凑阈值。

### R3：稳定代理 PID 被当成 SSH 恢复成功（新增设计缺口，已反证）

定位：`Sources/TunnelPadCore/TunnelManager.swift:696-722`。

连续三次相同 PID 即调用 `finishRecovery(success: true)`；这个 PID 是日志代理，不是握手/转发成功证据。主审源码桩得到 `threeUnverifiedPIDObservations attemptCounter=0`，随后再次断线调度次数为 `[1, 1]`，退避被清零。

Banach 的既有 Release 代理隔离样本进一步确认：直接子命令已退出、代理正在清理忽略 TERM 的后代时，0.2、1.3、2.4 秒代理 PID 均不变，到约 4.166 秒才返回 255。持续失败但每次存活超过三次采样的路径可反复被当成首次恢复。应区分代理存在、SSH 已建立、转发可用及稳定窗口；连接证据不足时不能清零失败历史。

### R4：启动队列对 loaded/notRunning 的 KeepAlive 作业可能只观察、不修复（既有设计与新需求冲突，已反证）

定位：`Sources/TunnelPadCore/TunnelManager.swift:367-378,668-669,891-892`。

只对 `!keepAlive` 的 notRunning 作业执行 stop；KeepAlive 作业直接返回 transient，未进入 ECS 检查或 plist 重建。该 ID 又一直归启动队列所有，运行期监控和健康恢复会跳过它。遇到无法自行重新运行的作业，例如旧代理路径失效，就缺少能把它带回完整恢复链的分支。

主审原样抽取 `executeLaunchAttempt`，对每次都返回 notRunning 的 fake owner 连续调用五次，结果均为 retry，`stop=0 preflight=0 start=0`。现有 `LaunchRecoveryIntegrationTests.swift:143-151` 明确期望此行为，最后人工把桩改成 running，没有验证无法自行恢复的路径。

应为可信的受管、已加载停止作业提供有界观察后的协调收敛与重新前置；unknown/身份不可信仍然 fail-closed。

### R5：IP 探测可沿 curl 代理出口，随后撤销正确的 SSH 来源规则（既有缺口，假云实测）

定位：`rust/tunnelpad-core/src/preflight/transaction.rs:355-362`；`Sources/TunnelPadCore/ECSPreStart.swift:183-186`。

curl 调用未禁用用户配置/代理，App 又保留真实 HOME。两个端点同走代理出口 B，而 SSH 直连出口为 A 时，双端点一致并不等于 SSH 来源正确。Bacon 用系统 curl、临时 CURL_HOME、回环代理和假云复现：同步执行一次 Authorize/一次 Revoke，最终只剩代理返回的 `/32`，随后检查仍成功；全部探测在回环处理，没有访问真实 IP 服务。

应将 `-q` 放在首参数并显式禁用代理，同时明确与 SSH 同路由的前提；禁用 HTTP 代理也不能自动证明 VPN/TUN 分流下出口一致。curl 默认配置文件和禁用选项见 [curl 官方手册](https://curl.se/docs/manpage.html)。

### R6：规则“完整匹配”遗漏源端口限制，可能确认坏规则并删掉旧规则（既有缺口，假云实测）

定位：`rust/tunnelpad-core/src/preflight/transaction.rs:43-56,305-316`。

`requested_rule` 不检查 `SourcePortRange`。授权未确认、journal 的 new 尚为空时，若云端出现同描述、当前 `/32`、TCP、目标 22、优先级 1，但源端口被限定为 `22/22` 的规则，续作会接纳它并撤销旧规则。Bacon 用真实 helper 的失败路径生成 journal 后复现：第二轮未新增规则，只撤销一次旧规则，返回 synchronized；最终规则仍带错误源端口限制。普通 SSH 临时源端口不能依赖该规则。

该字段是实际云端响应字段，参见 [阿里云 DescribeSecurityGroupAttribute](https://www.alibabacloud.com/help/en/ecs/developer-reference/api-ecs-2014-05-26-describesecuritygroupattribute)。应统一规范化后的完整元组校验，覆盖只读检查、幂等成功和新规则接纳；属性异常不能继续删除旧规则。

校正旧报告：协议、目标端口已有 `safe_rule` 检查，不能称为漏检；UDP 对照被拒绝。既有 Priority=2 被接受属于另一项完整属性契约差异，并不意味着该规则必然不能连接。

### R7：停止身份核验把被检查对象提供的 program 当作可信预期（新增回归，源码可达）

定位：`rust/tunnelpad-core/src/launchctl.rs:798-805,822-830`。

调用方传入的预期 executable 被任意 `launchctl print` program 覆盖。如果相同 label 已被外部替换为其他程序，只要 PID、UID、PGID 满足核验，它就会被当成受管目标 bootout，必要时整组 KILL。此处证明的是“进程符合它自报的程序”，不是“它属于允许管理的 TunnelPad SSH/代理”。HEAD 原先会拒绝可执行路径不匹配的目标。

这违反孤儿计划 O6 的同 label 外部替换 fail-closed 边界。应从配置和可信部署信息导出允许身份，再核验 fresh program/PID/启动身份；不能让待核验数据决定授权集合。本轮没有对真实外部作业做信号实验。

### R8：持续输出的后代会让代理漏掉主命令退出（新增回归，隔离实测）

定位：`rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs:163-189`。

仅在日志接收超时或管道断开时才调用 `child.try_wait()`；持续收到日志时不检查子进程退出。Banach 让父命令 exit 255、后台后代每 20ms 输出一行，在 0.2、2.2、6.2 秒观测到直接子进程为 zombie、代理同 PID 仍运行，显式 TERM 后才收敛。

后果限于包装命令/后代持管道等可达场景：主命令已失败，代理却不退出，KeepAlive 看不到故障，PID 稳定门还可能报恢复成功。应独立检查子进程状态，并给退出后日志排空设置界限。不能只测试静默持管道的 sleep 后代。

## P2：仍需处理的可靠性及诊断问题

| ID | 定位 | 已确认的问题、边界与建议 |
|---|---|---|
| R9 | `rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs:183-187,202,224` | TERM 后 reader 先关闭，会跳过有界 cleanup 并进入无超时 wait，同时已停止信号线程。隔离子命令在 TERM trap 关闭输出但不退出，7 秒后双方仍存活。外层 launchd/Rust 可能最终 KILL 兜底，不能据此说所有真实停止都会永久挂起；代理所有停止路径仍应共用有界回收。 |
| R10 | `rust/tunnelpad-core/src/plist_render.rs:147-155` | 不同隧道安装共享代理，却使用同一个可截断临时文件；各 ID 锁不保护此共享文件。两方同时打开后，第一方 rename、第二方 rename 可报 ENOENT，导致启动失败。源码可达，未做真实 App 并发实验；使用共享部署锁或独占唯一临时文件。 |
| R11 | `Sources/TunnelPadCore/TunnelManager.swift:1092,1141-1147`；`LaunchRecoveryCoordinator.swift:107-112` | 运行中恢复直接逐隧道 checkAsync，未复用启动队列的资源等待、容量和分类。底层内核锁仍能阻止并行云写，不能称为完全没有互斥；但 lock_busy 会变成恢复失败而非共享结果/等待，错误原因又被 catch 丢弃。应共享资源队列、结构化结果与脱敏失败日志。 |
| R12 | `rust/tunnelpad-core/src/preflight/transaction.rs:383-388` | pending 的 validate 只证明事务相容，未比较本轮 desired，却返回 synchronized。假云复现：仅旧规则、或两条规则且 IP 又变化时均漏报；后续无参数同步均能续作收敛。因此本轮按 P2 记录“启动只读复核漏报”，不声称写路径永久卡死或此检查直接放行 bootstrap。 |
| R13 | `rust/tunnelpad-core/src/bin/tunnelpad-log-proxy.rs:155-160` | 延迟 0.4 秒正常 TERM 的隔离样本仍约 0.457 秒返回 70，记录日志代理失败，但最终进程组为空。本轮按退出/诊断误分类评 P2，不沿用旧报告 P1，也不把它等同于遗留孤儿。 |
| R14 | `Sources/tunnelpad/LoginItemController.swift:36-38,52-55` | register/unregister 抛错后 refresh 清空 registrationError，菜单无法展示失败原因。主审原样方法与抛错服务桩得到 `state=notRegistered registrationError=nil`。这是 9/12 已记录的未修既有问题，不是本次新增。 |
| R15 | `Sources/TunnelPadCore/TunnelManager.swift:550-558,663-665,688-689,735-744` | 显示名/备注变化也会删除 manuallyStopped 状态；新监控枚举当前所有 autoStart+keepAlive SSH，并对首次观察的停止状态发起恢复。因此已手动停止的隧道改备注可能自动复活，后新增 autoStart 隧道也可能本次会话就启动，绕开启动候选冻结。源码组合可达，未做真实配置编辑；应持久区分用户运行意图、启动资格与观测状态。 |

R11–R13 是对旧独立报告的重新定性，不删除旧记录，也不以严重性校正解除本轮 R1–R8 阻断。

## 证据和限制

### 图谱与源码

- 已刷新 `analyze --pdg --index-only`。`detect_changes(scope=all)` 报告 130 个变更符号、137 个受影响流程、12 个已跟踪变更文件，risk=critical，返回未标记 partial/truncated；未跟踪实现也做了直接阅读。
- triggerAutomaticRecovery 的 upstream risk=HIGH（直接调用为 observeLaunchdFailure/runInitialIPDriftCheck）；performAutomaticRecovery 为 HIGH（直接来自 scheduleRecovery）；Rust restart_with_generation 为 CRITICAL。executeLaunchAttempt 图上 LOW 不会降低跨组件契约的实际影响。
- 部分宽范围 impact 输出被截断，已对关键入口重跑 summary；不把截断的零调用者当干净检查。索引有动态属性/跨语言解析和流程预算限制，协议分发另以源码调用点确认。
- explain 未报告相关 taint，不代表并发、状态机、身份授权或生命周期安全通过。

主审源码反证的 SHA-256：

```text
TunnelManager.swift       fc081cf3b16eed97d67b630b230d5f64bfba9746734edac57416d6484cc0f59e
HealthRecovery.swift      ed1cf5f6eb1179128ecd5027ed4b105cc745034c923defd5e0b9e3f756cee158
LoginItemController.swift 14ba922e650b3ef925c7f16dea44acdecd7f31564917a8c481ab50d3501e185f
transaction.rs            5c4fbdf3cca2d50615317796ad437b6efd3dd2b4431fedd5acf96fc851ecf777
tunnelpad-log-proxy.rs     d51e71fba4eb8babb965325c02ae64798ff8a794038b70e657567c7e200527f4
```

### 本轮验证而非历史通过

- 主审：当前源码方法抽取、外部依赖桩化，Swift stdin 执行；验证 R2/R3/R4/R14。没有把整个 App/真实 launchd 包装为已测试。
- Bacon：既有 helper + 假云生成真实事务 journal；系统 curl 的回环代理反证；覆盖 R5/R6/R12 和 UDP 负向对照。无真实安全组写入。
- Banach：既有 Release 日志代理（SHA-256 前缀 `a41348ae3d9b`）隔离进程组，覆盖持续输出后代、假稳定、reader 先关闭、延迟 TERM；实验进程组均已清理。原始非敏感日志保留在 `/tmp/tunnelpad-rust-ssh-review.RiAAy0/`，该临时路径不是持久完成证据。
- 本轮未重新跑 Swift/Rust 全量，也未做重启登录、真实出口切换、远端 18080 故障注入或隔夜资源验收；历史 181 项等通过只能说明历史样本，不能覆盖本次反证。

已有二进制的来源与复验边界：

| 产物 | 本轮核对 |
|---|---|
| `rust/target/debug/tunnelpad-preflight` | mtime 2026-09-19 13:41:14 +0800；SHA-256 `1d121abf5da3b14ed554e2b42afafac1d295c4f8eff389fe0b3001b80c20d708`；同时间 Cargo 指纹及无 journal 旧来源返回 ip_drift 的特征行为，支持含当前未提交修复。 |
| `rust/target/release/tunnelpad-log-proxy` | mtime 2026-09-19 13:41:32 +0800；SHA-256 `a41348ae3d9bda6c630b74685c928d352e50247b141f799aada2f9dc4e7958a1`；`.d` 依赖记录引用当前代理源码，源码 mtime 13:31:12。 |

以上是时间、构建记录及行为交叉证据，不是源码哈希绑定的可重现构建证明。主审重新核对了两个二进制哈希和保留的假云最终状态/调用次数；SourcePortRange 样本最终唯一规则仍为 `22/22`，curl 样本确有一次新增、一次撤销。云端实验自建材料已移入 `/Users/jafish/.Trash/tunnelpad-ecs-readonly-review.VGraYx`，可恢复；重跑前需复制到新 scratch 并调整脚本路径/初值。代理实验脚本只在子任务调用记录中，PID、采样时间及清理观测也不全在日志文件内，不能将临时日志当完整可重放验收包。

### 不应冒充已证明的部分

- 本地进程消失不等于远端 18080 已释放；Rust restart 的新注释不构成远端收敛证据。本轮没有判定真实远端孤儿存在或已排除。
- `launchctl.rs:984` 状态查询超时时只凭旧 PID 消失判定收敛，是既有缺口；需要独立的 label/进程组负向样本，不把它混为本轮新增实现。
- `log_proxy.rs:47,63-67` 的 I/O 失败测试检查的是代理句柄，不能证明被代理命令/后代已回收。需要直接记录后代身份和进程组，并验证最终为空。
- 当前一秒状态监控属于新增持续唤醒，不能继承旧“无持续全量快照”版本的能耗验收；需要多隧道数量、CPU/唤醒和长时日志增量实测。
- 现有边界要求用户已登录且 App 常驻；未登录或 App 不运行时不保证 IP 同步与恢复。若要覆盖这些场景，需要另行明确系统级监督需求，而不是声称现有实现已支持。

## 建议修复顺序与验收门

1. 先冻结统一恢复所有权与用户停止意图：明确每次 spawn 的许可、先收敛后退避、启动队列和运行恢复交接；修 R1/R2/R4/R11/R15。
2. 修真实连接确认与进程回收：不要只凭代理 PID 清零；退出检测独立于日志吞吐；所有停止路径有界且身份来自可信部署集合；修 R3/R7/R8/R9/R10/R13。
3. 收紧云端同步：探测出口约束、完整规则属性、pending 与 synchronized 的区别；修 R5/R6/R12。补登录项错误展示 R14。
4. 自动反证矩阵必须包含：已有 0/1/2 次探针失败后断线、握手/失败超过三秒、loaded/notRunning 的坏路径、退避期间零自发 spawn、同资源多隧道、curl 代理污染、SourcePortRange 与 journal、持续输出后代、TERM 后先关管道、外部替换 label、编辑备注不复活手动停止项。
5. 修复后由未参与实现者复核；再进行受控 Release、真实登录、出口变化、18080、孤儿身份与长时资源验收。保持当前计划实施中，不用一次测试全绿关闭高影响计划。

## 文档门禁

本轮只更新评审和当前计划/地图。四份文档的 224 个本地文件链接及行尾空白检查通过，`git diff --check` 退出 0。`plan-governance-cli check .` 退出 1：当前阶段存在未解除的独立失败和阻塞；另保留历史高影响自验记录的警告。最新复核与追加记录的字段已对齐，无新增镜像冲突；没有为取得绿色结果清除真实阻塞，也没有把检查当成阶段准入。
