# TunnelPad 隧道备注说明与列表副标题：阶段 1–3 实施证据

日期：2026-08-31
计划：[TunnelPad 隧道备注说明与列表副标题](../plans/tunnelpad-tunnel-remarks.md)
基线：备注计划阶段 0 独立准入已通过；Rust Core 迁移阶段 5 已完成，Rust 继续作为配置读写、schema 校验和生命周期唯一 owner。

## 实施范围

- TunnelConfig 在 Swift/Rust 两侧增加 remark: String；旧配置缺失该字段时解码为空字符串，新保存配置显式写出。
- 新建和编辑表单均增加“备注说明”，保存 TunnelFormState 时去除首尾空白。
- 左侧列表副标题优先显示备注；备注为空或仅含空白时回退到原 launchd label。
- 备注不参与 command、executor、keepAlive、throttleInterval、probe、launchd label、日志路径或生命周期操作；刷新配置仍不隐式重启运行中的隧道。
- 新增跨语言差分 fixture，覆盖中文、emoji 和引号；未修改真实 config.json，未执行真实隧道启停、重启、删除或退出操作。

## 样本矩阵与结果

| # | 样本/验证 | 命令或操作 | 结果 |
|---|---|---|---|
| 1 | Rust 配置默认值、特殊字符和 Apple JSON | cargo test --manifest-path rust/Cargo.toml | 50/50 通过；包含缺失 remark 默认空值、Unicode/引号 round-trip 和 Apple JSON 键序 |
| 2 | Swift 配置兼容与 round-trip | swift test | 当前工作树 82/82 通过（包含并行 ECS 测试）；备注专项包含旧 JSON 缺省、Unicode/引号、空备注和 launchd label 不变 |
| 3 | 表单新建/编辑适配 | TunnelRemarksTests；TunnelManagerTests.testUpdateTunnelPersistsChangesAndClearsDroppedProbe | 5 项备注专项测试通过；备注首尾空白被清理、空备注可保存、已有备注可加载并持久化 |
| 4 | 左侧副标题 | TunnelRemarksTests.testSidebarSubtitlePrefersTrimmedRemark、testSidebarSubtitleFallsBackToLaunchdLabel | 有备注显示备注；空白备注回退 launchd label；不改变 label |
| 5 | Rust/Swift 配置 parity | ./rust/scripts/differential.sh | Swift harness 1/1、Rust differential 1/1 通过；config-store fixture 覆盖备注特殊字符，legacy-derive 投影同步 |
| 6 | C ABI 与发布 smoke | ./rust/scripts/smoke.sh | Rust 50/50 + differential 1/1、Swift 兼容断言、arm64、ad-hoc 签名全部通过 |
| 7 | Release App 与 AX | ./scripts/build_app.sh；Computer Use 读取隔离实例 AX | release .app、动态库、@rpath、Info.plist、签名通过；AX 可见主窗口、侧栏和新建表单“备注说明”/“用于说明隧道用途”控件。当前工作树 Swift 全量回归 82/82；打开表单后取消，未保存。 |
| 8 | 差异/治理反向引用 | git diff --check；rg -n 'tunnelpad-tunnel-remarks|remark|备注说明|刷新配置|下次重启|草案为准|以草案为事实源|详见草案' docs | 备注计划、索引和证据术语一致；未发现旧草案重新成为事实源 |

## 生命周期与安全边界

TunnelManager.updateTunnel 回归确认备注写入内存和 config.json 时既有命令、探针和重启参数保留；实现只调用配置保存和状态刷新路径，没有为备注增加 start/stop/restart/bootstrap/bootout。reloadConfig 的既有实现仍只重新加载配置、裁剪运行时状态并刷新展示。

AX 检查使用临时唯一 bundle ID 的实例读取窗口和表单；LaunchServices 读取标准用户 home，因此不把其真实配置中的列表内容作为“带备注”实机证据。带备注/空备注的副标题行为以 TunnelRemarksTests 的表示层测试为准；打开表单后取消，未保存。临时目录已移入废纸篓，当前 release 实例未被终止。

## 治理门禁说明

- 目标计划自身的阶段 0–3 内容、Step 0、完成条件、证据链接和独立复核记录已同步。
- plan-governance-cli check . 的仓库级结果需结合并行 ECS 计划现状阅读；若 strict-readiness 仍报告 ECS 阶段状态漂移，该错误不由备注改动引入，也不属于本计划范围。
- 提交前仍需运行 GitNexus detect_changes()，确认差分只覆盖备注实现、测试、fixture 和本计划文档；并行 ECS 文件保持原样。
