# 计划：ECS 动态 SSH 公网 IP 同步

## 背景

本机网络切换会改变公网 IPv4，使仅允许旧来源 `/32` 的 ECS SSH 安全组规则失效。本计划先在项目外跑通受控的安全组同步流程，再将已验证的流程接入仓库；阶段 0 和阶段 1 保持与 TunnelPad 启动链路隔离，阶段 2 才在 Rust Core 唯一 owner 已完成的边界上设计 SSH 启动前集成。

[ecs-dynamic-ssh-ip-design.md](../ecs-dynamic-ssh-ip-design.md) 是初始背景材料。本计划是本事项的唯一规范事实源。

## 目标

在不扩大公网入口、不读取 SSH 私钥内容、不把云凭证写入仓库的前提下，先验证一条可审计、可回滚的项目外同步流程；验证通过后，再以本机命令接入仓库。该流程确认本机实际 SSH 出站公网 IPv4 后，只维护目标 ECS 动态 SSH 安全组的一条 TCP SSH `/32` 入方向规则。

## 非目标

- 阶段 0 和阶段 1 不修改 TunnelPad UI、`config.json` schema、启动流程或 launchd 执行器；阶段 2 不修改 Rust Core 的生命周期 owner、C ABI 或 launchd 托管实现。
- 不使用、不读取、不迁移现有的 `AliyunECSFullAccess` 凭证 CSV。
- 不创建 `0.0.0.0/0`、IPv6、私网或端口范围宽于 SSH 端口的规则。
- 不自动删除未知来源的安全组规则，也不管理 80/443、ECS 服务、Caddy、systemd、SSL-VPN 或 Workbench。
- 不将 AccessKey、Secret、SSH 私钥、完整安全组/实例 ID 或原始公网 IP 写入仓库、日志或证据文档。

## 需求探索

### 已确认事实

- 用户确认本事项是独立优化计划，可立即开始阶段 0 准备，但不改变 TunnelPad v1 的范围。
- 先在项目外跑通受控流程；仅在流程通过独立复核后，才将独立同步命令与安全预检接入仓库。TunnelPad 自动启动前调用是后续候选阶段。
- 现有下载目录中的 AccessKey 具有 `AliyunECSFullAccess`，明确排除在本计划外。
- 用户已创建新的专用 RAM 用户；其身份和目标安全组只读权限已经验证。用户明确选择由本机直接调用 ECS API，不增加中央执行器；安全组写动作的实际授权和受控实跑仍待验证。
- 用户随后明确指定本计划使用的 ECS，并已通过 Workbench 在 `cn-chengdu` 成功建立会话；复查现有生产 SSH 配置后，目标 SSH 别名使用同一公网入口直连成功。
- 2026-08-31，用户确认 TunnelPad Rust 重构已完成；当前仓库以 Rust Core 作为唯一生命周期 owner，Swift `TunnelManager` 是 UI/FFI 门面，`config.json` version=1 和现有 launchd 语义保持不变。
- 2026-08-31，用户确认阶段 2 的边界：只对 SSH 命令隧道执行启动前同步，所有启动入口统一经过该前置检查，非 SSH 命令保持现状，不把凭证写入 `config.json`。
- 2026-08-31，用户确认仓库外配置路径和 CLI 凭证配置路径可以通过环境变量传给同步子进程；沿用现有 `TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG`，仅传递路径，不把凭证内容交给 TunnelPad。

### 暂定假设与验证方式

| 假设 | 验证方式 |
|---|---|
| SSH 到目标 ECS 的实际来源可由本机公网 IP 探测得到 | 代理环境下两个 HTTPS 探测结果与真实 SSH 会话 `SSH_CONNECTION` 来源哈希不一致；因此以实际 SSH 会话观察到的来源为准，不把普通探测结果作为安全组输入。 |
| 专用动态 SSH 安全组已关联到承载 SSH 公网流量的 ECS 网卡 | 阶段 0 通过控制台或只读 ECS 查询记录脱敏关联关系，并检查所有相关安全组。 |
| 不存在会绕过动态规则的宽泛 SSH allow 规则 | 阶段 0 查询目标网卡相关安全组；发现 `TCP 22/22 + 0.0.0.0/0` 或等效覆盖范围即不通过。 |
| 新 RAM 身份可支撑本机直调且风险可控 | 用户明确选择不增加中央执行器，接受 `AuthorizeSecurityGroup` 不能按目标安全组或端口缩小的已知 IAM 范围；阶段 0 只使用新专用身份，并以固定目标、TCP SSH、严格 `/32` 校验、先增后删和 Workbench 恢复边界降低误操作风险。 |

### 范围与非目标

范围：阶段 0 形成只读基线、权限可行性结论与项目外受控实跑证据；阶段 1 在仓库内交付与该流程等价的独立命令、测试和操作说明；阶段 2 设计并验证 SSH 命令隧道的启动前调用边界。凭证保管 UX 与配置 schema 扩展不属于阶段 1 或阶段 2。

非目标：见本计划“非目标”章节。

### 候选方案与取舍

| 决策点 | 候选 | 当前结论 |
|---|---|---|
| 规则归属 | 专用动态 SSH 安全组 / 在现有组以描述标记维护 | 优先专用安全组；仅在已关联且没有宽泛 SSH 规则时使用。无法新建时，允许在现有组中以精确描述和完整规则元组识别。 |
| 落地顺序 | 项目外受控实跑 / 仓库独立命令 / TunnelPad 自动调用 / 定时任务 | 先在项目外跑通并复核，再接入仓库独立命令；自动调用和定时任务留到后续阶段。 |
| 凭证 | 现有 FullAccess / 本机长期专用 RAM 身份 / 中央受控执行器 | 排除现有 FullAccess；用户已选择新专用 RAM 身份在本机直调 ECS API，不增加中央执行器。`AuthorizeSecurityGroup` 的 IAM 范围不能缩小到单一安全组或端口，此为已确认并接受的边界。 |
| 阶段 2 集成位置 | TunnelManager 启动前置 / 修改每条 `command` 加 wrapper / UI 单独按钮 | 已完成 TunnelManager 统一前置方案：只约束 SSH 命令隧道且所有启动入口统一检查；同步脚本随 `.app` 分发并由 `/bin/bash` 调用。`TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG` 作为子进程环境中的外部路径输入，不写入 `config.json`；超时、取消和依赖环境已冻结并通过契约测试。 |

### 未决问题

| 问题 | 影响 | 阻塞级别 |
|---|---|---|
| 断连前的来源发现机制 | 已验证 `myip.ipip.net` 与 `ip.3322.net` 两个中国直连 IPv4 回显端点，与真实 SSH 会话来源一致且彼此一致；阶段 1 必须双端点校验，任一不一致即停止写入 | 非阻塞（已验证） |
| 阶段 1 启动范围确认 | 用户已确认创建仓库内独立同步命令，并保持与 TunnelPad 启动链路隔离；契约已冻结 | 非阻塞（已确认） |
| 阶段 2 外部命令调用适配 | 脚本已随 `.app` 放入 `Contents/Resources` 并由 `/bin/bash` 调用；外部配置/CLI 凭证配置路径可通过 `TUNNELPAD_CONFIG_FILE`、`TUNNELPAD_ALIYUN_CONFIG` 传入；Finder 环境下的 `PATH`、工作目录、环境 allowlist、超时/取消、输出脱敏和退出码映射均已冻结并验证 | 非阻塞（已完成） |
| 阶段 2 失败后的启动语义 | 已确认并验证同步失败不得调用 Rust Core 的 start/restart；错误展示和现有启动/重试入口已由契约测试覆盖 | 非阻塞（已完成） |

