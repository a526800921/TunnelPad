# TunnelPad 界面优化——阶段 1 证据（界面减法与日志体验）

- 日期：2026-08-29
- 阶段：阶段 1（界面减法与日志体验）
- 基线：commit `b6c9796`（`swift test` 55 用例全过）；本阶段实施含一次行为口径变更（日志滚动交互改 ModelPad 式，用户 2026-08-29 改定）。

## 实施内容

- `MainPanelView.swift`：NavigationSplitView → HSplitView（固定侧栏，保留拖拽调宽，无折叠控件）；footer 移除「全部启动」「全部停止」（保留 刷新状态 / 重新加载 config.json）；消息栏仅渲染 `lastError`（红色错误），`lastMessage` 信息文案不再上屏。
- `LogView.swift`：LazyVStack 按行渲染末 500 行；「自动刷新」开关替换为 ModelPad 式「自动滚动」开关（默认开）；刷新静默（行内容与行数无变化不写状态、不重绘）。
- 实施中发现并修复：初版用 ScrollView+VStack 内 1px 标记的 onAppear/onDisappear 探测"视口是否在底部"，macOS 非懒加载容器中滚动不触发，翻看历史被拽回；按用户指示改为 ModelPad 同款「自动滚动」开关方案并重写（参照 ModelPad `App/Sources/Views/LogView.swift`）。
- 实施中发现并修复：`ForEach` 直接用 `EnumeratedSequence` 在 macOS 14 不可用（需 `Array` 包装）；PreferenceKey `defaultValue` 改计算属性消除 MutableGlobalVariable 告警。

## 验证记录

构建与测试：`swift build` 零告警；`swift test` 55 用例全过；`plan-governance-cli check .` 通过（严格模式剩余 ERROR 均为并行 ecs 计划在途状态，与本计划无关）。

样本矩阵逐行：

| # | 结果 | 证据 |
|---|---|---|
| 1 无侧栏折叠控件 | 通过 | 实机 AX 观察：工具栏无「隐藏边栏」按钮，侧栏固定（HSplitView）；截图核对 |
| 2 footer 仅两个刷新按钮 | 通过 | 实机 AX 观察：「全部启动/全部停止」消失，仅剩 刷新状态、重新加载 config.json |
| 3 自动滚动开=跟随 | 通过（ModelPad 式实现） | 实机：静置 7s，日志文件 +24 行，AX 滚动比值保持 0.99998（钉在底部）；旧底部检测实现同场景实测被拽回（已废弃重写） |
| 4 自动滚动关=回看不拽回 | 代码保证 + 实机待补 | 开关关闭后无任何滚动调用路径（与 ModelPad 逻辑一致）；实机点击开关时 AX 通道被环境中断，待随阶段 2/3 UI 验证补测 |
| 5 保存无信息文案 | 代码保证 + 实机待补 | `messageBar` 仅渲染 `lastError`（代码审查）；实机保存操作复验待随阶段 2/3 UI 验证合并执行 |
| 6 回归 55 用例 | 通过 | `swift build` 零告警、`swift test` 55/55 |

## 运行状态

- 阶段 1 构建部署后 reverse-ssh 未随新实例自启，已用 app 生成的 plist 走同一 `launchctl bootstrap` 路径恢复（`state = running`），日志出现新一轮 `forwarding_success`；admin-tunnel 经 UI 启动运行中（探针 401 ✓）。
- 用户指示（2026-08-29）：滚动交互定稿为 ModelPad 式，剩余实机补验项（矩阵 4、5）不阻塞后续阶段，随阶段 2/3 的 UI 验证合并执行；阶段 1 状态记为实施中（验证收尾）。
