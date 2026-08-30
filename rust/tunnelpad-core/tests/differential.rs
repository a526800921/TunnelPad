//! 阶段 2 差分测试（Rust 侧）：用与 Swift harness 相同的 fixture 驱动 Rust 实现，
//! 与 `rust/target/differential/swift-events.json`（由 DifferentialHarnessTests 产出）
//! 做语义等价比较（serde_json::Value 相等，键序无关）。
//! 运行顺序由 rust/scripts/differential.sh 保证：先 swift test，再 cargo test。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use tunnelpad_core::app_executor::AppProcessExecutor;
use tunnelpad_core::config_store::ConfigStore;
use tunnelpad_core::demo::DemoLifecycle;
use tunnelpad_core::launchctl::{ExecutorError, LaunchCtlExecutor, ProcessRunning, ProcessResult, TunnelStatus};
use tunnelpad_core::legacy::{self, LegacyAgent};
use tunnelpad_core::log_tail::last_lines;
use tunnelpad_core::paths::TunnelPaths;
use tunnelpad_core::plist_render::plist_xml;
use tunnelpad_core::probe::{ProbeOutcome, ProbeService, ProbePerforming};
use tunnelpad_core::ssh_command;
use tunnelpad_core::tunnel_id;
use tunnelpad_core::TunnelConfig;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap().to_path_buf()
}

fn fixtures_dir() -> PathBuf {
    repo_root().join("rust/differential/fixtures")
}

// MARK: - 归一化（与 Swift harness 相同的规则）

fn is_digit(c: char) -> bool {
    c.is_ascii_digit()
}

