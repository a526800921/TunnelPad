# 无人值守启动恢复迁移与回滚

- 状态：阶段 1 实施契约；尚未部署。
- 关联：[专项计划](../plans/tunnelpad-unattended-launch-recovery.md)。

## 版本与文件

Swift App、Rust Core 与 `tunnelpad-preflight` helper 必须同版打包。config.json version=1 不变；Core C 函数签名不变，追加的自动启动 JSON 能力必须探测成功才启用队列。新严格命令受控超时追加错误码 14，旧错误码含义不变。

入口脚本与 helper 相邻部署到 Contents/Resources；独立 CLI 安装必须一起更新两者。缺 helper/旧库不提供新能力时明确失败，禁止回退到旧宽松同步/启动入口。

私有运行时目录为 `~/Library/Application Support/TunnelPad/preflight`，包含资源互斥、可信目录锁标记、认证/日志节流状态和未完成 journal；目录 0700、状态文件 0600。journal 不包含 AccessKey、Secret、私钥或原始云响应，不作为 shell 配置执行。

## 共存

新 supervisor 先获取资源 native 锁，再原子获取既有目录锁；旧脚本只获取后者。不能检查旧锁不存在后直接运行；未知旧锁不擅删。新版可信残留只有确认对应持有者已结束后才能回收。隔离 fixture 可覆盖路径，生产使用统一入口和约定路径。

App 自启开关/autoStart 配置不因升级改变。手动 stop 或关闭 autoStart 取消当前队列，重启 App 后按配置重新构造候选。

## 回滚

1. 取消新队列，等待本地前置进程及其受监督子进程收敛，不启动旧客户端抢占资源。
2. 检查私有 journal：有未完成可信操作时先用同版本工具只读核对，按本计划允许的精确事务续作处理；不能直接删除记录或批量撤销同描述规则。
3. 无未完成事务、无在途进程、旧新锁均已收敛后，才成套回退 App/Core/helper/脚本。
4. 不可信多规则、损坏记录、未知旧锁或权限不足保持 fail-closed，明确需要用户处理；回滚不得扩大云端权限或覆盖用户配置。

真实升级/回滚属于阶段 2，需具体目标、授权和前后状态证据；阶段 1 只验证隔离样本与打包完整性。
