# ADR-0002：App bundle ID 迁移至 com.jafish.tunnelpad.app

- 状态：已接受
- 日期：2026-08-30
- 范围：App 打包身份与菜单栏集成

## 背景

### 现象

2026-08-29 起，bundle ID 为 `com.jafish.tunnelpad` 的 app 菜单栏图标不再显示；系统设置 → 控制中心 → 菜单栏面板中该身份的条目与开关仍然存在且为开启态。该问题在 2026-08-30 22:16 整机重启后依旧存在。

### 根因

1. **托管模型**：Tahoe 上第三方 app 的 NSStatusItem 不由 app 自己渲染——实测所有 layer-25 菜单栏窗口的属主都是 ControlCenter 进程（含 Docker、Stats 等经典 NSStatusItem app）。app 只负责注册图标，渲染与放置由 ControlCenter 决定；系统还按 bundle ID 持久记录每个 app 的菜单栏项（即设置面板中按 app 列出的条目）。
2. **记录损坏**：`com.jafish.tunnelpad` 的持久宿主记录损坏为僵尸绑定——条目仍在、指向的宿主窗口已死。此后每次启动注册的新状态项按 bundle ID 匹配到坏记录后被丢弃，图标永不渲染；面板条目正常显示造成"已注册"的假象。
3. **最可能触发**：app 在状态项正被托管时崩溃（2026-08-29 16:48 与 2026-08-30 11:00 两次 `tunnelpad` 进程崩溃报告，见 `~/Library/Logs/DiagnosticReports/Retired/`）。v1 时代 autosave 标识曾被系统"缓存为无效宿主窗口"（见 MenuBarController 历史注释），属同类损伤，说明该故障模式可重复发生。
4. **不可修复性**：记录位于系统私有存储。用户态全量检索无果——`com.apple.controlcenter` 主域/ByHost（含 bentoboxes、displayablemenuextras 的内嵌 bplist 递归解码）、`com.apple.systemuiserver`、app 自身 defaults 域、`~/Library/Containers`、`~/Library/Application Support`、`/var/folders` 用户目录，并以一次性字符串 `tunnelpad.trial3` 做全文取证，均未找到任何按 bundle ID 键控的记录；且损坏跨越整机重启。结论：该存储用户态不可读、不可改。

### 排除项

- **非图标资源问题**：菜单栏图标为代码绘制（`makeMenuBarIcon`），不经过 asset catalog，无图片缓存环节。
- **非二进制/代码回归**：同一二进制换任意新 bundle ID 后图标立即可见（2026-08-30 三次闭环实验：status-trial 22:39、trial3 23:25、正式迁移后 23:28）。
- **非 LS / autosave / app prefs**：`lsregister` 注销死路径并强制注册真实路径、autosave 标识 v2→v3、清理 app defaults 域，均无效。
- **autosave 版本化假设已被证伪**："(bundle ID, autosave) 组合缓存"理论与三次实验结果矛盾（v3 全新组合同样不显示），键控维度是 bundle ID 本身。

## 决策

1. App bundle ID 由 `com.jafish.tunnelpad` 迁移至 `com.jafish.tunnelpad.app`（唯一定义点 `App/Resources/Info.plist`）。
2. 旧 ID `com.jafish.tunnelpad` 永久退役，不再用于任何 app 身份；其系统侧宿主记录已损坏且不可清除。
3. launchd 标签前缀 `com.jafish.tunnelpad.<tunnel-id>` 保持不变（`TunnelConfig.launchdLabelPrefix` 独立于 app 身份）；配置目录 `~/Library/Application Support/TunnelPad`、日志 `~/Library/Logs/TunnelPad` 按名不按 ID，均不受影响。唯一损失为旧 defaults 域中的窗口位置记忆。
4. 菜单栏 status item autosave 保持无版本号 `com.jafish.tunnelpad.menu-bar`，停止版本化递增；新 ID 下该记录全新，无需再绕行。
5. 治理同步：本 ADR 是根因与身份决策的唯一事实源；`docs/plans/tunnelpad-v1.md` 打包约定行与 `MenuBarController` 注释链接/对齐到本结论。

## 后果

### 正面

- 菜单栏图标恢复并经实机截图验证；隧道管理与 launchd 集成零影响（AX 树确认 admin-tunnel、reverse-ssh 正常）。
- 新身份的宿主记录全新，历史污染不再触达。

### 代价与风险

- 旧 defaults 域 `com.jafish.tunnelpad` 遗留（仅窗口 frame），可择机 `defaults delete` 清理。
- 系统设置面板曾短暂残留旧身份僵尸条目；观察为重启后被系统自行回收，无需人工处理。
- **崩溃诱因未消除**：app 在状态项正被托管时崩溃仍可能污染新身份的记录（本 ADR 假定的触发路径）。降低崩溃率由 `tunnelpad-stability` 计划承担。若新身份复发，处置预案即再次迁移 bundle ID（成本一行）并回归本 ADR 记录触发场景。
