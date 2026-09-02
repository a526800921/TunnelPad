# TunnelPad 稳定性阶段 3 Step 0 证据

- 日期：2026-09-02
- 计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 阶段：阶段 3
- 基线类型：阶段 2 独立完成复核后的发布产物基线 + 隔离 demo/应用门禁边界
- 当前结论：Step 0、独立准入和最终发布门禁均已完成；阶段 3 已关闭

## 目标与边界

阶段 3 只收口隔离 demo、当前 `launchd` 执行器的受控应用冒烟、Release 产物和计划治理门禁。它不新增稳定性代码、不改变 `config.json` Schema、不操作真实用户的 `launchctl`、SSH、ECS 或凭证，也不实现未来 `app` 执行器和 pidfile 孤儿进程收敛。

阶段 2 的真实 `admin-tunnel` 业务闭环已经在[阶段 2 真实 App 受控验收](tunnelpad-stability-stage2-real-app-acceptance-20260902.md)中完成；阶段 3 只验证当前工作树重新构建后的可发布性和隔离边界，不重复对真实隧道做故障注入。

## Step 0 样本矩阵

| 样本 | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| Swift 稳定性回归 | 当前工作树阶段 0–2 专项与全量测试 | `swift test` | 全量通过；阶段 2 迟到结果、ECS 顺序、启动收敛和关闭失效测试均通过 | 任一测试失败或触碰真实资源 | 本文与终端输出 |
| Rust owner 回归 | 当前 Rust owner、配置重载、shutdown 和差分 fixture | `cargo test --manifest-path rust/Cargo.toml` | Rust 单元、差分测试和 doctest 全部通过 | owner/差分失败或修改真实 launchd | 本文与终端输出 |
| Release 产物 | 当前 Swift executable、Rust dylib、`dist/TunnelPad.app` | `scripts/build_app.sh --skip-tests`；`plutil -lint`；`codesign --verify --deep --strict` | Release App、动态库、Info.plist 和签名有效 | 构建、链接、签名或包结构失败 | 本文与构建输出 |
| 隔离 demo | Rust 既有 `demo-*` ID 边界、临时 home 和生命周期 fixture | `cargo test --manifest-path rust/Cargo.toml demo`；读取既有 Rust migration/log streaming 隔离 App 证据 | 只使用虚构 ID/临时路径；启动、停止、重载、清理不触碰真实资源 | 出现真实配置/路径/label 或隔离产物残留 | Rust 测试与既有隔离证据 |
| 受控应用冒烟 | 当前 `dist/TunnelPad.app`，无运行中受管隧道 | `xcodebuildmcp macos launch/stop`；只读检查 App、label、PID、端口 | App 能启动/退出；不猜测性启动隧道；退出后无残留 | App 无法启动、误启停真实隧道或产生残留 | 阶段 2 真实 App 受控验收与本轮输出 |
| 治理和反向引用 | `PLAN_MAP.md`、专项计划、ADR/migration、阶段证据 | `plan-governance-cli check . --strict-readiness`；`plan-governance-cli check . --stale-days 10`；`git diff --check`；关键术语反向引用搜索 | 状态、阶段、证据和非目标一致；无治理 ERROR 或草案事实源回退 | 状态漂移、缺证据、空白错误或旧草案成为事实源 | 本文与终端输出 |

## 已执行的基线检查

- `cargo test --manifest-path rust/Cargo.toml demo`：3/3 demo 单元测试通过，0 失败；覆盖非 `demo-*` 拒绝、接管边界和 launchd demo 清理。
- `scripts/build_app.sh --skip-tests`：Rust release、Swift release、App bundle、动态库复制、Info.plist、ad-hoc 签名和包校验均通过。
- 当前工作树 `swift test`：129/129 通过，其中 `StabilityStage2Tests` 11/11 通过。
- 当前工作树 `cargo test --manifest-path rust/Cargo.toml`：62 个 Rust 单元测试、1 个差分测试通过。
- `scripts/update-ecs-ssh-ip --check`：双端点探测和受管安全组读取成功，未执行写操作。
- `codesign --verify --deep --strict dist/TunnelPad.app`：通过。
- `xcodebuildmcp macos launch --app-path dist/TunnelPad.app --output json`：启动成功；只读复查确认两个受管 label 均不存在/未加载，8081 无监听，未猜测性启动隧道。
- `xcodebuildmcp macos stop --process-id 16698 --output json`：退出成功；退出后 App、两个受管 label、隧道 PID 和 8081 端口均无残留。
- 真实环境清理复查：`admin-tunnel` label 不存在/未加载，App/隧道 PID 不存在，8081 无监听；真实 App 业务闭环沿用阶段 2 独立完成复核证据。
- `plan-governance-cli check . --strict-readiness` 与 `--stale-days 10`：通过；`git diff --check`：通过。

## 验证与回滚边界

阶段 3 的所有应用验证必须使用隔离 demo 或当前工作树构建产物；真实用户隧道只允许复用阶段 2 已记录的结果，不再进行新的故障注入。若 Release 或隔离门禁失败，保留阶段 2 已关闭的代码和证据，仅回滚阶段 3 产物/文档变更，不删除真实配置、日志、plist 或远端规则。

阶段 3 完成前仍需独立核对：隔离 demo 未越过资源边界、Release App 可启动、真实 App 受控验收证据仍与当前代码一致、治理和反向引用检查通过。通过后才可关闭阶段 3；本 Step 0 与准入复核本身不代表阶段 3 完成。
