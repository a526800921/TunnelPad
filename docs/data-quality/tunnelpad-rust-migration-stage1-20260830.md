# TunnelPad Rust Core 迁移：阶段 1 证据

- 日期：2026-08-30
- 范围：C ABI 最小原型与契约冻结；不接入 Package.swift 产品目标，不操作真实隧道
- 对应计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)
- 基线：阶段 0 复验基线（HEAD `64e126fa` 工作树干净）+ Rust 1.96.0

## 交付物

- Rust workspace：`rust/`（crate `tunnelpad-core`，`staticlib` + `rlib`；`rust/.gitignore` 排除 `target/`，`Cargo.lock` 随仓提交）。
- 契约头文件（单一事实源）：`rust/include/tunnelpad_core.h` + `module.modulemap`。
- Swift 兼容调用样本：`rust/smoke/main.swift`（swiftc 直链静态库，不改动 `Package.swift` 与 `Sources/`）。
- 验证脚本：`rust/scripts/smoke.sh`（cargo build/test → swiftc 链接 → ad-hoc 签名与校验 → 运行断言）。

## 样本矩阵结果

| # | 命令/操作 | 结果摘要 | 判定 |
|---|---|---|---|
| 1 | `cargo test --manifest-path rust/Cargo.toml` | 15 个测试，0 失败（DTO round-trip、Swift 缺省值对齐、错误分类、所有权释放、launchd label） | 通过 |
| 2 | swiftc 编译样本链接静态库并运行 | `SWIFT SMOKE: 全部通过`：29 项断言（ABI 版本、完整/最小 config round-trip、缺省字段补全、错误码 1–5、TunnelStatus 四 case、ProbeResult 三 case、last-error 清空、`tp_string_free(NULL)` 安全） | 通过 |
| 3 | Release 链接 + 签名 | `cargo build --release` 产出 `libtunnelpad_core.a`；`swiftc -I rust/include -L rust/target/release -ltunnelpad_core` 链接成功；`codesign --force --sign -` + `codesign --verify --strict` 通过；`file`/`lipo -archs` 确认 arm64 Mach-O | 通过 |
| 4 | `swift test`（既有回归） | 74 个测试，0 失败（原型未影响任何既有行为） | 通过 |
| 5 | `git status --short` 边界审计 | 仅新增 `rust/`；无既有 Swift/docs 修改、无未跟踪杂项 | 通过 |

## 门槛核对（阶段 0 冻结的 5 项）

| # | 门槛 | 结果 |
|---|---|---|
| 1 | 表达完整性 | 通过：`AppConfig`/`TunnelConfig`/`ProbeConfig`/`ExecutorKind`（serde 键序与 Swift CodingKeys 一致、缺省值语义对齐、probe 缺省省略）；`TunnelStatus` 四 case（pid 可空）、`ProbeResult` 三 case、错误码 0–5 与版本字段全部可无损表达 |
| 2 | 内存与所有权 | 通过：分配方/释放方规则冻结（Rust 分配、`tp_string_free` 释放、禁止 free、单次释放、NULL 安全）；Rust FFI 测试与 Swift 样本两侧覆盖 |
| 3 | Swift 兼容调用 | 通过：独立 swiftc 样本调用全部 6 个 API 并断言通过 |
| 4 | 取消/退出映射 | 通过：方案已冻结并写入计划「阶段 1 契约冻结」（Swift 拥有并发；Rust 同步函数、无线程、无跨调用状态；busy/generation 门禁保留 Swift；退出路径保持 Swift 串行直调） |
| 5 | 发布链接样本 | 通过：arm64 Release 静态库链接 + ad-hoc 签名校验；`.app` 打包接入按计划留阶段 4 |

## 比较指标

- 契约规模：6 个 C ABI 函数、6 个错误码、7 个契约类型（AppConfig/TunnelConfig/ProbeConfig/ExecutorKind/TunnelStatus/ProbeResult/TpError）。
- 测试覆盖：Rust 单元/FFI 测试 15 项；Swift 兼容断言 29 项；既有 Swift 回归 74 项。
- 工具链：rustc/cargo 1.96.0，target `aarch64-apple-darwin`。
- sidecar 备选：未触发（5 项门槛全部成立）。

## 安全边界

- 未执行 launchctl/SSH/真实隧道启停、迁移接管或配置删除；所有样本数据为 fake。
- 未修改 `Package.swift`、`Sources/`、`scripts/`、`App/`；Rust 代码仅在 `rust/`。
- 未读取或记录私钥、AccessKey 等敏感信息。

## 结论

阶段 1 完成条件中的实现与验证部分已全部满足；等待独立完成复核确认契约冻结与阶段 2 准入。
