# TunnelPad 日志低写放大：阶段 2 Step 0

- 日期：2026-09-05
- 阶段：阶段 2
- 基线类型：真实 Release App + 本机 launchd 隧道 + 日志文件元数据 + 本地 API
- 关联计划：[TunnelPad 日志低写放大与流式保留](../plans/tunnelpad-log-write-amplification.md)

## Step 0 输入与边界

- 使用刚构建的 `/Users/jafish/Documents/work/TunnelPad/dist/TunnelPad.app`。
- 使用现有 `admin-tunnel` 与 `reverse-ssh`，不改变远端服务、凭证、端口暴露边界或 SSH 转发目标。
- 先停止旧 App 和由其管理的两个 launchd 隧道，再启动新 Release App 和两个真实隧道。
- 仅记录安全摘要：状态、PID、CPU、日志大小/mtime/行数和 `debug1` 计数；不记录完整命令、密钥内容、AccessKey 或私钥。

## 已完成的 Step 0 观察

- 两个隧道均真实启动，API 健康为 `{"ok":true}`。
- admin 本机探针为 `401/satisfied`；reverse 探针为配置中的 `disabled`。
- 静默配置确认：两个配置的独立 `-v` 均为 `false`。
- 静默窗口初始日志：`admin-tunnel.log` 199,441 字节/2000 行，`reverse-ssh.log` 128,947 字节/2000 行。
- 40 秒窗口内两份日志大小、mtime、`debug1` 计数均未变化；两个 SSH 进程 CPU 采样均为 0.0。
- 详细日志开关回归后，reverse-ssh 的 `debug1` 计数增加；关闭开关并重启后配置回到无独立 `-v`，随后 40 秒静默窗口没有周期性 mtime/大小变化。

## 阶段 2 样本矩阵与完成观察

| 样本 | 操作 | 预期 | 失败判定 |
|---|---|---|---|
| A | 两隧道静默运行至少 30 分钟，每分钟记录日志大小/mtime/行数、debug1 计数、SSH CPU 和 API 状态 | mtime 不再约每 10 秒变化；大小与 debug1 基本稳定；状态持续 running | 周期性整文件写回、debug1 持续增长、API/隧道异常 |
| B | 观察 Release App 进程 CPU 与 Activity Monitor 磁盘累计写入 | 不再接近旧基线约 57 KiB/s 的日志写放大投影 | 写入重新出现旧周期性峰值或 CPU 持续异常 |
| C | 结束 App 后检查 launchd 隧道退出清理 | 两个受管隧道均收敛为未加载/未运行 | 遗留受管隧道或错误影响非目标资源 |

## Step 0 准入结论

当前阶段目标、范围、样本、命令、预期、失败判定和退出/回滚边界已明确；40 秒静默观察与开关回归支持进入阶段 2 长期真实窗口。阶段 2 仍以 30 分钟窗口和独立完成复核为最终准入，不把本 Step 0 记录提前当作完成结论。