### 用户确认的探索结论

2026-08-29 用户确认：本事项新开为 TunnelPad 后续优化计划；先在项目外跑通安全组同步流程，验证通过后才接入仓库；TunnelPad 自动集成推迟到后续阶段；现有 `AliyunECSFullAccess` 凭证永不用于该能力，改用新专用 RAM 身份。用户进一步确认不增加 FC 或其他中央执行器：本机直接调用 ECS API，并接受 `AuthorizeSecurityGroup` 无法在 IAM 层缩小到单一安全组或端口的已知范围。

2026-08-31 用户确认：Rust Core 重构已完成；阶段 2 只对 SSH 命令隧道执行启动前同步，所有启动入口统一经过该检查，非 SSH 命令保持现状；不新增 `config.json` 凭证字段。阶段 2 先完成基于当前 Rust owner 边界的计划设计、Step 0 和准入复核，再决定是否进入实现。

2026-08-31 用户确认阶段 2 的分发方案：将 `update-ecs-ssh-ip` 作为 `.app` 的 `Contents/Resources` 资源随包分发，由 `TunnelManager` 通过 `/bin/bash` 调用；仓库外配置、专用 CLI profile 和依赖继续由本机环境提供，不把命令路径或凭证写入 `config.json`。

2026-08-31 用户补充确认：仓库外配置文件路径和阿里云 CLI 配置/凭证路径允许通过环境变量传给同步子进程。阶段 2 沿用 `TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG`；TunnelPad 只传递路径，不读取、复制或持久化凭证内容。

## 不变量

- 更新顺序必须是“新增当前规则 → 查询确认 → 按规则 ID 清理已验证的旧规则”；新增失败时保留旧规则，删除失败时保留新旧规则并报告失败。
- 只操作方向 `ingress`、`TCP`、`<SSH_PORT>/<SSH_PORT>`、`accept`、VPC `intranet`、描述精确匹配的动态 SSH 规则；绝不按“所有 22 端口规则”批量删除。
- 每次 API 写操作必须带唯一 `ClientToken`；重试或规则 ID 不存在时必须重新查询收敛状态，不能把未知错误视为成功。
- 单次运行最多接受一个经过严格校验的公网 IPv4，并写为 `/32`；任何空值、私网/保留地址、IPv6、两个来源不一致或异常响应都会终止且不写云端。
- 使用本地互斥锁；日志仅保存脱敏资源标识、规则 ID、结果和时间，绝不包含凭证或原始公网 IP。
- Workbench 保留为恢复通道；脚本、TunnelPad 和动态安全组都不得成为唯一 SSH 恢复方式。

## 影响模块或文件

