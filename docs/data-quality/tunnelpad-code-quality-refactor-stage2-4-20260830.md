# TunnelPad 代码质量重构：阶段 2–4 实施与硬化证据（2026-08-30）

## 范围

本轮继续遵守“外部使用功能保持正常”的硬约束，收口阶段 2 的异步生命周期、阶段 3 的 UI 组合，以及阶段 4 的自动化硬化。真实用户隧道的启停、删除、接管或退出不作为自动化门禁；隔离 demo 生命周期用于验证同一套代码路径，用户配置和运行实例未被修改。

## 实施内容

### 阶段 2：异步生命周期与取消

- `TunnelLifecycleCoordinator` 统一 launchd/app 的启动、停止、重启、状态查询和删除停止路径；UI 入口通过 async 调用，保留同步兼容门面。
- `TunnelManager` 使用刷新代际、探针 actor/generation 和每隧道操作代际，丢弃取消任务或旧操作的迟到结果。
- app 执行器的 keepAlive 延迟重启在手动停止、删除和退出清理时失效；退出路径仍停止全部受管子进程。
- 配置重新加载和状态查询在后台执行；隐藏主窗口时暂停状态轮询，日志尾部读取在后台执行，避免主线程等待文件或 launchctl。

### 阶段 3：UI 组合与共享表单

- `MainPanelView` 只保留页面编排；侧栏行、详情操作、状态展示和状态枚举扩展移至 `TunnelDetailComponents.swift`。
- `TunnelFormState` 统一新建/编辑的字段状态、命令解析、探针校验、SSH `-v` 开关和默认值；保存入口保留原有字段、文案和 id 派生规则。
- 设置窗口切换执行器时使用异步更新入口；菜单栏单项启停保留，批量启动/停止入口未恢复。

### 阶段 4：失败注入与发布前硬化

- repository 可注入，覆盖保存失败回滚；异步删除覆盖 launchd 未加载时跳过 bootout 的兼容路径。
- GitNexus `detect_changes(scope=all, worktree=...)` 已执行；结果标记为高影响，回归以全量测试、构建和应用冒烟为门禁。
- 通过临时运行的 debug 可执行文件进行只读应用冒烟：TunnelPad 窗口成功出现，AX 树可见主面板、双隧道列表、状态点、探针状态、启动/停止/重启/删除按钮、日志区和刷新/复制控件；未点击启停或删除。

## 验证矩阵

| # | 输入/命令或操作 | 预期 | 结果 |
|---|---|---|---|
| 1 | `swift test` | Core 和可执行目标构建；全部测试通过 | 通过：74 个测试，0 失败 |
| 2 | `swift test --filter RefactorBoundaryTests` | 状态聚合、探针取消、异步删除兼容、持久化回滚通过 | 通过：7 个测试，0 失败 |
| 3 | `swift test --filter AppProcessExecutorTests` | keepAlive、手动停止、退出清理代际保护和启动失败收尾通过 | 通过：9 个测试，0 失败 |
| 4 | `swift build` | `TunnelPadCore` 与 `tunnelpad` 可构建 | 通过 |
| 5 | `swift build -c release` | 发布配置可编译并链接 | 通过 |
| 6 | `git diff --check` | 无空白错误 | 通过 |
| 7 | `plan-governance-cli check . --strict-readiness` | 治理结构和索引无本计划 ERROR | 通过；仅保留既有 ECS 重复目标 WARNING |
| 8 | 临时 debug 可执行文件启动 + AX 读取 | 窗口与主要控件可见；不操作真实隧道 | 通过；窗口和控件可见，未执行启停/删除 |
| 9 | `RefactorBoundaryTests.testAsyncAppLifecycleSequenceKeepsConfigAndCleansArtifacts` | 隔离 app demo 启动→停止→重启→删除闭环，配置/pidfile/日志收口 | 通过；状态和产物均正确清理 |

## 兼容性核对

- `TunnelManager` 的同步初始化器、`start/stop/restart/removeTunnel/refresh` 入口仍存在；新增 async 入口不改变旧调用方。
- `config.json` schema、隧道 id、launchd 标签、日志路径、状态枚举和已有中文错误/成功文案未改动。
- 菜单栏保留单隧道切换、打开主面板和退出；没有重新加入“全部启动/全部停止”。
- 删除未加载 launchd 隧道时仍跳过无意义的 bootout；配置写入失败时内存配置回滚。
- 主窗口关闭只暂停状态/日志轮询，不退出应用；重新显示后任务恢复。

## 完成边界

- 未在真实 launchd/app 隧道上点击启动、停止、重启、删除或退出；这些动作可能改变用户实例，因此保留为可选人工验收。
- release 构建、治理检查、隔离 demo 生命周期和计划索引已完成对齐，阶段 4 达到本计划完成标准。
