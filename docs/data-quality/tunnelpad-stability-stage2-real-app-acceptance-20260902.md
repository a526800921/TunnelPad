# TunnelPad 稳定性阶段 2 真实 App 受控验收

- 验收日期：2026-09-02
- 计划：`tunnelpad-stability`
- 验收对象：当前工作树构建的 `dist/TunnelPad.app`
- 验收边界：真实 macOS App 启动、启动状态发现、真实 `launchd` 隧道启动/探针/受控退出、App 崩溃后重启发现、正常退出清理，以及真实 HTTP 探针假死触发 ECS 前置后恢复；不验证未来 `app` 执行器
- 验收结论：**通过（当前 `launchd` 真实受管隧道与 App 生命周期场景；不代表阶段 2 总计划完成）**

## 前置状态

只读检查确认旧版 App 进程 PID 63807 正在运行，二进制时间早于当前源码；其对应的两个配置内 `launchd` label 在 `gui/501` 域均为 `not_loaded`。根据用户授权，先用 XcodeBuildMCP 正常停止旧 App；停止后 App 不再运行，两个 label 仍为 `not_loaded`。

配置中识别到两个受管隧道：`admin-tunnel` 和 `reverse-ssh`。本次没有调用 App 的真实 start/restart，不修改真实 SSH、ECS、安全组或用户隧道状态。

## 验收步骤与结果

| 步骤 | 命令/输入 | 预期 | 实际结果 | 结论 |
|---|---|---|---|---|
| 1 | `xcodebuildmcp macos stop --process-id 63807 --output json` | 旧 App 正常退出 | 返回 `SUCCEEDED`；进程消失；两个受管 label 仍为 `not_loaded` | 通过 |
| 2 | `./scripts/build_app.sh --skip-tests` | 当前工作树生成可启动 App | Rust release、Swift release、App bundle、ad-hoc 签名和签名校验均成功 | 通过 |
| 3 | `xcodebuildmcp macos get-macos-bundle-id --app-path dist/TunnelPad.app --output json`；`codesign --verify --deep --strict dist/TunnelPad.app` | Bundle ID 和签名有效 | Bundle ID 为 `com.jafish.tunnelpad.app`，签名校验成功 | 通过 |
| 4 | `xcodebuildmcp macos launch --app-path dist/TunnelPad.app --output json` | 最新 App 启动成功 | 返回 `SUCCEEDED`，进程 PID 5702 存活 | 通过 |
| 5 | 启动后查询 `gui/501` 下两个受管 label | 启动只读取并展示现状，不猜测性启动隧道 | `admin-tunnel=not_loaded`、`reverse-ssh=not_loaded`，未产生新隧道 | 通过 |
| 6 | `xcodebuildmcp macos stop --process-id 5702 --output json`，随后复查进程和两个 label | 正常退出后无 App/受管 label 残留 | 返回 `SUCCEEDED`；App 已停止；两个 label 仍为 `not_loaded` | 通过 |

## 无运行中隧道子场景结束状态

该子场景结束时曾再次启动同一份最新 `dist/TunnelPad.app`，XcodeBuildMCP 返回 `SUCCEEDED`，当时 App 进程为 PID 6324；两个受管 label 均为 `not_loaded`。后续追加验收已重新建立并清理真实隧道，以下结果为本记录的最新状态。

## 证据与限制

- 构建使用项目现有 `scripts/build_app.sh --skip-tests`；Swift 129/129、阶段 2 专项 11/11、Rust 53+1 已在本工作树的前置回归中通过。
- 本次真实验收覆盖了最新 App 的启动/退出路径和“配置有隧道但 launchd 当前未加载”的安全状态发现。
- 上述无运行中隧道子场景没有验证真实 `bootout`；追加验收已在用户明确授权的可观察窗口内补充该场景。
- 该段只记录前一轮“无运行中隧道”真实 App 子场景；后续追加验收已在本记录下方覆盖 ECS 自动恢复的真实业务闭环，未来 `app` 执行器语义仍不在本次验收范围内。

## 追加验收：真实运行中受管隧道与 App 崩溃恢复

### 前置与安全边界

- 真实 TunnelPad 配置包含 `admin-tunnel` 和 `reverse-ssh`；本次只验证 `admin-tunnel`，不加载 `reverse-ssh`。
- `scripts/update-ecs-ssh-ip --check` 返回成功，确认公网 IP 探测和受管安全组读取成功，未执行云端写操作。
- 启动前确认 `admin-tunnel` label 为 `not_loaded`，使用 App 生成的真实 plist；未修改 `config.json`、plist、ECS 规则或凭证。
- 由于当前 App 为 `LSUIElement` 菜单栏应用且本环境 UI 自动化无法识别其菜单项，本次隧道启动使用同一真实 plist 的 `launchctl bootstrap`；App 的启动、崩溃、重启和正常退出仍使用真实 `dist/TunnelPad.app` 验证。该限制不替代 App 启动按钮的 ECS 前置集成验收。

### 步骤与结果

