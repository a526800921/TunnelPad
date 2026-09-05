# TunnelPad 能耗阶段 2：隔夜复验与日志热点诊断

- 日期：2026-09-05（Asia/Shanghai）
- 关联计划：[后台健康监测能耗优化](../plans/tunnelpad-health-monitor-energy.md)
- 基线类型：隔夜真实 Release App、连续 CPU 采样、活动监视器读数、两次运行栈采样、日志元数据与换行统计。
- 结论：未通过；阶段 2 隔夜能耗复验失败，日志裁剪热点未修复。此前短窗口通过仅保留为历史证据。
- 操作边界：本轮只读诊断并更新文档；未重启 App、启停隧道、清空或裁剪真实日志、修改源码或重新构建。

## 运行产物核验

- 当前 App PID `70993`，启动于 `2026-09-04 17:28:12`；09-05 11:37 仍是同一进程，持续运行约 18 小时。
- `dist/TunnelPad.app/Contents/MacOS/tunnelpad` 修改时间为 `2026-09-04 17:28:07`，早于进程启动时间。
- 仓库 HEAD 为 `7576e6842f90957789a8d52853cff8db4d8000ad`；本轮开始时只有两份计划文档未提交，无源码变更。
- App 与 `.build/arm64-apple-macosx/release/tunnelpad` 的 Mach-O UUID 都是 `9C649E1E-5505-32C3-BAF7-D484CD7AC1FE`。
- 两者 `otool -s __TEXT __text` 数据输出（去掉前两行文件标识）的 SHA-256 均为 `74beed75187dc1fddb52a8549281e7a72df82049efd84ddf1131b6a4806b3511`。
- App 符号表含 `ProbeSession`、`runHealthProbeCycle` 和 `settleLifecycleStatus`；签名校验成功。
- 整个可执行文件的哈希与大小不同，不能单凭此判断版本不同：打包流程会重新签名；上面的 UUID 和代码段比较确认代码一致。

这些证据排除了“没有重新打包/仍运行上一个旧进程”的解释。

## 隔夜 CPU 与能耗

同一任务此前在 09-05 11:04–11:05 对该进程执行 `top -l 66 -pid 70993 -stats pid,cpu,threads,time -s 1`，66 个采样实际覆盖约 71 秒。多数样本为 `0%`，但反复出现约 10 秒周期的短峰：

| 时间 | CPU |
|---|---:|
| 11:04:43 | 21.7% |
| 11:04:52 | 26.4% |
| 11:05:03 | 26.6% |
| 11:05:13 | 17.6%（下一采样 9.0%） |
| 11:05:24 | 23.4% |
| 11:05:34 | 26.3% |
| 11:05:44 | 25.5% |

活动监视器能耗页两次读取为 `282.5`、`279.7`，12 小时字段为 `131.33`。这些是各自观测时刻的系统指标，不是瓦数，也不代表一整夜的逐秒记录。不能将此前 `0.5` 或 `7.3` 的短窗口读数外推为长期改善比例。

本机 API 显示两条隧道均 `running`，`admin-tunnel` 为 `401/satisfied`。当前两个 launchd 注册实例均 `runs = 1`；SSH PID 与昨晚启动时不同，因此本次快照不能证明两个 SSH 进程整夜从未重建，也不能据此推断重建原因。

## 运行栈与日志变化证据

两次执行系统采样，均未暂停进程或触发生命周期动作：

```bash
/usr/bin/sample 70993 35 2 -file /dev/stdout
/usr/bin/sample 70993 22 5 -file /dev/stdout
```

第一段开始于 `11:37:28.910`，第二段开始于 `11:39:05.788`。两次忙碌工作线程的突出路径一致：

```text
LogEventStore.ensureWatcher 回调
  → fileDidChange                         LogEventStore.swift:422
  → refreshState                         LogEventStore.swift:446
  → LogFileRetention.trimIfNeeded         LogEventStore.swift:169,173
  → Collection.split / String 字符遍历
```

第二段该 watcher 分支采到 113 个栈样本，其中 111 个在 `trimIfNeeded` 的第 173 行切分路径，另 2 个在第 169 行读取路径。这是该分支的采样计数，不能直接当作全进程 CPU 百分比。第一段另采到少量配置读取栈；不能再仅根据 10 秒周期把热点归因于 `loadConfig` 或网络会话初始化。

日志只统计大小、换行和固定类别，不保存真实日志正文：

| 文件 | 字节数 | LF 数 | CRLF 数 | 单独 LF 数 | NUL 数 |
|---|---:|---:|---:|---:|---:|
| admin-tunnel.log | 8,445,721 | 83,516 | 83,516 | 0 | 0 |
| reverse-ssh.log | 364,625 | 5,775 | 5,775 | 0 | 0 |

`11:39:04 → 11:39:14 → 11:39:24` 的 admin 日志 mtime 间隔各 10 秒；文件依次为 `8,444,493 → 8,444,800 → 8,445,107` 字节，每次增长 307 字节。最近 60 行统计包含 20 次转发连接、20 次 direct-tcpip channel 创建和 20 次释放。

## 根因与证据边界

1. 每 10 秒的既有 HTTP 探针经过 SSH 本地转发，产生 channel 调试日志。日志变化和该节奏吻合；生产配置已启用 SSH verbose 日志。
2. `refreshState` 在增量读取之前，无条件调用 `trimIfNeeded`；该方法读取全文件，再执行 `text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)`。
3. Swift 将 `"\r\n"` 视为一个 `Character`，与单独 `"\n"` 不同；真实文件全部为 CRLF，按当前字符切分会漏计换行，导致 2000 行裁剪门槛失效。该语义见 [Swift 核心开发者说明](https://forums.swift.org/t/r-n-is-one-character/1215/2)及 [Apple Character.isNewline 文档](https://developer.apple.com/documentation/swift/character/isnewline)。这是源码与真实输入推导出的缺陷，本轮没有执行会改写真实日志的裁剪调用。
4. 因而小量追加触发大文件全文字符扫描，并随着未被裁剪的文件增长放大成本。运行栈直接确认当前主要热点在此路径；外部 SSH 输出是触发输入，应用日志处理是缺陷所在。

当前日志保留测试使用 LF 文本及同类 split 计数，未覆盖 CRLF 持久日志。之前的短窗口验收没有覆盖这一真实大日志形态，不能证明所有 10 秒能耗峰值已消失。没有昨晚连续栈记录，因此不声称该缺陷一定是隔夜才出现。

## 拟议修复与再次验收

- 修正 LF/CRLF 的行边界识别；优先采用字节级定位以保留原始日志字节，遵守 [ADR-0003](../adr/0003-log-event-stream-and-retention.md) 的 2000 行与原位、安全保留边界。
- 避免每次几百字节追加都全文解码、逐字符切分；裁剪检查本身也应具备有界开销，覆盖失败延后和重试场景。
- 补充 LF、CRLF、混合换行、末行未结束、大日志小追加、锁失败和并发写入的隔离样本；随后才验证真实长期 CPU/能耗与日志行数收敛。
- 以上为拟议变更，尚未实现或获得本次修复的独立准入；不以清空用户日志、关闭探针或降低日志级别代替修复。

本记录是当前阶段未满足完成条件的反证，计划继续保持实施中；历史完成快照不代表本次复验通过。

## 文档检查

- `git diff --check`：通过。
- `plan-governance-cli check .`：通过，保留“最新复核未通过”的 WARNING。
- `plan-governance-cli check . --strict-readiness`：未通过，原因是当前最新复核明确失败；不能将本次诊断写成新增修复准入通过。历史复核追加保留，日期和当前结论同步。