- `docs/plans/ecs-dynamic-ssh-ip.md`：本计划、阶段证据与准入事实源。
- `docs/PLAN_MAP.md`：计划状态、顺序、依赖和阻塞项索引。
- `docs/ecs-dynamic-ssh-ip-design.md`：背景材料链接；不承载新规范。
- `scripts/update-ecs-ssh-ip`：阶段 1 起新建的独立同步命令。
- `Tests/update-ecs-ssh-ip-test.sh` 与 `Tests/fixtures/update-ecs-ssh-ip/`：阶段 1 的本地合成 fixture 测试，不调用真实 ECS。
- `docs/examples/ecs-ssh-ip.env.example` 与 `docs/ecs-dynamic-ssh-ip-operations.md`：仓库外配置示例和独立命令操作说明。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-local-preflight-20260829.md`：阶段 0 本机脱敏预检证据。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-*.md`：后续阶段 0 脱敏基线与受控实跑证据。
- `Sources/TunnelPadCore/TunnelManager.swift`：阶段 2 启动/重启编排边界的候选前置检查位置；不改变 Rust Core owner。
- `Sources/TunnelPadCore/SSHCommand.swift` 与 `Tests/TunnelPadCoreTests/SSHCommandTests.swift`：阶段 2 SSH 命令识别的既有契约和回归范围。
- `Sources/TunnelPadCore/ProcessRunner.swift`、阶段 2 适配器候选文件与 `Tests/TunnelPadCoreTests/`：阶段 2 外部命令调用、超时、取消和失败映射的实现/测试范围，具体文件待设计冻结。
- `scripts/build_app.sh` 与 `App/Resources/`：阶段 2 将同步脚本作为 `.app/Contents/Resources` 资源分发，并在签名/产物校验中纳入。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md`：阶段 2 Rust owner 与启动入口只读基线。
- 仓库外配置：`~/.config/tunnelpad/ecs-ssh-ip.env`（仅非秘密参数）与专用阿里云 CLI profile；不得纳入 Git。

## 公共契约变化

阶段 1 已新增仓库内命令 `scripts/update-ecs-ssh-ip`。阶段 0 的项目外实跑已通过独立复核，本阶段已冻结其稳定契约、退出码、参数及外部配置键；不得复用或改变 TunnelPad `config.json` v1。

阶段 2 的自动集成不改变 `config.json` version=1、`TunnelConfig.command`、Rust C ABI 或 launchd owner。`preStart` 类内部契约、SSH 命令识别、外部命令路径/环境、允许继承的环境变量（至少包括 `TUNNELPAD_CONFIG_FILE`、`TUNNELPAD_ALIYUN_CONFIG`）、超时与取消、失败呈现、重试入口和向后兼容策略已冻结；凭证继续由仓库外 profile/config 管理，TunnelPad 只传路径，不读取或持久化凭证值。

## 阶段路线图

| 阶段 | 目标 | 进入条件 | 验证方向 | 状态 |
|---|---|---|---|---|
| 阶段 0 | SSH 出站路径、安全组现状、专用 RAM 权限边界的基线与项目外受控实跑 | 本计划已登记；不使用现有 FullAccess CSV；所有写入前置检查通过 | 脱敏快照、权限验证、实际同步与 SSH 连通性验证 | 已完成 |
| 阶段 1 | 将已验证流程接入仓库：独立同步命令、外部非秘密配置、测试与操作说明 | 阶段 0 独立完成复核通过 | 与阶段 0 流程等价、幂等、先增后删、故障保留旧规则 | 已完成 |
| 阶段 2 | SSH 前置同步与 TunnelPad 自动启动前集成 | 阶段 1 独立完成复核通过；schema、凭证路径和前置调用契约已冻结 | 启动失败不拉起隧道、正常路径不泄密、真实 App→ECS→SSH 闭环通过后才完成 | 已完成 |

## 阶段 0 收口记录

阶段 0（基线、权限可行性与项目外受控实跑）、阶段 1（仓库内独立同步命令）和阶段 2（SSH 启动前自动集成）均已完成；阶段 2 已通过真实 App 启动、重启、负向失败隔离、恢复重试及本机直连 SSH 验收。

阶段 0 未改动 TunnelPad v1 代码或自动集成链路；项目外受控实跑和独立准入复核均已完成。

### 范围

- 固定目标 SSH 别名及其真实出站路径；用户已报告本机运行代理，须先验证其对 SSH 出口的实际影响，不能以 `ssh -G` 未出现跳板为充分证据。
- 获取目标 ECS 网卡关联安全组、SSH 入方向规则和专用动态组关联关系的脱敏只读快照。
- 排除宽泛 SSH 规则，验证专用安全组方案能实际约束入口。
- 设计并验证新的专用 RAM 身份的权限边界；只读身份验证不得使用或读取现有 FullAccess CSV。
- 在上述前置检查通过后，以项目外临时命令完成一次“新增当前规则 → 查询确认 → 清理已验证旧规则 → SSH 实连”的受控流程；临时命令、凭证与原始输出均不得进入仓库。

### 非目标

- 前置检查未通过时，不调用 `AuthorizeSecurityGroup`、`RevokeSecurityGroup` 或其他写接口。
- 不自动创建 RAM 用户、AccessKey、安全组、ECS 配置或 TunnelPad 代码。
- 不把原始网络、账户或凭证数据写入仓库。

### 阶段 0 准入收口

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 架构探索基线：建立 SSH 实际出站路径、目标安全组实际约束与专用 RAM 权限边界的可观察快照；通过后再做一次项目外受控实跑。 |
| 样本矩阵 | 见本阶段“样本矩阵”；所有输出使用脱敏快照或本机临时路径。 |
| 验证方式 | 逐项复跑基线；核对无宽泛 SSH 规则、无跳板路径歧义、无 FullAccess 凭证参与；实跑后验证新规则、旧规则清理和 SSH 连通性；独立复核后才可进入阶段 1。 |
| 失败/回滚边界 | 任一前置检查不通过即停止且无写入；实跑新增失败保留旧规则，清理失败保留新旧规则并通过 Workbench 恢复。 |
| 当前阻塞项 | 无。阶段 1 已按自身 Step 0、验证方式和独立复核完成；其通过结论记录在下方“独立复核记录”中。 |
| 最新独立准入复核 | 2026-08-29：通过（达到阶段 0 完成条件）。 |

### 实施步骤

1. 用户已提供新专用 RAM 用户结果 CSV、策略确认及受控目标；仅在本机建立隔离 CLI profile 并验证 STS 身份。现有 FullAccess CSV 持续禁止读取或导入，受控目标标识不写入仓库。
2. 以只读命令记录 SSH 配置、目标安全组关联及入方向 SSH 规则的脱敏基线。
3. 检查是否存在绕过动态组的宽泛 SSH 允许规则；若存在，记录为阻塞项，不执行任何删除。
4. 用新身份验证身份归属、预期只读权限和本机直调写权限；用户已明确选择不增加中央执行器，并接受 `AuthorizeSecurityGroup` 不能达到目标安全组/端口级 IAM 最小权限的已知范围。写入实现仍固定目标、TCP SSH、严格 `/32` 校验和规则归属，不得接受任意资源或端口输入。
5. 仅在步骤 2–4 通过后，以项目外临时命令实跑“新增当前规则 → 查询确认 → 清理旧规则 → SSH 实连”；失败按不变量保留可用规则。
6. 填写阶段 0 证据、独立完成复核，并同步 `PLAN_MAP.md`；阶段 0 复核通过后已冻结阶段 1 的仓库命令契约。

### Step 0 证据

本机预检、云端只读验证、写权限审查和项目外受控实跑均已形成脱敏证据；最新实跑记录见 [阶段 0 项目外受控实跑](../data-quality/ecs-dynamic-ssh-ip-stage0-controlled-run-20260829.md)。证据不含原始公网 IP、账户 ID、完整资源 ID、AccessKey 或 Secret。

### 样本矩阵

| 样本/基线 | 可执行命令或动作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|
| SSH 出站配置 | `ssh -G -F ../motorcycle-manual-app/infra/production/ssh_config motorcycle-manual-prod`，再执行一次非交互式 SSH | 生产配置直连目标 ECS，SSH 命令返回成功；配置层无跳板指令 | 存在跳板/代理、目标不一致或 SSH 失败 | 脱敏阶段 0 快照 |
| 专用身份归属 | `aliyun --config-path "$TUNNELPAD_ALIYUN_CONFIG" --profile tunnelpad-ecs-sync sts GetCallerIdentity` | 返回新的专用身份；使用 profile 的 JSON 输出设置，不显示 Secret | profile 缺失、身份不符、使用 FullAccess 身份 | 脱敏阶段 0 快照；本机完整输出不得提交 |
| 安全组规则读取 | `aliyun --config-path "$TUNNELPAD_ALIYUN_CONFIG" --profile tunnelpad-ecs-sync ecs DescribeSecurityGroupAttribute --RegionId "$ALIBABA_REGION_ID" --SecurityGroupId "$ECS_SECURITY_GROUP_ID" --Direction ingress --NicType intranet` | 可读取目标组，并可提取规则 ID、方向、协议、端口、来源和描述 | 无权限、目标错误、输出无法脱敏处理 | 脱敏阶段 0 快照 |
| 宽泛 SSH 反查 | 对目标公网网卡关联的每个安全组检查 `TCP 22/22` 入方向规则 | 不存在 `0.0.0.0/0` 或等效覆盖当前 SSH 的宽泛规则 | 发现宽泛规则、关联关系未知 | 脱敏阶段 0 快照与 PLAN_MAP 阻塞项 |
| 公网 IPv4 探测基线 | 通过实际 SSH 会话的 `SSH_CONNECTION` 观察来源；再请求 `myip.ipip.net` 与 `ip.3322.net` 两个中国直连 IPv4 端点做同路由对照 | 两端点返回相同、合法 IPv4，并与 SSH 来源一致；后续可在断连时仅依赖双端点探测 | 代理/TUN 导致来源不一致、端点异常、IPv6/私网或两端点不一致 | 仅记录通过/失败与地址哈希的阶段 0 快照 |
| FullAccess 排除检查 | 审阅执行 profile 名称与凭证来源，不读取现有 FullAccess 凭证 CSV | 所有阶段 0 命令不引用该 CSV 或其身份 | 任何命令、环境变量或 profile 指向该凭证 | 脱敏阶段 0 快照 |
| 项目外受控实跑 | 通过真实 SSH 会话取得当前来源，执行“新增 `/32` → `Describe` 确认 → `Revoke` 已验证旧受管规则 → 再次 `Describe`” | 新规则存在、旧受管规则消失、其他规则未修改；每次写入使用唯一 `ClientToken` | 新增未确认、删除目标不精确、API 错误或未建立恢复通道 | 脱敏受控实跑记录；完整命令与凭证输出只留本机临时目录 |
| SSH 实连 | 受控实跑后，以生产 SSH 配置执行非交互式连接测试，并再次观察 `SSH_CONNECTION` | SSH 建连成功、来源可观察，且未依赖宽泛规则或 FullAccess 身份 | 超时、认证失败、来源无法观察或连接路径变化 | 脱敏受控实跑记录 |

### 阶段证据

- [本机预检（2026-08-29）](../data-quality/ecs-dynamic-ssh-ip-stage0-local-preflight-20260829.md)：目标 SSH 别名配置未输出跳板/代理指令；`jq` 与 OpenSSH 可用；阿里云 CLI 未安装；未读取 FullAccess CSV，未连接 ECS 或调用云 API。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-cli-credential-prep-20260829.md`（CLI 与凭证准备，2026-08-29）：官方 CLI 已安装；经用户授权的新 CSV 数据行仅在本机进程内用于一次失败的隔离 profile 初始化，未写入配置或输出；因尚无 RegionId 未执行 STS 或 ECS 调用。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-cloud-readonly-20260829.md`（云端只读验证，2026-08-29）：隔离 profile 已在仓库外创建；新专用 RAM 用户通过 STS 验证，且读取目标安全组成功；仅该安全组中未发现宽泛 SSH 放行。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-network-baseline-20260829.md`（公网出口基线，2026-08-29）：禁用代理、强制 IPv4 后两个 HTTPS 端点返回一致的全局 IPv4；用户随后报告本机运行代理，故该基线不能单独证明 SSH 实际来源。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-console-topology-20260829.md`（控制台拓扑基线，2026-08-29）：用户提供的控制台页显示一个主网卡、无辅助网卡和目标安全组；现有两条 SSH 规则均不是本计划可证明管理的规则，必须保留。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-write-authorization-review-20260829.md`（写权限审查，2026-08-29）：官方授权信息确认直接 `AuthorizeSecurityGroup` 只能使用全部资源授权，条件键不能限制目标安全组或端口；用户已选择由新专用 RAM 身份本机直调并接受该 IAM 边界，后续实跑已验证该动作可用。
- `docs/data-quality/ecs-dynamic-ssh-ip-stage0-controlled-run-20260829.md`（项目外受控实跑，2026-08-29）：目标 ECS 已由 Workbench 与生产 SSH 配置双路径确认；真实 SSH 来源已观察并完成“新增、确认、撤销旧受管规则、SSH 重连”，对照 HTTPS 探测因代理路径不同未作为安全组输入。
- 同一受控复核还观察到 `createdByEcsWorkbench`、`System created rule.` 和无描述的既有 SSH/服务规则；这些规则均保留，动态流程只精确匹配 `tunnelpad-dynamic-ssh-managed`，不按端口批量删除。
- 阶段 0 独立准入复核已通过；阶段 1 已按用户确认的范围完成实现、验证和独立复核，命令契约已冻结，TunnelPad 自动集成仍留在阶段 2。

