# TunnelPad 稳定性阶段 2：配置重载资源收敛切片实施证据

- 日期：2026-09-02
- 对应 Step 0：[配置重载资源收敛切片 Step 0](tunnelpad-stability-stage2-config-reload-reconciliation-step0-20260902.md)
- 对应准入：[配置重载资源收敛切片独立准入复核](tunnelpad-stability-stage2-config-reload-reconciliation-independent-review-20260902.md)
- 当前结论：实现完成，待独立完成复核

## 实施内容

修改 `CoreOwner::load_config`：

- 候选配置先完成现有解析和 `launchd` 校验，失败时不触发生命周期操作。
- 以旧 owner 配置与候选配置的 ID 差集找出待删除隧道，按 ID 稳定排序并持有对应隧道锁。
- 已加载的待删除 label 先 `bootout`，再查询确认 `notLoaded`；已未加载的 label 只接受现状，不发送 `bootout`。
- 任何停止失败或停止后仍加载都拒绝候选配置，旧 owner 配置保持不变；已成功停止的旧隧道仍保留在旧 owner 配置中，供后续人工重试。
- 所有待删除 label 收敛后才替换 owner 配置；新增隧道不自动启动，同 ID 参数变化不自动重启。

未修改 Swift UI 提示、配置 Schema、执行器枚举、plist 格式、ECS/SSH 业务链路或真实用户隧道。

## 专项验证

新增 Rust owner fixture 9 项，覆盖 CfgR-1–CfgR-9：

1. 新增隧道不自动启动。
2. 删除未加载 label 不发送 `bootout`。
3. 删除已加载 label 按 `print → bootout → print` 收敛后才提交。
4. `bootout` 失败时保留旧配置。
5. 停止后仍加载时保留旧配置。
6. 多个删除项部分失败时继续尝试后续 label，候选不提交。
7. 同 ID 参数变化不触发自动重启。
8. 无效候选不产生生命周期副作用。
9. 配置重载与同隧道生命周期操作按 owner 隧道锁串行。

命令与结果：

```text
cargo test --manifest-path rust/tunnelpad-core/Cargo.toml owner::tests::reload_config
9 passed; 0 failed

cargo test --manifest-path rust/Cargo.toml
62 unit tests passed; 1 differential test passed; 0 failed

swift test
129 tests passed; 0 failed
```

## 范围检查

- `git diff --check`：通过。
- 尚未进行真实 `launchctl`、SSH 或 ECS 故障注入。
- 当前运行中的 App 未因本切片自动操作真实隧道；真实 App 受控验收仍沿用无运行中受管隧道边界。

## 待完成

由独立只读复核再次核对当前 owner 实现、CfgR-1–CfgR-9 输出、全量回归、计划外行为和变更范围；通过后仅关闭该配置重载切片，不改变阶段 2 整体“实施中”状态。
