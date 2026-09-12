# 阶段 2 U9：无自启候选资源对照

日期：2026-09-12。代码基线 ca3463d，同一 Release 包；增量独立准入见[Step 0](tunnelpad-unattended-launch-recovery-stage2-step0-20260912.md)。本轮无代码/真实配置修改。

## 实际输入与隔离

正常退出真实受护栏 App 后，单进程 CFFIXED_USER_HOME 指向私有临时 home，其 config.json 为 version=1/tunnels=[]。API 稳定返回空数组；日志实际生成于隔离 home。全程校验真实配置哈希与真实前置wrapper计数未变。

## 结果

| 指标 | 120.18 秒实际增量 |
|---|---|
| App PID | 57846，全窗口一致 |
| 配置与 API 条目 | 0 |
| 前置调用 | 0 |
| App 日志 | 0 字节（扣除初始启动写入后） |
| 进程磁盘读取 / 写入 | 0 / 0 字节 |
| 累计 CPU | 0.20 → 0.32 秒，增量约 0.12 秒 |
| 中断唤醒 | 218；包含 App/UI、现有后台逻辑与采样 API 开销，不声称零唤醒 |
| RSS | 104736 → 106176 KiB（ps读数） |

13 条样本每约10秒采集；只证明该窗口没有前置重试/新增日志或磁盘IO，不外推全天。与已记录的长期故障窗口和成功交接后静默窗口共同覆盖 U9 的三个输入状态；各窗口长度及负载不同，不能作严格能耗因果归因。

## 退出与恢复

空实例正常退出，API关闭且进程结束。恢复真实新版时移除 CFFIXED_USER_HOME，保留单进程云只读护栏：
- App PID 58917；目标 motorcycle-local-docker SSH PID 58949，running。
- lsof 确证该SSH PID存在ESTABLISHED TCP连接，并持有127.0.0.1:10080监听。
- admin-tunnel、reverse-ssh仍通过launchctl确证未加载。
- 真实配置SHA-256不变，前置网络故障标记不存在。

这些传输/监听证据独立于OrbStack返回的401，不将401冒充SSH业务转发健康。

## 原始证据与后续

私有目录：`/var/folders/t0/t1h7z_pd6716d4kstbbmxxyc0000gn/T/tunnelpad-stage2-empty-fs77iipa`；empty-observe.py、samples.jsonl、summary.json、restore-summary.json。脚本与样本无凭据内容。

当前增量自验及同范围独立完成复核通过（高影响，stage2_review）：独立复算13条样本，并只读核对真实新版/目标PID、连接监听、隔离变量移除、只读护栏与配置哈希，未发现必须修复项。系统重新登录与最终用户体验接受仍待完成；暂存探针问题按用户要求后续统一修复。
