# 逐隧道 ECS 策略阶段 2 MacBook 部署记录（2026-09-27）

## 结果与范围

按[阶段 2 Step 0](20260927-tunnelpad-per-tunnel-ecs-policy-stage2-step0.md)完成 MacBook 受控替换。新版从项目 `dist/TunnelPad.app` 启动，PID 为 `48138`；`/api/health` 返回 HTTP 200、`{"ok":true}`。Mac mini 未操作。未启动任何受管隧道，未执行真实 ECS 写入或远端端口清理。

本次配置唯一的逻辑变化是给精确 ID `motorcycle-local-docker` 增加 `ecsSyncPolicy: required`。`admin-tunnel` 和 `reverse-ssh` 保留缺字段，按新版语义均为 `disabled`。三项的 `autoStart` 仍为 false；配置权限保持 `0600`。

## 备份与替换

- 旧 App 与原始配置已备份至本机 `~/Library/Application Support/TunnelPad/backups/20260927-ecs-policy.VO9bEk/`，备份目录权限为 `0700`，配置副本权限为 `0600`。旧 App 原件另以 `TunnelPad.original.app` 保留在同目录；未输出配置内容或凭据。
- 旧 App 通过应用退出事件正常退出；确认原 PID `3333` 和本机 API 均停止后，才原子更新配置并替换 App。
- 候选 Release App 的 ad-hoc 签名严格校验通过；替换后再次通过 `codesign --verify --deep --strict`，主可执行文件与候选逐字节相同，SHA-256 为 `fae207579cc818f78da579d10ef0e1e3964480979c8a3c325d5e55f7fb2ddee7`；Rust 动态库 SHA-256 为 `9ef58358c6072d5f2f069e596363b8949920131999ba99eb4302debf70662918`。
- 将部署后 JSON 与备份解析比较：除 `motorcycle-local-docker.ecsSyncPolicy` 外各字段及隧道顺序相同；模式仍为 `0600`。

## 运行验收

- 新 App 仅有一个匹配进程，路径为 `/Users/jafish/Documents/work/TunnelPad/dist/TunnelPad.app/Contents/MacOS/tunnelpad`。
- 本地 API 仅监听 `127.0.0.1:9998`；健康检查 HTTP 200。
- `/api/tunnels` 中 `admin-tunnel`、`reverse-ssh`、`motorcycle-local-docker` 均为 `not_loaded`；对应三个精确 launchd label 查询均返回未加载（退出码 113）。部署未让原有隧道自动启动。
- 阶段 1 的假云测试覆盖 disabled SSH 零 ECS 调用和 required 前置；本次真实 App 未启动普通 SSH 或 motorcycle，因此**不把真实连接零调用、ECS 安全组同步及远端清理记为通过**。这些是后续用户体验/真实连接验收边界。
- 部署期间未触发失败回滚；备份仍保留。若后续需要回退，先退出新版、核对三个受管 label 未加载，再同时恢复备份 App 与配置。旧版不能用于托管依赖 disabled 语义的普通 SSH。

## 后续

用户可在需要时手动启动 `motorcycle-local-docker` 做真实连接验收；该操作会执行 required 的 ECS 前置及既有远端端口清理。技术部署已完成，阶段 2 的真实连接体验与用户验收尚未完成，计划继续保持实施中。
