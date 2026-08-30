# TunnelPad Rust Core 迁移：阶段 4 Step 0 时间戳兼容证据

日期：2026-08-30
计划：[tunnelpad-rust-migration.md](../plans/tunnelpad-rust-migration.md)

## 结论

阶段 4 的时间戳兼容前置、进程内 shadow bridge、回退路径和 Release 接入已完成本机实现验证，并经独立准入复核通过。用户已确认 Rust 跟随 Swift 的系统本地时区；Swift `TunnelManager` 仍是唯一生命周期 owner，Rust 只做非权威配置校验。

## Step 0 基线

- Swift `ConfigStore.timestamp` 和 `AppProcessExecutor.timestamp` 使用 Foundation `DateFormatter` 的默认系统本地时区。
- Rust 原实现使用 UTC，可能使 `config.json.corrupt-*`、迁移备份和 app 日志的墙上时间与 Swift 不一致。
- 用户确认采用兼容优先方案：Rust 使用系统本地时区，不改变既有 Swift 的文件名和日志时间语义。

## 实现

- `system_timestamp()` 和 `local_log_timestamp()` 均通过 `libc::localtime_r` 获取本地时间组件。
- `localtime_r` 失败或时间超出 `time_t` 可表示范围时回退到 UTC 组件，避免时间戳生成失败阻断配置留档或日志写入。
- 将原 `utc_log_timestamp` 按调用图重命名为 `local_log_timestamp`，消除函数名与行为不一致。
- 新增 `RustCoreShadow`：按 ABI v1 动态加载 app bundle 内的 `libtunnelpad_core.dylib`，先验证 `tp_abi_version`，再调用 `tp_config_parse` 并立即释放结果；缺失库、真实 ABI v2、不兼容符号或解析失败均返回回退结果。
- 新增 `rust/fixtures/incompatible-core` 真实 ABI v2 `cdylib` fixture，覆盖不依赖模拟后端的版本拒绝路径。
- `TunnelManager` 仅在配置初始加载、同步和异步重载后调用 shadow 校验，忽略 shadow 结果，不改变配置、状态、提示或生命周期操作。
- `scripts/build_app.sh` 先构建 Rust `cdylib`，把 install name 固定为 `@rpath/libtunnelpad_core.dylib`，再复制到 `.app/Contents/Frameworks/` 并纳入 ad-hoc 签名。
- 没有修改 `config.json` schema、launchd 语义或真实隧道路径；Release App AX 检查未点击启停、删除、退出或其他真实隧道操作。

## 样本矩阵

| # | 输入/基线 | 可执行命令或操作 | 预期结果 | 失败判定 | 输出位置 |
|---|---|---|---|---|---|
| 1 | 固定 Unix epoch `0` 与本机系统时区 | `cargo test --manifest-path rust/Cargo.toml config_store::tests::fixed_epoch_uses_local_components_and_swift_formats` | Rust 使用本机 `localtime_r` 组件，并生成 Swift 兼容的 `yyyyMMdd-HHmmss` / `yyyy-MM-dd HH:mm:ss` 形状 | 组件、格式或范围不符 | cargo 输出 |
| 2 | 当前本机时钟 | `cargo test --manifest-path rust/Cargo.toml config_store::tests::public_timestamps_use_local_clock_and_expected_shapes` | 两个公开时间戳函数使用本地时钟且格式长度/分隔符正确 | 任一断言失败 | cargo 输出 |
| 3 | 固定时区与 DST 期望值 | `cargo test --manifest-path rust/Cargo.toml config_store::tests::fixed_epochs_match_known_timezone_and_dst_offsets` | `UTC0`、`CST-8`、`PST8PDT` 的固定 epoch 分别命中独立预期墙上时间 | 任一时区偏移或 DST 断言失败 | cargo 输出 |
| 4 | Rust Core 组件和 demo 生命周期 | `cargo test --manifest-path rust/Cargo.toml`；`./rust/scripts/differential.sh` | Rust 38 个单测 + 1 个差分测试通过，Swift/Rust 差分全绿 | 任一失败或事件流分叉 | cargo/Swift/Rust 输出 |
| 5 | Swift 回归与 shadow 回退/成功 | `swift test` | Swift 80/80；缺失库、ABI 不匹配、解析失败回退通过；真实 Release dylib 成功加载并验证有效/无效 config | 任一失败、跳过真实 dylib 或 Swift 行为改变 | Swift 输出 |
| 6 | arm64 C ABI 发布样本 | `./rust/scripts/smoke.sh` | Rust staticlib、Swift 兼容样本、ad-hoc 签名、arm64 检查和 ABI 断言全部通过 | 构建、签名、架构或断言失败 | smoke 输出 |
| 7 | Release App 与 UI/AX 边界 | `./scripts/build_app.sh --skip-tests`；Release App 只读 AX 检查；`git diff --check` | `.app` 含 arm64 Rust dylib、签名通过、`LSUIElement=true`；窗口和主要控件可访问；未执行真实隧道操作 | 复制、签名、架构、AX 或边界审计失败 | build_app/AX/git 输出 |
| 8 | 计划治理 | `plan-governance-cli check . --strict-readiness` | 阶段 4 文档、状态和独立复核记录同步 | 治理检查失败或阶段状态漂移 | 治理输出 |

## 本轮验证结果

- `cargo test --manifest-path rust/Cargo.toml`：38 个单测 + 1 个差分测试通过。
- `swift test`：80/80 通过；`RustCoreShadowTests` 的缺失库、真实 ABI v2、不兼容解析、解析失败和真实 Release dylib 加载均通过，相关用例未跳过。
- `./rust/scripts/differential.sh`：Swift harness 与 Rust 差分均通过。
- `./rust/scripts/smoke.sh`：既有 staticlib C ABI、Swift 兼容样本、arm64 和 ad-hoc 签名检查均通过。
- `./scripts/build_app.sh --skip-tests`：生成 `dist/TunnelPad.app`；`Contents/Frameworks/libtunnelpad_core.dylib` 存在，主程序和 dylib 均为 arm64，`otool -L` 仅显示 `@rpath/libtunnelpad_core.dylib` 与系统库，`codesign --verify --deep --strict`、`plutil -lint` 和 `LSUIElement=true` 校验通过。
- Release App 只读 AX：窗口、侧栏隧道列表、状态区、启动/停止/重启/删除按钮、日志区、自动滚动、刷新和复制控件均可见；未点击启停、删除、退出或其他真实隧道操作。

## 当前边界

- 本证据同时记录阶段 4 shadow bridge 的实现验证；Rust 仍不是生命周期 owner，也没有新增生命周期 C ABI。
- SwiftPM 不依赖预装 Rust 库：缺失动态库时由 `RustCoreShadow` 安全回退；Release `.app` 由构建脚本携带动态库。
- 未执行真实 launchd、SSH 或用户隧道启停/删除操作；AX 检查只读取当前窗口树。
- `cargo fmt --check` 的全仓失败仍是阶段 2 遗留格式差异；本次只保持新增代码局部格式，不进行全仓格式化。

## 后续边界

阶段 4 的样本矩阵、独立准入复核和严格治理检查均已通过，阶段 4 已关闭。若继续推进，只能在用户明确决定后另行设计和准入阶段 5；阶段 5 仍保持可选粗粒度设计，不因阶段 4 完成自动接管真实隧道或删除 Swift Core。
