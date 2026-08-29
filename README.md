# TunnelPad

TunnelPad 是一个 macOS 菜单栏应用，用来统一管理本机与服务器之间的 SSH 隧道（启动/停止/状态/日志/配置）。首个版本迁移接管两条现有 launchd 常驻隧道：

- `admin-tunnel`：本机 8081 → ECS 8081，访问 motorcycle-manual-app 个人后台。
- `reverse-ssh`：ECS 22022 反向转发回本机 22 端口，供外部电脑经 ECS 跳板远程连回本机开发。

## 状态

设计阶段。专项计划与治理入口：

```text
docs/PLAN_MAP.md
docs/plans/tunnelpad-v1.md
```

代码尚未开始实现；阶段 0 为迁移基线快照（只读）。
