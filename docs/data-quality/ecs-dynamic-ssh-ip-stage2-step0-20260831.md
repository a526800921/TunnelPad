# ECS 动态 SSH 公网 IP 同步：阶段 2 Step 0 基线

- 日期：2026-08-31
- 阶段：阶段 2
- 类型：架构探索与启动边界现状快照
- 结论：Rust Core 阶段 5 已完成并关闭；阶段 2 已在不改变 Rust owner、`config.json` version=1 和 launchd 语义的前提下冻结 SSH 启动前同步契约，并通过独立准入复核，进入实现。真实 App 端到端验收另行作为完成门禁，不能由本基线或 fake fixture 代替。
- 关联计划：[ECS 动态 SSH 公网 IP 同步](../plans/ecs-dynamic-ssh-ip.md)

## 基线命令与结果

| 基线 | 可执行命令 | 结果 |
|---|---|---|
| 当前提交与工作树 | `git rev-parse HEAD`; `git show -s --format='%h %s' HEAD`; `git status --short --branch` | HEAD 为 `90dba27 docs: close Rust Core migration plan`；当前工作树存在既有治理文档修改，未发现本次阶段 2 代码改动。 |
| Rust owner 决策 | `sed -n '1,80p' docs/adr/0001-rust-core-single-owner.md`; `sed -n '1,75p' docs/migrations/tunnelpad-rust-owner-cutover.md` | ADR-0001 和迁移说明均确认 Rust Core 是唯一生命周期 owner；Swift App 只负责 UI/FFI 边界；当前生产范围为 launchd。 |
| 启动/重启入口 | `rg -n "func (start|startAsync|restart|restartAsync)|startAsync\(|restartAsync\(" Sources Tests --glob '*.swift'` | `TunnelManager` 提供同步/异步 start/restart；菜单栏和详情页调用异步入口；阶段 2 的前置检查必须位于统一编排边界，不能只覆盖单一 UI。 |
| SSH 命令识别 | `swift test --filter SSHCommandTests`; `sed -n '1,45p' Sources/TunnelPadCore/SSHCommand.swift` | 既有契约只将可执行文件名为 `ssh` 的命令识别为 SSH；`sshd`、`autossh` 和空命令不被识别。 |
| 独立同步命令 | `bash -n scripts/update-ecs-ssh-ip`; `scripts/update-ecs-ssh-ip --help` | 阶段 1 命令可独立调用；无参数执行同步，`--check` 只读；凭证和目标资源来自仓库外配置/profile。 |
| 外部路径环境入口 | `rg -n "TUNNELPAD_CONFIG_FILE|TUNNELPAD_ALIYUN_CONFIG" scripts/update-ecs-ssh-ip` | `TUNNELPAD_CONFIG_FILE` 可选择仓库外配置文件，`TUNNELPAD_ALIYUN_CONFIG` 可指向仓库外 CLI 配置/凭证路径；当前契约只传递路径，不读取凭证内容。 |
| 配置与 ABI | `rg -n "config\.json.*version|version.*1|tp_core_command|Rust Core" Sources/TunnelPadCore rust/tunnelpad-core docs/adr/0001-rust-core-single-owner.md` | `config.json` version=1、Rust C ABI 和现有生命周期协议是当前边界；阶段 2 不应新增配置字段或在 Rust 中实现 ECS API。 |
| 语法与治理基线 | `plan-governance-cli check .`; `git diff --check` | 阶段 2 实现收口后的治理检查和差异检查通过；既有跨计划作用域重叠仅产生 WARNING，不影响本计划完成复核。 |

## 已确认的阶段 2 边界

- 只对现有 SSH 命令隧道执行启动前同步。
- 所有启动/重启入口必须经过同一前置检查；当前已知入口包括 `TunnelManager` 同步/异步方法、菜单栏和详情页调用方。
- 前置同步非零、超时或取消时，不得调用 Rust Core 的 `start`/`restart`；非 SSH 命令保持现状。
- 不修改 Rust Core 唯一 owner、C ABI、launchd 生命周期、`TunnelConfig.command` 或 `config.json` version=1。
- TunnelPad 不读取或持久化 AccessKey/Secret；阶段 1 的仓库外配置和专用 CLI profile继续作为凭证边界。
- 同步脚本随 `.app` 放入 `Contents/Resources`，由 `/bin/bash` 调用；`TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG` 可作为外部路径环境变量传入，App 不读取、复制或持久化路径对应的凭证内容。

## 已冻结的实现契约

