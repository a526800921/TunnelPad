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
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let mut child = Command::new(proxy)
        .env("TUNNELPAD_LOG_PROXY_FAIL_AFTER_LINES", "1")
        .args([
            "--log",
            log_path.to_str().unwrap(),
            "--",
            "/usr/bin/yes",
            "tunnelpad-test",
        ])
        .spawn()
        .unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !log_path.is_file() && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(70));
    assert!(
        child.try_wait().unwrap().is_some(),
        "proxy child should have been reaped"
    );
    assert!(fs::metadata(&log_path).unwrap().len() > 0);
    cleanup_directory(&directory);
}

#[test]
fn signal_shutdown_reaps_child() {
    let directory = temp_directory("signal");
    let log_path = directory.join("proxy.log");
    let proxy = env!("CARGO_BIN_EXE_tunnelpad-log-proxy");
    let mut command = Command::new(proxy);
    command.args([
        "--log",
        log_path.to_str().unwrap(),
        "--",
        "/bin/sleep",
        "30",
    ]);
    let mut process = command.spawn().unwrap();
    let log_deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !log_path.is_file() && std::time::Instant::now() < log_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(log_path.is_file(), "proxy should create its log before shutdown");
    let result = unsafe { libc::kill(process.id() as i32, libc::SIGTERM) };
    assert_eq!(result, 0);
    let status = process.wait().unwrap();
    assert!(!status.success());
    let content = String::from_utf8(fs::read(&log_path).unwrap()).unwrap();
    assert!(
        !content.contains("日志代理失败"),
        "signal-driven shutdown should not be logged as a proxy failure: {content:?}"
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