### 最近实施/验证记录

| 日期 | 类型 | 动作/结果 | 证据 | 状态 | 记录者 |
|---|---|---|---|---|---|
| 2026-08-29 | 需求探索 | 用户确认独立命令优先、现有 FullAccess 凭证排除、专用凭证须经最小权限验证 | 本计划“需求探索” | 完成 | 用户与 Codex |
| 2026-08-29 | 阶段 0 预检 | 只读解析 `motorcycle-manual-prod` 的 SSH 配置：未输出 `ProxyJump`/`ProxyCommand`；`jq`、OpenSSH 可用，阿里云 CLI 缺失；未读取凭证、未连接 ECS、未调用云 API | 本机预检 | 部分完成 | Codex |
| 2026-08-29 | 阶段 0 准备 | 用户确认专用 RAM 用户及策略已创建；官方阿里云 CLI 已安装。经授权的新用户 CSV 数据行仅用于本机一次失败的隔离 profile 初始化，未写入配置或输出；因未取得 RegionId，未调用 STS 或 ECS。 | CLI 与凭证准备 | 部分完成 | 用户与 Codex |
| 2026-08-29 | 阶段 0 云端只读验证 | 已在仓库外创建仅当前用户可读的隔离 profile；移除不兼容输出参数后，STS 确认专用 RAM 用户身份。修正最小只读策略后，目标安全组读取成功：5 条入方向规则、2 条 SSH 规则，未发现宽泛 SSH 放行；未调用任何安全组写接口。 | 云端只读验证 | 部分完成 | Codex |
| 2026-08-29 | 阶段 0 网络基线 | 在禁用代理、强制 IPv4 条件下，两个 HTTPS 公网地址端点返回一致的全局 IPv4；原始地址未记录，仅保留哈希。 | 公网出口基线 | 通过 | Codex |
| 2026-08-29 | 阶段 0 控制台拓扑 | 用户提供实例“网络与安全”页面：一个主网卡、无辅助网卡，展示的安全组与已读取目标一致；页面有远程连接入口，但尚未验证 Workbench 实际恢复连通性。两条现有 SSH 规则均不作为本计划管理对象。 | 控制台拓扑基线 | 部分完成 | 用户与 Codex |
| 2026-08-29 | 阶段 0 恢复与写权限审查 | 用户确认 Workbench 可用。官方授权信息确认 `AuthorizeSecurityGroup` 为全部资源授权，条件键不能限制目标安全组或端口；直接本机长期凭证写入路径停止，未调用写接口。 | 写权限审查 | 设计阻塞 | 用户与 Codex |
| 2026-08-29 | 阶段 0 架构取舍 | 用户确认不增加 FC 或其他中央执行器，采用新专用 RAM 身份在本机直调 ECS API；接受 `AuthorizeSecurityGroup` 无法按目标安全组或端口缩小的 IAM 范围。 | 写权限审查 | 待准备 | 用户与 Codex |
| 2026-08-29 | 阶段 0 策略修正 | 用户报告已保存策略修正：`AuthorizeSecurityGroup` 使用全部资源范围，读取与撤销动作保持目标安全组范围；尚未由本机实际调用验证。 | 写权限审查 | 待验证 | 用户与 Codex |
| 2026-08-29 | 阶段 0 受控实跑 | 本机专用身份的首次数组参数写请求被拒绝，复查未留下规则；改用 CLI 标量规则参数后，成功新增并查询确认一条当前公网 `/32` 的受管 TCP SSH 规则。未执行任何删除。 | 项目外受控实跑 | 部分完成 | Codex |
| 2026-08-29 | 阶段 0 连通性验证 | Workbench CLI 列表查询成功；新增受管规则后以目标 SSH 别名执行无输出连接测试失败。保留全部规则，转入只读诊断。 | 项目外受控实跑 | 诊断中 | Codex |
| 2026-08-29 | 阶段 0 目标一致性诊断 | `ssh -G` 显示别名直连 22 端口且无跳板；Workbench 查询到的目标 ECS 与别名解析地址不一致，远端 sshd 日志没有对应连接。确认测试流量未到达受控安全组。 | 项目外受控实跑 | 等待确认 | Codex |
| 2026-08-29 | 阶段 0 出站路径澄清 | 用户报告本机运行代理；禁止代理的 HTTPS 出口探测不能代替 SSH 实际来源。后续必须在确认的 SSH 目标上观察来源或证明探测与 SSH 同路由。 | 本计划当前阻塞项 | 等待确认 | 用户与 Codex |
| 2026-08-29 | 阶段 0 目标确认复测 | 用户明确指定本计划目标并成功建立 Workbench 会话；加载生产 SSH 配置后，`motorcycle-manual-prod` 直连同一目标 ECS 成功。先前默认配置下的地址不一致属于检查未加载 `-F` 配置造成的诊断偏差。 | 项目外受控实跑 | 通过 | 用户与 Codex |
| 2026-08-29 | 阶段 0 实际来源同步 | 从真实 SSH 会话提取来源并只记录哈希；代理环境下 HTTPS 探测哈希不同，未使用探测值。以实际来源新增并确认 `/32` 规则，随后撤销上一条受管旧规则，最终 SSH 重连成功。 | 项目外受控实跑 | 通过（独立复核） | Codex |
| 2026-08-29 | 阶段 0 断连前来源探测 | `myip.ipip.net` 与 `ip.3322.net` 两个中国直连 IPv4 回显端点返回相同哈希，且与真实 SSH 会话来源一致；可在 SSH 断开时先做双端点探测，任一不一致即停止写入。 | 项目外受控实跑 | 通过（独立复核） | Codex |
| 2026-08-29 | 阶段 0 规则归属复核 | 目标安全组同时存在 Workbench/system-created 与既有无描述规则；所有非 `tunnelpad-dynamic-ssh-managed` 规则均保留，动态流程只管理精确描述匹配项。 | 项目外受控实跑 | 通过（独立复核） | Codex |