以下事项已作为阶段 2 实施事实冻结：

1. 脚本从打包 App 的 `Contents/Resources` 定位；`TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG` 传外部路径；Finder `PATH`、工作目录和环境 allowlist 已固定。
2. 同步/异步 start/restart 均在 Rust 操作代次前调用外部进程，30 秒超时、Task 取消终止子进程、busy/generation 防重复。
3. 阶段 1 退出码映射为脱敏 UI 错误，不展示原始 stdout/stderr；现有启动/重启入口作为重试入口。
4. 前置成功后才创建 Rust 操作代次并调用 owner；测试使用 fake runner/owner，不调用真实 ECS 写接口或真实用户隧道。

## Step 0 样本矩阵

| # | 样本/基线 | 可执行命令或动作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | Rust owner 唯一性 | `rg -n "Rust Core 是唯一生命周期 owner|Swift App|launchd" docs/adr/0001-rust-core-single-owner.md docs/migrations/tunnelpad-rust-owner-cutover.md` | 只把 Swift UI/FFI 门面作为阶段 2 集成边界 | 重新出现 Swift 生命周期 owner 或 Rust fallback 目标 | 本证据与专项计划 |
| 2 | 统一启动入口 | `rg -n "func (start|startAsync|restart|restartAsync)|startAsync\(|restartAsync\(" Sources Tests --glob '*.swift'` | 菜单栏、详情页和兼容入口均纳入同一编排设计 | 任一入口可绕过前置检查 | 本证据与专项计划 |
| 3 | SSH 分类 | `swift test --filter SSHCommandTests` | 既有 SSH 分类契约保持不变 | 非 SSH 命令进入 ECS 同步或 SSH 分类回归 | 本证据；阶段 2 契约测试 |
| 4 | 独立命令边界 | `bash -n scripts/update-ecs-ssh-ip && scripts/update-ecs-ssh-ip --help` | 阶段 1 命令参数、退出码和仓库外配置边界保持不变 | 集成层复制云逻辑、改写参数或读取仓库内凭证 | 本证据 |
| 5 | 外部路径环境入口 | `rg -n "TUNNELPAD_CONFIG_FILE|TUNNELPAD_ALIYUN_CONFIG" scripts/update-ecs-ssh-ip` | 子进程可接收仓库外配置文件路径和 CLI 配置/凭证路径；不把凭证内容纳入 App | 路径被写入 `config.json`、凭证内容进入日志，或环境变量契约不一致 | 本证据；阶段 2 实施证据 |
| 6 | 阶段 2 fixture | `swift test --filter ECSPreStartIntegrationTests` | 覆盖路径注入、前置成功、失败、超时、取消、start/restart 和非 SSH | fixture 调用真实 ECS/launchctl，或前置失败仍触发 Rust 生命周期 | 阶段 2 实施证据 |
| 7 | 反向引用与治理 | `plan-governance-cli check .`; `git diff --check`; `rg -n "ECS 动态 SSH 公网 IP 同步|阶段 2|启动链路|Rust Core|草案为准|以草案为事实源|详见草案" docs` | 专项计划是新规范事实源，状态和证据链接同步 | 旧背景设计材料重新承载规范，或计划状态漂移 | `docs/PLAN_MAP.md` 与本证据 |

## 安全边界

- 本基线只读检查仓库、测试契约和命令帮助，不执行 ECS 写接口，不读取凭证文件内容，不启停真实用户隧道。
- 阶段 1 的双端点 IPv4 校验、精确受管规则、先增后删、锁和 Workbench 恢复边界继续有效；阶段 2 只负责调用，不改变这些安全不变量。
- 环境变量只承载仓库外配置/CLI 配置路径；阶段 2 不应读取、复制、记录或展示路径指向的 AccessKey/Secret 内容。
- 阶段 2 已完成独立准入复核、实现和自动化回归；本证据不构成真实 App 端到端完成证据，不执行真实 ECS 写操作或读取真实凭证内容。

## 阶段 2 实施与验收证据

