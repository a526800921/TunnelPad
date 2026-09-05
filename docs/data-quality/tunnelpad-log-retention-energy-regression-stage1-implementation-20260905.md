# TunnelPad 日志保留与能耗回归修复：阶段 1 实施证据

- 日期：2026-09-05（Asia/Shanghai）
- 关联计划：[日志保留与能耗回归修复](../plans/tunnelpad-log-retention-energy-regression.md)
- 阶段：阶段 1
- 结论：实现完成；进入阶段 2 真实 Release 回归前置复核

## 实施范围

本阶段只修改 `LogFileRetention.trimIfNeeded` 及其隔离测试，未修改健康循环、`ProbeService`、Rust Core、HTTP API、配置 Schema、launchd label、真实配置或真实日志路径。

实现要点：

- 使用原始字节从文件尾部反向扫描 LF；LF 和 CRLF 均按一个逻辑行处理，裸 CR 保留为正文。
- 末尾有换行时反向定位 `maxLines + 1` 个 LF，末尾无换行时定位 `maxLines` 个 LF，原样保留尾部字节。
- 不再把整个文件解码为 `String` 后切分；大文件只读取定位所需的尾部范围，再读取待保留的最近 2000 行。
- 在加锁后、写入前核对文件身份、大小和修改时间；锁失败、文件变化或写入失败时保留原文件并延后重试。
- 写入前建立同目录临时 clone/copy 回滚副本，原位写回并保留现有文件路径与身份语义。

## 验证矩阵

| 场景 | 验证 | 结果 |
|---|---|---|
| LF 2001 行、末尾换行 | `testMemoryCacheKeepsLatest500AndFileKeepsLatest2000Lines` | 通过；保留最近 2000 行 |
| CRLF 2001 行、末尾换行 | `testRetentionCountsCRLFAndPreservesRawLineEndings` | 通过；CRLF 原始字节保留且行数正确 |
| 混合换行、末行无换行、裸 CR | `testRetentionSupportsMixedLineEndingsAndUnterminatedFinalLine` | 通过；裸 CR 未被解释为新行，未终止末行保留 |
| 空文件与小文件 | `testRetentionLeavesEmptyAndSmallFilesUntouched` | 通过；不产生伪造内容，不做无意义裁剪 |
| 大 CRLF 文件尾部扫描 | `testRetentionScansTailOfLargeCRLFFileForBoundedCost` | 通过；读取计数断言小于原文件一半，且保留 2000 行 |
| 锁失败与后续重试 | `testRetentionDefersWhenFileIsLockedAndRetriesLater` | 通过；锁占用时原文件不变，解锁后可重试 |
| 文件替换与增量采集 | `testFileReplacementResetsOffsetWithoutRepeatingOldContent` | 通过；不重复发布旧内容 |

## 回归与产物

| 命令/检查 | 结果 |
|---|---|
| `xcodebuildmcp swift-package test --package-path . --filter LogEventStoreTests --output text` | 15/15 通过 |
| `xcodebuildmcp swift-package test --package-path . --output text` | 144/144 通过 |
| `cargo test --manifest-path rust/Cargo.toml` | 76 个单元测试 + 1 个差分测试通过 |
| `xcodebuildmcp swift-package build --package-path . --target-name tunnelpad --configuration release --output text` | Release 目标构建通过 |
| `./scripts/build_app.sh --skip-tests` | arm64 Release `.app`、Rust 动态库、资源和 ad-hoc 签名校验通过 |
| `plutil -p dist/TunnelPad.app/Contents/Info.plist` | Bundle ID `com.jafish.tunnelpad.app`，`LSUIElement=true` |
| `dwarfdump --uuid dist/TunnelPad.app/Contents/MacOS/tunnelpad` | arm64 UUID `8D9C658D-F546-3EF0-BA3A-EFC83CEF29FF` |
| `xcodebuildmcp macos launch --app-path dist/TunnelPad.app --output json` | 真实 Release App 启动成功 |
| `GET http://127.0.0.1:9998/api/health` | `{"ok":true}` |
| `GET http://127.0.0.1:9998/api/tunnels` | 两条配置均为 `not_loaded`，未启动隧道 |
| 真实 Release App 无隧道约 35 秒 `top` 采样 | CPU 最高约 1.6%，未见固定周期高峰 |

## 影响与安全边界

GitNexus `detect_changes(scope=all, repo=TunnelPad)` 的结果为 CRITICAL，原因是共享日志入口的调用图影响：4 个已跟踪文件、19 个相关符号和多条日志读取/清空/同步执行流。实际实现范围仍只包含日志保留函数、日志测试及治理文档；没有健康循环、Rust owner、API、配置或真实隧道的计划外变更。

真实 Release 验证只启动 App，没有启动 `admin-tunnel` 或 `reverse-ssh`，没有读取或改写真实日志，没有调用隧道启停、ECS 或凭证相关操作。使用的 CPU 输出保存在 `/tmp/tunnelpad-log-retention-release-no-tunnels-20260905.txt`。

## 阶段结论

阶段 1 的代码实现、LF/CRLF/混合换行、末行无换行、空/小文件、大文件尾部扫描、锁失败/重试、Swift/Rust 回归、Release 构建和无隧道真实启动均已完成。下一步只进入阶段 2：先完成本计划的阶段 2 Step 0 与独立准入，再在用户授权的实际日志增长窗口验证长期 CPU/能耗和日志保留收敛；当前不以无隧道控制组替代真实日志 watcher 回归。
