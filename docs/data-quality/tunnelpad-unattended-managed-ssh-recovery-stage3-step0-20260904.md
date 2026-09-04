# TunnelPad 无人值守受管 SSH 收敛恢复：阶段 3 Step 0

- 日期：2026-09-04
- 阶段：阶段 3
- 计划：[TunnelPad 无人值守受管 SSH 收敛恢复](../plans/tunnelpad-unattended-managed-ssh-recovery.md)
- 前置：[阶段 2 独立完成复核](tunnelpad-unattended-managed-ssh-recovery-stage2-independent-completion-review-20260904.md)
- 基线类型：真实 Release App、真实受管 launchd 隧道、真实 HTTP 探针和 ECS 只读前置的现场快照；故障注入前固定目标身份和回滚动作

## 真实环境基线

- 当前用户 TunnelPad App PID 为 `30554`，本机 API 监听 `127.0.0.1:9998`；当前 `dist/TunnelPad.app` 与阶段 1 最新源码需在验收前重新构建确认，不能沿用旧产物。
- 当前配置安全摘要为两条 launchd 隧道：`admin-tunnel` 启用 HTTP 探针，预期响应为 `401`；`reverse-ssh` 不启用探针，属于非目标隧道。
- 只读 API 显示 `admin-tunnel` 为 `running`、探针 `401/satisfied`；直接 `launchctl print` 显示目标 label 运行中，PID 为 `38317`。`reverse-ssh` 也由 launchd 运行，PID 为 `45721`；验收期间不得对其发送信号或执行启停。
- `scripts/update-ecs-ssh-ip --check` 已成功，证明公网 IP 探测和受管安全组读取可用，未执行云端写操作。
- 目标只允许选择 `admin-tunnel` 的当前 SSH 子进程；在发出 `SIGSTOP` 前重新核验 launchd label、PID、UID、启动时间、可执行路径和 plist 归属，任何字段未知或不一致立即放弃注入并保持环境不变。

## 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 当前源码与 Release App | 停止旧 App（若仍运行且先完成状态快照），执行 `./scripts/build_app.sh --skip-tests`；`plutil -lint`、`codesign --verify --deep --strict` | 新 Release App 包含当前 Rust/Swift 实现且签名/Info.plist 有效 | 构建、签名失败或无法保留真实配置/隧道边界 | 阶段 3 实施证据 |
| 2 | 真实受管目标与非目标 | 只读检查 API、`launchctl print`、PID/UID/启动时间/可执行路径；确认 `admin-tunnel` 探针为 `401/satisfied`，`reverse-ssh` 记录但不操作 | 目标唯一、身份完整、非目标稳定 | 目标不唯一、身份读取失败、非目标状态被改变 | 阶段 3 实施证据 |
| 3 | 真实 ECS 前置 | `scripts/update-ecs-ssh-ip --check` | 双端点探测、安全组读取成功且无写操作 | 检查失败、规则歧义或发生未计划写入 | 阶段 3 实施证据 |
| 4 | 已核验 `admin-tunnel` SSH PID | 对该 PID 发送一次 `SIGSTOP`；之后不人工发送 `SIGCONT`，不点击 App 启停/重启 | 探针失败，自动恢复接管 | 发给非目标/身份不符 PID，或需要人工释放才能继续 | 阶段 3 实施证据 |
| 5 | 自动恢复过程 | 只读轮询 API、目标 label、PID、`8081` 探针和脱敏恢复状态 | 连续 3 次失败后自动 stop；Rust 先 bootout，身份仍一致时自动 `CONT → TERM → KILL`，旧 PID 消失后才 ECS/start | 人工介入、跳过身份复核、旧 PID 未消失即启动、触碰 reverse-ssh | 阶段 3 实施证据 |
| 6 | 恢复成功 | 观察目标 label 为 `running`、新 PID 与旧 PID 不同、HTTP 探针回到 `401/satisfied`；检查非目标 PID 未变化 | 完成 `notLoaded → ECS → running → HTTP satisfied` | 探针不恢复、旧 PID 残留、非目标受影响或启动顺序错误 | 阶段 3 实施证据 |
| 7 | 清理与回滚 | 只对 `admin-tunnel` 执行既有 stop/退出清理；复查 App、目标/非目标 label、PID、8081 和 9998 | 验收结束无测试残留；失败时仅恢复目标隧道，不删除配置/凭证/远端规则 | 残留进程/端口、配置丢失或远端规则超范围 | 阶段 3 实施证据 |
| 8 | 治理收口 | 全量 Swift/Rust/差分回归、`git diff --check`、`plan-governance-cli check . --strict-readiness`、反向引用检查 | 阶段 3 完成证据与 `PLAN_MAP.md` 同步 | 任一门禁失败或把一次真实验收误写成长期保证 | 阶段 3 独立完成复核 |

## 失败、回滚和人工边界

- 发出 `SIGSTOP` 后由程序自动处置；观察者只读取状态，不发送 `SIGCONT`、`SIGTERM`、`SIGKILL`，不点击启停/重启，不修改 plist/config/凭证。
- 任一身份字段读取失败、PID 变化、launchd 状态异常、取消/generation 失效、ECS 前置失败或资源未收敛，均判失败并保持 fail-closed；只在确认目标身份后按既有安全路径恢复，绝不处理 `reverse-ssh` 或未知进程。
- 若新 Release App 无法启动或自动恢复未在有界窗口内完成，停止进一步注入，记录当前状态；必要时使用本机 API/既有 stop 路径恢复 `admin-tunnel`，不删除配置、不改远端规则。
- 完成验收后恢复现场到 App 运行与两条隧道均由验收前快照决定的状态；若验收前目标为运行中，则恢复目标，非目标状态必须保持原样。

## 准入判断

阶段 2 已完成，真实目标、非目标、身份字段、故障注入、观察、回滚和清理边界已固定；本 Step 0 达到“待实施”候选，等待阶段 3 独立准入复核。独立准入通过前不发送 `SIGSTOP`。
