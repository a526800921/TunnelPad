# TunnelPad 界面优化——阶段 2 证据（删除隧道）

- 日期：2026-08-29
- 阶段：阶段 2（删除隧道）
- Step 0 基线：commit `a93e346`（`swift test` 55/55；TunnelManager 无 remove API、UI 无删除入口）

## 实施内容

- `TunnelManager.removeTunnel(_ id:)`：停止实例（launchd `bootout` 且校验 `status != .notLoaded` 才执行、停后再验；app 执行器 stop）→ 删除生成的 plist → 删除日志文件（尽力而为，失败仅告警）→ 从 config 移除并落盘（保存失败回滚内存态并报错）→ 清理 statuses/probeResults 缓存 → refresh。实例停止失败或配置写入失败即中断并保留配置。
- `MainPanelView.TunnelDetailView`：操作行新增红色「删除…」按钮（busy 时禁用），`.confirmationDialog` 显示"删除「名称」？"与说明文案，破坏性按钮「删除隧道与日志（不可恢复）」+「取消」。
- `Tests/TunnelPadCoreTests/TunnelManagerTests.swift` 新增 4 用例：launchd 产物与配置持久化清理、app 子进程终止与文件清理、bootout 失败中断保留配置（MockProcessRunner 脚本化 print=running/bootout=失败）、未知 id no-op。

## 验证记录

构建与测试：`swift build` 零告警；`swift test` 59 用例全过（55+4）；`plan-governance-cli check .` 通过（本计划零告警）。构建部署 `dist/TunnelPad.app` 后实测：

| # | 矩阵行 | 结果 | 证据 |
|---|---|---|---|
| 1 | 取消路径 | 通过 | demo-app（运行中）点「删除…」→ 弹窗显示"删除「demo-app」？/ 将停止实例并删除其配置条目、生成的 plist 与日志文件。"→ 点「取消」→ config 仍 4 条、pidfile 在、日志在、双进程存活 |
| 2 | launchd 隧道删除 | 通过 | demo-launchd（运行中，pid 6704）确认删除 → `launchctl print` 无此 label；plist 消失；demo-launchd.log 消失；config 移除条目（剩 3）；侧栏行消失，选中回落 admin-tunnel |
| 3 | app 隧道删除 | 通过 | demo-app（运行中，pid 66866）确认删除 → sleep 进程终止（pgrep 0 残留）；pidfile 清理；日志删除；config 剩 2 条 |
| 4 | 单元测试 | 通过 | `swift test` 59/59（含 bootout 失败中断保留配置用例） |
| 5 | 真实隧道保护 | 通过 | 全程 admin-tunnel（探针 401 ✓）、reverse-ssh（外部 bootstrap 恢复，app 5s 刷新正常识别）配置与运行未受影响 |

## 附带补验（阶段 1 矩阵 5）

- 保存类操作后无信息文案：结构性保证——`lastMessage` 已无任何 UI 读者（消息栏仅渲染 `lastError`）；实测两次删除操作（内部走 store.save）后的 AX 元素树中均无信息文案元素，窗口底部无消息栏。判定通过。
- 阶段 1 剩余待补验项仅矩阵 4（关「自动滚动」的回看保持，代码构造性保证：开关关闭后无任何滚动调用路径）。

## 运行状态

- 验证后 config.json 仅含 admin-tunnel、reverse-ssh 两条真实隧道（demo 条目经被测的删除功能自身清除，配置恢复与验证前一致）。
- 两条真实隧道运行中。
