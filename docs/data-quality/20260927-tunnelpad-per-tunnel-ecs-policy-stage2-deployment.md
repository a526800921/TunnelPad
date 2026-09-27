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

技术部署已完成。部署当时未主动启动 `motorcycle-local-docker`；后续真实连接验收结果记录如下。阶段 2 在健康探针业务目标通过前保持实施中。

## 提交后真实连接验收追加（2026-09-27）

源代码和部署记录已提交为 `42d87d8`。提交前 `gitnexus detect-changes --scope all` 报告 21 个文件、205 个符号、101 条执行流，整体风险 `critical`；阶段 1 同范围独立复核的四项发现已修复自验，`git diff --cached --check` 与严格治理检查通过。

- MacBook 上 `workbench list ecs` 未列出实例，因此未通过 Workbench 连接或修改实例。TunnelPad 自身既有 ECS 配置文件和 CLI 凭证路径均存在；打包同步器的 `--check --result-json` 在启动前后均返回 `success/synchronized`。这是只读云端状态验证，不能据此声称发生了安全组写入。
- `admin-tunnel` 保持缺字段即 disabled：真实 API 启动返回 HTTP 200/running，精确 launchd label 为 loaded；随后 API 停止返回 HTTP 200/not_loaded，label 解除。健康探针指向本机 `8081/admin`，在运行窗口内为 failed；直接访问该回环地址得到连接拒绝。因此本轮证明启动/停止生命周期，**未证明该业务端到端可达**。阶段 1 spy 测试是 disabled 零 ECS 调用的证据，本轮未直接跟踪子进程，不把实机零调用冒充已观测。
- `motorcycle-local-docker` 为唯一 required：真实 API 启动返回 HTTP 200/running，launchd label 运行且 SSH PID 存活；SSH 设置了 `ExitOnForwardFailure=yes`，本地 `127.0.0.1:10080` 监听可连接，HTTP `/` 返回 200。既有探针却仍指向本机 `8081/admin`，与该隧道的本地转发端口不同，实际连接被拒绝，API 探针为 failed。因此转发生效，但**健康探针验收未通过**；远端端口清理是否结束过监听进程、本轮是否发生 ECS 写入均无直接证据，不宣称通过。
- 验收后主动停止 motorcycle，API 返回 HTTP 200/not_loaded；三条受管隧道均为 not_loaded，三个精确 launchd label 均未加载，`10080` 本地监听已消失。同步器再次只读检查为 `success/synchronized`。没有保留验收用 SSH 连接。

用户确认 motorcycle 的健康探针继续使用 `8081/admin`，本轮没有修改探针配置。为排除 `admin-tunnel` 尚未运行这一原因，再次启动 `admin-tunnel`：本机 `127.0.0.1:8081` 可以建立 TCP 连接，但访问 `/` 和 `/admin` 都被重置；受管 SSH 日志在当次访问时记录 `connect failed: Connection refused`。配置中的 `-L` 将该端口转发到 SSH 目标的 8081。Workbench 在本机未列出实例，故使用已有 SSH 目标做一次只读 TCP 检查：远端 `127.0.0.1:8081` 返回 `closed`。这确认远端目标端口当前没有监听服务；没有尝试启动或修改该服务。

保持 admin 运行时再次启动 motorcycle：两条 API 状态均为 running，但探针仍为 failed；`motorcycle` 的 `10080/` 继续返回 HTTP 200。随后依次停止 motorcycle 和 admin，均返回 not_loaded。`8081/admin` 是用户确认的期望目标，不能擅自改为 `10080/`。阶段 2 的 SSH 生命周期和 motorcycle 转发已验收，**健康探针/8081 业务可达性未通过**，需在目标服务恢复后复验。

## 8081 恢复后的阶段 2 收尾验收（2026-09-27）

用户要求继续完成计划。本次开始时三条受管隧道均为 `not_loaded`，`motorcycle-local-docker` 落盘策略为 `required`、`autoStart=true`，另外两条旧项缺字段（有效值 `disabled`）。`workbench list ecs` 未列出实例；未通过 Workbench 修改 ECS。先为诊断短暂启动 `admin-tunnel`：本机 8081 由 SSH 监听，但 `/admin` 连接被重置；使用原配置的 SSH 目标做只读检查，远端 `127.0.0.1:8081` 没有监听。随后通过 App API 停止 admin，确认其 label 未加载、8081 不再由 SSH 占用。

之后 MacBook 上原有 OrbStack 的 motorcycle 容器恢复并显示 `healthy`，其本机 8081 监听可访问，`GET http://127.0.0.1:8081/admin` 返回预期的 HTTP 401。保持 admin 停止，使用 App API 启动唯一 `required` 的 `motorcycle-local-docker`：返回 `running`，精确 launchd label 的 PID 与 API 一致、`runs=1`、无退出；本地转发 `127.0.0.1:10080/` 返回 HTTP 200；App API 随后的探针为 `satisfied/401`。打包同步器的只读 `--check --result-json` 返回 `success/synchronized`，未据此声称本次发生云端写入。`admin-tunnel`、`reverse-ssh` 仍为 `not_loaded`；验收后保留用户当前 `autoStart=true` 的 motorcycle 运行状态。

这两条 HTTP 证据各有边界：8081 由本机 OrbStack 监听，401 证明用户保留的探针端点可用，不能单独证明流量经过 motorcycle SSH；`10080/` 的 200 加上受管 SSH 运行状态证明该隧道的本地转发可用。远端 ECS 的 8081 仍未监听，因此本次未把 `admin-tunnel` 的远端后台管理业务记为通过，也未修改用户要求保留的探针 URL。这是既有配置和业务服务的独立限制，不再作为逐隧道 ECS 策略交付的阻塞项。

用户在技术结果公布后明确回复“通过，关闭计划”。本阶段保存/回读、真实 required 启动、disabled 生命周期、探针端点与转发及用户体验验收均已形成证据；真实安全组写入仍无本次直接观测，沿用隔离回归和只读 synchronized 证据，不扩写为实测写入。
