# TunnelPad Mac mini 应用部署

## 授权与范围

用户最初要求从Git将TunnelPad部署到Mac mini同级路径，并开启motorcycle穿透；核对旧端仍运行该业务隧道后，用户明确缩小为“先部署TunnelPad，motorcycle先不管了”。本轮只交付源码和可启动的空配置macOS应用，不迁移隧道、SSH私钥、ECS凭据，不变更云端或停止旧端服务，也不提交/推送仓库。

这是现有版本的部署，不新增产品行为，不重开历史功能计划。采用既有构建脚本与运行契约；旧端当前运行中的应用包不可覆盖。若新端无Rust，允许在同架构旧端构建后传送应用产物，不为此次交付安装无关工具链或云CLI。

## 基线

- 源码：`https://github.com/a526800921/TunnelPad.git`，分支main，旧端HEAD `775a2b2ce46a4c9becba7721e36fca2bebb4bad6`，开始时Git工作区干净。
- 两端目标源码目录：`/Users/jafish/Documents/work/TunnelPad`。
- 新端已从GitHub克隆，具体HEAD和运行验证待补；初检有Swift 6.4/Command Line Tools，无Rust/Cargo及阿里云CLI、无既有TunnelPad安装与配置。
- 旧端arm64，现有`dist/TunnelPad.app`正在运行；新的构建使用独立dist目录，不使用脚本默认目标覆盖该应用。
- 现有motorcycle隧道保持旧端运行，所有依赖和端口保持不动。

## 验证与保护

核对源HEAD、架构、构建和签名；安全传送到新端不存在的应用路径；首次启动前确认配置不会自动启用示例/生产隧道。仅本机API `127.0.0.1:9998` 可监听，不暴露到局域网。验证health和空隧道列表，保留原Git服务及其他进程不变。不自动设为登录启动，后续按用户需求单独确认。

失败时保留源码及构建诊断，不触动旧端服务；不为解决部署问题擅自复制密钥、安装大型依赖或开启隧道。文档和静态检查不替代真实新端运行验证。

## 当前状态

已完成：源码已从GitHub克隆，应用在Mini以空配置运行。motorcycle部署与穿透明确定为暂缓，阿里云CLI/凭据缺失不阻塞空应用部署，但会限制后续真实SSH隧道启动。

## 构建与传输结果

新端clone HEAD与旧端一致，工作区干净；新端确认无配置时返回空列表、不会创建示例隧道或执行ECS同步。两端为arm64。

旧端使用原`scripts/build_app.sh`，通过`TUNNELPAD_DIST_DIR`定向到唯一临时目录`/tmp/tunnelpad-mini-deploy.RUvU1y`。Rust release成功；Swift 205项测试全部通过；Swift Release、Info.plist和ad-hoc深度严格签名验证通过。旧端正在运行的`dist/TunnelPad.app`没有被替换，motorcycle隧道PID6490仍running、探针satisfied。

应用归档`TunnelPad-775a2b2-arm64.zip`已传入Mini项目的忽略目录`dist`，两端SHA-256均为`c61f07c119df944e1775ffea3f89edfdd0c6173aefe1e82c1179a2152db5af9b`。只传应用包，不传旧配置/凭据。新端应用启动及API验证待完成。

## Mini运行终验

新端先核对HEAD、归档哈希、33个归档条目（无符号链接）、目标App不存在，再解压到`/Users/jafish/Documents/work/TunnelPad/dist/TunnelPad.app`。签名、arm64、最低macOS14、Info.plist和内嵌Rust库`@rpath`及辅助可执行文件均通过。

- 新端只有一个应用进程，PID2543，实际路径为上述App的`Contents/MacOS/tunnelpad`。
- `/api/health`返回200、`ok=true`；`/api/tunnels`返回200且`tunnels=[]`。
- 9998只监听IPv4回环127.0.0.1，无IPv6/通配监听。
- 没有受管隧道作业、没有生成隧道plist；默认配置文件仍不存在。系统自动生成的GUI应用登记属于App自身，不是SSH隧道。初次检测将该登记误归为隧道的断言已修正，并按精确受管身份重新验证通过。
- NAS两个容器ID和启动时间未变，SSH running、API running/healthy，NAS管理API200，固定Git主机身份一致。
- 未设置登录启动，未移入系统Applications，未迁移凭据、未安装Rust/云CLI，未改变旧机隧道或ECS。

两端源码HEAD保持`775a2b2ce46a4c9becba7721e36fca2bebb4bad6`。应用产物位于Git忽略的dist目录，本部署记录为新增未提交文档，不自动提交或推送。按plan-governance记录部署范围和真实证据，使用macOS构建技能核对工具与平台；本轮不修改代码，不进行新的穿透/权限变更，因此不重做历史高风险功能独立复核。
