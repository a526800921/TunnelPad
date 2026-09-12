# 阶段 2 当前会话独立复核

日期：2026-09-12。复核者：stage2_review。方式：独立只读；风险：高影响。代码基线 ca3463d；未参与实现或测试编写，未控制 App/云端或修改项目文件。

## 准入历史

首轮未通过：最终新版运行和旧包回滚可能移除云只读护栏，与本轮无云写范围冲突。修订两条路径均保留护栏、无法兼容即停止后，独立恢复准入通过。详见[Step 0](tunnelpad-unattended-launch-recovery-stage2-step0-20260912.md)。

## 当前会话完成复核

结论：**通过；仅本轮已准入会话矩阵，无必须修复项。**

独立检查 observer/cancel/resource 脚本、48 条连续状态样本、15 条资源样本、三个结果文件与实际护栏：
- 状态样本覆盖 1.01–467.4 秒，最大间隔 10.05 秒；第 427.27 秒目标 running/PID 55055。App PID 53906 连续，300 秒档实测间隔 303 秒。
- 资源样本固定 PID 53906，420.076 秒内中断唤醒 +443、读 4096/写 8192 字节，与实施报告一致。
- 取消矩阵记录两次失败后 stop，网络恢复 40 秒无迟到前置或启动；退出后 API/label/helper 清理且无 pending journal。
- 当前独立查证 App PID 56412 为独立新版，TUNNELPAD_CONFIG_FILE 指向私有只读护栏配置，网络故障标记已移除。
- 当前目标 PID 56447、running、401/satisfied；两非目标通过 launchctl 确证未加载；配置 SHA-256 与 Step 0 一致，journal 数为 0，原旧/测试 App 已退出。
- 累计 cloud-actions 为两次 describe，分别属于自动恢复和最终启动，无 blocked/write；恢复窗口 summary 的一次 describe 是当时窗口值。

首次采样器将 API unknown 误判为加载，及按前置次数误计整体尝试的修正历史已记录；持续运行窗口未因此重启 App，不能将 API unknown 当作未加载证据。

## 完成边界

本结论不关闭整体阶段 2。系统重新登录、无护栏正式启动/发布、无 autoStart 候选资源对照及用户接受仍未验收，阶段保持实施中。[实施记录](tunnelpad-unattended-launch-recovery-stage2-implementation-20260912.md)记录当前状态及证据入口。

## 增量 U9 空候选复核

独立准入与完成均通过（高影响，stage2_review）。读取隔离脚本、13条原始样本与结果，复算同PID57846窗口120.180秒、中断唤醒+218、磁盘读写0、日志0；空配置version1/tunnels[]成立。只读确认空实例退出，真实新版58917/目标58949恢复，目标TCP已连接且持有10080监听；CFFIXED_USER_HOME已移除，私有云只读护栏保留，配置哈希一致。无必须修复项，不外推零唤醒/全天能耗。[增量证据](tunnelpad-unattended-launch-recovery-stage2-empty-candidates-20260912.md)。

用户已要求将停止状态探针误导后续统一修复，401端点状态不能单独支持SSH业务健康。本次TCP连接/监听独立核验不依赖401。
