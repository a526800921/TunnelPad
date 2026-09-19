# TunnelPad 隧道日志时间戳

## 现状

`launchd` 当前把隧道进程的 stdout/stderr 直接写入同一个日志文件，因此历史行只有文本，没有逐行产生时间。文件 mtime 只能说明最后一次写入，不能还原每条错误的发生时间。

## 本次变更

为 launchd 隧道增加随进程输出写入的时间戳代理。后续日志行采用以下格式：

```text
2026-09-15T22:25:31.123+0800 [stderr] Error: remote port forwarding failed for listen port 18080
```

代理保持原始命令参数顺序，分别读取 stdout/stderr 并追加到原有的每隧道日志文件；历史已存在的无时间戳内容不回写、不猜测时间。代理异常只影响对应隧道的启动结果，不把凭据或完整命令写入日志。

## 验证边界

- 单元测试验证 plist 代理参数、日志路径和原始命令参数保持关系。
- Rust 代理测试验证 stdout/stderr 均能逐行写入 ISO8601 本地时间戳。
- 发布构建将代理复制到 App bundle 的 `Contents/Resources`，新生成的 launchd plist 才会启用它；已加载的旧 plist 需要重启对应隧道后生效。
