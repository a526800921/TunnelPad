# ADR-0001：Rust Core 作为唯一生命周期 owner

- 状态：已接受
- 日期：2026-08-30
- 范围：TunnelPad Core 迁移阶段 5

## 背景

阶段 4 已验证进程内 Rust 动态库可以由 Swift App 加载，但 Rust 只做配置影子校验，Swift 仍负责配置读写、生命周期、并发和退出清理。若后续稳定性、备注和配置能力继续分别在 Swift 与 Rust 中实现，会形成两套行为 owner 和重复迁移成本。

## 决策

1. 保留 SwiftUI/AppKit、菜单栏、窗口、表单和状态展示作为 App 外壳。
2. Rust 动态库通过进程内 C ABI 提供 Core；不引入 sidecar 进程。
3. Rust Core 是唯一生命周期 owner，持有配置、运行时状态、并发协调和活动操作取消状态；同步 C ABI 下不引入 Rust 持久 worker，Swift detached task 只负责脱离 UI 线程。
4. 跨边界使用 UTF-8 JSON 与 opaque Rust handle；Swift 只发命令、读取状态快照和绑定 UI。
5. `config.json` 的读取、解析、保存和 schema 校验由 Rust 负责；version=1 磁盘格式保持不变。
6. 阶段 5 只覆盖 `launchd`。当前 `app` 执行器入口、实现和配置分支移除；未来需要时另立计划。
7. 用户退出 TunnelPad 时由 Rust 使活动代次失效、取消正在运行的 `launchctl` 并停止全部受管 `launchd` 隧道；关闭窗口不停止隧道。
8. 验证完成后删除旧 Swift Core，不保留 App 内 Swift fallback；缺陷直接修复 Rust。

## 后果

### 正面

- 生命周期、配置、并发和稳定性只有一个业务实现。
- 后续备注字段和健康恢复直接进入 Rust 正式 Core，不需要再迁移一遍 Swift 运行时逻辑。
- UI 与生命周期解耦，Swift 只承担 macOS 原生展示和边界适配。
- 进程内调用保留阶段 4 已验证的打包和加载路径，不增加 sidecar 的 IPC/重连/签名复杂度。

### 代价与风险

- C ABI、JSON 所有权、opaque handle 线程安全和状态快照需要严格测试。
- Rust Core 出错可能影响整个 App 进程；阶段 5 不能依赖 App 内 Swift fallback。
- 异步操作需要在 Swift FFI 边界申请 Rust owner 代次；代次失配时 Rust 必须在系统副作用前拒绝迟到命令。
- 删除 Swift Core 后，修复必须通过新的 Rust 测试、构建和受控实机验证完成。
- 阶段 5 暂不提供 app 执行器能力，未来新增 app 需要重新设计配置和生命周期边界。

## 验证边界

阶段 5 先完成隔离 fake `launchd`、配置 owner、并发/退出和状态快照验证，再按用户授权逐条验证真实 `launchd` 隧道。所有完成条件和独立复核通过后，才删除旧 Swift Core。Git 历史保留源代码演进记录，但不作为运行时回滚机制。
