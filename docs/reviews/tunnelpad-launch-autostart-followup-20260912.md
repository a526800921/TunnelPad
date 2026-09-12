# 开机自启后续复核与日志修复

- 日期：2026-09-12；起始 HEAD：`92b610c`，起始工作树干净。
- 本次记录者/修复者：Codex；日志修复为低风险自验，不冒充独立复核。
- 关联：[原计划](../plans/tunnelpad-launch-autostart.md)、[无人值守启动恢复新计划](../plans/tunnelpad-unattended-launch-recovery.md)。历史完成证据不回写。

## 用户取舍与范围

1. 单次恢复队列在等待期间覆盖用户最新操作的边界竞态：用户明确暂不处理，未修复。
2. 登录项错误被清除：已解释。`toggle()` 捕获 register/unregister 错误后调用 `refresh()`，后者清空 `registrationError`，菜单无法显示失败弹窗。本次未获修复指示，代码保持原样。
3. `.completed(status:)` 携带非运行态却记录成功：用户明确要求修复，本次已完成代码和测试修改。
4. 启动失败不重试不满足无人值守：用户要求新计划，已建立设计中计划与地图入口，未实现重试。

## 实际修改

- `Sources/TunnelPadCore/TunnelManager.swift`：仅 `.completed(status: .running)` 计成功；`.notRunning`、`.notLoaded`、`.other` 写入“请求完成，但未确认运行”及返回状态；汇总增加“未确认运行”计数。保持 startAsync、候选、次数、状态和失败路径不变。
- `Tests/TunnelPadCoreTests/TunnelManagerTests.swift`：桩可注入启动返回状态；新增三种非运行态的日志回归，保留运行成功、抛错、发现失败与幂等检查。

运行态表示进程状态，仍不等同于业务探针健康。本次修复不新增探测或改变 API 结果。

## 影响与验证

- GitNexus 起初未收录新符号；通过仓库 `.gitnexus/run.cjs analyze` 刷新索引后重新查询。`restoreAutoStartTunnels` upstream 返回 LOW、3 个直接调用方：AppDelegate 启动入口及两个专项测试；测试桩 start 的接口调用边界另以实际使用范围核对。
- `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter TunnelManagerTests`：最终 **10 tests passed, 0 failed**。新用例覆盖 notLoaded/notRunning/other 三种返回值均无成功日志，汇总为成功 0、未确认运行 3。
- 首轮测试中额外的最终 UI 缓存断言失败：桩 snapshot 对所有条目默认返回 notLoaded，后续隧道刷新会覆盖前一条缓存。该断言不属于此次日志契约，已删除；保留真实恢复入口、启动调用次数、逐条日志与汇总断言，复跑通过。
- 当前验证为 Swift Package 编译与隔离测试；未替换运行中 App、未注册/注销系统登录项、未操作生产隧道。Rust 代码未变，本次不重复 Rust 全套或真实启动验收。
- 文档验证：`plan-governance-cli check .` 通过，仅保留新计划可执行基线/错误分类及退避/并发初值未解决的预期警告；新增文档相对文件链接与 `git diff --check` 通过。新计划保持设计中，结构检查不构成实现准入。

## 风险与回滚

变更只影响 app.log 文案和统计，未改变生命周期行为；撤销本次日志分支与配套测试即可回到原记录方式，不修改配置或系统注册状态。尚未解决的第 1、2 项按用户取舍保留，不以本次日志测试通过宣称全面复核通过。
