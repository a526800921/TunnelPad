# TunnelPad 无人值守阶段 1 合并独立复核（2026-09-19）

## 复核边界

- 复核者：Kierkegaard（独立子任务，未参与本轮实现）。
- 方式：只读源码、测试、计划与 GitNexus 证据核对；未修改文件，未启动或停止真实 TunnelPad App/隧道，未写入 ECS。
- 范围：两个无人值守专项计划共享的阶段 1 生命周期、ECS 前置、配置 owner、退出清理和登录项错误路径。
- 治理定位：这是按风险分流执行的一次合并高影响复核，不替代阶段 2 的真实登录、出口变化、`18080`、孤儿扫描或长时无人值守验收。

## 首轮结论

结论：**不通过（NOT READY）**。未发现 P0；发现以下必须在同一复核上下文中增量复验的 P1：

1. 运行期自动恢复逐隧道执行 ECS 同步，没有共享同一 ECS 资源的在途结果。两条隧道并发恢复时，后到者可能得到 `lock_busy` 并进入独立退避，而不是等待并复用同一结果。
2. Rust `CoreOwner` 的 load/save/remove/shutdown 没有覆盖完整配置事务的全局线性化；磁盘提交、内存 owner 更新、旧身份停止和另一配置操作可能交错。
3. App 首次退出请求处于 `.terminateLater` 清理期间时，再次收到退出请求会直接返回 `.terminateNow`，可能绕过尚未完成的孤儿 SSH 清理。

另有一项 P2 文档/测试缺口：R14 当时声称 `refresh()` 不会清除登录项错误，但实现仍会在后续显式刷新时清除。真正需要保证的是 `toggle()` 返回后错误仍可供当前提示读取；当时缺少 register/unregister 抛错注入测试。

复核同时确认：既有 R1–R10、R12–R13、R15 的代码方向和隔离证据没有出现新的阶段 1 P1；阶段 2 真实/长时证据仍待补，但不把该范围缺口重复计作阶段 1 代码缺陷。

## 首轮后的整改

实施者随后在本地完成以下整改；正式闭环按计划规范记录为实施者修复自验：

- 新增运行期 ECS 共享前置协调：同资源等待并复用结构化结果，不同资源全局最多两个并发；认证失败按资源缓存 300 秒，脱敏分类和 retry hint 进入持续恢复退避与日志。
- 为 `CoreOwner` 增加覆盖 load/save/remove/shutdown 完整边界的 `config_transaction`，保持“事务锁 → 稳定顺序 tunnel 锁”的单向锁序；增加 load/save、save/save、save/remove 并发反证。
- 新增 `ApplicationTerminationGate`：首个请求启动一次清理，清理期间重复请求继续 `.terminateLater`，仅清理成功后允许 `.terminateNow`；失败回到可重试状态。
- 为登录项服务增加可注入边界，验证注册失败在 `toggle()` 返回后仍可立即展示；后续显式 `refresh()` 清除旧提示是记录的实际语义。

## 补充只读核对（非新增独立门禁）

同一复核者在本地机械门禁全部通过后完成了一次补充只读核对。按计划规范，独立发现由实施者以“发现 → 修复 → 验证”的修复自验闭环，后续独立通过不能覆盖首轮发现；因此本节保留为补充交叉检查，不登记为第二个独立门禁，也不替代专项计划中的正式修复自验记录。

补充核对结果：**READY**。四项原发现均为 PASS，未发现整改引入的新 P0/P1：

1. 运行期 ECS 协调 PASS：同资源复用一个 `Task` 和结构化结果，不同资源全局容量为 2，认证失败按资源冷却 300 秒；单个等待者取消不会中断仍有使用者的共享任务。`TunnelManager` 通过 `launchResource → coordinator.run → checkLaunch` 接入，失败保留 category、sanitized code 和 retry hint 并继续限频重试。
2. 配置事务 PASS：`config_transaction` 覆盖 load/save/remove/shutdown；多隧道锁按 ID 稳定排序，复核未发现反向锁序或死锁环；load/save、save/save、save/remove 三项并发反证通过。
3. 重复退出 PASS：`cleaning` 阶段重复请求保持 `waitForCleanup`，仅清理成功后允许 `terminateNow`，失败回到可重新发起清理的 `idle`。
4. 登录项错误 PASS：`toggle()` 返回时保留本次失败供菜单立即展示，后续显式 `refresh()` 清除旧提示；实现、失败注入测试和整改文档语义一致。

复核者独立重跑并确认 Swift 196/196、Rust 111/111、ECS fixture 18/18、监督场景 9/9、Swift/Rust Release、隔离 App 签名/资源、GitNexus 变更检查和 `git diff --check` 均通过。复核过程未修改工作树，未操作真实 App、ECS 或隧道。

阶段 2 仍待完成：真实登录项批准与重启、真实公网出口/IP 漂移与阿里云规则写入、多隧道共享 ECS、真实 `18080` 冲突释放、孤儿 SSH 扫描，以及睡眠/唤醒、VPN/TUN 和长时间无人值守观察。这些不属于本次阶段 1 代码缺陷，也不因 `READY` 自动完成。
