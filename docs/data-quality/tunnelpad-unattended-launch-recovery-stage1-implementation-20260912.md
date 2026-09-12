# 无人值守启动恢复阶段 1 实施证据

日期：2026-09-12。起始 HEAD：`92b610c`。当前为未提交工作树；本阶段已授权且独立恢复准入通过。真实 ECS、运行 App 替换、发布与设备重启未执行。

## 实现范围

- `LaunchRecoveryCoordinator.swift`：生产调度器，可注入单调时钟；5/15/30/60/300 秒持续退避，全局 2，同资源 1，资源等待不占全局槽，认证共享 1800 秒冷却，取消保留槽直到后端退出，成功无新增定时器，日志去重。
- `TunnelManager.swift`：冻结首份有效配置；严格状态、停止/前置/启动流程；手动操作、运行配置变化及退出取消并等待；名称/备注保持候选；启动 owner 期间抑制健康恢复，fresh PID 后交接。旧 Core 能力缺失 fail-closed。
- `owner.rs` / `launchctl.rs` / `launchd_executing.rs`：非等待 begin、checked 状态、锁内配置/代次复核、整体预算及有界 bootstrap、沿用受管 stop 身份边界；新命令的受控超时追加错误码 14。现有 C ABI 和配置 schema 保持 1。
- `preflight/` + helper：同版 guardian/worker、专用进程组、继承 flock、共同旧目录锁与可信残留回收、私有原子 journal、精确续作、原始云输出隔离、结构化类别及日志限频。云事务是单一 native owner；脚本只导出外部配置并 exec helper。
- `BoundedPreflightProcess.swift`：非阻塞且限量读管道，取消先让 guardian 清理，最多额外 5 秒后结束监督者；worker 独立检查 guardian 存活。
- 打包脚本增加相邻 `tunnelpad-preflight`；缺 helper 不回退旧脚本行为。

## 已执行验证

| 验证 | 实际结果 |
|---|---|
| 原有 Rust lib 回归 | 首轮 77/77；严格入口加入后 80/80 |
| Rust workspace + 差分 | 最终 83 个 lib、2 个 helper、1 个差分通过；新增取消不等待配置锁及错误码 14 fixture 通过 |
| Python 能力 fixture | v1 checkedStart/deadline 通过，基线 NULL 已转正 |
| shell 假云兼容 | 15/15，撤销失败后再次运行已收敛；未知多规则仍禁止写入 |
| native 故障注入 | 第三条规则、属性变化、只读 journal、符号链接拒绝、IP 再变、认证冷却、TERM 抵抗、guardian 崩溃与不同 profile 共锁通过；同范围增量复验通过 |
| Swift 生产协调器 + 管理器 | 23/23 首轮专项通过；名称/备注保留增量后 34/34（含原前置集成）通过 |
| Swift 全量 | 167/167 通过（XcodeBuildMCP，2026-09-12T12:47:29Z） |
| Release/打包/治理 | Swift/Rust Release 构建、独立目录打包与 ad-hoc 签名检查通过；治理 strict-readiness 与 diff --check 通过（完成复核未通过前仍不代表阶段完成） |

新增隔离测试驱动生产调度器与管理器。`UnattendedLaunchStage0Tests` 旧 owner 夹具转为旧能力拒绝验证；阶段 0 当时的缺口结论保留原证据。正向网络恢复在 `LaunchRecoveryIntegrationTests`，不是重写测试中的调度算法。

## 风险与差异检查

GitNexus 对操作准入、配置更新、Rust 客户端及部分测试/私有辅助类返回 CRITICAL；启停/退出/取消返回 HIGH，修改前已告知。Shell 和本次未索引的新符号可能返回 UNKNOWN；补充实际引用、隔离测试和独立只读复核，不把 UNKNOWN 当作低风险。

本阶段独立完成复核首轮三项 P1 已修复，经同范围独立恢复通过；阶段 1 实现与隔离验证完成。代码通过不代表阶段 2 真实无人值守/能耗验收。


## 打包与运行实例隔离

当前进程位于默认 `dist/TunnelPad.app`，因此使用 `TUNNELPAD_DIST_DIR=…/dist/stage1-validation bash scripts/build_app.sh --skip-tests` 生成独立包。验证输出为 `dist/stage1-validation/TunnelPad.app`；未运行该 App，未覆盖现有实例。Swift Release 由 XcodeBuildMCP 构建；同版 Core 能力探测通过。脚本新增输出目录覆盖只影响构建目标，默认路径不变。

`detect_changes({scope:"compare",base_ref:"main"})` 返回 CRITICAL（97 个索引符号、137 条影响记录、13 个 tracked 文件）。索引未覆盖全部新增文件且行位移使部分旧函数被宽泛映射；实际范围依据工作树 diff、新文件清单及独立复核，不能用图谱数字声称完整覆盖。

## 独立完成复核与修复

[首轮独立完成复核](tunnelpad-unattended-launch-recovery-stage1-independent-completion-review-20260912.md)发现三项 P1：未确认新规则 Priority 校验缺失、配置语法失败继续执行、严格入口共享配置锁阻塞。修复和原反例及受影响回归均已通过自验，native 矩阵增至 9 项，Rust lib 增至 83 项；按风险分流由原独立复核者再次检查并运行 Rust 严格入口 6/6、native 9/9，明确恢复通过。


## 最终交付状态

阶段 1 已完成；未提交工作树。修复后的 Rust Release 重新构建，独立目录打包及严格签名检查通过，包内 Core 的 capabilities v1/checkedStart/deadline 隔离探测通过。Swift 167/167、Rust 83+2+1、shell 15/15、native 9/9 通过。真实运行实例仍为原默认 dist 包；新包未启动。阶段 2 维持设计中，尚未执行真实环境操作或能耗验收。

修复后独立包内 Release helper 再执行 native 矩阵 9/9 通过；不只验证仓库 Debug helper。

最终文档同步后，git diff --check 通过；plan-governance-cli check . --strict-readiness 退出 0。当前阶段已切换至阶段 2 设计中，因此检查如实提示阶段 2 尚未复核、无本阶段记录、授权与 Step 0 未完成；这些提示不代表阶段 2 准入，也不撤回已完成的阶段 1 独立恢复结论。