### 验证方式

- 阶段 0：复跑样本矩阵全部项目；审阅证据文档不含敏感值；独立复核 RAM 作用范围、安全组反向检查、实跑的规则收敛和 SSH 实连。
- 阶段 1：将阶段 0 已通过流程接入仓库后，做幂等、网络切换、重复执行、新增失败、删除失败和并发锁测试；不得用未通过阶段 0 的目标在项目中试错。
- 阶段 2：验证自动前置失败时不启动隧道，退出或回滚后独立命令仍可运行，且不把凭证写入 TunnelPad 配置。

### 测试覆盖率

- 阶段 0：八项样本矩阵的运行证据已形成；实跑前置检查、双端点同路由来源探测、规则收敛、SSH 实连、证据脱敏审阅和独立准入复核均已通过。阶段 1 已在独立复核后启动并完成实现验证。
- 阶段 1：`Tests/update-ecs-ssh-ip-test.sh` 覆盖当前规则幂等、端点不一致、私网 IPv4 拒绝、首次新增、授权响应异常后的重新查询收敛、旧规则轮换、授权失败、撤销失败、撤销响应异常后的重新查询收敛、规则歧义、云端读取失败、锁冲突、配置缺失和 `--check` 只读，共 14 个 fixture 场景；真实 ECS 只读回归另行记录。
- 阶段 2：在阶段 1 覆盖基础上，增加前置调用成功、失败、取消和回滚用例；ECS 专用测试 11 passed、全量 Swift 测试 82 passed、Rust 测试 51 passed、阶段 1 shell fixture 14 passed。

### 完成条件

- 阶段 0 完成：八项样本矩阵均有脱敏证据；确认直连出站或记录不可实施原因；目标安全组实际关联且无宽泛 SSH 绕过；新专用身份不使用 FullAccess；项目外受控实跑证实“先新增、确认后清理”和 SSH 实连；独立完成复核明确通过。

## 阶段 1 收口记录

阶段 1（仓库内独立同步命令实现与验证）已完成。该阶段按用户确认保持与 TunnelPad 启动链路隔离，阶段 2 不继承其准入状态。

### 范围

- 在仓库内实现独立命令 `scripts/update-ecs-ssh-ip`，先于任何 TunnelPad 启动链路调用。
- 复用阶段 0 已验证的双端点来源探测、严格公网 IPv4 校验、精确受管规则识别、先增后删和本地互斥锁边界。
- 使用仓库外的非秘密配置与专用阿里云 CLI profile；日志只记录脱敏标识、哈希、结果和时间。
- 补齐可重复测试、故障说明和 Workbench 恢复操作。

### 非目标

- 不修改 TunnelPad v1 UI、`config.json` schema、启动流程或 launchd 执行器。
- 不自动管理非 `tunnelpad-dynamic-ssh-managed` 规则，不按端口批量删除，不读取或迁移现有 FullAccess 凭证。
- 不把 Workbench 改造成通用端口转发、SFTP 或 IDE Remote SSH 通道。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 行为迁移基线：阶段 0 项目外受控实跑已证明双端点同路由、规则收敛和 SSH 重连；阶段 1 已据此建立可执行 fixture。 |
| 样本矩阵 | 可执行 fixture 覆盖：双端点一致且规则已是最新、双端点不一致、私网/保留 IPv4、无受管旧规则、先增后删、写入失败、未知响应重新查询、撤销失败、受管规则歧义、云端读取失败、锁冲突和 profile 缺失。 |
| 验证方式 | 已用本地 fixture/mock API 覆盖校验、精确匹配、幂等、先增后删、未知响应收敛、失败保留、锁和日志脱敏，并用项目外当前 ECS 完成只读回归。 |
| 失败/回滚边界 | 任一探测、权限、锁或查询异常均不写入；新增未确认保留旧规则；撤销失败保留新旧规则并报告；Workbench 作为恢复通道。 |
| 当前阻塞项 | 无；阶段 1 实现、验证和独立复核已完成。 |
| 最新独立准入复核 | 2026-08-29：通过（达到完成标准）。 |

### 阶段证据

- 阶段 1 实现与验证：`docs/data-quality/ecs-dynamic-ssh-ip-stage1-implementation-20260829.md`。

### 阶段 1 冻结契约

- 命令：`scripts/update-ecs-ssh-ip`；无参数执行同步，`--check` 只探测并读取云端状态，`--help` 输出用法，未知参数退出。
- 外部配置：默认读取仓库外 `$HOME/.config/tunnelpad/ecs-ssh-ip.env`，可用 `TUNNELPAD_CONFIG_FILE` 覆盖；阶段 2 子进程也可直接继承/注入 `TUNNELPAD_ALIYUN_CONFIG`，指向仓库外阿里云 CLI 配置/凭证路径。必须提供 `TUNNELPAD_ALIYUN_CONFIG`、`ALIBABA_REGION_ID` 和 `ECS_SECURITY_GROUP_ID`；`ALIBABA_PROFILE` 默认 `tunnelpad-ecs-sync`。两个探测端点默认使用阶段 0 已验证的 `https://myip.ipip.net` 与 `https://ip.3322.net`，均可由配置覆盖。
- 依赖与运行时覆盖：使用本机已有 `curl`、`jq`、`aliyun`、`shasum`；测试可通过 `CURL_BIN`、`ALIYUN_BIN` 等环境变量注入 fixture，不改变生产默认路径。
- 云端规则匹配：只匹配入方向、TCP、`22/22`、`accept`、`intranet` 且描述精确为 `tunnelpad-dynamic-ssh-managed` 的规则；最多允许一条，零条表示首次新增，多条为歧义并停止。所有其他规则保留。
- 同步顺序：双端点返回同一个严格校验的公网 IPv4 后，先按 `<ip>/32` 新增并查询确认，再按已确认的旧规则 ID 撤销；新增未确认保留旧规则，撤销失败保留新旧规则。
- 安全边界：每次写请求带唯一 `ClientToken`；本地 `mkdir` 互斥锁防并发；日志只记结果、脱敏资源/规则标识和地址哈希，不记原始 IP、凭证、私钥或完整资源 ID。
- 退出码：`0` 成功或已是最新；`2` 参数、配置或依赖无效；`3` 探测失败、IPv4 无效或双端点不一致；`4` 云端读取失败或受管规则歧义；`5` 新增失败或新增后未确认；`6` 撤销失败；`7` 锁冲突。

### 阶段 1 样本矩阵

