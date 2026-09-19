use std::fs;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::thread;
use std::time::Duration;

#[test]
fn prefixes_stdout_and_stderr_lines_with_local_timestamps() {
    let directory = std::env::temp_dir().join(format!(
        "tunnelpad-log-proxy-{}-{}",
        std::process::id(),
        unique_suffix()
    ));
    fs::create_dir_all(&directory).unwrap();
    let log_path = directory.join("proxy.log");

    let output = Command::new(env!("CARGO_BIN_EXE_tunnelpad-log-proxy"))
        .args([
            "--log",
            log_path.to_str().unwrap(),
            "--",
            "/bin/sh",
            "-c",
            "printf 'out-line\\n'; printf 'err-line\\n' >&2",
        ])
        .output()
        .unwrap();

    let content = String::from_utf8(fs::read(&log_path).unwrap()).unwrap();
    let lines: Vec<&str> = content.lines().collect();
    let _ = fs::remove_dir_all(&directory);
    assert!(output.status.success(), "proxy failed: {:?}", output);
    assert_eq!(lines.len(), 2, "unexpected log: {content:?}");
    assert!(lines
        .iter()
        .any(|line| has_prefix(line, "stdout") && line.ends_with("out-line")));
    assert!(lines
        .iter()
        .any(|line| has_prefix(line, "stderr") && line.ends_with("err-line")));
}

#[test]
fn log_write_failure_reaps_child_before_proxy_exits() {
    let directory = temp_directory("io-failure");
    let log_path = directory.join("proxy.log");
    let child_pid_path = directory.join("child.pid");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let mut command = Command::new(proxy);
    command
        .env("TUNNELPAD_LOG_PROXY_FAIL_AFTER_LINES", "1")
        .args([
            "--log",
            log_path.to_str().unwrap(),
            "--",
            "/bin/sh",
            "-c",
            "echo $$ > \"$1\"; exec /usr/bin/yes tunnelpad-test",
            "sh",
        ])
        .arg(&child_pid_path);
    let mut proxy_process = command.spawn().unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while (!log_path.is_file() || !child_pid_path.is_file()) && std::time::Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(10));
    }
    let child_pid = read_pid(&child_pid_path);
    let status = proxy_process.wait().unwrap();
    assert_eq!(status.code(), Some(70));
    assert_process_exited(child_pid, "日志写入失败后的隧道子进程");
    assert!(fs::metadata(&log_path).unwrap().len() > 0);
    cleanup_directory(&directory);
}

#[test]
fn signal_shutdown_reaps_child() {
    let directory = temp_directory("signal");
    let log_path = directory.join("proxy.log");
    let child_pid_path = directory.join("child.pid");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let mut command = Command::new(proxy);
    command
        .args([
            "--log",
            log_path.to_str().unwrap(),
            "--",
            "/bin/sh",
            "-c",
            "echo $$ > \"$1\"; exec /bin/sleep 30",
            "sh",
        ])
        .arg(&child_pid_path);
    let mut process = command.spawn().unwrap();
    let log_deadline = std::time::Instant::now() + Duration::from_secs(2);
    while (!log_path.is_file() || !child_pid_path.is_file())
        && std::time::Instant::now() < log_deadline
    {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        log_path.is_file(),
        "proxy should create its log before shutdown"
    );
    let child_pid = read_pid(&child_pid_path);
    let result = unsafe { libc::kill(process.id() as i32, libc::SIGTERM) };
    assert_eq!(result, 0);
    let status = process.wait().unwrap();
    assert!(!status.success());
    let content = String::from_utf8(fs::read(&log_path).unwrap()).unwrap();
    assert!(
        !content.contains("日志代理失败"),
        "signal-driven shutdown should not be logged as a proxy failure: {content:?}"
    );
    assert_process_exited(child_pid, "收到 SIGTERM 后的隧道子进程");
    cleanup_directory(&directory);
}

