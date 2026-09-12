# 无人值守启动恢复：阶段 1 Step 0

- 日期：2026-09-12；实施者：Codex；起始 HEAD：`92b610c`，保留此前日志修复和阶段 0 工作树。
- 授权：用户在确认阶段 1 范围后明确回复“那你开始吧”；覆盖本阶段代码、隔离测试和打包检查。真实 ECS、运行中 App 替换、发布及设备重启仍留给阶段 2。
- 事实源：[专项计划](../plans/tunnelpad-unattended-launch-recovery.md)。本阶段先加固前置与 Rust 入口，再接调度。

## 本阶段基线

1. 新增 `Tests/launch-recovery-capability-test.py`：在临时 home 创建 owner，只查询 `launchRecoveryCapabilities`，不启动任何作业。`cargo build --offline --manifest-path rust/Cargo.toml -p tunnelpad-core` 后执行该 Python 测试，当前 FFI 返回空响应，断言“能力响应为空”失败。目标为返回 version=1、checkedStart=true、deadline=true。
2. `rust/target/debug/tunnelpad-preflight` 当前不存在；前置监督、内核锁及 journal 均未实现。
3. 阶段 0 的 B1/B2 已实证无重试与撤销失败卡住；阶段 1 会把它们迁移为恢复目标断言。历史基线结果保留于[阶段 0 证据](tunnelpad-unattended-launch-recovery-stage0-step0-20260912.md)，不改写历史。

## 固定实现边界

### Rust owner JSON

- 新增 `launchRecoveryCapabilities`：返回 `{version:1, checkedStart:true, deadline:true}`。
- 新增 `launchRecoveryBegin {id}`：只做非等待 try-lock；忙时返回 `{operation:"busy",generation:null}`，不创建 generation。取得锁才创建 generation；协调器取消后不得继续发后续命令，已经取得的 generation 立即 cancel。禁止在没有 generation/requestId 时开启后台锁等待，也禁止退回无界 begin。
- 新增 `launchRecoveryStatus {id,generation,timeoutMs}`：fresh checked 状态，无缓存降级；单次 print 限制为剩余预算和 2 秒中的较小值。
- 新增 `launchRecoveryStart {id,generation,timeoutMs,expectedConfig}`：锁内校验运行相关配置、generation、取消、closed、deadline；只有 notLoaded 写 plist/bootstrap。返回正常 status；running 必须有有效 PID，其他状态由调度器观察。bootstrap 最多 10 秒，收敛最多 10 秒且共用剩余预算。
- 对 KeepAlive=false 的停止作业需要有界 `launchRecoveryStop`，复用 Rust 受管 stop 身份/收敛，不新增 Swift 进程信号 owner。
- 旧 C 函数签名、config schema、手动 start/stop/restart 与 HTTP API 不变。新客户端遇到不支持能力的旧库 fail-closed；新增 JSON 命令配套 Rust/Swift fixture。

### 原生前置程序

- 固定目标：`rust/tunnelpad-core/src/bin/tunnelpad-preflight.rs`，辅助模块位于 `rust/tunnelpad-core/src/preflight/`，复用现有 serde/serde_json/libc，不新增依赖。
- `scripts/update-ecs-ssh-ip` 保持用户入口和外部配置约定，改为配置导出后 exec 同版本 supervisor；实际 curl/aliyun 调用及事务状态机集中到 native worker，由 supervisor 统一监督，减少 shell 与 native 双重状态 owner。此细化保留阶段 0 的监督与信号边界，原 shell 算法由现有 fixture 逐项保持兼容。
- supervisor/worker 同一二进制不同内部模式，worker 拥有专用进程组；guardian 监督整体期限，worker 同时检查 guardian 存活，guardian 崩溃不得使 CLI 永久无人监督。所有在途 CLI 继承锁描述符并受有界命令执行器管理。
- CLI：无参数同步、`--check` 只读、`--local-check` 只验证本地前提、`--result-json` 输出机器结果、`--resource` 返回脱敏资源键供调度器协调；结果 version=1，stage/category/retryHint/sanitizedCode，不输出外部原始响应。
- 资源键按 region/security-group 规范化哈希，profile 不参与互斥身份。默认状态目录 `~/Library/Application Support/TunnelPad/preflight`；隔离 fixture 可指定专用状态目录。journal、锁标记与结果缓存均私有权限，拒绝符号链接/所有者异常。
- 事务完整记录旧/新规则的限定属性、精确 ID、来源 /32、幂等 token 与阶段，只存在私有运行时文件；日志不记录这些原始值或密钥。写前原子落盘，响应不确定先查询，可信续作不新增第三条规则。
- 旧/新路径同持既有目录锁，native 锁在它之前获取；目录锁的可信 owner/worker 身份可用于确认残留无活进程后回收，未知锁不删除。
- 程序随 App 放入 Contents/Resources，与脚本相邻；开发入口可定位仓库已构建产物，禁止隐式下载/构建；缺失 helper 返回配置错误，不回退到旧无监督同步。

### Swift 调度与适配

- 单独的启动恢复策略/协调模块提供可注入单调时钟和后端接口，TunnelManager 负责配置/手动操作/健康 owner 的桥接；测试必须驱动生产协调器，不在测试中复制调度算法。
- 每次尝试统一 55 秒工作预算和清理边界。资源令牌取得后才占全局最多 2 个槽，同资源最多 1；收到取消必须等待本次后端退出再释放槽。
- busy、状态发现、前置类别、非运行态与健康交接均有类型化结果，禁止解析 lastError。
- 背景日志复用 AppEventLog 并去重；手动 UI/API 错误语义不变。前置程序的资源与认证冷却跨隧道共享。

## 可执行验证与失败判定

| 范围 | 命令/样本 | 通过标准 |
|---|---|---|
| FFI 能力与 strict owner | Python capability + Rust owner 单测 | 新能力可识别；未知/取消/超时/配置变化都无 bootstrap；锁内复核；旧命令兼容 |
| begin 忙与取消 | 持目标锁→try-begin 返回 busy→协调器取消→释放锁→随后手动 begin | try-begin 不产生迟到代次，不影响后续手动代次；协调器取消后无重发 |
| native 前置 | `cargo test --offline --manifest-path rust/Cargo.toml` | 进程组与 deadline、活锁/旧锁、受保护 journal、分类和部分成功续作通过 |
| 原 shell 兼容与假云 | `bash Tests/update-ecs-ssh-ip-test.sh` | 原幂等/先加后删/未知规则不写保持；故障解除后 B2 转正向收敛 |
| Swift 队列 | XcodeBuildMCP Swift Package tests | U1–U8/U12 的虚拟时间、次数、容量、取消、交接和旧库兼容全部通过 |
| 差分/打包 | 现有差分 harness、同版 Release 构建与静态包检查 | Core 与 helper/入口配套；不运行打包 App、不访问生产服务 |
| 治理 | `plan-governance-cli check . --strict-readiness` | 状态/阻塞/证据一致；机械通过不代替独立完成复核 |

任何无法结束的副作用、同资源重叠、未知资源写入、取消后 bootstrap、无期限等待或敏感输出都阻止进入持续调度/阶段完成。实际执行结果另记实施证据，未执行项不填通过。

## 回滚与完成

本阶段只作用于源码、隔离 home/假云和构建目录；失败可撤销当前变更，保留此前日志修复。运行部署和 journal 兼容见[迁移说明](../migrations/tunnelpad-unattended-launch-recovery.md)。先做本阶段独立准入，再实施；完成时执行同范围独立验证，不能用阶段 0 通过代替。
