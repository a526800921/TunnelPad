# TunnelPad 运行问题：暂存待统一修复

日期：2026-09-12。用户明确要求“记录一下，后面一起修复，现在继续计划”。本轮仅记录，不修改实现或探针配置。

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
