# 无人值守启动恢复：阶段 0 基线

- 日期：2026-09-12；记录者：Codex。
- 起始 HEAD：`92b610c`。承接工作树已有日志修复、新计划及地图文档；本阶段没有新增生产逻辑改动。
- 用户授权：确认推进阶段 0，包括设计收敛、隔离测试基线、独立准入；尚未授权阶段 1 的队列/监督/事务实现或真实外部操作。
- 契约事实源：[专项计划](../plans/tunnelpad-unattended-launch-recovery.md#需求探索)。本文件只记录事实与验证，不复制目标状态机。

## 静态事实与设计后果

| 事实 | 代码证据 | 后果 |
|---|---|---|
| 进程启动恢复先永久置完成标记，失败不再入队 | `Sources/TunnelPadCore/TunnelManager.swift:236` | 网络恢复也不会补首次启动，必须新增队列 |
| `startAsync` 把各种错误统一为 failed；日志字符串不适合作调度输入 | `Sources/TunnelPadCore/TunnelManager.swift:913` | 要有内部结构化结果，手动 API 兼容 |
| 初始停止状态不参与健康恢复 | `Sources/TunnelPadCore/HealthRecovery.swift:67`，`TunnelManager.recordHealthResult` | 不能让已有健康监测自动代替启动队列 |
| snapshot 串行遍历隧道并使用宽松 status；错误可能降级为 notLoaded | `rust/tunnelpad-core/src/owner.rs:558`；`launchctl.rs:603` | 不增加周期全量 snapshot，自动启动需 checked 单条状态 |
| Rust start 锁内仍使用宽松 status，非 running 就 bootstrap | `rust/tunnelpad-core/src/owner.rs:399` | Swift 事先查询不足以封住检查到执行之间变化，需锁内严格自动入口 |
| Rust checked print 每次 2 秒，start 后最多 21 次查询；Swift 再有 30 次收敛查询 | `launchctl.rs:625`、`:641`；`TunnelManager.settleLifecycleStatus` | 重试次数不是整体超时，需共享剩余 deadline |
| `runRustOperation` 取消会发 Rust cancel，但锁等待/部分查询目前不接受统一预算 | `TunnelManager.runRustOperation`、`owner.rs:385` | 不能超时后遗弃原任务并开启同 ID 新操作 |
| ECS 的 4/5/6 等退出码混合临时失败、歧义、部分成功 | `Sources/TunnelPadCore/ECSPreStart.swift:35`、`:207`；`scripts/update-ecs-ssh-ip:175` | 新增脱敏机器结果及 unknown 的保守策略 |
| ECS task group 超时会等子任务退出，runner 只 TERM 根进程；shell TERM trap 只清锁 | `ECSPreStart.swift:219`、`:331`、`:400`；`scripts/update-ecs-ssh-ip:107` | 前置监督、整个进程组与锁寿命必须纳入方案 |
| 当前 mkdir 锁无 owner 身份，异常退出可能遗留永久锁 | `scripts/update-ecs-ssh-ip:107` | 新锁需自动释放，未知旧锁不能擅删 |
| 撤销旧规则失败后留下两条，再次入口遇多条即返回 4 | `scripts/update-ecs-ssh-ip:201`、`:295` | 单纯重跑无法无人值守，需可信记录内精确续作 |

引用行号为本次核对位置；实施前以符号和当前 diff 再核对。GitNexus 查询了 ECS 前置及健康恢复调用关系，其接口动态分发图存在 lower-bound，不据零调用宣称无影响。

## 可执行基线 B1：前置恢复后仍不补启动

- 文件：`Tests/TunnelPadCoreTests/UnattendedLaunchStage0Tests.swift`。
- 输入：仅一条 autoStart 隧道、fake Rust owner 恒返回 notLoaded、前置 checker 初次超时；注入手动单调时钟，不调用真实网络或 launchd。
- 操作：执行真实 `restoreAutoStartTunnels` → checker 切在线 → 虚拟时间推进 86400 秒、驱动一次现有健康循环 → refresh → 再次调用恢复入口。
- 实际断言：前置检查仍为 1 次，Rust start 为 0，隧道 notLoaded。**基线测试通过表示确认现有缺口，不表示无人值守已实现。**
- 限制：单次跳时证明现有健康循环及重入不能重新获得启动资格，不宣称执行了 24 小时真实循环或证明未来队列频率。
- 另一个测试验证虚拟时钟不到期不唤醒、到期唤醒、取消移除等待者；阶段 1 可延续该手动时钟思想，按生产注入接口迁移。

## 可执行基线 B2：临时撤销故障消失后仍无法收敛

- 文件：`Tests/update-ecs-ssh-ip-test.sh`，新加 `baseline-retry-after-revoke-failure-remains-blocked` 顶层场景，既有 fixture 函数不变。
- 输入：假云仅有一条旧受管规则；fake curl 返回固定测试来源；fake aliyun 第一次撤销失败，所有路径均在 fixture 临时目录。
- 操作：第一次同步返回 6、保留两条；清除假撤销错误，保留同一份假云状态，再次执行真实脚本。
- 实际断言：第二次返回 4、仍两条规则、撤销调用次数未增加。基线证明即使外部故障消失也会卡在歧义门禁。
- 原有“未知多条规则禁止写入”断言仍通过；未来不能为修复此基线放宽到批量删除同描述规则。

## 命令与结果

| 命令 | 实际结果 | 范围 |
|---|---|---|
| `xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter 'UnattendedLaunchStage0Tests\|ECSPreStartIntegrationTests\|TunnelManagerTests'` | 24 tests passed, 0 failed, 0 skipped | 新基线 2 项、ECS 集成 12 项、TunnelManager 10 项；Swift Package 编译成功 |
| `bash Tests/update-ecs-ssh-ip-test.sh` | 15 条 PASS，最终“全部 update-ecs-ssh-ip fixture 测试通过” | 新旧假云脚本场景；无真实云调用 |

Swift 构建日志位于 `/Users/jafish/Library/Developer/XcodeBuildMCP/workspaces/TunnelPad-fadc694a998e/logs/swift_package_test_2026-09-12T11-37-22-381Z_pid12219_2d88cc55.log`。没有打包/替换运行中 App，没有更改登录项，没有重启设备或操作实际隧道。

## 阶段 1 必须验证的新增边界

U1–U12 的目标矩阵以专项计划为准。本阶段不编写重复生产实现的“测试内调度器”，不以模拟模型自洽代替生产行为证据。实现时必须补充：

- 精确 5/15/30/60/300 秒时序、24 小时调用次数上限、唤醒不补发、认证资源级 1800 秒限制。
- Rust checked 锁内二次判断、deadline 包括锁等待及所有查询、busy/取消与阶段交接，无迟到 bootstrap。
- 实际 supervisor 的 TERM/KILL、孙进程/管道、退出、活锁、崩溃和旧锁兼容；结束确认前不释放资格。
- 假云写前/写后各崩溃点、响应丢失、事务原子持久化、仅可信规则续作、第三条/未知状态保持不写。
- 新 Swift/旧 Rust、旧 CLI/新 supervisor、资源缺失和回滚中 journal 未清的兼容失败分支。

## 初次独立设计观察的处理

独立只读复核者 `stage0_preflight_review` 确认四项设计缺口：前置取消、临时撤销失败、分类不足、遗留锁。已据此把 supervisor、结构化结果、资源锁与可信事务续作纳入计划，明确了远程只读重新认证仍有请求成本。该修改不声称已修复生产实现；收敛设计仍须同范围最终准入复核。