| 步骤 | 命令/输入 | 实际结果 | 结论 |
|---|---|---|---|
| 1 | `scripts/update-ecs-ssh-ip --check` | 真实双端点探测与安全组读取成功；退出码 `0`；未执行写操作 | 通过 |
| 2 | `launchctl bootstrap gui/501 ~/Library/Application Support/TunnelPad/launchd/com.jafish.tunnelpad.admin-tunnel.plist` | 退出码 `0`；label 先进入 `xpcproxy`，随后变为 `running`；SSH PID `10260`；本机 `GET http://127.0.0.1:8081/admin` 返回 `401`；SSH 日志确认认证和本地转发监听 | 通过 |
| 3 | 身份校验后对 PID `10260` 发送 `SIGTERM` | 进程身份与目标 plist 完全匹配；`launchd` 自动拉起 PID `10320`；状态 `running`；本机探针再次返回 `401` | 通过 |
| 4 | `launchctl bootout gui/501/com.jafish.tunnelpad.admin-tunnel` | 退出码 `0`；label 为 `not_loaded`；PID `10320` 消失；`8081` 请求返回连接失败 | 通过 |
| 5 | 再次 bootstrap `admin-tunnel`，确认 PID `10411`/HTTP `401` 后对真实 App PID `8528` 发送 `SIGKILL` | App 进程消失；隧道保持 PID `10411`、状态 `running`、HTTP `401`；未发生重复启动 | 通过 |
| 6 | `xcodebuildmcp macos launch --app-path dist/TunnelPad.app --output json` | 最新 App 启动成功，PID `10474`；原 label PID `10411` 保持不变，状态 `running`，HTTP `401` | 通过 |
| 7 | `xcodebuildmcp macos stop --process-id 10474 --output json`，随后复查进程、label 和端口 | App 消失；`admin-tunnel` 与 `reverse-ssh` 均为 `not_loaded`；`8081` 已释放；签名校验通过 | 通过 |

### 前一轮追加验收结论

该轮真实场景证明：当前 `launchd` 隧道能建立真实 SSH 转发，进程退出后可由 `KeepAlive` 拉起；TunnelPad 崩溃不会重复启动仍在运行的受管隧道；重启后能发现原 label；正常退出能清理运行中的真实 label。该轮未覆盖 ECS 自动恢复；未验证未来 `app` 执行器。

## 追加验收：HTTP 探针假死触发 ECS 自动恢复

### 前置与安全边界

- 继续只使用真实 `admin-tunnel`，不加载 `reverse-ssh`；验收前 `scripts/update-ecs-ssh-ip --check` 已确认双端点探测和受管安全组读取成功。
- 未修改 `config.json`、真实 plist、凭证或安全组规则。故障注入只对与目标 plist 身份完全匹配的真实 SSH PID 发送 `SIGSTOP`，用于模拟“进程仍在但本地转发不可用”。
- 自动前置脚本按无参数同步模式执行；本次真实状态已是最新规则，因此日志只出现 `already_current`，没有发生安全组写入。没有执行批量 ECS 操作。

### 步骤与结果

| 步骤 | 命令/输入 | 实际结果 | 结论 |
|---|---|---|---|
| 1 | 真实 App 保持运行，使用 `launchctl bootstrap` 加载 `admin-tunnel`，再对身份匹配的 SSH PID `15035` 发送 `SIGSTOP` | label 仍由 `launchd` 管理但进程状态为 `T`；本机 `8081` 请求变为 `000` | 通过（假死已建立） |
| 2 | 等待后台健康监测累计连续 3 次失败并进入第 1 次自动恢复 | `recordHealthResult` 记录 `admin-tunnel` 失败，随后进入 `scheduleRecovery(attempt=1, delay=10s)` | 通过 |
| 3 | 观察自动恢复执行顺序 | 通过调试断点确认顺序为 `stop → ECSPreStartChecker.checkAsync → start`；停止后旧 PID 消失，前置脚本实际执行 | 通过 |
| 4 | 复查 `$HOME/.config/tunnelpad/ecs-ssh-ip.log` | 新增 `2026-09-02T14:39:52+0800 start mode=sync` 和 `2026-09-02T14:39:53+0800 already_current ...`；未出现失败或写入事件 | 通过 |
| 5 | 复查真实隧道 | 新 SSH PID `15710` 运行；label 为 `running`；`GET http://127.0.0.1:8081/admin` 返回 `401` | 通过（自动恢复闭环完成） |
| 6 | `xcodebuildmcp macos stop --process-id 14280 --output json`，随后复查 | App 停止成功；`admin-tunnel` label 不存在/未加载；PID 和 `8081` 端口均已清理 | 通过（环境已恢复干净） |

### 观察窗口说明

前一次观察在停止旧 PID 后截断于前置检查完成之前，曾暂时看到 label 未加载，因此不能直接判定为失败。本次重新执行并保留完整恢复链路后，已观察到 ECS 脚本、重新启动和 HTTP `401`，该结果覆盖了阶段 2 的真实 ECS 自动恢复业务闭环。
