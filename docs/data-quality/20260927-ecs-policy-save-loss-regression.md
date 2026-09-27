# ECS 策略编辑后丢失：复现、修复与 MacBook 验收（2026-09-27）

## 现象与当前边界

用户报告在 `motorcycle-local-docker` 的设置页勾选“连接前同步阿里云 ECS 安全组”并保存，**立刻重新打开**仍未勾选；随后点击“刷新”也一样。截图中的其他选项含 `autoStart=true`。本机 `config.json` 于 2026-09-27 17:01:42 CST 更新；与部署前备份比较，三个隧道中仅 motorcycle 的 `autoStart` 从 false 变为 true，`ecsSyncPolicy` 仍缺失。文件权限为 `0600`，MacBook 运行的是本轮签名部署的新版 App 和 Rust 动态库。用户已明确要求保持当前实际配置；修复与部署已获授权。

缺字段按当前契约等效 `disabled`。调查及修复验收开始时，motorcycle 同时是 `autoStart=true`、ECS 同步关闭；验收后用户重新在新版 App 中选中 ECS `required`，最终状态见文末。

## 根因证据

1. `TunnelSettingsSheet.ecsSyncEnabled` 的 setter **按源码意图**把勾选映射为 `form.ecsSyncPolicy = .required`；`TunnelFormState.makeTunnel` 把表单值传入 `TunnelConfig`。当前尚无真实 UI 事件证据证明该 setter 在本次点击后实际提交了 required。
2. `TunnelManager.updateTunnelAsync` 将候选配置交给 `RustCoreClient.saveConfig`，再通过 Rust owner 的 `ConfigStore.save` 写盘。Rust 模型及 JSON 反序列化均支持 `ecsSyncPolicy`。
3. 最终写盘使用 `rust/tunnelpad-core/src/apple_json.rs` 的 `app_config_to_apple_json → render_tunnel`。`render_tunnel` 的固定字段清单没有 `ecsSyncPolicy` 分支，所以无论输入为 `required`、`disabled` 还是缺字段，落盘结果都缺该字段。下次**从磁盘重新加载**即按 `disabled` 显示。文件中 `autoStart` 正常变化而 ECS 字段缺失，与这条路径完全吻合。
4. 现有 Apple JSON 字节对等测试只覆盖旧字段，没有策略字段的写盘/再读取样本。阶段 1 的 Swift/Rust 配置解析和前置测试未覆盖这个自定义写盘器，故未发现回归。

这是已确认的**磁盘持久化缺陷**。`TunnelManager.updateTunnelAsync` 在写盘成功后会先把内存配置设为提交候选，Rust owner 的 `snapshot` 也读取其内存副本，然后才关闭弹窗。用户明确说立刻重开就未勾选，所以写盘缺陷**单独不足以解释立即重开的表现**：还需在实际 Toggle → 表单候选 → manager 配置 → sheet 再呈现之间查明第二个状态问题。点击“刷新”后仍未勾选则可由已确认的磁盘丢字段解释。不能把两个时序混为同一条已证实根因。

在旧版真实 UI 上再次复现：复选框从 `Value: 0` 变为 `Value: 1`，点击保存后弹窗自动关闭；磁盘文件仍缺 `ecsSyncPolicy` 且与复现前备份 SHA-256 完全相同；立即重开复选框为 `Value: 0`。复现前已将配置与旧 App 备份到 `~/Library/Application Support/TunnelPad/backups/20260927-ecs-save-fix.ythyagon/`（目录 `0700`、配置 `0600`），复现未改变实际配置或启动隧道。这说明开关的可见绑定确实更新，但尚不能从 UI 黑盒证据区分保存路径中的内存回退和再次呈现时的状态重用。

GitNexus 对 `app_config_to_apple_json` 的 upstream impact 给出 `LOW`：直接调用者为 `ConfigStore.save`，图中关联 demo install/remove 两类流程。此静态风险值未覆盖业务语义：生产 owner 保存配置亦经过 `ConfigStore.save`，字段丢失会改变下次启动的 ECS 安全组门禁，按数据完整性/安全行为评估为高风险。对 `render_tunnel` 和 owner 测试函数的 `UNKNOWN` 结果已用文本调用点与 Rust 测试入口核对，未把空 caller 集当作安全结论。

