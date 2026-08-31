# TunnelPad 日志事件流与面板生命周期阶段 0 基线证据

- 日期：2026-08-31
- 关联计划：[TunnelPad 日志事件流与面板生命周期](../plans/tunnelpad-log-streaming.md)
- 基线类型：行为迁移现状快照 + 隔离最小复现设计
- 结论：源码、日志路由、Rust owner 和并行工作树边界已完成只读核验；隔离最小复现、事件时序 fixture 和独立准入复核尚未完成

## 复核范围

本证据只覆盖日志事件流计划阶段 0。阶段 0 不修改 Swift/Rust 日志实现、不修改配置、不启停真实隧道、不删除或重写真实日志文件，也不生成构建产物。

当前工作树已有其他计划的未提交变更，不能把它们归入本计划：

- 备注阶段 1 相关的配置模型、Rust 配置序列化、表单和侧栏改动；其中 `Sources/tunnelpad/TunnelDetailComponents.swift` 与本计划未来面板范围重叠，暂不触碰。
- ECS 阶段 2 的计划文档及阶段证据。
- 本轮只新增本证据文档，并更新日志计划与 `PLAN_MAP.md` 的证据链接。

## Step 0 现状核验

### 工作树基线

| 项目 | 命令 | 结果 | 判定 |
|---|---|---|---|
| 基线提交 | `git rev-parse HEAD` | `90dba27b582411c6c836233cc3d1319c03593001` | 通过 |
| 现有变更 | `git status --porcelain=v1`、`git diff --stat` | 存在备注/ECS 计划相关变更；日志计划未新增实现代码 | 通过，按外部变更隔离 |
| 补丁格式 | `git diff --check` | 无空白错误 | 通过 |

### 当前日志 UI 基线

对干净 HEAD 中的 `Sources/tunnelpad/LogView.swift` 和 `Sources/TunnelPadCore/LogTail.swift` 进行只读核对：

- `LogView` 绑定 `appDelegate.isMainWindowVisible` 的视图任务；窗口可见时先 `load()`，随后每 `2_000_000_000` 纳秒再次 `load()`。
- `load()` 在后台调用 `LogTail.lastLines(of:maxLines:)`，上限为 500 行；只有完整尾部文本或文件存在状态变化时才写入 UI 状态。
- 当前基线没有统一的每隧道日志追加事件、独立订阅句柄、单调事件版本或面板关闭期间的事件快照链路。
- 因而，当前源码能证明“日志变化由下一次 Timer 驱动 UI 读取”，不能证明事件驱动实现已经存在。

证据命令：

```text
git show HEAD:Sources/tunnelpad/LogView.swift | rg -n 'task\\(id: appDelegate\\.isMainWindowVisible\\)|2_000_000_000|LogTail\\.lastLines|load\\(\\)'
```

输出命中 `task(id:)`、2 秒等待、`load()` 和 `LogTail.lastLines(... maxLines: 500)`。

### 当前 launchd 日志路由基线

对干净 HEAD 中的 Swift plist 渲染器和 Rust 路径实现进行只读核对：

- `LaunchdPlistRenderer` 将 `StandardOutPath` 和 `StandardErrorPath` 指向同一个 `logURL.path`。
- Rust `TunnelPaths.log_url` 从日志目录派生 `<tunnel-id>.log`；日志路径不由面板是否打开决定。
- 当前 owner 的 `start`、`stop`、`restart`、`remove` 以及退出清理仍由 Rust Core 统一承载；日志计划不得另起一套生命周期 owner。

证据命令：

```text
git show HEAD:Sources/TunnelPadCore/LaunchdPlistRenderer.swift | rg -n 'StandardOutPath|StandardErrorPath|plistDictionary|plistXMLData'
git show HEAD:rust/tunnelpad-core/src/paths.rs | rg -n 'logs_directory|log_url|\\.log'
git show HEAD:docs/adr/0001-rust-core-single-owner.md | rg -n '唯一生命周期 owner|配置.*Rust|version=1|关闭窗口'
```

输出确认 stdout/stderr 路由、按隧道日志路径、Rust 唯一 owner、`config.json` version=1 和“关闭窗口不停止隧道”的既有边界。

## 样本矩阵状态

| 样本 | 当前状态 | 证据或未完成原因 |
|---|---|---|
| 当前 UI 文件轮询基线 | 已完成 | 干净 HEAD 源码核验确认 2 秒 Timer、末 500 行和内容比较 |
| launchd 文件增量、分片 UTF-8、无换行尾部 | 未执行 | 阶段 0 尚未新增隔离采集器或测试 fixture |
| 文件截断/替换 | 未执行 | 尚无隔离事件采集实现，不能以现有 `LogTail` 尾读冒充增量验证 |
| 面板关闭/打开 | 未执行 | 尚无订阅/快照实现，不能以 UI 静态源码冒充时序验证 |
| 隧道切换与旧事件失效 | 未执行 | 尚无事件代次和订阅句柄 fixture |
| 自动滚动与内存缓存上限 | 未执行 | 当前 `NSTextView` 只覆盖现有文本刷新，事件缓存尚未实现 |
| 本地日志文件 2000 行保留上限 | 未执行 | 当前源码核验未发现该裁剪机制；并发追加/异常中断边界需隔离 fixture |
| 重启/文件恢复 | 未执行 | 尚无事件缓存恢复实现；文件路径基线已确认 |
| 治理与反向引用 | 部分完成 | 功能图谱校验通过、`git diff --check` 通过；普通治理检查通过但有并行计划重叠警告，严格检查仍受备注计划阶段元数据不一致阻塞 |

## Step 0 尚未完成项

仍缺少以下可执行隔离最小复现：

1. 可控日志追加后，现状 UI 只能在下一次 2 秒 Timer 到达时看到变化。
2. 面板关闭期间没有事件订阅时，现状无法实时交付；重新打开需要重新读取快照。
3. 日志超过 2000 行时，现状没有安全裁剪机制。

这些复现应使用 fake executor、隔离日志文件和可控输出，并把输出落在新的阶段证据或测试证据中。由于本轮只获准推进治理文档、未获准新增测试代码，不能把上述项目标记为通过，也不能把日志计划阶段 0 转为 `待实施`。

## 并行边界记录

- 日志计划阶段 0 的文档、基线和 fixture 设计可与备注阶段 1、ECS 阶段 2 设计并行。
- 日志实现涉及 `TunnelManager`、`TunnelRuntimeState`、`MainPanelView`、`TunnelDetailComponents` 和共享测试目录时，必须等待共享文件的单一编辑窗口；备注侧栏改动和稳定性生命周期改动不得同时改同一文件。
- ECS 阶段 2 只有在外部命令适配器和测试完全隔离时才可并行；其计划中的 `TunnelManager` 启动/重启前置与日志/稳定性生命周期编排必须串行合入。

## 后续准入条件

阶段 0 仍保持 `设计中`。进入日志阶段 1 前，必须补齐隔离最小复现和事件时序 fixture，冻结日志 owner、缓存/文件裁剪失败边界，完成共享模块影响复核，并由独立复核明确达到 `待实施` 标准。
