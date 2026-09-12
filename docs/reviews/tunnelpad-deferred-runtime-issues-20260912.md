# TunnelPad 运行问题：记录与修复收尾

日期：2026-09-12。用户明确要求“记录一下，后面一起修复，现在继续计划”。首次仅记录；后续用户已授权修复，实施与验证结论见文末。

## P2：未运行隧道仍自动探测，绿色标记可误导

现象：截图中 admin-tunnel 灰色未启动，却显示“探针 401 ✓”。

实际核对：
- admin-tunnel autoStart=false，launchctl 确证未加载。
- runHealthProbeCycle 与 runProbes 只按是否存在 ProbeConfig 收集候选，未按运行状态过滤。
- admin-tunnel 与 motorcycle-local-docker 均探测 http://127.0.0.1:8081/admin，允许状态 200/401；该端口实际由 OrbStack 监听。
- UI probeBadge 根据 HTTP 结果直接显示绿色；返回符合预期不证明当前隧道运行或流量经过该隧道。

拟议修复（待统一实现）：停止或尚未确认运行的隧道暂停自动探测；停止/删除/配置变化时失效旧结果与在途提交；UI 明确未运行/未检测，避免继续展示旧绿色标记；单独核对探针 URL 与目标转发路径。需要保留“HTTP 端点符合预期”和“隧道本身确证运行”的区别。

待验收反例：隧道未加载但相同端口由另一服务返回 401；探针在途时用户停止；停止后已有绿标；另一隧道复用相同 URL。均不得显示当前隧道健康或接受迟到结果。

关联文件：Sources/TunnelPadCore/TunnelManager.swift 的 runProbes/runHealthProbeCycle/applyProbeResults；Sources/tunnelpad/TunnelDetailComponents.swift 的 probeBadge。

## 对当前阶段 2 证据的限制

先前 401/satisfied 是端点证据，不能单独作为目标 SSH 业务转发健康证明。目标 fresh PID、launchd 运行、自动重试、取消与退出事实仍由独立证据支撑；后续报告明确区分。该问题按用户要求延后修复，不阻断继续无人值守启动恢复计划的其它验收。

## 待评估：launchd 重连后 API 的 PID 仍为旧值

2026-09-12 实际重启验收：API报告motorcycle-local-docker PID8020，但同期launchctl running/PID9120、runs=2，lsof确认9120连接及监听。记录快照差异，不以API旧PID判断SSH死亡或当前身份。候选原因是健康端点一直satisfied时没有刷新运行状态，需后续定位；本轮不修改实现。身份核验仍须使用fresh launchctl/进程证据。

补充：随后独立复核时API已追平PID9120，属于当时的缓存滞后，不是已证实的持续不更新；保留为待评估观察，不直接认定新缺陷。

## 2026-09-12 授权修复

用户要求“提交，然后进行修复收尾”；先以 `1cefd8a` 提交已完成计划验收。以下是独立于已关闭启动恢复计划的一次修复，不改写历史验收结论。复核策略：单次独立复核（共享运行状态/健康恢复为高影响）。

修复前基线：截图、launchctl 未加载与同端口返回 401 的实测已记录于上文；源码候选只有 probe 配置过滤。该既有反例作为本次可观察基线，没有将修复后的测试倒填为修复前执行。

实现范围：
- 一次性刷新与后台 HTTP 探针只接受运行中、非 busy、非启动恢复占用的隧道；后台每轮先复核配置了探针的目标状态，不扫描无探针隧道，不重复全量 snapshot。
- 状态/PID/busy 变化取消旧探针代次，停止、配置变化、删除清理展示缓存；提交结果再次验证代次及候选资格。查询未知不发送 HTTP，清除绿色结果。
- 预检失败导致受管 SSH 暂停的既有恢复，使用内部失败信号推进原有有界重试，不再靠停机 HTTP 请求触发。
- UI 区分未运行/未检测/端点探针；提示端点响应不证明流量经过该隧道。保留原 HTTP URL，不擅自推断用户想探测的远端服务。
- PID 在健康周期也会更新，解决仅失败探针才查询状态造成的滞后；这仍是周期采样，不是实时事件订阅。

GitNexus 实施前 impact：runProbes CRITICAL（2 直接调用、6 流程），updateRuntime CRITICAL（18 直接调用、11 流程），applyEffectiveConfig CRITICAL（6 直接调用、8 流程），applyProbeResults 写入重载 CRITICAL（2 直接调用、7 流程）；已向用户说明。runHealthProbeCycle、UI 与修改的测试入口为 LOW；新测试/辅助函数未在旧索引中。

