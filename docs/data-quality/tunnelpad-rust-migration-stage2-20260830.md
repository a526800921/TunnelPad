# TunnelPad Rust Core 迁移：阶段 2 证据

- 日期：2026-08-30
- 范围：9 类组件 parity + 跨语言差分测试；不接入产品路径，不操作真实隧道
- 对应计划：[TunnelPad Rust Core 迁移](../plans/tunnelpad-rust-migration.md)
- 基线：阶段 1 完成态（HEAD `adfb12e`）

## 交付物

`rust/tunnelpad-core/src/` 新增组件模块（对照 Swift 事实源）：

| 模块 | Swift 事实源 | 说明 |
|---|---|---|
| `paths.rs` | TunnelPaths.swift | 全部磁盘路径；测试可注入 home |
| `tunnel_id.rs` | TunnelID.swift | slug 生成、冲突 `-2/-3`、`tunnel` 回退 |
| `ssh_command.rs` | SSHCommand.swift | `-v` 精确增删、isSSH/hasVerboseFlag |
| `apple_json.rs` | ConfigStore 保存编码 | Apple 风格 prettyPrinted+sortedKeys 字节级对齐写盘器 |
| `plist_render.rs` | LaunchdPlistRenderer.swift | plist XML 渲染 + 原子写入 |
| `launchctl.rs` | LaunchCtlExecutor.swift / ProcessRunner.swift | 可注入 runner、bootstrap/bootout/status、print 输出解析 |
| `config_store.rs` | ConfigStore.swift | 读写、损坏留档 `config.json.corrupt-<stamp>`、重建空配置 |
| `app_executor.rs` | AppProcessExecutor.swift | 真实子进程托管、pidfile、SIGTERM→5s→SIGKILL、keepAlive 重启计划 |
| `probe.rs` | ProbeService.swift | 三态判定，HTTP 传输注入 |
| `log_tail.rs` | LogTail.swift | 尾部读取（含结尾换行处理） |
| `legacy.rs` | LegacyImporter.swift | 扫描/解析（XML plist 子集）、派生规则 |
| `migration.rs` | MigrationService.swift | 备份→bootout→bootstrap→验证→回滚编排 |
| `shutdown.rs` | Shutdown.swift | stop-all 编排（fake 执行器单元测试覆盖） |

差分设施：`rust/differential/fixtures/`（12 个 fixture 文件、约 40 个用例）、
`Tests/TunnelPadCoreTests/DifferentialHarnessTests.swift`（Swift 侧事件产出）、
`rust/tunnelpad-core/tests/differential.rs`（Rust 侧执行 + 语义等价对比）、
`rust/scripts/differential.sh`（门禁脚本）。

## 样本矩阵结果

| # | 命令/操作 | 结果摘要 | 判定 |
|---|---|---|---|
| 1 | `cargo test` | 30 项组件单元测试 + 1 项差分测试，全过 | 通过 |
| 2 | `rust/scripts/differential.sh` | Swift/Rust 在全部 fixture 上事件流一致（含 config 读写、损坏恢复、ID、SSH、plist、launchctl 三操作、探针、日志、legacy 扫描/派生、迁移接管 4 场景、app 执行器真实子进程生命周期） | 通过 |
| 3 | 故障注入 | 损坏留档+重建、runner 失败/耗尽、bootstrap 失败回滚（含 bootout not-found 不算错误）、verify 失败、空命令、非法 URL、非 UTF-8 日志、二进制垃圾 plist | 通过 |
| 4 | `swift test` | 75 项通过（74 项既有 + 1 项差分 harness 产出测试），既有行为无变化 | 通过 |
| 5 | `git status` 边界审计 | 仅 `rust/` 修改/新增与新增 `Tests/TunnelPadCoreTests/DifferentialHarnessTests.swift`；无既有 Swift/docs 行为改动 | 通过 |

## 判定口径落实（阶段 2 Step 0）

- **config.json 差分按解码后语义等价判定**：两侧事件流以 serde_json::Value 相等比较（键序无关）。
- **写盘字节对齐可行性已验证：可行**。`apple_json.rs` 按实证探针格式（2 空格缩进、`"key" : value`、`\/` 转义、空数组 `[⏎⏎  ]`）实现，差分中 `saveContent` 字符串字节级一致（含空 tunnels、中文、引号/反斜杠、正斜杠转义用例）。
- **plist XML 字节对齐**：`plist_render.rs` 与 PropertyListSerialization 输出字节一致（TAB 缩进、键字母序、`<true/>`、XML 实体转义）。

## 差分归一化约定（两侧一致）

- 临时 home 路径 → `<home>`；`yyyyMMdd-HHmmss` 时间戳 → `<stamp>`（本地时区 vs Rust UTC 的差异归一化）；app 执行器日志时间戳 → `[<ts>]`；真实 pid → `<pid>`（pidfile 内容与 running 状态）。
- 错误文案文本（`String(describing:)` 与 Rust `Debug`）不作等价判定；判定对象为错误 case 与结构化载荷（label/exit_code/stderr/message 原文）。

## 已知边界（记录，不阻塞）

- `Shutdown.stopAllManagedTunnels` 的 launchd 分支：Swift 事实源硬编码 SystemProcessRunner，无法在不触碰真实 launchctl 的前提下差分（阶段 0–3 禁止），以 Rust 单元测试（fake 执行器）覆盖编排语义；app 分支 killByPidfile 语义在 Rust 对等实现并有测试。
- legacy plist 解析覆盖 XML 子集（差分 fixture 均为 XML）；二进制 plist 不在矩阵内。
- app 执行器 keepAlive 的延迟重启：Swift 为 terminationHandler 事件驱动，Rust 为 `handle_exits()` 轮询驱动（返回待重启计划，由并发所有者执行）——并发所有权在 Swift 的契约映射不变。

## 安全边界

- 未执行 launchctl/SSH/真实隧道启停、迁移接管或配置删除；launchctl 全部走 fake runner；app 执行器场景仅 spawn `/bin/sleep 2`。
- 全部文件操作在隔离临时目录；未修改 `Package.swift`、`Sources/`、`scripts/`、`App/`。

## 结论

阶段 2 完成条件中的实现与验证部分已全部满足；等待独立完成复核确认 parity 与阶段 3 准入。