| 样本 | 可执行命令或 fixture | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|
| 当前规则幂等 | `Tests/update-ecs-ssh-ip-test.sh` 的 `current` fixture | 退出 `0`，无新增/撤销 | 写入或撤销任一被调用 | 测试标准输出；临时 fixture 自动清理 |
| 双端点不一致 | 同测试的 `mismatch` fixture | 退出 `3`，不调用云端 | 仍调用 Describe/Authorize/Revoke | 测试标准输出 |
| 私网 IPv4 | 同测试的 `invalid-ip` fixture | 退出 `3`，不调用云端 | 私网/保留地址被写入安全组 | 测试标准输出 |
| 首次同步 | 同测试的 `first-sync` fixture | 退出 `0`，新增并确认一条受管规则 | 未新增、未确认或误撤销非受管规则 | 测试标准输出 |
| 旧规则轮换 | 同测试的 `rotate` fixture | 退出 `0`，先新增确认再按旧 ID 撤销 | 按端口批量删除、顺序反转或非受管规则消失 | 测试标准输出 |
| 新增失败 | 同测试的 `authorize-fail` fixture | 退出 `5`，旧规则保留 | 旧规则被撤销或错误报告成功 | 测试标准输出 |
| 新增响应异常 | 同测试的 `authorize-uncertain` fixture | 重新读取后确认已落云则继续收敛 | 把未知响应直接当作未执行或重复新增 | 测试标准输出 |
| 撤销失败 | 同测试的 `revoke-fail` fixture | 退出 `6`，新旧规则均保留 | 旧规则被误删或新规则消失 | 测试标准输出 |
| 撤销响应异常 | 同测试的 `revoke-uncertain` fixture | 重新读取后确认旧规则已消失则收敛成功 | 把未知响应直接当作失败或重复撤销 | 测试标准输出 |
| 受管规则歧义 | 同测试的 `ambiguous` fixture | 退出 `4`，不写云端 | 仍执行新增或撤销 | 测试标准输出 |
| 云端读取失败 | 同测试的 `describe-failure` fixture | 退出 `4`，不写云端 | 读取异常时仍执行新增或撤销 | 测试标准输出 |
| 本地锁冲突 | 同测试的 `lock` fixture | 退出 `7`，不探测、不调用云端 | 锁冲突时仍有外部调用 | 测试标准输出 |
| 配置缺失 | 同测试的 `missing-config` fixture | 退出 `2`，不调用外部命令 | 继续探测或调用 ECS | 测试标准输出 |
| 只读检查 | 同测试的 `check-only` fixture | 退出 `0`，只 Describe，不写云端 | `--check` 触发新增或撤销 | 测试标准输出 |

### 测试覆盖率

- 阶段 1 已覆盖双端点 IPv4 校验、私网/保留地址拒绝、规则精确匹配、已是最新时幂等、`ClientToken`、先增后删、授权/撤销未知响应重新查询收敛、云端读取失败、失败保留、锁冲突、profile 缺失和日志脱敏；14 个 fixture 场景及一次真实 ECS `--check` 回归均通过。

### 完成条件

- 阶段 1 完成：仓库内独立命令、测试、外部配置示例和故障边界齐备；其行为与阶段 0 已通过流程等价且不丢失已有 SSH 入口；独立完成复核通过。

## 当前阶段

当前阶段为阶段 2（基于 Rust Core 唯一 owner 的 SSH 启动前自动集成），已完成。阶段 1 已完成；阶段 2 已通过自动化验证和真实 App 端到端验收。

### 范围

- 以现有 `scripts/update-ecs-ssh-ip` 作为唯一同步实现；阶段 2 只设计其在 TunnelPad 启动/重启前的调用边界，不复制 ECS API 逻辑到 Rust Core。
- 对现有 SSH 命令识别契约判定为 SSH 的隧道，在 Rust Core 执行 `start`/`restart` 前执行一次同步前置检查；菜单栏、详情页和兼容入口均不得绕过同一检查边界。
- 前置检查成功后才允许调用 Rust Core 的生命周期命令；失败、超时或取消时不得调用 Rust Core 的 `start`/`restart`，并向 UI 提供可诊断的失败结果。
- 非 SSH 命令保持当前启动/重启行为；阶段 2 不要求新增配置字段、设置项或凭证输入。
- 同步脚本固定从打包 App 的 `Contents/Resources` 定位，由 `/bin/bash` 调用；不依赖仓库工作树路径，也不把脚本路径或凭证路径写入 `config.json`。`TUNNELPAD_CONFIG_FILE` 与 `TUNNELPAD_ALIYUN_CONFIG` 仅作为外部路径环境输入。
- 在 `TunnelManager` 编排边界调用独立 ECS 前置适配器；同步和异步兼容入口都执行同一 SSH 分类与前置检查。Finder 环境只继承冻结的 `PATH`、`HOME`、`TMPDIR`、外部配置/CLI 配置路径及阶段 1 运行参数变量，不继承任意未列入 allowlist 的环境变量。

### 非目标

- 不修改 Rust Core 的生命周期 owner、C ABI、配置 owner、launchd bootstrap/bootout/status 实现或 `config.json` version=1 schema。
- 不把 `scripts/update-ecs-ssh-ip` 的凭证、地域、安全组 ID 或 IP 端点写入 `config.json`、TunnelPad UI 或日志；TunnelPad 不读取或持久化 AccessKey/Secret 值。
- 不为非 SSH 命令执行 ECS 同步，不按每条 `TunnelConfig.command` 注入 wrapper，不改变现有 SSH 命令参数和 launchd label。
- 不在本阶段增加定时任务、全局网络监控、UI 凭证管理、独立“同步公网 IP”设置页或 Workbench 通道改造。

### 阶段准入摘要

| 字段 | 内容 |
|---|---|
| 准入状态 | 已完成 |
| Step 0 | 架构探索基线：Rust Core 阶段 5 已完成并关闭；当前启动/重启调用路径、SSH 命令识别、version=1 配置和独立同步命令契约均已通过只读核对。 |
| 样本矩阵 | 阶段 2 Step 0 证据已固定 owner、所有启动入口、SSH/非 SSH 分类、独立命令、路径环境和 schema 隔离；实现矩阵覆盖外部命令成功、失败、超时、取消、路径注入及 Rust 调用顺序。 |
| 验证方式 | 已使用可注入的外部进程 runner 和 Rust owner fake 验证成功、非零退出、超时、取消、重试、路径环境传递和无启动副作用，并完成 Swift/Rust 回归、打包资源/签名校验、敏感值扫描和治理检查；真实 App→同步脚本→ECS→隧道→SSH 正向、重启、负向失败隔离和恢复闭环均已通过。 |
| 失败/回滚边界 | 前置同步非零、超时、取消或输出无法分类时，不创建 Rust 操作代次、不调用 Rust `start`/`restart`，保持隧道状态不变；非 SSH 路径不变；回滚只撤销前置适配器、资源复制和 manager 调用切片。 |
| 当前阻塞项 | 无。Finder/launchd 环境兜底、真实 App 启动/重启、前置失败隔离、恢复重试、ECS 规则读取、隧道探针和本机直连 SSH 均已复验。 |
| 最新独立准入复核 | 2026-08-31：通过真实完成验收；阶段 2 达到完成标准。 |

### 阶段证据

- 阶段 2 Rust owner、启动入口、实现与验收证据：`docs/data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md`。

### 阶段 2 实现冻结

