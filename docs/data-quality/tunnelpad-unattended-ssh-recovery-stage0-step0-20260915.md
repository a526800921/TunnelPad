# TunnelPad 无人值守 SSH 异常恢复与孤儿清理：阶段 0 Step 0 基线

日期：2026-09-15

## 范围

本基线只观察本机源码、当前受管 launchd 作业和临时非 TunnelPad 隔离进程；不改变配置，不调用 ECS，不对当前真实隧道做故障注入。真实 `motorcycle-local-docker` 异常恢复列入阶段 2，不能用本记录替代用户验收。

## 现状证据

### 1. launchd 顶层身份

使用当前用户域的 `launchctl print` 只读取 `state`、`active count` 和 `program` 字段。结果为：

- `state = running`
- `active count = 1`
- `program` 是 TunnelPad 的 `tunnelpad-log-proxy`，不是 SSH 可执行文件

因此 launchd 顶层受管 PID 的身份应按代理核验；SSH 必须作为代理的受管子进程单独核验。

### 2. 当前进程组关系

对当前受管作业读取 `pid/ppid/pgid/state/comm`，结果显示代理由 launchd 接管，SSH 是代理子进程，但代理 PGID 与 SSH PGID 不同。该关系与代理源码中的 `setpgid(0, 0)` 一致。

### 3. SIGKILL 孤儿复现

使用临时目录和当前 Release 代理启动 `/bin/sleep`，记录代理 PID/PGID 和子进程 PID/PGID；随后只对代理发送 SIGKILL，再读取子进程：

```text
proxy_pid=<temporary pid> child_pid=<temporary pid> proxy_pgid=<temporary pgid> child_pgid=<temporary pgid>
<child pid>     1 <child pgid> SN /bin/sleep
```

结果：代理退出后 child 仍存活且 PPID 变为 1，证明当前独立进程组设计不能保证代理被强杀时自动清理孤儿。测试 child 随后按精确 PID 清理；未扫描或终止其他进程。

### 4. 源码缺口

- 日志接收循环对 `write_log_line(...)` 使用直接错误返回；错误路径在 `child.wait()` 之前结束，没有终止/等待 child。
- 代理 reader 忽略读取错误，孙进程持有管道时，主循环可能无法结束。
- 代理只把可捕获信号转发给 child 进程组，没有代理自身的 SIGTERM→SIGKILL 有界升级。
- `stop_managed_cancellable` 当前按调用方传入的 SSH 路径核验 launchd 顶层 PID；当顶层程序是日志代理时存在身份不匹配风险。
- Rust 和 Swift 的代理路径在资源缺失时可能回退为直启 SSH，和本计划要求的 local prerequisite/fail-closed 不一致。

## O1–O7 隔离基线输出

以下均使用当前 Release 代理和本机临时进程，不涉及 TunnelPad 真实 label；临时进程在每项结束后按精确 PID 清理。

### O1：正常输出与退出

已有 `cargo test --manifest-path rust/Cargo.toml --test log_proxy prefixes_stdout_and_stderr_lines_with_local_timestamps` 通过，证明正常 stdout/stderr 行可写入时间戳日志；当前代码尚未对异常子进程收敛做断言。

### O2：日志/资源写入失败

使用 `ulimit -f 1` 限制代理日志文件大小，使代理收到文件大小限制信号；当前输出为：

```text
resource_limit proxy_status=153 child_pid=<temporary pid> child_alive=yes
```

这不是目标行为，而是当前缺口的可复现反证：代理因日志资源限制退出时，SSH 模拟 child 仍存活。阶段 1 必须改为可注入的 I/O 错误并断言 child 已退出和被 wait 回收；不能把 153 当作正常分类。

### O3：可捕获信号

对代理发送 SIGTERM，当前输出为：

```text
term proxy_status=143 child_pid=<temporary pid> child_pgid=<temporary pgid> child_alive=no
```

当前普通信号路径能让 `/bin/sleep` 退出，但还没有 TERM→KILL 升级、kill 返回值和孙进程收敛断言。

### O4：孙进程持有管道

启动一个立即退出的 shell，并让其后台 `/bin/sleep` 继续持有 stdout/stderr；在 shell 已退出后观察代理，当前输出为：

```text
pipe_holder proxy_pid=<temporary pid> proxy_alive=yes desc_pid=<temporary pid> desc_alive=yes
```

代理仍存活，说明 reader 会被后代持有的管道拖住；阶段 1 必须保证超时、关闭管道和进程组回收有界。

### O5：代理 SIGKILL

详见上文“SIGKILL 孤儿复现”：child 被 1 号进程接管并继续存活，当前独立 PGID 方案不能作为无人值守清理保证。

### O6：身份变化

执行 `cargo test --manifest-path rust/Cargo.toml launchctl::tests::managed_stop_refuses_signal_when_launchd_pid_changes -- --exact`，结果为 `1 passed; 0 failed`。该测试证明现有顶层 PID 变化时不发信号；阶段 1 还需覆盖代理顶层路径、PGID/父子关系和状态超时。

### O7：代理资源缺失

当前源码核对输出显示 Rust `bundled_log_proxy_path()` 返回 `Option<PathBuf>`，`write_plist` 将 `None` 传入直写分支；Swift `bundledLogProxyURL()` 同样返回可选值，缺失/不可执行时回退为原始 SSH `ProgramArguments`。因此 O7 的当前基线是“可静默绕过代理”，不是安全失败；阶段 1 必须增加移动 Bundle、缺失资源、恢复重写和不 bootstrap fixture。

## 阶段 0 结论

现状缺口已可复现，阶段 1 的 O1–O7 验证入口、观测字段、错误注入点和失败判定已登记在[专项计划](../plans/tunnelpad-unattended-ssh-recovery-and-orphan-cleanup.md)。O2–O7 的当前隔离输出已经补齐；其中 O2、O4 和 O7 是明确失败反证，不能冒充通过。2026-09-16 独立只读复核确认阶段 0 达到准入，阶段 1 可开始实现；这些反证必须迁移为正向断言，O8 仍延期阶段 2。

## 脱敏与安全边界

本证据不记录 SSH 参数、凭据、私钥内容、完整远端地址或原始云响应；临时 child 只使用本机 `/bin/sleep`。任何后续真实验收须沿用“只清理可证明属于当前 label 的进程”的边界。
