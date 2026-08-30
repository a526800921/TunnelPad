# TunnelPad Rust Core 迁移：阶段 0 基线证据

- 日期：2026-08-30
- 范围：只读架构/工具链/行为基线；不创建 Rust 工程，不操作真实隧道
- 对应计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)

## 基线结论

当前项目仍由 SwiftUI/AppKit + SwiftPM 构成，产品目标为 `TunnelPadCore` 库与 `tunnelpad` 可执行目标；仓库没有 `Cargo.toml`、Rust 源码或 Rust target。用户已确认 Rust 迁移边界为：保留 SwiftUI/AppKit，只逐步替换 `TunnelPadCore`。

首轮基线执行时工作树不是干净基线：包含 Swift Core/UI 重构、侧栏 UI 调整、ECS 计划/fixture 等未提交改动；这些改动已于 2026-08-30 作为独立提交落库，干净基线复验结果见文末「阶段 0 基线复验」。Rust 实施要求从独立、可复现的提交开始，后续继续保持 Rust 变更与其他计划隔离。

## 可复现样本矩阵（首轮基线，2026-08-30 12:03–12:12，HEAD b6ffd22）

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

1. 已确认以 C ABI wrapper 为默认路径，需完成最小原型验证；若未达到安全、契约或发布门槛，再启用 sidecar IPC 备选。
2. FFI/IPC DTO、错误分类、取消和版本策略尚未冻结。
3. Rust 实施要求继续保持独立变更隔离，不能把其他计划的改动混入迁移提交。

## 结论

阶段 0 基线可用于进入设计和原型准备，但尚未达到阶段 1 的“待实施”标准；需要通过独立准入复核后，才能进入阶段 1 的原型实施与 Rust 代码工作。

## 阶段 0 本轮执行（2026-08-30 12:12）

- 复跑 `swift test`：74 个测试，0 失败。
- 复跑 `swift build -c release`：Release product `tunnelpad` 构建通过。
- 重新核对 `git rev-parse HEAD`、`git status --short`、Swift/Rust 版本、`Package.swift`、Core/UI 文件边界和 Rust 文件缺失：结果与上述基线一致。
- 未创建 Cargo 工程，未修改 `Package.swift`，未执行 `launchctl`、SSH、真实隧道启停/删除或 ECS 操作。

## 本轮计划同步（2026-08-30）

- 暂定采用“C ABI 主路径 + Swift Core 可回退”作为默认 bridge 方案（已于同日经用户确认为默认方案，见下节）；sidecar IPC 仅在 C ABI 原型未达到安全、契约或发布门槛时作为备选。
- 本轮同步计划基线、复验与决策记录；未创建 Cargo 工程、未修改 Swift 实现。

## 阶段 0 基线复验（2026-08-30，HEAD 64e126fa）

- `git rev-parse HEAD` → `64e126fa0f334984cd7b262a845afdc5dff0828b`；`git status --short` 无输出，工作树干净，无未提交或未跟踪文件。
- 首轮基线的未提交改动已作为 `4fcf94b`（Core 拆分重构）与 `64e126f`（ECS SSH IP 同步命令）等提交落库，即当前干净基线的内容来源。
- 在 HEAD `64e126fa` 复跑 `swift test`：74 个测试，0 失败。
- 在 HEAD `64e126fa` 复跑 `swift build -c release`：Release product `tunnelpad` 构建通过。
- 本轮未复跑 `build_app.sh` 打包与签名校验（沿用首轮基线记录）；未创建 Cargo 工程，未执行 `launchctl`、SSH、真实隧道启停/删除或 ECS 操作。

## 默认 bridge 方案确认（2026-08-30）

- 用户确认默认采用“C ABI 主路径 + Swift Core 可回退”作为默认 bridge 方案；sidecar IPC 仅在 C ABI 原型未达到安全、契约或发布门槛时作为备选。
- 方案确认后，阶段 0 剩余准入门槛为独立准入复核；本轮未创建 Cargo 工程、未修改 Swift 实现。

## 阶段 0 收尾

- 2026-08-30 独立准入复核通过（复核者：独立复核 subagent）：复核者独立复跑基线命令与 `swift test` 74/74、Release 构建，逐条核对完成条件与 AGENTS.md 阶段准入最低条件，全部通过；阶段 1 准入草案同步达到待实施标准。
- 复核记录见专项计划「最新独立准入复核」与「独立复核记录」。