- 资源定位：生产 App 从 `Bundle.main.resourceURL/update-ecs-ssh-ip` 定位脚本；构建脚本复制到 `.app/Contents/Resources`，运行时固定调用 `/bin/bash <resource>/update-ecs-ssh-ip`，不依赖仓库工作树。
- 调用时机：`TunnelManager.start`、`startAsync`、`restart`、`restartAsync` 在创建 Rust 操作代次前调用同一前置适配器；`SSHCommand.isSSH` 为 false 时直接放行，不启动外部进程。
- 进程契约：同步和异步调用均执行脚本无参数的真实同步流程；退出码 `0` 才继续 Rust 生命周期。阶段 1 退出码映射为脱敏 UI 错误，不把 stdout/stderr 原文写入 UI 或日志。
- 环境契约：只向子进程传递 `PATH`、`HOME`、`TMPDIR`、`TUNNELPAD_CONFIG_FILE`、`TUNNELPAD_ALIYUN_CONFIG`、阶段 1 的非秘密参数和测试用 binary override；凭证内容不进入 App。
- 超时与取消：默认 30 秒；超时抛出前置失败并终止子进程；异步 Task 取消终止子进程并在 Rust 调用前返回；同一隧道的 busy/generation 门禁阻止重复启动。
- 重试与回滚：前置失败只发布可诊断错误并释放 busy 状态，用户再次点击现有启动/重启入口即可重试；不修改 `config.json`、Rust Core、launchd plist 或阶段 1 独立命令。

### 实施步骤

1. 已以阶段 5 完成后的 Rust owner、Swift FFI 门面和现有启动入口建立阶段 2 基线，未把旧 Swift 生命周期实现重新作为集成目标。
2. 已冻结并实现“仅 SSH 命令、所有启动/重启入口、非 SSH 保持现状”的内部 `preStart` 行为契约，覆盖成功、失败、超时、取消和重试结果。
3. 已选择 `TunnelManager` 统一编排前置方案，保持 `TunnelConfig.command`、Rust owner 和 launchd plist 不变。
4. 已将同步脚本纳入 `.app/Contents/Resources`，并固定 `TUNNELPAD_CONFIG_FILE`、`TUNNELPAD_ALIYUN_CONFIG` 等允许传入的外部路径环境、工作目录、Finder `PATH`、超时、子进程终止、stdout/stderr 脱敏和阶段 1 退出码到 UI 错误的映射。
5. 已完成不调用真实 ECS 或真实用户隧道的 fixture：前置成功才调用 Rust start/restart；失败、超时、取消和非 SSH 分类均不产生 Rust 生命周期副作用。
6. 已完成独立准入复核、代码实现、自动化回归和真实 App 端到端验收；阶段 2 已达到完成标准并同步 `PLAN_MAP.md`。

### Step 0 证据

本阶段 Step 0 采用架构探索基线类型，已通过只读命令固定 Rust owner、启动入口、SSH 分类和阶段 1 命令契约；证据见[阶段 2 Step 0 基线](../data-quality/ecs-dynamic-ssh-ip-stage2-step0-20260831.md)。该证据不调用真实 ECS 写接口、不启停真实隧道，也不包含凭证或原始公网 IP。

### 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | Rust owner 已完成切换 | `rg -n 'Rust Core 是唯一生命周期 owner|Swift App|config.json.*version|launchd' docs/adr/0001-rust-core-single-owner.md docs/migrations/tunnelpad-rust-owner-cutover.md Sources/TunnelPadCore/RustCoreClient.swift | head -n 80` | 集成目标是 Swift UI/FFI 门面到既有 Rust owner，不重新引入 Swift 生命周期 owner | 出现旧 Swift owner 作为阶段 2 目标或配置 schema 漂移 | 阶段 2 Step 0 证据 |
| 2 | 所有启动/重启入口 | `rg -n 'func (start|startAsync|restart|restartAsync)|startAsync\(|restartAsync\(' Sources Tests --glob '*.swift'` | 菜单栏、详情页和兼容入口均能映射到统一的 manager 前置边界 | 任一启动/重启入口可绕过前置检查 | 阶段 2 Step 0 证据 |
| 3 | SSH 与非 SSH 分类 | `swift test --filter SSHCommandTests`；静态核对 `Sources/TunnelPadCore/SSHCommand.swift` | `/usr/bin/ssh`/`ssh` 命令进入前置候选；`sshd`、`autossh` 和空命令不被误判为 SSH | 分类不稳定或非 SSH 进入 ECS 同步 | 阶段 2 Step 0 证据；阶段 2 契约测试 |
| 4 | 独立同步命令契约 | `bash -n scripts/update-ecs-ssh-ip && scripts/update-ecs-ssh-ip --help` | 命令可被外部调用；退出码和仓库外配置边界保持阶段 1 冻结值 | 修改阶段 1 命令参数、读取仓库内凭证或 help 触发云端写入 | 阶段 2 Step 0 证据 |
| 5 | `.app` 资源分发 | `./scripts/build_app.sh --skip-tests`；检查 `dist/TunnelPad.app/Contents/Resources/update-ecs-ssh-ip`、`codesign --verify --deep --strict dist/TunnelPad.app` | 脚本随包存在且签名校验通过；不依赖仓库路径 | 资源缺失、未签名或仍调用开发工作树脚本 | 阶段 2 实施证据 |
| 6 | 外部路径环境注入 | 阶段 2 fake process runner 注入 `TUNNELPAD_CONFIG_FILE` 和 `TUNNELPAD_ALIYUN_CONFIG`；不读取真实凭证内容 | 子进程收到仓库外路径，能使用外部配置完成预检；App 不持久化路径对应内容或 Secret | 路径被写入 `config.json`、凭证内容进入 UI/日志，或环境变量被静默丢弃 | 阶段 2 实施证据 |
| 7 | 前置成功 | `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter ECSPreStartIntegrationTests` | 外部命令退出 `0` 后只调用一次 Rust `start`/`restart`，不改 command/schema | Rust 调用早于前置成功、重复调用或配置发生写入 | 阶段 2 实施证据 |
| 8 | 前置失败、超时或取消 | 同一 `ECSPreStartIntegrationTests` 测试组 | 返回可诊断失败；Rust `start`/`restart` 未调用；现有状态保持 | 隧道仍被启动、取消后迟到启动、原始 stderr/凭证泄露 | 阶段 2 实施证据 |
| 9 | 非 SSH 与 schema 隔离 | `cargo test --manifest-path rust/Cargo.toml`；`rg -n 'config\.json|AccessKey|Secret|TUNNELPAD_ALIYUN_CONFIG' Sources rust Tests docs/plans/ecs-dynamic-ssh-ip.md` | Rust 现有测试通过；不新增 config 字段，不把凭证值纳入 App | Rust owner/schema 改动、凭证进入普通配置或日志 | 阶段 2 Step 0/实施证据 |
| 10 | 治理反向引用 | `plan-governance-cli check .`、`git diff --check`，并搜索 `ECS 动态 SSH 公网 IP 同步|阶段 2|启动链路|Rust Core|草案为准|以草案为事实源|详见草案` | 状态、当前阶段、关键边界和证据链接一致，背景设计材料不重新成为事实源 | 计划索引漂移、旧阶段 1 叙述误作当前事实或出现未声明路径 | `docs/PLAN_MAP.md` 与阶段 2 证据 |
| 11 | Finder/launchd 运行环境 | `ECSPreStartChecker.defaultEnvironment(from:)` 的自动化测试；并以最小 PATH/HOME 输入验证合并 Homebrew/系统路径与当前用户 home | App 启动的子进程能找到 `aliyun`、读取默认外部配置并完成只读检查 | PATH/HOME 未补齐导致退出码 2；修复后自动化测试和真实 App 启动均通过 | 阶段 2 实施与端到端复核证据 |
| 12 | 真实 App 正向闭环 | 从新构建的 `dist/TunnelPad.app` 启动，触发一个真实 SSH 隧道的“启动/重启”入口；观察前置同步、Rust/launchd 状态、隧道探针/转发端口，再执行本机直连 SSH | `App → Contents/Resources 脚本 → ECS 规则收敛 → Rust/launchd 隧道 → SSH/探针` 连续成功，且只调整受管规则 | 任何一环未发生、顺序错误、规则未收敛、隧道未启动或 SSH/探针失败 | 端到端复核证据 |
| 13 | 真实 App 负向与恢复 | 在隔离外部配置/依赖条件下从 App 触发 SSH 启动，再恢复默认配置重试 | 前置失败时不调用 Rust/launchd；恢复配置后同一入口可重试成功 | 失败仍拉起隧道、恢复后无法重试或输出泄露原始 stderr/凭证 | 端到端复核证据 |