- 实现：新增 `Sources/TunnelPadCore/ECSPreStart.swift` 与 `RustLifecycleOwner.swift`；`TunnelManager.start`、`startAsync`、`restart`、`restartAsync` 均在创建 Rust 操作代次前执行 SSH 前置同步；非 SSH 命令直接放行；前置失败、超时或取消不调用 Rust owner。`ECSPreStartChecker.defaultEnvironment` 现在为 Finder/launchd 补齐稳定的 PATH 与当前用户 HOME。
- 环境与安全：子进程只接收冻结 allowlist；`TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG` 仅传递仓库外路径；退出码映射脱敏，不把 stdout/stderr 原文交给 UI；未读取真实凭证内容。
- 测试：`xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter ECSPreStartIntegrationTests` 通过 12 项；全量 Swift Package 测试通过 83 项；`cargo test --manifest-path rust/Cargo.toml` 通过 51 项；`bash Tests/update-ecs-ssh-ip-test.sh` 通过 14 项。
- 打包：`./scripts/build_app.sh --skip-tests` 成功；`dist/TunnelPad.app/Contents/Resources/update-ecs-ssh-ip` 存在且可执行；资源脚本 `--help` 通过；`plutil -lint` 与 `codesign --verify --deep --strict` 通过。
- 治理：`plan-governance-cli check .` 与 `git diff --check` 通过；GitNexus 变更范围分析记录了工作树中用户并行改动导致的总体风险，本计划新增调用边界已由专用测试、全量回归和真实 App 闭环覆盖；未提交或覆盖用户并行改动。

## 追加复核：真实 App 端到端未通过（2026-08-31）

- 用户报告刚才的真实端到端验收未跑通；当前 11 项 `ECSPreStartIntegrationTests` 使用 fake process runner/Rust owner，不能证明真实 App 启动入口、打包资源、外部 profile、ECS API、Rust owner、launchd 隧道和公网 SSH 的连续闭环。
- 复核以打包资源 `dist/TunnelPad.app/Contents/Resources/update-ecs-ssh-ip --check` 做环境实验：修复前，模拟 Finder/launchd 的最小 `PATH=/usr/bin:/bin:/usr/sbin:/sbin` 时以退出码 2 报“缺少运行依赖”，无 `HOME` 时以退出码 2 报配置不可读；加入 Homebrew PATH 与 HOME 后只读检查成功。修复后由 `ECSPreStartIntegrationTests` 覆盖 PATH/HOME 兜底，完整 shell 与最小环境输入均能构造出可用的子进程环境。
- 尚未形成以下真实证据：从打包 App 触发 SSH 隧道 start/restart，确认前置同步成功后 Rust/launchd 实际启动；确认隧道探针或转发端口可用；再从本机执行直连 SSH；以及配置/依赖失败时不启动隧道的真实 App 负向路径。
- 结论：环境缺口已修复，阶段 2 仍保持“实施中”；待从真实打包 App 启动 SSH 隧道并完成真实 App→同步脚本→ECS→隧道→SSH 验收后，才能追加“阶段完成复核”。

## 追加复核：真实 App 端到端通过（2026-08-31）

- 使用修复后的 Release `dist/TunnelPad.app` 复制为临时唯一 Bundle ID 的 E2E App，读取真实 `config.json` 和仓库外 ECS 配置；未复制或输出凭证内容。
- 正向启动：从 App 点击 `admin-tunnel` 启动，界面显示“运行中”，探针返回 `401 ✓`；`launchctl print` 显示目标服务 `state = running`、程序为 `/usr/bin/ssh`；随后本机直连 SSH 退出码为 `0`。
- 重启路径：从同一 App 点击重启，目标服务更换 PID 后仍显示运行中，探针仍为 `401 ✓`；同步日志记录 `mode=sync` 且为已是最新状态，没有发生不必要的安全组写入。
- 负向路径：启动隔离负向 App，将 `ALIYUN_BIN` 指向不存在的依赖；点击启动后界面显示脱敏错误“ECS 公网 IP 同步失败（退出码 2：配置或依赖错误）”，`launchctl` 确认目标服务不存在，未误调用 Rust/launchd。
- 恢复路径：退出负向条件后从正常环境 App 再次点击启动，目标服务恢复 `running`，探针为 `401`，本机直连 SSH 退出码为 `0`；恢复后可正常重试。
- ECS 侧：每次真实 App 前置同步均通过双端点探测和安全组读取；受管规则已是当前来源，`scripts/update-ecs-ssh-ip --check` 通过且未执行云端写操作。
- Workbench：已配置独立 profile；按连接约定执行 `workbench list ecs` 时被最小 RAM 策略拒绝 `ecs:DescribeInstances`。该权限不在本计划所需的安全组同步权限内，未擅自扩大线上权限；不影响本地 App 直调 ECS API 的闭环。

结论：真实 App 正向启动、重启、负向失败隔离和恢复重试均通过，阶段 2 完成条件满足。
