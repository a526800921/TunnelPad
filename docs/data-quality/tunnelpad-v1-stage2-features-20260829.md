# TunnelPad v1 阶段 2 功能与验收记录（2026-08-29）

- 执行时间：2026-08-29 19:20–21:05 CST
- 执行者：ZCode Agent（实施轮次）
- 代码：commit `c31f771`（阶段 2 全部实现，基于阶段 2 准入提交 `7ae04ae`）
- 前置：[阶段 1 接管验证记录](tunnelpad-v1-stage1-takeover-20260829.md)

## 样本矩阵执行结果

| # | 矩阵行 | 实际结果 | 判定 |
|---|---|---|---|
| 1 | 测试套件 `swift build && swift test` | 构建零告警；**48 用例全部通过**（阶段 1 的 29 个 + 新增 19 个：Probe 7、AppProcessExecutor 6、LogTail 3、Shutdown pidfile 3） | ✅ |
| 2 | app 执行器单元 | `/bin/sleep` fixture：start 即 running 且写 pidfile/日志；stop 后进程终止且 pidfile 删除；keepAlive 外部 kill 后按注入延迟（0.2s）自动重启（新 pid）；手动 stop 不被拉起；重复 start 幂等；shutdownAll 全清 | ✅ |
| 3 | 探针单元 | expectedStatuses 命中 → satisfied；403 → unexpected；抛错/非法 URL → failed；config 无 `probe` 字段照常解码（向后兼容） | ✅ |
| 4 | 日志单元 | LogTail 末 N 行（含尾随换行处理）、不足上限返回全部、文件缺失返回 nil | ✅ |
| 5 | 真实探针 | config 给 admin-tunnel 加 `probe{url: http://127.0.0.1:8081/admin, expectedStatuses:[200,401]}` → .app 内显示 **`探针 401 ✓`**；隧道停止时显示"探针失败"（连接拒绝，符合语义） | ✅ |
| 6 | 真实 app 执行器 | demo 隧道（`/bin/sleep 300`，executor=app）经 UI"全部启动"拉起（pid 9740）；外部 `kill -9` 后 **1 秒**内自动重启（新 pid 10139），pidfile 同步更新；验收后已从 config 移除 | ✅ |
| 7 | 打包产物 | `./scripts/build_app.sh` 产出 `dist/TunnelPad.app`；`plutil -lint` OK；`codesign --verify --deep --strict` 通过 | ✅ |
| 8 | .app 行为 | `open dist/TunnelPad.app` → `lsappinfo` **`ApplicationType="UIElement"`**（LSUIElement 生效，不进 Dock）；UI"全部启动"后 launchd 双标签 running、demo 子进程运行、curl 401、ECS LISTEN 22022；菜单"退出 TunnelPad" → 两个 launchd 标签卸载 + demo 子进程终止 + pidfile 清理 + 8081 拒连；重启 .app → 一键恢复 | ✅ |
| 9 | 治理检查 | `plan-governance-cli check .` 与 `--strict-readiness` 无 ERROR | ✅ |

## 真实验证时间线（.app，pid 9536）

1. 20:44 退出 dev 实例（正常退出路径，隧道随之停止）。
2. 20:47 config 写入 admin 探针 + demo 隧道；`build_app.sh` 构建打包（含 swift test 全通过）。
3. 20:52 `open dist/TunnelPad.app`：三条隧道列出（admin/reverse=launchd、demo=app），探针初值"失败"（隧道未启动，语义正确）。
4. 20:54"全部启动"：双 launchd 标签 running、demo 子进程 pid 9740、pidfile `run/demo-sleep.pid`、curl 401、ECS LISTEN 22022。
5. 20:56 刷新 → 探针 `401 ✓`；打开 admin 日志 sheet（路径/自动刷新/复制控件正常，ssh 静默时日志为空属正常）。
6. 20:59 外部 `kill -9` demo pid 9740 → 1s 内自动重启为 pid 10139，pidfile 更新。
7. 21:00 菜单"退出 TunnelPad"→ app 退出、双标签卸载、demo 终止、pidfile 清空、8081 拒连。
8. 21:02 config 移除 demo → 重启 .app →"全部启动"→ 双标签 running、刷新后 `探针 401 ✓`。

**最终线上状态**：`dist/TunnelPad.app`（UIElement）常驻菜单栏，`com.jafish.tunnelpad.admin-tunnel` / `com.jafish.tunnelpad.reverse-ssh` 托管运行，admin 探针满足，`~/Library/LaunchAgents` 无旧 plist。

## 实现要点（对应"技术方案（阶段 2 冻结）"）

- `ProbeConfig` 为 schema v1 追加的可选字段（`url` + `expectedStatuses` 缺省 `[200]`），旧 config 不受影响；合成 Codable 对 Optional 使用 encodeIfPresent，回写不引入新必填字段。
- `ProbeService` 每次探测用临时 ephemeral URLSession 且 `connectionProxyDictionary = [:]`（绕过系统代理，回环探测必须如此）。
- `AppProcessExecutor` 不经 shell 直接 spawn `command`；terminationHandler 以代次（generation）防僵尸重启；keepAlive 重启延迟取 `throttleInterval`。
- 信号退出路径（SIGTERM/SIGINT）读 pidfile 终止 app 子进程（`Shutdown.killByPidfile`），弥补信号处理器无法访问 app 内存状态的限制。

## 已知边界（如实登记）

1. 探针在"刷新/启停动作"时执行，无后台轮询；隧道状态变化后徽标需下一次刷新更新（v1 语义：探针只影响展示）。
2. 隧道停止时探针显示"失败"（连接拒绝）——语义为"探测未满足"，不区分隧道停止与目标服务不可达。
3. app 执行器子进程在 app 崩溃时会残留（pidfile 留存），与 launchd 崩溃边界一致，下次启动可清理；pidfile 终止仅发 SIGTERM（ssh 类进程足够）。
4. demo 隧道为验收临时配置，已移除；验收期间两条真实隧道始终由 TunnelPad 托管，未出现不可用窗口。
