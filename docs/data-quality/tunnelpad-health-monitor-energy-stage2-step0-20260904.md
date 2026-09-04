# TunnelPad 后台健康监测能耗优化：阶段 2 Step 0

- 日期：2026-09-04
- 关联计划：[TunnelPad 后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 基线类型：用户授权的真实 App、真实本机配置和 Activity Monitor 现状快照
- 用户决策：用户明确要求直接使用真实环境，阶段 2 不再额外运行隔离 App；该替代不改变代码范围和安全边界

## 目标与边界

验证阶段 1 实现部署到真实 `dist/TunnelPad.app` 后，后台健康循环的周期性 CPU/能耗峰值是否明显下降，并确认当前配置、隧道 label、远端规则和凭证没有被改写。

本次不主动启动当前处于 `not_loaded` 的隧道，不执行 ECS 写操作，不做 SSH 故障注入；因此本记录不宣称“活动隧道下的自动恢复闭环”已经完成。

## 基线与样本矩阵

| # | 输入/操作 | 可执行命令或观察 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 旧版本真实 App，PID 44523 | `ps -p 44523 -o pid=,pcpu=,etime=,state=`；30 秒逐秒 CPU 采样 | 记录切换前实际 CPU 波形 | 采样无法关联旧进程 | 阶段 2 真实验收 |
| 2 | 新 Release App 构建 | `./scripts/build_app.sh --skip-tests` | Release 二进制、Rust dylib、签名校验通过 | 构建/签名失败 | 阶段 2 真实验收 |
| 3 | 新 App 真实配置 | `curl --fail --silent http://127.0.0.1:9998/api/tunnels` | 只读返回 2 条现有配置，状态/探针语义未被改写 | 配置条数、状态或探针被意外修改 | 阶段 2 真实验收 |
| 4 | 新 App，PID 15264 | 45 秒逐秒 `ps` CPU 采样 | 不再出现几十个百分点的固定周期 CPU 峰值 | 出现约 10 秒固定高峰或持续高 CPU | 阶段 2 真实验收 |
| 5 | 新 App 能耗页 | Activity Monitor “能耗”页观察 TunnelPad | 当前能耗影响显著低于旧截图中的 367.2 | 出现同量级持续/周期峰值 | 阶段 2 真实验收 |
| 6 | 远端/本机资源边界 | `ps -axo ...` 检查 TunnelPad、ssh/autossh；只读 API 与进程状态 | 不主动产生 SSH/ECS 写操作，现有隧道保持原状态 | 出现计划外远端或隧道变化 | 阶段 2 真实验收 |

## 回滚与安全边界

- 旧 App 已优雅退出；原 bundle 在 `/tmp/tunnelpad-real-DYcBbH00/TunnelPad.app` 完成可执行文件和签名校验备份。
- 新 App 只通过项目现有构建脚本生成并启动；没有修改 `config.json`、launchd label、ECS 规则、SSH 凭证或远端服务。
- 若真实验收失败，先停止新 App，再用备份恢复 `dist/TunnelPad.app` 并重新启动；不通过删除 plist 或改写远端资源回滚。