fn normalize_text(text: &str, home: &Path) -> String {
    let replaced = text.replace(&home.to_string_lossy().to_string(), "<home>");
    let chars: Vec<char> = replaced.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        // yyyyMMdd-HHmmss → <stamp>
        if i + 15 <= chars.len()
            && chars[i..i + 8].iter().all(|c| is_digit(*c))
            && chars[i + 8] == '-'
            && chars[i + 9..i + 15].iter().all(|c| is_digit(*c))
        {
            out.push_str("<stamp>");
            i += 15;
            continue;
        }
        // [yyyy-MM-dd HH:mm:ss] → [<ts>]
        if i + 21 <= chars.len()
            && chars[i] == '['
            && is_digit(chars[i + 1])
            && is_digit(chars[i + 2])
            && is_digit(chars[i + 3])
            && is_digit(chars[i + 4])
            && chars[i + 5] == '-'
            && is_digit(chars[i + 6])
            && is_digit(chars[i + 7])
            && chars[i + 8] == '-'
            && is_digit(chars[i + 9])
            && is_digit(chars[i + 10])
            && chars[i + 11] == ' '
            && is_digit(chars[i + 12])
            && is_digit(chars[i + 13])
            && chars[i + 14] == ':'
            && is_digit(chars[i + 15])
            && is_digit(chars[i + 16])
            && chars[i + 17] == ':'
            && is_digit(chars[i + 18])
            && is_digit(chars[i + 19])
            && chars[i + 20] == ']'
        {
            out.push_str("[<ts>]");
            i += 21;
            continue;
        }
        // pid=\d+ → pid=<pid>
        if i + 4 <= chars.len()
            && chars[i] == 'p'
            && chars[i + 1] == 'i'
            && chars[i + 2] == 'd'
            && chars[i + 3] == '='
        {
            let mut j = i + 4;
            while j < chars.len() && is_digit(chars[j]) {
                j += 1;
            }
            if j > i + 4 {
                out.push_str("pid=<pid>");
                i = j;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn normalize_value(value: &mut Value, home: &Path) {
    match value {
        Value::String(text) => {
            *text = normalize_text(text, home);
        }
        Value::Array(items) => items.iter_mut().for_each(|item| normalize_value(item, home)),
        Value::Object(map) => map.values_mut().for_each(|item| normalize_value(item, home)),
        _ => {}
    }
}

fn normalize_status(status: &TunnelStatus) -> Value {
    let mut value = serde_json::to_value(status).unwrap();
    if value["case"] == "running" && !value["pid"].is_null() {
        value["pid"] = json!("<pid>");
    }
    value
}

// MARK: - fake runner

struct ScriptedRunner {
    script: Mutex<Vec<ScriptEntry>>,
    invocations: Mutex<Vec<Vec<String>>>,
}

enum ScriptEntry {
    Result(ProcessResult),
    Spawn(String),
}

impl ScriptedRunner {
    fn from_fixture(entries: &[Value]) -> Self {
        let mut script = vec![];
        for entry in entries {
            let repeat = entry.get("repeat").and_then(|r| r.as_u64()).unwrap_or(1);
            for _ in 0..repeat {
                if let Some(spawn_error) = entry.get("spawnError").and_then(|s| s.as_str()) {
                    script.push(ScriptEntry::Spawn(spawn_error.to_string()));
                } else {
                    let result = entry.get("result").expect("脚本项缺 result");
                    script.push(ScriptEntry::Result(ProcessResult {
                        exit_code: result["exitCode"].as_i64().unwrap_or(0) as i32,
                        stdout: result["stdout"].as_str().unwrap_or("").to_string(),
                        stderr: result["stderr"].as_str().unwrap_or("").to_string(),
                    }));
                }
            }
        }
        ScriptedRunner { script: Mutex::new(script), invocations: Mutex::new(vec![]) }
    }

    fn remaining(&self) -> usize {
        self.script.lock().unwrap().len()
    }
}

impl ProcessRunning for ScriptedRunner {
    fn run(&self, executable_path: &str, arguments: &[String]) -> Result<ProcessResult, String> {
        // 与 Swift harness 对齐：仅记录 arguments（exe 固定 /bin/launchctl）
        let _ = executable_path;
        self.invocations.lock().unwrap().push(arguments.to_vec());
        let mut script = self.script.lock().unwrap();
        if script.is_empty() {
            return Err("runner script exhausted".into());
        }
        match script.remove(0) {
            ScriptEntry::Result(result) => Ok(result),
            ScriptEntry::Spawn(message) => Err(message),
        }
    }
}

fn error_event(error: &ExecutorError) -> Value {
    serde_json::to_value(error).unwrap()
}

// MARK: - 组件执行器

fn temp_home(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tp-diff-{label}-{}-{}",
        std::process::id(),
        uuid_like()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let counter = nanos % 1_000_000_000;
    format!("{nanos:x}{counter:x}")
}

fn tunnel_from_fixture(spec: &Value) -> TunnelConfig {
    serde_json::from_value(spec.clone()).expect("fixture tunnel 应可解码")
}

fn demo_outcome(
    op: &str,
    outcome: Result<&'static str, tunnelpad_core::demo::DemoOpError>,
) -> Value {
    match outcome {
        Ok(result) => json!({"op": op, "result": result}),
        Err(error) => json!({"op": op, "error": serde_json::to_value(error).unwrap()}),
    }
}

fn run_component(component: &str, fixture: &Value, home: &Path) -> Vec<Value> {

    match component {
        "demo-lifecycle" => {
            let tunnels: Vec<TunnelConfig> = fixture["tunnels"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or(&[])
                .iter()
                .map(tunnel_from_fixture)
                .collect();
            let first_tunnel = tunnels.first().expect("demo-lifecycle fixture 缺 tunnels");
            let runner = ScriptedRunner::from_fixture(
                fixture["runnerScript"].as_array().map(Vec::as_slice).unwrap_or(&[]),
            );
            let executor = LaunchCtlExecutor::new(runner_invocations_alias(&runner), tunnelpad_core::launchctl::current_uid());
            let paths = TunnelPaths::new(home);
            let lifecycle = DemoLifecycle::new(paths.clone(), executor);
            let operations = fixture["ops"].as_array().cloned().unwrap_or_default();
            let mut events = vec![];

            for operation in &operations {
                let op = operation["op"].as_str().expect("demo-lifecycle fixture 缺 op");
                let tunnel = operation
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|id| tunnels.iter().find(|item| item.id == id))
                    .unwrap_or(first_tunnel);
                match op {
                    "install" => {
                        let ids = lifecycle.install(&tunnels).expect("demo install 应成功");
                        events.push(json!({"op": "install", "ids": ids}));
                    }
                    "snapshot" => {
                        let mut snapshot = lifecycle.fs_snapshot();
                        normalize_value(&mut snapshot, home);
                        events.push(snapshot);
                    }
                    "plist" => events.push(json!({
                        "op": "plist",
                        "content": lifecycle.plist_content(&tunnel.id).map(|content| normalize_text(&content, home)),
                    })),
                    "start" => events.push(demo_outcome(op, lifecycle.start(&tunnel.id))),
                    "stop" => events.push(demo_outcome(op, lifecycle.stop(&tunnel.id))),
                    "restart" => events.push(demo_outcome(op, lifecycle.restart(&tunnel.id))),
                    "status" => events.push(json!({
                        "op": "status",
                        "status": normalize_status(&lifecycle.status(&tunnel.id).expect("demo status 应成功")),
                    })),
                    "remove" => match lifecycle.remove(&tunnel.id) {
                        Ok((result, log_warning)) => events.push(json!({
                            "op": "remove", "result": result, "logWarning": log_warning
                        })),
                        Err(error) => events.push(json!({
                            "op": "remove", "error": serde_json::to_value(error).unwrap()
                        })),
                    },
                    "takeover" => {
                        let legacy = fixture["legacy"].as_object().expect("takeover fixture 缺 legacy");
                        let label = legacy["agentLabel"].as_str().expect("takeover fixture 缺 agentLabel");
                        let plist = legacy["agentPlist"].as_str().expect("takeover fixture 缺 agentPlist");
                        let launch_agents = paths.launch_agents_directory();
                        fs::create_dir_all(&launch_agents).expect("demo takeover 应创建 LaunchAgents");
                        let agent_path = launch_agents.join(format!("{label}.plist"));
                        fs::write(&agent_path, plist).expect("demo takeover 应写入 legacy plist");
                        let agent = tunnelpad_core::legacy::parse_plist_file(&agent_path)
                            .expect("demo takeover legacy plist 应可解析");
                        match lifecycle.takeover(&agent) {
                            Ok(outcome) => {
                                let store = lifecycle.store();
                                let mut config = store.load().config;
                                config.tunnels.push(outcome.tunnel.clone());
                                store.save(&config).expect("demo takeover 应保存配置");
                                events.push(json!({
                                    "op": "takeover",
                                    "result": "ok",
                                    "rolledBack": outcome.rolled_back,
                                    "tunnelId": outcome.tunnel.id,
                                    "label": outcome.tunnel.launchd_label(),
                                }));
                            }
                            Err(tunnelpad_core::migration::TakeoverError::InvalidAgent { .. }) => {
                                events.push(json!({"op": "takeover", "errorCase": "invalidDemoID"}));
                            }
                            Err(error) => panic!("demo takeover 失败: {error:?}"),
                        }
                    }
                    "shutdown-all" => events.push(json!({
                        "op": "shutdown-all", "stopped": lifecycle.shutdown_all()
                    })),
                    _ => panic!("demo-lifecycle 不支持操作 {op}"),
                }
            }

            assert_eq!(runner.remaining(), 0, "demo-lifecycle runnerScript 未完全消费");
            let invocations = runner.invocations.lock().unwrap().clone();
            events.push(json!({
                "op": "runner",
                "invocations": invocations.iter().map(|args| json!({
                    "args": args.iter().map(|arg| normalize_text(arg, home)).collect::<Vec<_>>()
                })).collect::<Vec<_>>(),
                "remaining": runner.remaining(),
            }));
            lifecycle.app.shutdown_all();
            events
        }

        "demo-race" => {
            let scenarios = fixture["scenarios"].as_array().cloned().unwrap_or_default();
            let delay = fixture["restartDelay"].as_u64().unwrap_or(1);
            let mut events = vec![];
            for scenario in scenarios {
                let name = scenario["name"].as_str().expect("demo-race scenario 缺 name");
                let id = scenario["id"].as_str().expect("demo-race scenario 缺 id");
                let action = scenario["action"].as_str().expect("demo-race scenario 缺 action");
                let scenario_home = temp_home(&format!("race-{name}"));
                let paths = TunnelPaths::new(&scenario_home);
                let runner = ScriptedRunner::from_fixture(&[]);
                let launchd = LaunchCtlExecutor::new(runner_invocations_alias(&runner), tunnelpad_core::launchctl::current_uid());
                let tunnel = tunnel_from_fixture(&json!({
                    "id": id, "name": id, "command": ["/bin/sleep", "2"],
                    "executor": "app", "keepAlive": true, "throttleInterval": 1
                }));
                let app = AppProcessExecutor::with_options(
                    paths.clone(),
                    Some(delay),
                    Arc::new(|| "2026-08-30 00:00:00".to_string()),
                );
                let lifecycle = DemoLifecycle { paths: paths.clone(), launchd, app };
                lifecycle.install(&[tunnel.clone()]).expect("demo race install 应成功");
                lifecycle.app.start(&tunnel).expect("demo race start 应成功");
                let initial_pid = match lifecycle.app.status(id) {
                    TunnelStatus::Running { pid: Some(pid) } => pid,
                    status => panic!("demo-race 初始进程未运行: {status:?}"),
                };
                assert_eq!(unsafe { libc::kill(initial_pid, libc::SIGKILL) }, 0, "无法注入异常退出");

                let plan = {
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
                    loop {
                        let plans = lifecycle.app.handle_exits();
                        if let Some(plan) = plans.into_iter().next() {
                            break plan;
                        }
                        assert!(std::time::Instant::now() < deadline, "demo-race 等待重启计划超时");
                        std::thread::sleep(std::time::Duration::from_millis(20));
                    }
                };

                let mut restart_observed = false;
                match action {
                    "allow-restart" => {
                        std::thread::sleep(std::time::Duration::from_secs(plan.delay_secs));
                        assert!(lifecycle.app.restart_if_current(&plan).expect("keepAlive 重启不应报错"));
                        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
                        while std::time::Instant::now() < deadline {
                            if let TunnelStatus::Running { pid: Some(pid) } = lifecycle.app.status(id) {
                                if pid != initial_pid {
                                    restart_observed = true;
                                    break;
                                }
                            }
                            std::thread::sleep(std::time::Duration::from_millis(20));
                        }
                        assert!(restart_observed, "demo-race 未观察到 keepAlive 延迟重启");
                        lifecycle.app.stop(&tunnel);
                    }
                    "stop" => lifecycle.app.stop(&tunnel),
                    "remove" => {
                        lifecycle.remove(id).expect("demo race remove 应成功");
                    }
                    "shutdown-all" => {
                        lifecycle.shutdown_all();
                    }
                    _ => panic!("demo-race 不支持动作 {action}"),
                }
                let restart_blocked = if restart_observed {
                    false
                } else {
                    !lifecycle.app.restart_if_current(&plan).expect("stale restart 校验不应报错")
                };
                let status = normalize_status(&lifecycle.app.status(id));
                let mut snapshot = lifecycle.fs_snapshot();
                normalize_value(&mut snapshot, home);
                events.push(json!({
                    "scenario": name,
                    "restartBlocked": restart_blocked,
                    "restartScheduled": true,
                    "restartObserved": restart_observed,
                    "status": status,
                    "snapshot": snapshot,
                }));
                lifecycle.app.shutdown_all();
                fs::remove_dir_all(&scenario_home).ok();
            }
            events
        }

        "config-store" => {
            let mut events = vec![];
            for test_case in fixture["cases"].as_array().unwrap() {
                let case_home = temp_home("cfg");
                let store = ConfigStore::new(TunnelPaths::new(&case_home));
                if let Some(content) = test_case["fileContent"].as_str() {
                    fs::create_dir_all(store.paths.support_directory()).unwrap();
                    fs::write(store.paths.config_url(), content).unwrap();
                }
                let loaded = store.load();
                store.save(&loaded.config).unwrap();
                let saved = fs::read_to_string(store.paths.config_url()).unwrap_or_default();
                events.push(json!({
                    "name": test_case["name"],
                    "recoveredFrom": loaded.recovered_from.as_ref().map(|p| normalize_text(&p.to_string_lossy(), &case_home)),
                    "tunnelIds": loaded.config.tunnels.iter().map(|t| json!(t.id)).collect::<Vec<_>>(),
                    "saveContent": normalize_text(&saved, &case_home),
                }));
                fs::remove_dir_all(&case_home).ok();
            }
            events
        }

        "tunnel-id" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let existing: std::collections::BTreeSet<String> = test_case["existing"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|v| v.as_str())
                    .map(|s| s.to_string())
                    .collect();
                json!({
                    "name": test_case["name"],
                    "existing": test_case["existing"],
                    "id": tunnel_id::generate(test_case["name"].as_str().unwrap(), &existing),
                })
            })
            .collect(),

        "ssh-command" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let command: Vec<String> = test_case["command"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_string())
                    .collect();
                json!({
                    "command": command,
                    "isSSH": ssh_command::is_ssh(&command),
                    "hasVerbose": ssh_command::has_verbose_flag(&command),
                    "added": ssh_command::adding_verbose_flag(&command),
                    "removed": ssh_command::removing_verbose_flag(&command),
                })
            })
            .collect(),

        "plist-render" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let tunnel = tunnel_from_fixture(&test_case["tunnel"]);
                let log_path = test_case["logPath"].as_str().unwrap();
                json!({
                    "label": tunnel.launchd_label(),
                    "content": plist_xml(&tunnel, log_path),
                })
            })
            .collect(),

        "launchctl-status" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let runner = ScriptedRunner::from_fixture(&[json!({
                    "result": {"exitCode": 0, "stdout": test_case["printOutput"], "stderr": ""}
                })]);
                let executor = LaunchCtlExecutor::new(runner, tunnelpad_core::launchctl::current_uid());
                json!({
                    "label": test_case["label"],
                    "status": normalize_status(&executor.status(test_case["label"].as_str().unwrap())),
                })
            })
            .collect(),

        "launchctl-bootout" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let runner = ScriptedRunner::from_fixture(&[test_case.clone()]);
                let executor = LaunchCtlExecutor::new(runner, tunnelpad_core::launchctl::current_uid());
                let outcome = match executor.bootout(test_case["label"].as_str().unwrap()) {
                    Ok(unloaded) => json!({"ok": unloaded}),
                    Err(error) => json!({"error": error_event(&error)}),
                };
                json!({"label": test_case["label"], "outcome": outcome})
            })
            .collect(),

        "launchctl-bootstrap" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let runner = ScriptedRunner::from_fixture(&[test_case.clone()]);
                let executor = LaunchCtlExecutor::new(runner, tunnelpad_core::launchctl::current_uid());
                let plist_path = home.join(format!("plist-{}.plist", test_case["label"].as_str().unwrap()));
                let outcome = match executor.bootstrap(test_case["label"].as_str().unwrap(), &plist_path) {
                    Ok(()) => json!({"ok": true}),
                    Err(error) => json!({"error": error_event(&error)}),
                };
                json!({"label": test_case["label"], "outcome": outcome})
            })
            .collect(),

        "probe" => {
            struct Queued {
                results: Mutex<Vec<Result<i32, String>>>,
            }
            impl ProbePerforming for Queued {
                fn perform(&self, _url: &str) -> Result<i32, String> {
                    self.results.lock().unwrap().pop().expect("probe 脚本耗尽")
                }
            }
            // Vec::pop 是 LIFO，按消费顺序逆序入队
            let mut queued = vec![];
            for test_case in fixture["cases"].as_array().unwrap().iter().rev() {
                let perform = test_case.get("perform").cloned().unwrap_or(json!({}));
                if let Some(error) = perform.get("error").and_then(|e| e.as_str()) {
                    queued.push(Err(error.to_string()));
                } else {
                    queued.push(Ok(perform["status"].as_i64().unwrap_or(0) as i32));
                }
            }
            let service = ProbeService { performer: Some(Box::new(Queued { results: Mutex::new(queued) })) };
            fixture["cases"]
                .as_array()
                .unwrap()
                .iter()
                .map(|test_case| {
                    let probe: tunnelpad_core::ProbeConfig = serde_json::from_value(json!({
                        "url": test_case["url"],
                        "expectedStatuses": test_case["expectedStatuses"],
                    }))
                    .unwrap();
                    match service.check(&probe) {
                        ProbeOutcome::Satisfied { status } => json!({"case": "satisfied", "status": status}),
                        ProbeOutcome::Unexpected { status } => json!({"case": "unexpected", "status": status}),
                        ProbeOutcome::Failed { reason } => json!({"case": "failed", "reason": reason}),
                    }
                })
                .collect()
        }

        "log-tail" => fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|test_case| {
                let max_lines = test_case["maxLines"].as_u64().unwrap_or(500) as usize;
                let url = home.join(format!("log-{}.txt", uuid_like()));
                let result = if test_case.get("missing").and_then(|m| m.as_bool()).unwrap_or(false) {
                    None
                } else {
                    let content = test_case["content"].as_str().unwrap_or("");
                    fs::write(&url, content).unwrap();
                    last_lines(&url, max_lines)
                };
                fs::remove_file(&url).ok();
                json!({"result": result})
            })
            .collect(),

        "legacy-scan" => {
            let scan_dir = home.join("Library/LaunchAgents");
            fs::create_dir_all(&scan_dir).unwrap();
            for (name, content) in fixture["files"].as_object().unwrap() {
                fs::write(scan_dir.join(name), content.as_str().unwrap()).unwrap();
            }
            let agents = legacy::scan(&scan_dir);
            vec![json!({
                "agents": agents.iter().map(|agent| {
                    json!({
                        "label": agent.label,
                        "programArguments": agent.program_arguments,
                        "keepAlive": agent.keep_alive,
                        "runAtLoad": agent.run_at_load,
                        "throttleInterval": agent.throttle_interval,
                    })
                }).collect::<Vec<_>>()
            })]
        }

        "legacy-derive" => {
            let ids: Vec<Value> = fixture["labels"]
                .as_array()
                .unwrap()
                .iter()
                .map(|label| match legacy::tunnel_id(label.as_str().unwrap()) {
                    Some(id) => json!(id),
                    None => Value::Null,
                })
                .collect();
            let configs: Vec<Value> = fixture["agents"]
                .as_array()
                .unwrap()
                .iter()
                .map(|spec| {
                    let agent = LegacyAgent {
                        label: spec["label"].as_str().unwrap().to_string(),
                        plist_path: PathBuf::from("/tmp/unused.plist"),
                        program_arguments: spec["programArguments"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|v| v.as_str().unwrap().to_string())
                            .collect(),
                        keep_alive: spec["keepAlive"].as_bool().unwrap_or(false),
                        run_at_load: spec["runAtLoad"].as_bool().unwrap_or(false),
                        throttle_interval: spec["throttleInterval"].as_i64(),
                    };
                    match legacy::tunnel_config(&agent) {
                        Some(config) => serde_json::to_value(&config).unwrap(),
                        None => Value::Null,
                    }
                })
                .collect();
            vec![json!({"ids": ids, "configs": configs})]
        }

        "migration" => fixture["scenarios"]
            .as_array()
            .unwrap()
            .iter()
            .map(|scenario| {
                let scenario_home = temp_home("mig");
                let scenario_paths = TunnelPaths::new(&scenario_home);
                let launch_agents = scenario_home.join("Library/LaunchAgents");
                fs::create_dir_all(&launch_agents).unwrap();
                let label = scenario["agentLabel"].as_str().unwrap();
                let agent_plist = launch_agents.join(format!("{label}.plist"));
                fs::write(&agent_plist, scenario["agentPlist"].as_str().unwrap()).unwrap();

                let runner = ScriptedRunner::from_fixture(scenario["runnerScript"].as_array().unwrap());
                let executor = LaunchCtlExecutor::new(runner_invocations_alias(&runner), tunnelpad_core::launchctl::current_uid());
                let service = tunnelpad_core::migration::MigrationService::new(
                    scenario_paths.clone(),
                    executor,
                    Arc::new(|| {}),
                    Arc::new(tunnelpad_core::config_store::system_timestamp),
                );

                let parsed = legacy::parse_plist_file(&agent_plist).expect("fixture agent plist 应可解析");
                let agent = LegacyAgent {
                    label: label.to_string(),
                    plist_path: agent_plist.clone(),
                    program_arguments: parsed.program_arguments,
                    keep_alive: parsed.keep_alive,
                    run_at_load: parsed.run_at_load,
                    throttle_interval: parsed.throttle_interval,
                };

                let mut event = json!({"scenario": scenario["name"]});
                match service.takeover(&agent) {
                    Ok(outcome) => {
                        event["outcome"] = json!({
                            "rolledBack": outcome.rolled_back,
                            "tunnelId": outcome.tunnel.id,
                            "label": outcome.tunnel.launchd_label(),
                        });
                    }
                    Err(error) => {
                        let (error_case, error_label) = match &error {
                            tunnelpad_core::migration::TakeoverError::InvalidAgent { label, .. } => ("invalidAgent", Some(label.clone())),
                            tunnelpad_core::migration::TakeoverError::BackupFailed { label, .. } => ("backupFailed", Some(label.clone())),
                            tunnelpad_core::migration::TakeoverError::Executor { .. } => ("executor", None),
                            tunnelpad_core::migration::TakeoverError::Io { .. } => ("executor", None),
                            tunnelpad_core::migration::TakeoverError::VerifyFailed { label } => ("verifyFailed", Some(label.clone())),
                            tunnelpad_core::migration::TakeoverError::RollbackFailed { label, .. } => ("rollbackFailed", Some(label.clone())),
                        };
                        event["errorCase"] = json!(error_case);
                        if let Some(label) = error_label {
                            event["errorLabel"] = json!(label);
                        }
                    }
                }
                let invocations = runner.invocations.lock().unwrap().clone();
                event["invocations"] = Value::Array(
                    invocations
                        .iter()
                        .map(|args| {
                            json!({"args": args.iter().map(|a| json!(normalize_text(a, &scenario_home))).collect::<Vec<_>>()})
                        })
                        .collect(),
                );
                let mut launch_agents_files: Vec<String> = fs::read_dir(&launch_agents)
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .map(|e| normalize_text(&e.file_name().to_string_lossy(), &scenario_home))
                            .collect()
                    })
                    .unwrap_or_default();
                launch_agents_files.sort();
                let mut backup_files: Vec<String> = fs::read_dir(scenario_paths.migration_backup_directory())
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .map(|e| normalize_text(&e.file_name().to_string_lossy(), &scenario_home))
                            .collect()
                    })
                    .unwrap_or_default();
                backup_files.sort();
                event["launchAgentsFiles"] = json!(launch_agents_files);
                event["backupFiles"] = json!(backup_files);
                fs::remove_dir_all(&scenario_home).ok();
                event
            })
            .collect(),

        "app-executor" => {
            let command: Vec<String> = fixture["command"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_string())
                .collect();
            let executor_home = temp_home("app");
            let executor_paths = TunnelPaths::new(&executor_home);
            let executor = AppProcessExecutor::new(executor_paths.clone());
            let tunnel = tunnel_from_fixture(&json!({
                "id": "diff-app", "name": "diff-app", "command": command,
                "executor": "app", "keepAlive": false, "throttleInterval": 10
            }));

            executor.start(&tunnel).expect("start 应成功");
            let status_after_start = normalize_status(&executor.status(&tunnel.id));
            let pidfile = executor_paths.pidfile_url(&tunnel);
            let pidfile_after_start = if pidfile.exists() { json!("<pid>") } else { Value::Null };
            let log_content = fs::read_to_string(executor_paths.log_url(&tunnel)).unwrap_or_default();
            let spawned_line = log_content
                .split('\n')
                .next()
                .map(|line| json!(normalize_text(line, &executor_home)));

            executor.stop(&tunnel);
            let status_after_stop = normalize_status(&executor.status(&tunnel.id));
            let pidfile_after_stop = if pidfile.exists() { json!("EXISTS") } else { Value::Null };

            let events = vec![json!({
                "statusAfterStart": status_after_start,
                "pidfileAfterStart": pidfile_after_start,
                "spawnedLine": spawned_line,
                "statusAfterStop": status_after_stop,
                "pidfileAfterStop": pidfile_after_stop,
                "managedIds": executor.managed_ids(),
            })];
            fs::remove_dir_all(&executor_home).ok();
            events
        }

        other => vec![json!({"unsupported": other})],
    }
}

