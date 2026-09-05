# TunnelPad 日志低写放大：阶段 1 实施证据

- 日期：2026-09-05
- 阶段：阶段 1
- 结论：实施完成；进入阶段 2 真实 Release 回归
- 关联计划：[TunnelPad 日志低写放大与流式保留](../plans/tunnelpad-log-write-amplification.md)

## 实施内容

- `LogEventStore` 删除文件变化时的无条件整文件裁剪。
- 新增 512 KiB 持久日志高水位和 64 KiB 触发余量；未达到高水位时只增量读取，达到高水位后批量保留最近 2000 个逻辑行。
- 裁剪失败保留原文件并在后续刷新重试；文件替换、截断、清空和读取异常会重置裁剪状态。
- 裁剪完成后重新读取文件身份和大小，避免采集 offset 继续指向已被压缩掉的旧位置。
- 通过现有设置开关完成两个真实隧道的一次性静默迁移：只移除独立 `-v`，未修改密钥、连接参数或 `-vv/-vvv` 语义；设置开关仍可按需恢复 `-v`。

## 验证结果

| 验证 | 结果 |
|---|---|
| 日志专项 Swift 测试 | 16/16 通过 |
| Swift 全量测试 | 145/145 通过 |
| Rust Core 回归 | 76 单元测试 + 1 differential 通过 |
| Release 目标构建 | 通过 |
| Release App 打包、签名和校验 | 通过；产物为 `dist/TunnelPad.app` |
| 未达高水位 fixture | 文件追加到 2002 行时不裁剪；跨过 512 KiB 后裁剪到最近 2000 行；单次后续追加不立即再次裁剪 |
| 锁失败重试 fixture | 加锁时保留原文件，解锁后下一次刷新完成裁剪 |
| 换行和生命周期矩阵 | LF、CRLF、混合换行、替换、重开、多隧道隔离通过 |
| 真实详细日志开关 | 开启并重启 reverse-ssh 后 `debug1` 计数增加；关闭并重启后配置恢复静默 |

## 真实配置状态

2026-09-05 真实 Release App 当前配置摘要：

- `admin-tunnel`：无独立 `-v`，状态 `running`，本机探针 `401/satisfied`。
- `reverse-ssh`：无独立 `-v`，状态 `running`，探针按配置为 `disabled`。
- API `127.0.0.1:9998/api/health` 返回 `{"ok":true}`；`/api/tunnels` 返回两个隧道均为 `running`。

阶段 1 不修改 API、Schema、ABI、Rust Core owner、ECS、凭证或远端资源。
