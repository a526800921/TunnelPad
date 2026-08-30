# TunnelPad Rust Core 迁移：阶段 0 基线证据

- 日期：2026-08-30
- 范围：只读架构/工具链/行为基线；不创建 Rust 工程，不操作真实隧道
- 对应计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)

## 基线结论

当前项目仍由 SwiftUI/AppKit + SwiftPM 构成，产品目标为 `TunnelPadCore` 库与 `tunnelpad` 可执行目标；仓库没有 `Cargo.toml`、Rust 源码或 Rust target。用户已确认 Rust 迁移边界为：保留 SwiftUI/AppKit，只逐步替换 `TunnelPadCore`。

工作树不是干净基线：包含 Swift Core/UI 重构、侧栏 UI 调整、ECS 计划/fixture 等未提交改动。Rust 实施前必须选择性提交或创建干净分支，不把这些改动混入 Rust 提交。

## 可复现样本矩阵

| # | 命令/核对 | 结果摘要 | 安全边界 |
|---|---|---|---|
| 1 | `git rev-parse HEAD` | `b6ffd2232833a2d3e6ef0d894f6cb23fa0448f48` | 只读 |
| 2 | `git status --short` | 工作树非洁净；Swift/UI、ECS 和 fixture 改动已列出 | 只读，不归类为 Rust 实现 |
| 3 | `rustc --version && cargo --version` | `rustc 1.96.0`、`cargo 1.96.0` | 只探测工具链 |
| 4 | `swift --version` | Apple Swift 6.3.3，arm64 macOS target | 只读 |
| 5 | `swift test` | 74 个测试，0 失败（2026-08-30 12:03 左右复跑） | 不触碰用户隧道；测试使用临时 fixture |
| 6 | `swift build -c release` | Release product `tunnelpad` 构建通过 | 只生成本地构建缓存 |
| 7 | `./scripts/build_app.sh --skip-tests` | `dist/TunnelPad.app` 重新生成；`Info.plist`、ad-hoc 签名校验通过；包内二进制时间 12:03:46 | 只覆盖仓库内发布产物 |
| 8 | `find Sources -maxdepth 2 -type f`、`Package.swift` | Core/UI/test target 边界可复现；未发现 Rust target | 只读 |
| 9 | Rust 文件检查 | 无 `Cargo.toml`、`Cargo.lock` 或 Rust 源文件 | 不创建文件 |

## 迁移边界核对

- 保留：`Sources/tunnelpad/` 的 AppKit/SwiftUI UI、`AppDelegate`、`MenuBarController`、窗口/表单/日志交互。
- 替换目标：`Sources/TunnelPadCore/` 内的配置、执行器、探针、日志、迁移和生命周期实现。
- 保持不变：`config.json` schema、launchd label/路径、SSH command 参数、删除/退出/迁移回滚语义。
- 阶段 0–3 不允许：真实 `launchctl bootstrap/bootout`、真实 SSH 接管、真实配置删除或双 owner 并行控制。

## 未决项

1. C ABI wrapper 与 sidecar IPC 需要最小原型比较后再选型。
2. FFI/IPC DTO、错误分类、取消和版本策略尚未冻结。
3. Rust 实施要求先隔离当前未提交工作树，不能直接在现有混合 diff 上创建迁移提交。

## 结论

阶段 0 基线可用于进入设计和原型准备，但尚未达到阶段 1 的“待实施”标准；需要独立复核确认接口方案和干净实施基线后才能开始 Rust 代码工作。

## 阶段 0 本轮执行（2026-08-30 12:12）

- 复跑 `swift test`：74 个测试，0 失败。
- 复跑 `swift build -c release`：Release product `tunnelpad` 构建通过。
- 重新核对 `git rev-parse HEAD`、`git status --short`、Swift/Rust 版本、`Package.swift`、Core/UI 文件边界和 Rust 文件缺失：结果与上述基线一致。
- 未创建 Cargo 工程，未修改 `Package.swift`，未执行 `launchctl`、SSH、真实隧道启停/删除或 ECS 操作。