## 修复与验收

- `render_tunnel` 现在按键序输出可选 `ecsSyncPolicy`：`Some(Required)` 写 `required`，`Some(Disabled)` 写 `disabled`，`None` 继续省略，保留旧配置缺字段默认关闭的约定和 Apple JSON 格式。Apple JSON 键序、`ConfigStore.save → load` 临时目录回读覆盖三种状态；owner 策略升级测试还断言保存成功后磁盘可回读 required。
- Rust 全套 `101 + 6 + 1 + 7` 通过；owner 新断言定向复跑通过，`cargo fmt --all --check` 通过。Swift 全套第一次默认并行运行停在 `IPDriftRecoveryTests.testConcurrentRuntimeRecoverySharesSingleECSPreflightByResource`，该测试的 4 条断言失败，约 8 分钟后终止；单独复跑该项通过，`TunnelRemarksTests` 6 项、`RustCoreClientTests` 3 项、`TunnelManagerTests` 10 项通过；全套串行复跑 **221 通过、0 失败、1 跳过**（6 秒）。本次 Swift 代码未改，保留第一次并行失败记录，不把串行通过写成默认并行通过。
- 隔离目录 `/tmp/tunnelpad-ecs-policy-save-fix/TunnelPad.app` 完成 Rust/Swift Release 构建与 ad-hoc 签名，候选及 MacBook 部署包均通过严格签名校验，主程序和 Rust 动态库与候选逐字节一致。部署前确认三条受管隧道未加载；旧 App 正常退出后，以临时 `autoStart=false` 启动新 App，避免验收期间自动拉起 motorcycle；App 稳定后逐字节恢复用户原配置并显式刷新。备份在上述受限目录内，Mac mini 未操作。
- 新版真实 UI 上，motorcycle 原始开关为 0、`autoStart` 为 1；勾选 ECS 后开关变为 1，保存关闭弹窗，磁盘 `ecsSyncPolicy=required`；立刻重开仍为 1，点击“刷新”后重开仍为 1。旧版的同样操作会丢字段并重开为 0。没有证据支持再改 `.sheet` 状态逻辑，因此本次只修复写盘器。测试结束时曾用备份逐字节恢复旧配置并刷新核对 0/1；其后用户亲自在新版 App 中再次选中 ECS `required`。复核最终落盘为 motorcycle `ecsSyncPolicy=required`、`autoStart=true`，其他两条仍缺字段；重开设置显示 1/1，配置权限 `0600`。三条受管 label 均未加载，MacBook 本机 API `/api/health` HTTP 200。此次未启动隧道或修改 ECS 安全组。
- 新增写盘范围由未参与实现的 `ecs_save_review` 子代理完成一次 high 独立只读复核，未发现修复引入的可证实缺陷；其指出“立即重开”无法只从旧写盘路径推导，因此以真实 UI 结果闭环。静态图谱对 `CoreOwner.save_config` 报 CRITICAL，生产实现未改；`render_tunnel` 为 UNKNOWN 已经用文本调用点确认。CLI 无 `explain` 命令，未宣称完成 PDG/污点检查。

保存/回读缺陷已按用户报告的两个界面场景通过 MacBook 实测；最终 `motorcycle-local-docker` 为用户新选定的 `required`、`autoStart=true`，其他旧项仍按缺字段语义 `disabled`。`8081/admin` 业务探针的阶段 2 验收仍按独立问题保留，不能由本修复结果推断其已恢复。

计划治理检查仍因阶段 2 的 `8081/admin` 未解决阻塞项返回非零；这不回退本次保存缺陷的 UI 验收，也不代表整个 ECS 计划已经完成。首次检查提示的最新复核结论与历史记录不一致、地图缺少结构化阻塞行均已同步，复查仅剩真实业务阻塞。