验证进行中：首轮旧有 167 项中 165 通过、2 项旧断言失败，均原先假定未运行隧道仍有 HTTP 结果；调整断言并补充真正运行后配置清理、迟到返回等反例。新增测试编译曾因缺少注入 checker 和 Swift 6 actor 隔离报错，已修正；最终结果另行补录。能耗取舍明确：健康目标也增加每周期一次单目标状态查询；不沿用旧“健康路径零状态查询”的性能结论。

### 独立发现与修复自验

2026-09-12，只读独立复核者 `/root/probe_fix_review`，首轮结论未通过，发现两项 P2：
1. 同步 refresh 在 snapshot 失败后仍无条件 runProbes，异步失败也保留旧结果/在途提交。修复为两个失败入口均失效代次并清空结果，同步入口立即返回；新增测试在已有绿标和阻塞 HTTP 时分别触发两个失败入口，确认无新请求、无迟到写回。
2. 后台 coordinator 整批串行执行时，停止尚未发送的 B 后仍可在 A 完成时发送 B。修复为后台逐条请求前验证状态读取 token、probe generation 和运行资格；新增 A 阻塞、停止 B、释放 A 的双目标测试，确认没有后续 B 请求。

补充 impact：refresh MEDIUM（9 直接调用、1 流程）；refreshAsync CRITICAL（9 直接调用、6 流程），已说明风险。复核后未扩大云端/生命周期写入范围；按本次单次策略完成修复自验，没有将实施者自验写成独立通过。

最终自验通过：`xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad`，175 passed / 0 failed / 0 skipped；其中新增 8 项覆盖停止、未知、共享端点、手动停止后迟到、配置移除、健康 PID 更新/外部停止、失败刷新两个入口、后台过期批次。既有恢复退避、预检失败后的停止态重试、取消与熔断回归通过。最终日志：`~/Library/Developer/XcodeBuildMCP/workspaces/TunnelPad-fadc694a998e/logs/swift_package_test_2026-09-12T13-40-11-837Z_pid14376_b4cb7a0c.log`。

Release 经项目脚本 `TUNNELPAD_DIST_DIR=dist/probe-fix-validation ./scripts/build_app.sh --skip-tests` 重建，打包、Info.plist 与深度签名校验通过；`--skip-tests` 复用前述当前源码的 Swift 测试结果。Rust/脚本无源码差异，不重复宣称本轮运行其全套测试。

### 真实 App 验证与交付

- 旧 App PID 7169 的真实 UI/API 再次观察到 admin-tunnel not_loaded + satisfied/401，作为修复前对照。
- 正常 Cmd+Q 退出旧 App，确认 API 9998 关闭、三条 launchd label 均未加载。
- 保留旧包 `dist/probe-fix-backup-1cefd8a/TunnelPad.app`，以新包替换原 `dist/stage1-validation/TunnelPad.app`，保持现有登录项路径；新 App PID 14976。
- 新包真实 UI：`admin-tunnel launchd 未运行 · 未检测`，操作栏已停止；API admin-tunnel not_loaded/probe unknown，不再显示 HTTP 401；reverse-ssh 仍未加载。
- 唯一既有 autoStart 目标 motorcycle-local-docker 自动恢复，PID 15032 与 fresh launchctl 一致；没有点击 start/restart。
- 真实 config.json SHA-256 与更新前一致。单进程外部配置 source 原配置并仅覆盖 ALIYUN_BIN，wrapper 只放行 DescribeSecurityGroupAttribute；截至首次验证记录两次 describe（含预检查），无放行写操作。前置 `--check --result-json` 为 success/synchronized。
- 私有验证目录 `/var/folders/t0/t1h7z_pd6716d4kstbbmxxyc0000gn/T/tunnelpad-probe-fix-dvq1gxab` 保存脱敏快照、配置哈希、App PID、只读 wrapper 与动作名称记录；未复制凭证。该护栏只用于本次进程，不宣称下次系统登录仍带该环境变量。

本次修复完成。URL 仍指向原配置端点；其 401 只能说明 HTTP 端点符合预期，不证明该响应经过 SSH。更换探针为实际业务转发路径需明确目标端点，未凭猜测修改。PID 仍存在一个健康采样周期加查询/HTTP 耗时的可见延迟；未作全天能耗结论。

末次实机采样：App 运行 41 秒，motorcycle-local-docker 已出现端点 satisfied/401，admin-tunnel 仍 unknown；这里只验证探针门控和持续运行。提交前 `detect_changes(scope: staged)` 报告 9 文件、28 个索引符号、2 条健康监测流程、MEDIUM；实际 diff 核对范围仅本次状态/探针、UI、测试与记录。旧索引按行偏移额外映射到 recordHealthResult/endOperation/beginRustOperation 等邻接符号，未将这些标记视为实际函数体修改；新增测试尚无旧索引符号。`git diff --check` 与 `plan-governance-cli check .` 均通过。
