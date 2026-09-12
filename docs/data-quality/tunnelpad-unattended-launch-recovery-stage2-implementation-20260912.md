# 阶段 2：真实登录会话验证记录

日期：2026-09-12。代码基线：ca3463d；本轮无生产代码修改。用户授权继续并可关闭当前 App。[Step 0 与独立恢复准入](tunnelpad-unattended-launch-recovery-stage2-step0-20260912.md)。

## 已执行结果

| 项目 | 实际证据 |
|---|---|
| 旧 App 退出 | 正常 AppleScript quit；PID 49471 结束，API 关闭，三条 label 均未加载 |
| 真实新包 | dist/stage1-validation/TunnelPad.app，完整时间窗口 App PID 53906 保持不变 |
| 长期前置故障 | curl wrapper 阻断网络探测约 407.18 秒；未阻断整机网络，真实 SSH 未被提前拉起 |
| 退避 | 前置调用间隔 16/31/63/303 秒，已包含子过程耗时；初始还有一次未到前置的早期重试，不能把 curl 调用数当总尝试数 |
| 自动恢复 | 第 407.18 秒解除故障；第 427.27 秒观测新 SSH PID 55055，running，HTTP 401/satisfied；期间无 start/restart、App 重启或人工启动 |
| 成功后静默 | 后续至少 40 秒无额外前置调用；成功轮两次公网探测间隔小于 1 秒，不算两轮重试 |
| 非目标 | admin-tunnel、reverse-ssh 始终由 launchctl 证明未加载；API 初始 unknown 不作为未加载证据 |
| 云端约束 | ALIYUN_BIN 护栏仅允许 Describe；恢复窗口实际一次 describe，未调用 Authorize/Revoke；无未完成 journal |
| 配置 | SHA-256 与开始一致：198cf1d8510674cb44faa47454a5ca815ad76169a37200c1b009bb8651b7fdf6 |
| 日志 | 故障窗口 App 日志只增长 190 字节；成功交接后总增长 301 字节 |
| CPU | 完整 467.4 秒窗口 App 累计 CPU 约 1.02 秒；这是当前负载观测，不是跨机器能耗阈值 |
| 补充资源采样 | 420.08 秒、15 个 proc_pid_rusage(v2) 样本：中断唤醒增量 443，磁盘读 4096 字节、写 8192 字节；RSS 142753792 → 142671872 字节；其中长期退避 270 秒子窗口磁盘写增量为 0 |

## 观测器修正及失败历史

首次观测器将 API unknown 误作非目标启动，实际 launchctl 证实均未加载；正常退出后另起完整成功窗口。完整窗口的早期本地重试使 curl 调用数少于总尝试数，采样器断言按实际层级修正；只更换 Python 观测器，App PID 53906、故障标记和队列持续未变。保留预检查日志及连续样本，不把观测器失败当作业务成功。

## 取消、收尾和独立复核

- 手动取消：新一轮故障启动达两次失败探测后，经既有 POST stop 取消目标；解除故障继续观察 40 秒，未再次调用前置，目标与非目标均未加载。
- 两轮正常退出都确认 API 关闭、三条 label 未加载；取消轮退出后无 tunnelpad-preflight 进程、无 pending journal。
- 最终受护栏新版已运行：App PID 56412，目标 SSH PID 56447，running、401/satisfied；两条非目标仍未加载，配置哈希不变。网络故障标记已移除，云只读护栏保留。
- 当前会话矩阵完成，[同范围独立复核通过](tunnelpad-unattended-launch-recovery-stage2-independent-review-20260912.md)，无必须修复项；整体阶段 2 仍有下述未覆盖项，不能关闭。

## 原始隔离证据

私有目录：`/var/folders/t0/t1h7z_pd6716d4kstbbmxxyc0000gn/T/tunnelpad-stage2-ca3463d-4ndhijs2`。包含 observe.py、observe-resume.py、resources.py、cancel-check.py、samples.jsonl、resources.jsonl、curl-times、cloud-actions、recovery-summary.json、cancel-summary.json、final-summary.json。配置文件仅 source 原仓库外配置，未复制凭据内容；样本仅含 ID、PID、状态、时间及资源计数。本报告持久记录可复验参数与结论，不依赖临时目录长期存在。

## 未覆盖的验收

这是已有登录会话中的真实 App/launchd/SSH/探针与真实时间验证。系统重新登录、无护栏默认发布、无 autoStart 候选资源对照以及用户接受仍未覆盖；不把短窗口外推到全天、无候选或完整 U9。最终当前进程将保留云端只读护栏；真实云写及默认运行实例替换未执行。

最终只读复核时累计两次 describe（自动恢复一次、最终启动一次），未发生云写。治理 strict-readiness 与 git diff --check 通过；本轮仅新增/更新阶段 2 文档，未修改生产代码或提交新 commit。

## 探针证据补充限定

后续用户截图核对发现：两条配置均探测本地8081，而该端口由OrbStack提供；停止隧道也会执行探针。因此本报告的401/satisfied仅为HTTP端点返回符合配置，不能据此声称目标SSH业务转发健康。目标fresh PID、launchd运行、自动重试/取消/退出事实仍成立。[问题已按用户要求记录后续统一修复](../reviews/tunnelpad-deferred-runtime-issues-20260912.md)，本轮未改代码。

## 系统登录项只读前提

sfltool dumpbtm 实际读取：TunnelPad disposition 为 enabled/allowed/notified，Bundle ID com.jafish.tunnelpad.app，URL 指向 dist/stage1-validation/TunnelPad.app。未执行登录项注册/开关操作。该静态前提不等于真实系统重新登录已经验收；单进程故障/只读环境也不自动成为系统登录环境。
