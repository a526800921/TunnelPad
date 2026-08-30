# TunnelPad 界面优化——阶段 3 与阶段 1 收尾实机证据（2026-08-30）

## 环境

- 目标：已打包的 `dist/TunnelPad.app`（TunnelPad 窗口处于前台）。
- 初始配置：`~/Library/Application Support/TunnelPad/config.json` 含 `admin-tunnel`、`reverse-ssh` 两条真实隧道；两条真实隧道保持运行。
- 验证原则：演示隧道使用 `/bin/sleep 100000`，不连接外部服务；完成后删除演示配置和产物，恢复真实配置。

## 阶段 3 样本矩阵

| # | 结果 | 证据 |
|---|---|---|
| 1 | 通过 | 点击侧栏「+」后显示空白新建表单；AX 显示 launchd 选中、keepAlive=1、重启间隔=10、探针=0，命令编辑区为空。 |
| 2 | 通过 | 空表单点击「保存」后弹窗仍在，AX 显示红色错误文案「名称不能为空」；未新增配置条目。 |
| 3 | 通过 | 填写名称 `Demo Add`、选择 app、命令 `/bin/sleep` 与 `100000` 后保存；侧栏出现 `Demo Add` / `app` / `com.jafish.tunnelpad.demo-add`，详情状态为「已停止」，未自动启动。 |
| 4 | 通过 | `TunnelIDTests` 已覆盖冲突序号规则；阶段 3 实施记录中的 `swift build` 零告警、`swift test` 63/63 已通过。 |
| 5 | 通过 | 用户确认删除演示隧道后，确认框执行删除；侧栏恢复仅两条真实隧道。只读核对显示 `config.json` 仅含 `admin-tunnel`、`reverse-ssh`，`demo-add.pid`、对应 launchd plist、`demo-add.log` 均不存在。 |
| 6 | 通过 | 阶段 3 实施记录保留回归证据：`swift build` 零告警、`swift test` 63/63、治理检查通过。 |

## 阶段 1 矩阵 4 补验

1. 选中 `admin-tunnel`，关闭「自动滚动」，AX 值由 `1` 变为 `0`。
2. 对日志滚动区执行一次「Scroll Up」，滚动条值约为 `0.9965`。
3. 静置 6.5 秒，期间日志继续产生新内容；AX 滚动条值约为 `0.9952`，没有被拉回底部，自动滚动仍为 `0`。

结论：关闭自动滚动后可以保持历史回看位置，阶段 1 矩阵 4 通过。阶段 1 矩阵 5（保存后不展示信息文案）已在阶段 2/3 验证记录中通过。

## 配置与真实隧道保护

收尾后的只读核对结果：

```text
config.tunnels = admin-tunnel, reverse-ssh
demo-add pidfile = absent
demo-add launchd plist = absent
demo-add log = absent
admin-tunnel = running；probe 401 ✓
```

真实隧道未被停止、删除或改写。

## 结论

- 阶段 1：完成，日志回看补验通过。
- 阶段 3：完成，新建→删除实机闭环通过。
- 阶段 4：已在独立证据文档中完成菜单栏单项启停实机验证、批量入口移除及回归检查。