/// ScriptedRunner 的引用别名辅助（保持 runner 存活到 invocations 读取完成）。
fn runner_invocations_alias(runner: &ScriptedRunner) -> impl ProcessRunning + '_ {
    struct Borrow<'a>(&'a ScriptedRunner);
    impl ProcessRunning for Borrow<'_> {
        fn run(&self, executable_path: &str, arguments: &[String]) -> Result<ProcessResult, String> {
            self.0.run(executable_path, arguments)
        }
    }
    Borrow(runner)
}

#[test]
fn differential_matches_swift_events() {
    let swift_events_path = repo_root().join("rust/target/differential/swift-events.json");
    if !swift_events_path.exists() {
        println!("swift-events.json 不存在；请先运行 rust/scripts/differential.sh（swift test 阶段）");
        return;
    }

    let mut fixture_paths: Vec<PathBuf> = fs::read_dir(fixtures_dir())
        .unwrap()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().map(|ext| ext == "json").unwrap_or(false))
        .collect();
    fixture_paths.sort();

    let mut rust_events: BTreeMap<String, Value> = BTreeMap::new();
    for fixture_path in &fixture_paths {
        let fixture: Value = serde_json::from_str(&fs::read_to_string(fixture_path).unwrap()).unwrap();
        let component = fixture["component"].as_str().unwrap().to_string();
        let home = temp_home(&component);
        let events = run_component(&component, &fixture, &home);
        let mut normalized = json!(events);
        normalize_value(&mut normalized, &home);
        rust_events.insert(fixture_path.file_name().unwrap().to_string_lossy().to_string(), normalized);
        fs::remove_dir_all(&home).ok();
    }

    let swift_events: Value = serde_json::from_str(&fs::read_to_string(&swift_events_path).unwrap())
        .expect("swift-events.json 应为合法 JSON");
    let swift_map = swift_events.as_object().expect("顶层应为对象");

    let mut failures = vec![];
    for (name, rust_value) in &rust_events {
        match swift_map.get(name) {
            Some(swift_value) => {
                if swift_value != rust_value {
                    failures.push(format!(
                        "场景 {name} 不一致：\n  swift = {swift_value:#}\n  rust  = {rust_value:#}"
                    ));
                }
            }
            None => failures.push(format!("场景 {name} 在 swift-events.json 中缺失")),
        }
    }
    for name in swift_map.keys() {
        if !rust_events.contains_key(name) {
            failures.push(format!("场景 {name} 在 Rust 侧缺失"));
        }
    }

    assert!(
        failures.is_empty(),
        "差分测试失败（{} 项）：\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}
