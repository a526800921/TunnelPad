# MacBook 访问 Mini TunnelPad API 的受限 SSH 隧道

## 最新需求：改为局域网直连（已授权，替代下述隧道方案）

用户已放弃本页下述SSH隧道方案，改为直接访问`http://10.0.0.2:9998`。不再追加SSH授权或TunnelPad隧道。源码核对：`TunnelAPIServer`默认host为127.0.0.1，AppDelegate直接采用默认构造，当前没有现成的监听地址配置开关；README明确无鉴权且原安全边界仅限回环。

拟议最小变更：保留默认回环模式，为Mini增加显式局域网监听配置，并将远程访问来源限制到核验后的MacBook IPv4；保留Mini本机访问，不开放公网、不修改ECS逻辑。来源限制在任何业务路由执行前生效，不信任客户端提交的转发头；不得把仅绑定10.0.0.2误认为只允许MacBook。IP白名单不是用户认证，后续网络环境或使用范围改变需重新评估。

前序仅记录需求；用户随后明确“那你直接改一下”，已授权代码修改与Mini部署。实际实现、独立复核及修复自验见[局域网直连证据](20260927-mac-mini-lan-api.md)。下文为已放弃方案的历史检查记录，不是当前实施任务。

## 授权、目标和边界

用户已明确要求在MacBook的TunnelPad新增隧道。目标为`127.0.0.1:19998`经已有固定主机身份的macOS SSH连接Mini `10.0.0.2`，转发至Mini `127.0.0.1:9998`。不将Mini API改为LAN监听，不修改TunnelPad源码，不迁移motorcycle，不复制私钥或云凭据，不停止现有应用或服务。

新增条目计划ID `mac-mini-tunnelpad`，名称“Mac mini TunnelPad”；SSH使用旧端已有专用配置`/Users/jafish/.ssh/nas-git-macmini-20260927/config`和Host `nas-git-macmini`，命令参数为`/usr/bin/ssh -F <上述配置> -N -T -L 127.0.0.1:19998:127.0.0.1:9998 nas-git-macmini`。保持严格主机校验、禁止agent/X11、受限公钥认证。keepAlive=true、autoStart=false、forceRemotePortCleanup=false，HTTP探针`http://127.0.0.1:19998/api/health`期望200。

Mini仅在已匹配的专用公钥授权行增加`permitopen="127.0.0.1:9998"`，保留已有2222/2223及restrict/强制false命令/sshd Match限制，原行有可恢复备份。不会对所有公钥或用户放开转发。

## 只读基线与实现约束

旧端19998空闲，9998属于旧端TunnelPad；原三条隧道中仅motorcycle-local-docker运行，PID6490，另外两条未加载。Mini空配置App正常且9998只回环监听。新增配置前后必须逐项比较旧三条配置与motorcycle PID不变。

GitNexus MCP及CLI都未注册TunnelPad索引，本轮按技能降级读取源码，不据缺索引认定代码无影响，也不重建索引或修改代码。已核对`ECSPreStartChecker`、`TunnelConfig`、`SSHCommand`、`reloadConfigAsync`和plist渲染：所有首命令为ssh的条目都会运行ECS前置，没有逐隧道跳过字段；不采用shell包装或伪装可执行文件规避检查。2026-09-27只读`--check --result-json`返回synchronized，未修改云端。

当前版本直接启动仍会调用既有ECS同步逻辑。新增LAN隧道不应成为修改云安全组的理由；独立复核确认，事前synchronized不能限制随后的同步事务，无法保证“发现需要云写入再停止”。此外，autoStart=false不能阻止运行后的HTTP健康恢复路径再次执行同步。因此当前方案不得启动；需要另行授权正式的逐隧道ECS前置策略改造，或明确扩大云同步授权。不得通过伪装SSH命令绕过检查。

配置修改使用精确追加并保留安全备份；通过App“重新加载config.json”读取，仅追加不得删除/更改其他条目。API只启动新增ID，不重启整个App。回滚只停止/移除新增ID并恢复该公钥新增权限，不动原隧道和NAS服务。

## 验收与复核

新增权限属于安全相关变更，实施前安排一次high强度独立只读复核。通过后验证：新增条目可见；19998回环监听；转发health200和Mini空列表；MacBook9998仍原条目集合加新条目；Mini LAN9998及MacBook LAN19998不可达；原Git/API/隧道正常；禁用其他目标的限制保留。不通过不放宽限制或绕过检查。

当前：Mini精确预检与一次high独立复核已完成，尚未修改配置或SSH授权，未启动新增隧道。Mini确认专用公钥唯一匹配，原permitopen仅2222/2223，restrict、port-forwarding、forced false均保留；.ssh为0700、authorized_keys为0600且不是符号链接；sshd仅允许local TCP forwarding并禁止stream-local forwarding。独立复核对SSH权限设计条件通过，但否决当前启动准入：首次启动及健康恢复都可能执行云写入。主agent据此暂停实施，等待用户选择；不重启App，不停止motorcycle，不扩大云端授权。