#[test]
fn delayed_signal_shutdown_with_reader_disconnect_is_not_a_proxy_failure() {
    let directory = temp_directory("delayed-signal");
    let log_path = directory.join("proxy.log");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let script =
        "trap 'exec 1>&- 2>&-; sleep 1; exit 0' TERM; printf 'ready\\n'; while :; do sleep 1; done";
    let mut process = Command::new(proxy)
        .args([
            "--log",
            log_path.to_str().unwrap(),
            "--",
            "/bin/sh",
            "-c",
            script,
        ])
        .spawn()
        .unwrap();
    let ready_deadline = std::time::Instant::now() + Duration::from_secs(2);
    while fs::read_to_string(&log_path)
        .map(|content| !content.contains("ready"))
        .unwrap_or(true)
        && std::time::Instant::now() < ready_deadline
    {
        thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(unsafe { libc::kill(process.id() as i32, libc::SIGTERM) }, 0);
    let status = process.wait().unwrap();
    assert!(
        status.success(),
        "delayed graceful child exit should be preserved"
    );
    let content = fs::read_to_string(&log_path).unwrap();
    assert!(
        !content.contains("日志代理失败"),
        "unexpected proxy failure: {content:?}"
    );
    cleanup_directory(&directory);
}

#[cfg(target_os = "macos")]
#[test]
fn descendant_pipe_holder_is_cleaned_when_proxy_owns_process_group() {
    let directory = temp_directory("pipe-holder");
    let log_path = directory.join("proxy.log");
    let descendant_pid_path = directory.join("descendant.pid");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let script = format!(
        "(sleep 30) & echo $! > {}; exit 0",
        descendant_pid_path.display()
    );
    let mut command = Command::new(proxy);
    command.args([
        "--log",
        log_path.to_str().unwrap(),
        "--",
        "/bin/sh",
        "-c",
        &script,
    ]);
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut process = command.spawn().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !descendant_pid_path.is_file() && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    let descendant_pid: i32 = fs::read_to_string(&descendant_pid_path)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let status = process.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    thread::sleep(Duration::from_millis(100));
    assert_ne!(unsafe { libc::kill(descendant_pid, 0) }, 0);
    cleanup_directory(&directory);
}

#[cfg(target_os = "macos")]
#[test]
fn continuous_descendant_output_cannot_hide_direct_child_exit() {
    let directory = temp_directory("continuous-descendant");
    let log_path = directory.join("proxy.log");
    let descendant_pid_path = directory.join("descendant.pid");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let script = format!(
        "(exec /usr/bin/yes descendant-output) & echo $! > {}; exit 0",
        descendant_pid_path.display()
    );
    let mut command = Command::new(proxy);
    command.args([
        "--log",
        log_path.to_str().unwrap(),
        "--",
        "/bin/sh",
        "-c",
        &script,
    ]);
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut process = command.spawn().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let status = loop {
        if let Some(status) = process.try_wait().unwrap() {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = unsafe { libc::kill(-(process.id() as i32), libc::SIGKILL) };
            let _ = process.wait();
            panic!("continuous descendant output hid the direct child exit");
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(status.code(), Some(0));
    let descendant_pid: i32 = fs::read_to_string(&descendant_pid_path)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    thread::sleep(Duration::from_millis(100));
    assert_ne!(unsafe { libc::kill(descendant_pid, 0) }, 0);
    cleanup_directory(&directory);
}

#[cfg(target_os = "macos")]
#[test]
fn term_trap_spawned_descendant_is_reenumerated_and_cleaned() {
    let directory = temp_directory("term-trap-descendant");
    let log_path = directory.join("proxy.log");
    let trap_pid_path = directory.join("trap.pid");
    let spawned_pid_path = directory.join("spawned.pid");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let script = format!(
        "(trap 'sleep 30 & echo $! > {}; exit 0' TERM; echo $$ > {}; while :; do sleep 1; done) & exit 0",
        spawned_pid_path.display(),
        trap_pid_path.display()
    );
    let mut command = Command::new(proxy);
    command.args([
        "--log",
        log_path.to_str().unwrap(),
        "--",
        "/bin/sh",
        "-c",
        &script,
    ]);
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut process = command.spawn().unwrap();
    let ready_deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !trap_pid_path.is_file() && std::time::Instant::now() < ready_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        trap_pid_path.is_file(),
        "TERM trap descendant did not start"
    );

    let status = process.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    let spawn_deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !spawned_pid_path.is_file() && std::time::Instant::now() < spawn_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    let spawned_pid = read_pid(&spawned_pid_path);
    assert_process_exited(spawned_pid, "TERM trap 新派生的同组后代");
    cleanup_directory(&directory);
}

fn temp_directory(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "tunnelpad-log-proxy-{name}-{}-{}",
        std::process::id(),
        unique_suffix()
    ));
    fs::create_dir_all(&directory).unwrap();
    directory
}

fn cleanup_directory(directory: &std::path::Path) {
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        fs::remove_file(path).unwrap();
    }
    fs::remove_dir(directory).unwrap();
}

fn read_pid(path: &std::path::Path) -> i32 {
    fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("无法读取子进程 PID {}：{error}", path.display()))
        .trim()
        .parse()
        .unwrap_or_else(|error| panic!("子进程 PID 非法 {}：{error}", path.display()))
}

fn assert_process_exited(pid: i32, context: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while process_exists(pid) && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_exists(pid), "{context}仍然存活，pid={pid}");
}

fn process_exists(pid: i32) -> bool {
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn has_prefix(line: &str, stream: &str) -> bool {
    let bytes = line.as_bytes();
    bytes.len() > 29
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b'T'
        && bytes[13] == b':'
        && bytes[16] == b':'
        && bytes[19] == b'.'
        && (bytes[23] == b'+' || bytes[23] == b'-')
        && bytes[28] == b' '
        && line[..23]
            .chars()
            .all(|character| character.is_ascii_digit() || b"-T:.".contains(&(character as u8)))
        && line[29..].starts_with(&format!("[{stream}] "))
}

fn unique_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}
