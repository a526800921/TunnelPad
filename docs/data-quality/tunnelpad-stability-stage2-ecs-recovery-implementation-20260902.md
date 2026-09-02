# TunnelPad 稳定性阶段 2 ECS 自动恢复切片实施证据

- 日期：2026-09-02
- 阶段：阶段 2（ECS 自动恢复切片）
- 状态：切片实现完成；阶段 2 整体仍在实施中
- 关联计划：[TunnelPad 隧道稳定性与健康恢复](../plans/tunnelpad-stability.md)
- 准入复核：[ECS 自动恢复切片独立准入复核](tunnelpad-stability-stage2-ecs-recovery-independent-review-20260902.md)

## 实施范围

本次只实现已经准入的 ECS 自动恢复切片：后台 HTTP 探针连续失败触发 SSH 自动恢复时，先通过现有 Rust 生命周期 owner 执行 `stop`/`bootout`，确认返回 `notLoaded` 后执行现有 ECS 前置同步；同步成功后沿用同一 Rust 操作代次执行 `start`/`bootstrap`。停止未收敛、同步失败、超时、取消或结果无法分类时不启动 SSH；非 SSH 隧道继续使用原有 `restart` 路径。

为保持普通测试注入器和非 ECS 场景兼容，`ECSPreStartChecking` 增加了默认关闭的 quiescence 能力声明，生产 `ECSPreStartChecker` 开启该能力；这不是配置字段、公共 C ABI 或 plist Schema 变化。

## 代码与测试变更

- [ECSPreStart.swift](../../Sources/TunnelPadCore/ECSPreStart.swift)：声明生产 ECS checker 需要自动恢复前先卸载 launchd 实例。
- [TunnelManager.swift](../../Sources/TunnelPadCore/TunnelManager.swift)：SSH ECS 恢复改为 `stop → preflight → start`，增加 `notLoaded` 门禁；前置失败后的停止态仍沿用恢复代次和固定退避，不会因状态为 `notLoaded` 截断后续尝试。
- [StabilityStage2Tests.swift](../../Tests/TunnelPadCoreTests/StabilityStage2Tests.swift)：新增 5 项隔离 fixture，覆盖成功顺序、ECS 失败不启动、停止状态门禁、前置失败后的有界重试和非 SSH 兼容路径。

## 验证结果

| 验证 | 结果 |
|---|---|
| `swift test --filter StabilityStage2Tests` | 5/5 通过 |
| `swift test --filter StabilityStage1Tests` | 9/9 通过 |
| `swift test --filter ECSPreStartIntegrationTests` | 12/12 通过 |
| 全量 `swift test` | 123/123 通过 |
| 全量 `cargo test --manifest-path rust/Cargo.toml` | Rust 51 个单元测试 + 1 个差分测试通过 |
| 治理与空白检查 | `plan-governance-cli check .`、`--strict-readiness`、`--stale-days 10`、`git diff --check` 通过 |
| GitNexus 变更范围 | 预期高风险：TunnelManager hub；生产改动集中在 ECS checker 能力声明和健康恢复协调路径，未扩展 Rust ABI/Schema |

所有 fixture 使用 fake owner、fake ECS checker、隔离临时目录和注入式探针；未调用真实 `launchctl`、SSH、ECS 或用户隧道。

## 仍留在阶段 2 的工作

启动/退出的统一资源发现与结果分类、跨层状态一致性、迟到任务反证和受控应用验收仍未完成，不能由本切片的 5 项测试或全量回归替代。下一步应另行补齐这些切片的 Step 0、独立准入和专项证据。
