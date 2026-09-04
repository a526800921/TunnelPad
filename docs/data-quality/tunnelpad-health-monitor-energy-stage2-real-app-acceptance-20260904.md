# TunnelPad 后台健康监测能耗优化：阶段 2 真实 App 验收

- 日期：2026-09-04
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 前置：[阶段 2 Step 0](tunnelpad-health-monitor-energy-stage2-step0-20260904.md)
- 结论：真实 App 能耗切片通过；活动 `admin-tunnel` 的 stop/start 状态收敛与自动恢复已在受控原 PID 释放窗口中通过；纯 `SIGSTOP` 无人工释放的进程处置边界仍未纳入生产行为，计划保持实施中

## 真实环境

- 架构：arm64 macOS Release App，路径为 `/Users/jafish/Documents/work/TunnelPad/dist/TunnelPad.app`。
- 构建：`./scripts/build_app.sh --skip-tests` 完成，Rust release dylib、Swift release 二进制、ad-hoc 签名和校验均通过。
- 新进程：PID 15264；旧进程 PID 44523 已优雅退出后才生成并启动新 App。
- 当前只读配置：2 条隧道；`admin-tunnel` 探针启用且当前结果为 `failed`；`reverse-ssh` 探针关闭；两条状态均为 `not_loaded`。

## 结果矩阵

| 观测 | 结果 | 判定 |
|---|---|---|
| 旧版本 30 秒 CPU 基线 | 绝大多数采样 0%，仅约 0.5%、0.9%、0.6% 的短采样 | 该窗口未重现旧截图中的高峰，作为切换前现场基线保留 |
| 新版本 45 秒 CPU 采样 | 主要为 0%；观测到约 3.0%、1.6%、1.8%、0.8%、3.3% 的短峰，没有几十个百分点峰值 | 通过 |
| Activity Monitor 当前能耗影响 | TunnelPad 当前约 7.3；旧截图约 367.2 | 通过；两次不是严格同一时刻 A/B |
| Activity Monitor 12 小时电源 | 新进程当前约 8.48；旧截图约 139.86 | 作为现场读数记录，不作严格 12 小时等时长结论 |
| 配置与资源边界 | API 仍返回原 2 条配置；未主动启动隧道；未执行 ECS/远端写操作；未发现 TunnelPad 子进程 ssh/autossh | 通过 |

## 结论与剩余项

阶段 1 的改动已在真实 App、真实配置下运行，当前观测不再出现原先约 10 秒一次、几十个百分点的 CPU 峰值，Activity Monitor 的即时能耗影响也明显低于旧截图。

首轮窗口只完成“真实 App + 当前配置”的能耗验收；后续追加窗口已覆盖活动 SSH 隧道和状态收敛后的自动恢复。纯 `SIGSTOP` 无人工释放的进程处置边界及阶段 2 独立完成复核仍未关闭本计划。

## 追加验收：活动 admin-tunnel 与会话复用

- 日期：2026-09-04
- 运行方式：重新构建并启动当前 Release App；通过本机回环 API 启动既有 `admin-tunnel`，未修改配置、真实 plist、ECS 或凭证。
- 活动状态：探针启用，HTTP 状态码为预期的 `401`，探针结果为 `satisfied`；对应 SSH 子进程持续存在。API 的生命周期摘要在采样时仍显示为 `other`，因此不把该字段误作恢复验收结论。
- 会话复用前对照：已移除主窗口 5 秒全量刷新循环，但在活动隧道下仍观测到约 `65.8%`、`51.2%`、`25.9%` 的短 CPU 峰；运行时采样定位到 `ProbeService.check → NSURLSession.data`。
- 会话复用后 60 秒 CPU 采样：启动暖机后主要为 `0%`，观测到约 `1.1%`、`3.6%`、`29.8%` 后回到 `0%`；后续采样保持低个位数，未再出现前一轮的 `70%–80%` 周期峰值。
- Activity Monitor：复测窗口读取 TunnelPad 即时“对能耗的影响”约 `0.5`，“12 小时电源”约 `10.13`。12 小时字段仍是系统累计现场读数，不作为等时长 A/B 门槛。
- 线程采样：当前周期栈落在 `runHealthProbeCycle → reloadConfigAsync → RustCoreClient.loadConfig`；未观察到 UI 全量刷新调用或 `launchctl` 状态扫描成为采样热点。

本追加窗口证明“活动探针 + 会话复用”下固定高 CPU 峰值已消失，能耗切片达到阶段 2 的真实运行要求。后续真实故障注入仅针对已核验的活动 `admin-tunnel` SSH PID 执行：探针失败符合预期，随后 launchd 在 bootout 后出现短暂 `SIGTERMed` 状态；既有恢复路径要求 stop 立即返回 `notLoaded`，因此在 ECS 前置之前按 fail-closed 停止，没有执行 ECS 或 start。另一次恢复后的手动 `stop → start` 对照确认：start 请求即时返回 launchd 过渡态 `other`，数秒后才稳定为 `running`，自动恢复的即时 `isRunning` 门禁同样会误判。上述诊断未扩大远端变更范围，隧道已通过本机 API 恢复到探针 `401/satisfied`；现已补齐两处有界重读。

## 追加验收：状态收敛后的活动隧道自动恢复

- 日期：2026-09-04
- 运行方式：重新构建并启动当前 Release App；仅对活动 `admin-tunnel` 做原 PID 身份核验和 `SIGSTOP` 故障注入。
- 故障现象：探针进入失败；launchd 先出现 `SIGTERMed` 过渡态，随后标签未加载。为完成受控窗口中的生命周期收敛，在确认该原 PID 与目标 SSH 进程身份一致后释放原 PID，未操作其他进程或隧道。
- 自动恢复结果：应用继续执行既有 `stop → ECS 前置 → start` 顺序；ECS 日志出现新的同步及 `already_current` 结果；随后观察到不同于原进程的新 SSH 进程、launchd `running` 和 HTTP `401/satisfied`。这证明 stop 后 `notLoaded`、start 后 `running` 的有界重读在真实活动隧道上生效。
- 远端与配置边界：同步结果为已是最新，未扩大受管规则范围；未修改 `config.json`、plist、凭证或其他隧道。
- 判定：自动恢复链路在“受控释放冻结原进程”的真实窗口中通过；若不释放冻结原进程，bootout/旧进程退出可能长时间阻塞，该纯 `SIGSTOP` 进程处置策略仍未纳入本计划的生产行为，阶段 2 保持实施中。

## 追加尾检：自动恢复后的能耗

- 自动恢复成功后继续运行 30 秒，完成 31 个 CPU 采样；最高约 `18.4%`，达到 `10%` 的采样 4 个，未出现旧基线的几十个百分点固定周期峰值。
- Activity Monitor 同时读取 TunnelPad 即时“对能耗的影响”为 `0.0`；本次现场“12 小时电源”为 `22.59`，仍只作现场累计读数，不作等时长 A/B 门槛。
- 活动 `admin-tunnel` 探针继续为 HTTP `401/satisfied`，launchd 管理的 SSH 进程持续存在。
