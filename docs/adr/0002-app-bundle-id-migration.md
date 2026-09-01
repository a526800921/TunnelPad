# ADR-0002：App bundle ID 迁移至 com.jafish.tunnelpad.app

- 状态：已接受
- 日期：2026-08-30（2026-09-01 补充 Tahoe 状态项托管证据）
- 范围：App 打包身份与菜单栏集成

## 背景

### 现象

2026-08-29 起，bundle ID 为 `com.jafish.tunnelpad` 的 app 菜单栏图标不再显示；系统设置 → 控制中心 → 菜单栏面板中该身份的条目与开关仍然存在且为开启态。该问题在 2026-08-30 22:16 整机重启后依旧存在。

### 根因

1. **托管模型（本机观测）**：在当前 Tahoe 环境中，实测被检查的 layer-25 菜单栏窗口属主均为 ControlCenter 进程（含 Docker、Stats 等经典 NSStatusItem app）。由此推断，app 负责注册图标，渲染与放置由 ControlCenter 决定；系统侧至少会按 bundle ID 持久化菜单栏项状态。该条目是本机实验结论，不把未公开的系统内部实现当作 Apple 的稳定公共契约。
2. **记录损坏（实验推断）**：`com.jafish.tunnelpad` 的持久宿主记录表现为僵尸绑定——条目仍在、指向的宿主窗口已死。此后在原 ID 的观测周期内，启动注册的新状态项无法完成渲染；面板条目仍存在造成“已注册”的假象。相同二进制更换为全新 bundle ID 后立即恢复，是该推断的关键依据。
3. **最可能触发**：app 在状态项正被托管时崩溃（2026-08-29 16:48 与 2026-08-30 11:00 两次 `tunnelpad` 进程崩溃报告，见 `~/Library/Logs/DiagnosticReports/Retired/`）。v1 时代 autosave 标识曾被系统"缓存为无效宿主窗口"（见 MenuBarController 历史注释），属同类损伤，说明该故障模式可重复发生。
4. **无法可靠修复原记录**：相关状态分散在系统私有存储中。用户态检索与重启验证未找到能够稳定清除宿主绑定的受支持接口；对 `group.com.apple.controlcenter` 持久数据的解析仍可见旧 ID 的嵌套残留，且该残留跨越服务重启和整机重启。结论不是“没有记录”或“已自动回收”，而是用户态无法可靠重置该宿主绑定；当前可确认的是，残留不再阻塞新 bundle ID。
5. **位置记录回归与修复（2026-09-01）**：新 ID 的打包 App 进程和 `NSStatusItem` 均保持存活，按钮有 `22×22` 图像且未隐藏；主屏正常工作的 ModelPad、TranslateBar 各有 AppKit 生成的 `NSStatusItem Preferred Position Item-0` 偏好，而 `com.jafish.tunnelpad.app` 没有该记录时，ControlCenter 将它回退到外接屏。为当前身份写入 `257` 后，命名宿主立即出现在主屏 `x=1181,y=0,38×33`，且位于 Stats 后、ModelPad 前；删除该记录后由新启动逻辑自动补写 `257`，同样得到主屏宿主。该闭环把当前问题收敛为 Tahoe 缺失位置记录的显示器回退，而不是 SwiftUI、Rust dylib、图标绘制或菜单项创建问题；解锁后的像素验收仍需完成。

### 排除项

- **非图标资源问题**：菜单栏图标为代码绘制（`makeMenuBarIcon`），不经过 asset catalog，无图片缓存环节。
- **非二进制/代码回归**：当前打包 App 的状态项对象、图像和菜单均存在；在缺失 AppKit 位置记录时，显示受 Tahoe 托管状态影响，补齐该记录后宿主进入主屏。
- **非 LS / 图标资源 / 自定义 autosave**：`lsregister` 注销死路径并强制注册真实路径、清理旧 app defaults 域和自定义 autosave 标识均未能单独恢复显示；有效的是补齐 AppKit 默认 `Item-0` 位置记录。
- **位置记录不是应用业务数据**：该偏好由 AppKit 写入应用 defaults 域，应用只在缺失时提供默认值，不覆盖用户已有的排列结果。

## 决策

1. App bundle ID 由 `com.jafish.tunnelpad` 迁移至 `com.jafish.tunnelpad.app`（唯一定义点 `App/Resources/Info.plist`）。
2. 旧 ID `com.jafish.tunnelpad` 永久退役，不再用于任何 app 身份；其系统侧宿主记录已损坏且不可清除。
3. launchd 标签前缀 `com.jafish.tunnelpad.<tunnel-id>` 保持不变（`TunnelConfig.launchdLabelPrefix` 独立于 app 身份）；配置目录 `~/Library/Application Support/TunnelPad`、日志 `~/Library/Logs/TunnelPad` 按名不按 ID，均不受影响。已确认的本地代价是旧 defaults 域中的窗口位置记忆丢失；由于 Bundle ID 也是 macOS 权限、钥匙串、登录项和分发更新等身份管理的常见键，正式签名分发前须分别复核这些按身份保存的状态。本次本地 ad-hoc 应用验证未发现额外消费者。
4. 菜单栏 status item 不设置应用自定义的 `autosaveName`，避免继续复用已污染的跨显示器位置记录；如果当前 app 域缺少 AppKit 的 `NSStatusItem Preferred Position Item-0`，启动时只补写默认位置 `257`，保留用户之后的手工排列。
5. 菜单栏 status item 使用与正常工作的 ModelPad 相同的 `NSStatusItem.squareLength`、按钮 frame 和 `22pt` 图像；现有对照实验未证明这些布局参数是当前主因。
6. 不再次迁移 Bundle ID；当前身份通过位置记录回归已能进入主屏宿主。只有在其他机器无法建立同类位置记录时，才另行评估身份迁移，因为它会影响 macOS 权限、钥匙串、登录项和后续分发更新身份。
7. 治理同步：本 ADR 是根因与身份决策的唯一事实源；`docs/plans/tunnelpad-v1.md` 打包约定行与 `MenuBarController` 注释链接/对齐到本结论。

## 后果

### 正面

- 当前打包版的 `NSStatusItem` 对象、图像和菜单均能创建；位置记录补齐后 ControlCenter 宿主位于主屏，隧道管理与 launchd 集成不受本次诊断影响。
- 状态项不再使用应用自定义的跨显示器持久化位置；缺失记录时使用主屏默认位置，之后保留用户手工排列。

### 代价与风险

- 旧 defaults 域 `com.jafish.tunnelpad` 遗留（仅窗口 frame），可择机 `defaults delete` 清理。
- 系统侧仍可能残留旧身份或当前身份的嵌套引用；不应依赖手工清理或假定重启会自动回收。当前证据表明清理后仍存在显示器/宿主差异。
- 旧的 `NSStatusItem Preferred Position com.jafish.tunnelpad.menu-bar` 偏好可能继续留在用户域，但代码不再读取或写入该 autosave 名称；本地位置自定义不再持久化。
- 系统默认的 `Item-0` 状态项记录仍由 AppKit 管理；当前机器的窗口坐标闭环已通过，仍需在解锁后做最终像素/UI 复核。
- **崩溃诱因未消除**：app 在状态项正被托管时崩溃仍可能污染新身份的记录（本 ADR 假定的触发路径）。降低崩溃率由 `tunnelpad-stability` 计划承担。若新身份复发，应先保留诊断证据并复核宿主状态；再次迁移 Bundle ID 只能作为最后的隔离手段，因为它会重新触发权限、钥匙串、登录项和分发身份的迁移成本。