### 测试覆盖率

- 阶段 2 已新增并通过 12 项专用契约测试；全量 Swift 测试 83 项通过，Rust 测试 51 项通过，阶段 1 shell fixture 14 项通过。PATH/HOME 兜底修复已由自动化测试覆盖；真实 App 启动、重启、负向失败隔离、恢复重试、ECS 读取、探针和本机直连 SSH 均已通过。

### 完成条件

- 阶段 2 设计完成：上述行为边界、实现位置、外部命令调用契约（含 `TUNNELPAD_CONFIG_FILE`、`TUNNELPAD_ALIYUN_CONFIG` 路径注入）、失败/回滚边界、样本矩阵和测试映射已冻结，独立准入复核已明确达到 `待实施` 标准。
- 阶段 2 实现完成：自动集成通过成功/失败/超时/取消和回归验证；Finder/launchd 运行环境能找到依赖并读取仓库外配置；真实 App 正向闭环完成 `App → 同步脚本 → ECS → Rust/launchd → SSH/探针`，且负向恢复边界通过；非 SSH 行为、Rust owner、`config.json` version=1、阶段 1 独立命令和凭证隔离均保持；`.app` 资源和签名验收通过；独立完成复核通过。

## 后续阶段（粗粒度）

- 阶段 2 之后如需定时同步、UI 设置项、Keychain 凭证管理或更广泛的网络出口监控，另立阶段或专项计划，不在本阶段预设。

## 最新独立准入复核

| 字段 | 内容 |
|---|---|
| 日期 | 2026-08-31 |
| 阶段 | 阶段 2 |
| 结论 | 通过（达到完成标准） |
| 证据 | 修复后的 Release App 已完成真实启动与重启；前置同步 `mode=sync` 成功，launchd 目标运行、探针 `401`、本机直连 SSH 成功；缺失依赖时退出码 `2` 且未加载 launchd，恢复后可重试成功。 |
| 复核者 | Codex（独立复核轮次） |

## 独立复核记录

| 日期 | 类型 | 阶段 | 结论 | 证据 | 复核者 |
|---|---|---|---|---|---|
| 2026-08-29 | 阶段准入复核 | 阶段 0 | 通过（达到待实施标准） | 目标、权限、同路由双端点、规则精确归属、先增后删、SSH 重连和文档脱敏均通过复核；阶段 0 已完成，阶段 1 不自动改变准入状态。 | Codex（独立复核轮次） |
| 2026-08-29 | 阶段完成复核 | 阶段 1 | 通过（达到完成标准） | 独立复跑语法、14 个 fixture、55 项 Swift 测试、治理差异检查、敏感值扫描和真实 ECS `--check`；行为与阶段 0 已验证流程等价，严格 IPv4 校验、授权/撤销未知响应重新查询收敛和云端读取失败不写入，未执行真实云端写操作，TunnelPad 启动链路保持隔离。 | Codex（独立复核轮次） |
| 2026-08-31 | 阶段准入准备 | 阶段 2 | 尚未进行（设计中） | 用户确认 SSH-only、所有启动入口统一前置、非 SSH 保持现状；Rust owner、现有启动入口和阶段 1 命令契约已完成只读基线，待冻结实现契约和补齐 fixture。 | Codex（设计准备） |
| 2026-08-31 | 阶段准入复核 | 阶段 2 | 通过（达到待实施标准） | 当前目标、范围/非目标、Step 0、样本矩阵、失败/回滚、30 秒超时、取消终止、路径环境 allowlist、脱敏映射和实现回滚边界已冻结；`PLAN_MAP.md` 已同步，无 ECS 计划自身阻塞项。 | Codex（独立复核轮次） |
| 2026-08-31 | 阶段完成复核 | 阶段 2 | 通过（达到完成标准） | ECS 专用 11 项契约测试、全量 Swift 82 项、Rust 51 项、阶段 1 shell fixture 14 项均通过；`.app/Contents/Resources/update-ecs-ssh-ip` 存在且可执行，`--help` 不触发云端操作，App 签名校验通过；未执行真实 ECS 写操作，未读取真实凭证内容。 | Codex（独立复核轮次） |
| 2026-08-31 | 阶段准入复核（真实端到端） | 阶段 2 | 未通过 | 用户报告真实 App 端到端未跑通；复核发现自动化测试均使用 fake/fixture，且 Finder/launchd 最小 PATH 不含 `/opt/homebrew/bin` 时，打包同步脚本 `--check` 以退出码 2 失败；加入 Homebrew 路径后只读检查成功。真实 App 启动 SSH 隧道及直连 SSH 闭环尚未补齐。 | 用户与 Codex |
| 2026-08-31 | 阶段实现修复复核 | 阶段 2 | 部分通过 | `ECSPreStartChecker.defaultEnvironment` 已补齐稳定 PATH 与当前用户 HOME；专用测试 12 项、全量 Swift 83 项、Rust 51 项和 shell fixture 14 项通过；打包资源/签名通过。真实 App 启动 SSH 隧道及直连 SSH 闭环仍未复验。 | Codex（实现复核） |
| 2026-08-31 | 阶段完成复核（真实端到端） | 阶段 2 | 通过（达到完成标准） | 正常环境 App 启动/重启 `admin-tunnel` 后 launchd 运行、探针 `401 ✓`、本机直连 SSH 退出码 `0`；负向依赖失败返回脱敏退出码 `2` 且目标服务未加载；恢复正常环境后再次启动成功；ECS `--check` 和同步日志均确认安全组读取成功且无需写入。 | Codex（独立复核轮次） |

## 风险和回滚

- 凭证或策略过宽：不使用现有 FullAccess CSV。用户已接受本机直调所需 `AuthorizeSecurityGroup` 的全部资源 IAM 范围；专用凭证只保存在本机受保护 profile，程序固定输入边界。若未来专用凭证泄露，立即在 RAM 禁用/删除该专用凭证，且不影响现有 SSH 私钥。
- 安全组误配：阶段 0 项目外实跑和阶段 1 仓库命令都固定为先新增、确认后清理；失败保留旧规则。Workbench 是恢复通道。
- 出站 IP 误判：端点不一致、代理、VPN、透明 TUN 或跳板均不把 IP 查询结果写入安全组；改由在实际 SSH 目标上观察来源、证明同路由，或保持手动访问。
- 并发执行：本地锁失败或持锁不明时不写入；由操作者检查后重试。

## 关联 ADR、迁移、spec 或 issue

- TunnelPad v1：范围隔离对象；本计划不修改其 v1 范围，也不依赖其阶段状态。
- [ECS 动态 SSH 公网 IP 更新方案（背景材料）](../ecs-dynamic-ssh-ip-design.md)：初始方案推导，不是规范事实源。
