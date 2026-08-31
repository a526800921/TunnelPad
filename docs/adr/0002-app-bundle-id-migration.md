# ADR-0002：App bundle ID 迁移至 com.jafish.tunnelpad.app

- 状态：已接受
- 日期：2026-08-30（2026-08-31 补充证据）
- 范围：App 打包身份与菜单栏集成

## 背景

### 现象

2026-08-29 起，bundle ID 为 `com.jafish.tunnelpad` 的 app 菜单栏图标不再显示；系统设置 → 控制中心 → 菜单栏面板中该身份的条目与开关仍然存在且为开启态。该问题在 2026-08-30 22:16 整机重启后依旧存在。

### 根因

1. **托管模型（本机观测）**：在当前 Tahoe 环境中，实测被检查的 layer-25 菜单栏窗口属主均为 ControlCenter 进程（含 Docker、Stats 等经典 NSStatusItem app）。由此推断，app 负责注册图标，渲染与放置由 ControlCenter 决定；系统侧至少会按 bundle ID 持久化菜单栏项状态。该条目是本机实验结论，不把未公开的系统内部实现当作 Apple 的稳定公共契约。
2. **记录损坏（实验推断）**：`com.jafish.tunnelpad` 的持久宿主记录表现为僵尸绑定——条目仍在、指向的宿主窗口已死。此后在原 ID 的观测周期内，启动注册的新状态项无法完成渲染；面板条目仍存在造成“已注册”的假象。相同二进制更换为全新 bundle ID 后立即恢复，是该推断的关键依据。
3. **最可能触发**：app 在状态项正被托管时崩溃（2026-08-29 16:48 与 2026-08-30 11:00 两次 `tunnelpad` 进程崩溃报告，见 `~/Library/Logs/DiagnosticReports/Retired/`）。v1 时代 autosave 标识曾被系统"缓存为无效宿主窗口"（见 MenuBarController 历史注释），属同类损伤，说明该故障模式可重复发生。
4. **无法可靠修复原记录**：相关状态分散在系统私有存储中。用户态检索与重启验证未找到能够稳定清除宿主绑定的受支持接口；对 `group.com.apple.controlcenter` 持久数据的解析仍可见旧 ID 的嵌套残留，且该残留跨越服务重启和整机重启。结论不是“没有记录”或“已自动回收”，而是用户态无法可靠重置该宿主绑定；当前可确认的是，残留不再阻塞新 bundle ID。

### 排除项

- **非图标资源问题**：菜单栏图标为代码绘制（`makeMenuBarIcon`），不经过 asset catalog，无图片缓存环节。
- **非二进制/代码回归**：同一二进制换任意新 bundle ID 后图标立即可见（2026-08-30 三次闭环实验：status-trial 22:39、trial3 23:25、正式迁移后 23:28）。
- **非 LS / autosave / app prefs**：`lsregister` 注销死路径并强制注册真实路径、autosave 标识 v2→v3、清理 app defaults 域，均无效。
- **autosave 版本化假设已被证伪**："(bundle ID, autosave) 组合缓存"理论与三次实验结果矛盾（v3 全新组合同样不显示），键控维度是 bundle ID 本身。

## 决策

1. App bundle ID 由 `com.jafish.tunnelpad` 迁移至 `com.jafish.tunnelpad.app`（唯一定义点 `App/Resources/Info.plist`）。
2. 旧 ID `com.jafish.tunnelpad` 永久退役，不再用于任何 app 身份；其系统侧宿主记录已损坏且不可清除。
3. launchd 标签前缀 `com.jafish.tunnelpad.<tunnel-id>` 保持不变（`TunnelConfig.launchdLabelPrefix` 独立于 app 身份）；配置目录 `~/Library/Application Support/TunnelPad`、日志 `~/Library/Logs/TunnelPad` 按名不按 ID，均不受影响。已确认的本地代价是旧 defaults 域中的窗口位置记忆丢失；由于 Bundle ID 也是 macOS 权限、钥匙串、登录项和分发更新等身份管理的常见键，正式签名分发前须分别复核这些按身份保存的状态。本次本地 ad-hoc 应用验证未发现额外消费者。
4. 菜单栏 status item autosave 保持无版本号 `com.jafish.tunnelpad.menu-bar`，停止版本化递增；新 ID 下该记录全新，无需再绕行。
5. 治理同步：本 ADR 是根因与身份决策的唯一事实源；`docs/plans/tunnelpad-v1.md` 打包约定行与 `MenuBarController` 注释链接/对齐到本结论。

## 后果

### 正面

- 菜单栏图标恢复并经实机截图验证；隧道管理与 launchd 集成零影响（AX 树确认 admin-tunnel、reverse-ssh 正常）。
- 新身份的宿主记录全新，历史污染不再触达。

### 代价与风险

- 旧 defaults 域 `com.jafish.tunnelpad` 遗留（仅窗口 frame），可择机 `defaults delete` 清理。
- 系统侧仍可能残留旧身份的嵌套引用；不应依赖手工清理或假定重启会自动回收。当前证据表明该残留不影响新身份显示。
- **崩溃诱因未消除**：app 在状态项正被托管时崩溃仍可能污染新身份的记录（本 ADR 假定的触发路径）。降低崩溃率由 `tunnelpad-stability` 计划承担。若新身份复发，应先保留诊断证据并复核宿主状态；再次迁移 Bundle ID 只能作为最后的隔离手段，因为它会重新触发权限、钥匙串、登录项和分发身份的迁移成本。
