# TunnelPad 日志保留与能耗回归修复：阶段 2 实施与真实验收证据

- 日期：2026-09-05（Asia/Shanghai）
- 关联计划：[日志保留与能耗回归修复](../plans/tunnelpad-log-retention-energy-regression.md)
- 阶段：阶段 2
- 结论：真实 Release 回归通过，等待独立完成复核

## 验收对象和边界

验收对象为当前工作树构建的 arm64 Release `dist/TunnelPad.app`。使用现有配置启动 `admin-tunnel` 和 `reverse-ssh`，观察真实日志 watcher、状态、CPU、Activity Monitor 和退出清理；没有修改配置、凭证、launchd plist、ECS 规则或非目标资源。

## 实际结果

| 场景 | 实际结果 | 状态 |
|---|---|---|
| Release 产物 | `scripts/build_app.sh --skip-tests` 完成；Bundle ID `com.jafish.tunnelpad.app`；arm64；ad-hoc 签名校验通过 | 通过 |
| App/API 启动 | `xcodebuildmcp macos launch` 成功；`GET /api/health` 返回 `{"ok":true}` | 通过 |
| 两条隧道启动 | `admin-tunnel` 为 `running`，探针 `401/satisfied`；`reverse-ssh` 为 `running` | 通过 |
| 多周期 CPU 采样 | App 约 46 秒、覆盖多个 10 秒周期；`top` 最高约 7.7%，未出现原先几十个百分点的固定周期峰值 | 通过 |
| Activity Monitor | TunnelPad「对能耗的影响」约 2.0；12 小时累计列约 129.26。累计列仅作现场读数，不作为跨窗口阈值 | 通过 |
| `admin-tunnel.log` | 约 202 KB；窗口结束时 LF 计数 2000；大小保持有界，mtime 有正常追加/裁剪变化 | 通过 |
| `reverse-ssh.log` | 约 129 KB；窗口结束时 LF 计数 2000；大小保持有界 | 通过 |
| 运行栈 | `sample` 未命中 `trimIfNeeded`、`LogFileRetention`、`refreshState` 或 `fileDidChange` | 通过 |
| 退出清理 | 通过既有 API 停止两条隧道，再停止 App；无 TunnelPad/SSH 残留、两个受管 label 未加载、8081/22022 无监听 | 通过 |

## 输出位置

- CPU：`/tmp/tunnelpad-log-retention-release-two-tunnels-20260905.txt`
- 日志元数据：`/tmp/tunnelpad-log-retention-real-metadata-20260905.txt`
- 运行栈：`/tmp/tunnelpad-log-retention-release-two-tunnels-sample-20260905.txt`
- 无隧道控制组 CPU：`/tmp/tunnelpad-log-retention-release-no-tunnels-20260905.txt`

## 安全边界

本轮只使用既有 TunnelPad 配置和既有隧道生命周期入口。未输出或记录凭证、私钥内容；未删除或手工裁剪真实日志；未修改 ECS、配置、launchd plist 或非目标隧道。验证结束后环境已恢复为 App 停止、两条隧道 `not_loaded`、无本机转发监听。

## 阶段结论

阶段 1 修复进入真实 Release 产物后，真实日志追加/裁剪保持 2000 个逻辑行，CPU/能耗峰值未再按原 10 秒模式出现，Activity Monitor 读数低，状态与退出清理通过。阶段 2 实施证据齐备，交由独立完成复核；该证据同时作为后台健康监测能耗计划重新关闭阶段 2 的输入。
