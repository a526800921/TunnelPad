# 无人值守启动恢复阶段 1 独立完成复核

日期：2026-09-12。复核者：`stage1_completion_review`，未参与实现或测试编写，只读审查及隔离反例。范围：阶段 1 当前未提交工作树；策略：风险分流；风险：高影响。

## 首轮结果：未通过

1. P1 新规则未确认时缺少完整请求属性校验。独立假云将 Authorize 后 Priority 改为 2，原实现仍返回 exit 0 / synchronized，并撤销旧规则一次。
2. P1 外部配置语法错误不终止入口。临时配置有效赋值后追加 `if then`，原实现继续执行 helper 并返回 0，stderr 包含原始解析错误。
3. P1 严格 owner 等待共享配置锁。begin/execute 经 tunnel() 阻塞，最终配置锁获取后先写 plist 再检查取消/到期；另一 ID bootstrap 持锁可使边界失效。

已覆盖调度、候选冻结、健康交接、严格 owner、监督进程组、旧新互斥、journal、迁移及打包差异。未访问真实 ECS、未替换或运行 App。已有自验不能抵消独立反例。

## 修复与自验

- 新增 requested_rule：完整安全形状、目标 CIDR、Priority=1、额外来源及目标约束空；首次收养和 journal.new 复核共用。fixture 新规则显式 Priority；优先级变化后首次及恢复均禁止撤销旧规则。
- wrapper 检查 source 返回值并隔离解析输出，失败固定脱敏 configuration_invalid / exit 2；fixture 验证 helper 未运行、云调用为零、无配置输出泄露。
- strict begin/execute/最终提交使用 try_lock，锁忙立即返回；取得锁后及 write_plist 前重查代次和 deadline。新增跨 ID 实际 bootstrap 持锁和 checked 状态后最终提交竞争测试，覆盖无迟到代次、busy、cancel、deadline、无 plist。
- 当前实施者自验：Rust 83 个 lib + 2 个 helper + 1 个差分；Swift 167；shell 15；native 9，全部通过。

## 恢复复核

结论：**通过；高影响，原三项必须修复全部关闭。**

复核者 `stage1_completion_review` 在修复后的同范围独立读取实际代码，并运行：
- `cargo test --manifest-path rust/Cargo.toml -p tunnelpad-core recovery_`：6/6，通过跨 ID 共享配置锁、最终提交 busy/cancel/deadline、无迟到代次与无 plist 断言。
- `python3 Tests/preflight-supervision-test.py`：9/9，原 Priority 与配置语法错误反例转为拒绝，禁止 revoke/helper 且无原始输出泄露；journal、IP 再变、认证、TERM、guardian/profile 回归通过。

首轮失败保留为历史；本次同范围独立通过恢复阶段完成门禁。最终同版隔离打包和包内能力由实施者验证，见[实施证据](tunnelpad-unattended-launch-recovery-stage1-implementation-20260912.md)。未访问真实 ECS、操作运行 App 或修改项目文件。阶段 2 真实无人值守和能耗验收未覆盖。
