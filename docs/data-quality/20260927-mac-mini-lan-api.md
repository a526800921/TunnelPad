# Mini 局域网 API 受限直连

## 授权与 Step 0

2026-09-27 用户明确授权修改 TunnelPad，替代未实施的 SSH 隧道方案：MacBook 直接访问 http://10.0.0.2:9998，仅允许核验后的 MacBook 10.0.0.30。默认仍回环；不改 ECS、motorcycle、NAS、SSH 授权或其他生产服务。旧端运行包不替换，仅部署 Mini 空配置 App，部署前再次核验无受管隧道。

基线 HEAD 775a2b2ce46a4c9becba7721e36fca2bebb4bad6；原代码 AppDelegate 使用固定回环默认构造。旧端路由至 Mini 使用 en0，地址10.0.0.30。工作树只有前序部署/隧道方案两份未跟踪文档，保留。GitNexus impact 返回未注册仓库，按技能降级为源码调用方核查：影响 API Server、AppDelegate 和 HTTP 契约测试；无 TunnelManager/Rust 生命周期变更。图分析不可用不视为低风险，本次按安全高风险处理，完成自验后部署前独立复核一次。

## 最小契约与样本

- 独立 api.json（与 config.json 同目录），缺省仅127.0.0.1；显式 host 必须为规范的RFC1918 IPv4，allowedClientIPs 非空且每项为规范RFC1918 IPv4。禁止通配、公网、CIDR、DNS、未知字段、损坏配置；错误不退化为无限制监听。固定端口9998，设置重启App后生效。
- LAN模式同时绑定指定地址和127.0.0.1；任一绑定失败清理本次已绑定地址，App继续运行但API停用。缺省模式行为兼容。
- 所有路由在业务处理前校验 socket peer；只允许127.0.0.1或精确IP白名单，不采信Forwarded/X-Forwarded-For。拒绝Origin和cross-site浏览器请求，校验Host以约束DNS rebinding。无CORS放行。
- 无TLS/用户身份认证，IP白名单仅适用于可信局域网，不能识别同IP的其他设备或进程；建议DHCP地址保留，不做公网映射。
- 自动化覆盖缺省、非法配置、白名单允许/拒绝、伪造头、跨站、Host、拒绝写接口且backend不执行、OpenAPI、原API路由及端口冲突；真实Mini验证允许MacBook、拒绝Mini非白名单LAN源、回环仍可用、无通配/IPv6监听。

## 回滚与完成条件

打包到独立临时目录，不覆盖旧端正在运行的dist。Mini旧App保留备份；新api.json不存在才创建，源文件只在匹配旧HEAD且无对应用户改动时同步，保留未提交差异清单。失败退回旧App并禁用新增LAN配置，不改NAS或旧端服务。完成需Swift测试、签名构建、独立复核发现闭环、双端只读验收和治理检查。

## 实施进度

已实现独立配置加载、双地址绑定及失败清理、socket来源/Host/浏览器来源校验、403与相对OpenAPI。未修改TunnelManager或Rust/ECS逻辑。XcodeBuildMCP专项测试11/11通过；完整测试、Release与独立复核进行中，尚未部署。Mini只读预检：PID2543、仅回环、空隧道、无api.json，HEAD775a2b2及NAS基线不变。

实施期间出现并行文档修改（PLAN_MAP中的逐隧道ECS策略条目及docs/plans/20260927/tunnelpad-per-tunnel-ecs-policy.md），视为用户/其他任务工作保留，不将其纳入本次实现、部署或提交。

## 独立复核与修复自验

2026-09-27 high独立只读复核：Einstein（01a0e1b9-d5b0-75f2-a273-9cdb14ec8027）。发现P2：第一监听已经可派发请求但第二监听可能绑定失败，关闭监听不能撤销已提交backend任务，因此最初判定NOT READY。其余来源、Host/Origin、默认兼容和ECS边界未发现绕过。

主实施者修复：新增同步readiness门禁，只有全部监听绑定成功才设为就绪，绑定失败/stop先撤销就绪；之前到达的合法请求只返回503，不派发业务。确定性fixture令相同回环地址第二次绑定失败，在两次绑定之间发真实HTTP POST，断言503、backend零调用、isRunning=false并可重新占用原端口。另在10.0.0.30真实LAN socket对全部9路由注入伪造Forwarded/X-Forwarded-For，断言403且backend零调用，回环health仍200。

修复自验：`TUNNELPAD_TEST_LAN_IP=10.0.0.30 xcodebuildmcp swift-package test --package-path /Users/jafish/Documents/work/TunnelPad --filter TunnelAPI`，13通过、0失败、0跳过。原P2已由自验闭环，不声称再次独立通过。旧包暂存在Mini的lan-api-deploy.6ZdAl2，仅允许staging、禁止部署；将使用修复后新包与新hash。首轮完整测试212/212及旧Release仅为修复前证据，最终完整测试与产物验证待追加。

修复后的完整构建：`TUNNELPAD_TEST_LAN_IP=10.0.0.30 TUNNELPAD_DIST_DIR=<mktemp目录> CARGO_NET_OFFLINE=true ./scripts/build_app.sh`，214/214 Swift测试通过、Release构建和严格签名通过。新产物为`/tmp/tunnelpad-mini-lan-fixed.di4su5/TunnelPad.app`；`git diff --check`与`plan-governance-cli check . --strict-readiness`通过。准入结论为独立发现经主实施者修复自验闭环，允许仅Mini部署与受限LAN验收。

## 部署与实机验收

修复后部署目录：Mini `dist/lan-api-fixed.eAL0ay`。App归档SHA256 `b55ce470841e39e7c00081c28ee325661b9dbbaaab20a556e0c9678834723086`，7文件源码归档SHA256 `8e40cf6a23c42bf85a20155f347d554b9f11aa19ba3bebeaa4764f18aaa6695e`；旧包及4个原有tracked源码已保留到该目录backup。仅Mini原`dist/TunnelPad.app`被替换，api.json新建为0600；不变更SSH授权或安装登录项。

MacBook使用curl --noproxy '*'实测：`10.0.0.2:9998/api/health`返回200/ok，`/api/tunnels`返回200/空列表；相同health附不可信Origin或Host均403/access_denied。6个源码/测试/README文件通过cmp确认双端字节一致。

Mini最终验收通过：新PID3598，仅监听10.0.0.2:9998和127.0.0.1:9998，无通配/IPv6；回环health/list200且空隧道。来源10.0.0.2不在白名单，9路由及伪造Forwarded/X-Forwarded-For均403，Origin/Host伪造也拒绝。NAS两容器ID/StartedAt/健康与基线不变。实际配置为host10.0.0.2、allowedClientIPs=[10.0.0.30]，文件0600。源码HEAD仍775a2b2，变更未提交或推送；旧包备份可恢复。

结论：本次有界直连改动已完成，独立P2修复自验闭环、214项全量回归、签名/治理、允许与拒绝实机路径均通过。未实施SSH隧道方案，未改变ECS同步策略。

旧端App保持PID3333、127.0.0.1:9998监听，未替换运行包。实施初期motorcycle为PID6490/running；部署前只读复查发现其已变为not_loaded，本轮未执行该隧道启停，也未自动恢复，已向用户说明。不得将后续停止状态误报为本次迁移或验收操作。
