//! launchd 隧道日志代理：给子进程 stdout/stderr 的每个逻辑行加本地时间戳。

use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
#[cfg(debug_assertions)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const CHILD_CLEANUP_TERM_WAIT: Duration = Duration::from_secs(2);
const CHILD_CLEANUP_KILL_WAIT: Duration = Duration::from_secs(1);
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(25);
const OUTPUT_POLL_INTERVAL: Duration = Duration::from_millis(100);

struct OutputLine {
    stream: &'static str,
    bytes: Vec<u8>,
}

enum OutputEvent {
    Line(OutputLine),
    ReaderError {
        stream: &'static str,
        message: String,
    },
}

fn main() {
    let (log_path, command) = match parse_arguments() {
        Ok(value) => value,
        Err(message) => {
            eprintln!("tunnelpad-log-proxy: {message}");
            std::process::exit(64);
        }
    };

    match run(&log_path, &command) {
        Ok(status) => {
            if let Some(code) = status.code() {
                std::process::exit(code);
            }
            std::process::exit(128 + status.signal().unwrap_or(libc::SIGTERM));
        }
        Err(error) => {
            append_proxy_error(&log_path, &format!("日志代理失败：{error}"));
            std::process::exit(70);
        }
    }
}

fn parse_arguments() -> Result<(PathBuf, Vec<String>), String> {
    let mut args = env::args_os().skip(1);
    match args
        .next()
        .and_then(|arg| arg.into_string().ok())
        .as_deref()
    {
        Some("--log") => {}
        _ => return Err("用法：tunnelpad-log-proxy --log <日志路径> -- <命令> [参数...]".into()),
    }
    let log_path = args
        .next()
        .ok_or_else(|| "缺少日志路径".to_string())
        .and_then(|value| {
            value
                .into_string()
                .map_err(|_| "日志路径不是有效 UTF-8".to_string())
        })?;
    if args
        .next()
        .and_then(|arg| arg.into_string().ok())
        .as_deref()
        != Some("--")
    {
        return Err("缺少命令分隔符 --".into());
    }
    let command: Vec<String> = args
        .map(|value| {
            value
                .into_string()
                .map_err(|_| "命令参数不是有效 UTF-8".to_string())
        })
        .collect::<Result<_, _>>()?;
    if command.is_empty() || command[0].is_empty() {
        return Err("缺少要启动的命令".into());
    }
    Ok((PathBuf::from(log_path), command))
}

fn run(log_path: &Path, command: &[String]) -> io::Result<std::process::ExitStatus> {
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;

    let signal_set = block_forwarded_signals()?;
    let mut child_command = Command::new(&command[0]);
    child_command
        .args(&command[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        child_command.pre_exec(|| {
            let mut empty_set = std::mem::zeroed::<libc::sigset_t>();
            if libc::sigemptyset(&mut empty_set) != 0
                || libc::pthread_sigmask(libc::SIG_SETMASK, &empty_set, std::ptr::null_mut()) != 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let mut child = match child_command.spawn() {
        Ok(child) => child,
        Err(error) => {
            write_log_line(
                &mut log,
                "proxy",
                format!("无法启动隧道进程：{error}").as_bytes(),
            )?;
            std::process::exit(127);
        }
    };

    let child_pid = Arc::new(AtomicI32::new(child.id() as i32));
    let signal_thread_stop = Arc::new(AtomicBool::new(false));
    let shutdown_signal = Arc::new(AtomicI32::new(0));
    spawn_signal_forwarder(
        signal_set,
        child_pid.clone(),
        shutdown_signal.clone(),
        signal_thread_stop.clone(),
    );

    let (sender, receiver) = mpsc::channel();
    let stdout = child.stdout.take().expect("stdout pipe should exist");
    let stderr = child.stderr.take().expect("stderr pipe should exist");
    spawn_reader(stdout, "stdout", sender.clone());
    spawn_reader(stderr, "stderr", sender);

    let mut child_status = None;
    let mut failure = None;
    loop {
        if shutdown_signal.load(Ordering::Relaxed) != 0 {
            failure = Some(io::Error::new(
                io::ErrorKind::Interrupted,
                "日志代理收到停止信号",
            ));
            break;
        }

        match receiver.recv_timeout(OUTPUT_POLL_INTERVAL) {
            Ok(OutputEvent::Line(line)) => {
                if let Err(error) = write_log_line(&mut log, line.stream, &line.bytes) {
                    failure = Some(error);
                    break;
                }
            }
            Ok(OutputEvent::ReaderError { stream, message }) => {
                failure = Some(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    format!("读取 {stream} 输出失败：{message}"),
                ));
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Some(status) = child.try_wait()? {
                    child_status = Some(status);
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                if shutdown_signal.load(Ordering::Relaxed) != 0 {
                    // 信号驱动的正常停止可能先关闭 reader，再回到循环顶部。
                    // 这时由下方的 child.wait() 等待已转发的停止信号，不应误报代理失败。
                    break;
                }
                if let Some(status) = child.try_wait()? {
                    child_status = Some(status);
                } else {
                    failure = Some(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "日志输出 reader 已断开",
                    ));
                }
                break;
            }
        }
    }

    signal_thread_stop.store(true, Ordering::Relaxed);
    if let Some(error) = failure {
        let cleanup = cleanup_child(&mut child, &child_pid);
        let group_cleanup = cleanup_owned_process_group();
        child_pid.store(0, Ordering::Relaxed);
        if let Err(cleanup_error) = cleanup {
            return Err(io::Error::new(
                cleanup_error.kind(),
                format!("{error}；清理隧道进程失败：{cleanup_error}"),
            ));
        }
        if let Err(group_error) = group_cleanup {
            return Err(io::Error::new(
                group_error.kind(),
                format!("{error}；清理隧道进程组失败：{group_error}"),
            ));
        }
        return Err(error);
    }

    let status = match child_status {
        Some(status) => status,
        None => child.wait()?,
    };
    child_pid.store(0, Ordering::Relaxed);
    cleanup_owned_process_group()?;
    Ok(status)
}

fn spawn_reader<R>(reader: R, stream: &'static str, sender: mpsc::Sender<OutputEvent>)
where
    R: io::Read + Send + 'static,
{
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        loop {
            let mut bytes = Vec::new();
            match reader.read_until(b'\n', &mut bytes) {
                Ok(0) => return,
                Ok(_) => {
                    if sender
                        .send(OutputEvent::Line(OutputLine { stream, bytes }))
                        .is_err()
                    {
                        return;
                    }
                }
                Err(error) => {
                    let _ = sender.send(OutputEvent::ReaderError {
                        stream,
                        message: error.to_string(),
                    });
                    return;
                }
            }
        }
    });
}

fn cleanup_child(child: &mut std::process::Child, child_pid: &AtomicI32) -> io::Result<()> {
    let pid = child_pid.load(Ordering::Relaxed);
    if pid <= 1 {
        return Ok(());
    }

    for signal in [libc::SIGCONT, libc::SIGTERM] {
        send_signal(pid, signal)?;
        if wait_for_child(child, CHILD_CLEANUP_TERM_WAIT)? {
            return Ok(());
        }
    }

    send_signal(pid, libc::SIGKILL)?;
    if wait_for_child(child, CHILD_CLEANUP_KILL_WAIT)? {
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "隧道进程在有界清理窗口内未退出",
    ))
}

fn wait_for_child(child: &mut std::process::Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(CHILD_POLL_INTERVAL);
    }
}

fn send_signal(pid: i32, signal: i32) -> io::Result<()> {
    let result = unsafe { libc::kill(pid, signal) };
    if result == 0 {
        Ok(())
    } else if std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// 仅当代理自己是该进程组 leader 时才清理同组后代，避免直接运行代理
/// 时误伤调用方所在的共享进程组。launchd 作业默认以代理 PID 作为组 leader；
/// 代理被 SIGKILL 时则由 launchd 按 `AbandonProcessGroup=false` 清理同组后代。
fn cleanup_owned_process_group() -> io::Result<()> {
    let own_pid = std::process::id() as i32;
    let process_group_id = unsafe { libc::getpgrp() };
    if process_group_id <= 1 || process_group_id != own_pid {
        return Ok(());
    }

    let members = process_group_members(process_group_id)?;
    let members: Vec<i32> = members
        .into_iter()
        .filter(|pid| *pid > 1 && *pid != own_pid)
        .collect();
    if members.is_empty() {
        return Ok(());
    }

    for signal in [libc::SIGCONT, libc::SIGTERM, libc::SIGKILL] {
        for pid in &members {
            if unsafe { libc::getpgid(*pid) } == process_group_id {
                let _ = send_signal(*pid, signal);
            }
        }
        if wait_for_group_members(process_group_id, &members, CHILD_CLEANUP_TERM_WAIT)? {
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "隧道进程组在有界清理窗口内未收敛",
    ))
}

fn wait_for_group_members(
    process_group_id: i32,
    members: &[i32],
    timeout: Duration,
) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        let has_live_member = members
            .iter()
            .any(|pid| *pid > 1 && unsafe { libc::getpgid(*pid) } == process_group_id);
        if !has_live_member {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(CHILD_POLL_INTERVAL);
    }
}

#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_listpids(
        ty: u32,
        typeinfo: u32,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

#[cfg(target_os = "macos")]
fn process_group_members(process_group_id: i32) -> io::Result<Vec<i32>> {
    const PROC_PGRP_ONLY: u32 = 2;
    let mut buffer = vec![0_i32; 256];
    let buffer_size = buffer.len() * std::mem::size_of::<i32>();
    let bytes = unsafe {
        proc_listpids(
            PROC_PGRP_ONLY,
            process_group_id as u32,
            buffer.as_mut_ptr().cast(),
            buffer_size as libc::c_int,
        )
    };
    if bytes < 0 {
        return Err(io::Error::last_os_error());
    }
    if bytes as usize >= buffer_size || bytes as usize % std::mem::size_of::<i32>() != 0 {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "隧道进程组成员超出有界观测容量",
        ));
    }
    buffer.truncate(bytes as usize / std::mem::size_of::<i32>());
    Ok(buffer.into_iter().filter(|pid| *pid > 0).collect())
}

#[cfg(not(target_os = "macos"))]
fn process_group_members(_process_group_id: i32) -> io::Result<Vec<i32>> {
    Ok(Vec::new())
}

fn write_log_line(log: &mut File, stream: &str, bytes: &[u8]) -> io::Result<()> {
    #[cfg(debug_assertions)]
    {
        static WRITE_COUNT: AtomicUsize = AtomicUsize::new(0);
        if let Some(limit) = env::var("TUNNELPAD_LOG_PROXY_FAIL_AFTER_LINES")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
        {
            let count = WRITE_COUNT.fetch_add(1, Ordering::Relaxed);
            if count >= limit {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "测试注入：日志行写入失败",
                ));
            }
        }
    }
    let mut content = bytes;
    if content.last() == Some(&b'\n') {
        content = &content[..content.len() - 1];
        if content.last() == Some(&b'\r') {
            content = &content[..content.len() - 1];
        }
    }
    let text = String::from_utf8_lossy(content);
    writeln!(log, "{} [{}] {}", timestamp(), stream, text)?;
    log.flush()
}

fn append_proxy_error(log_path: &Path, message: &str) {
    if let Some(parent) = log_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut log) = OpenOptions::new().create(true).append(true).open(log_path) {
        let _ = write_log_line(&mut log, "proxy", message.as_bytes());
    }
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = now.as_secs() as libc::time_t;
    let milliseconds = now.subsec_millis();
    let mut local = std::mem::MaybeUninit::<libc::tm>::zeroed();
    let result = unsafe { libc::localtime_r(&seconds, local.as_mut_ptr()) };
    if result.is_null() {
        return format!("1970-01-01T00:00:00.{milliseconds:03}+0000");
    }
    let mut buffer = [0i8; 32];
    let format = b"%Y-%m-%dT%H:%M:%S%z\0";
    let length = unsafe {
        libc::strftime(
            buffer.as_mut_ptr(),
            buffer.len(),
            format.as_ptr() as *const i8,
            local.as_ptr(),
        )
    };
    if length == 0 {
        return format!("1970-01-01T00:00:00.{milliseconds:03}+0000");
    }
    let base = String::from_utf8_lossy(unsafe {
        std::slice::from_raw_parts(buffer.as_ptr() as *const u8, length)
    });
    if base.len() >= 5 {
        format!(
            "{}.{milliseconds:03}{}",
            &base[..base.len() - 5],
            &base[base.len() - 5..]
        )
    } else {
        format!("{base}.{milliseconds:03}")
    }
}

fn block_forwarded_signals() -> io::Result<libc::sigset_t> {
    let mut set = unsafe { std::mem::zeroed::<libc::sigset_t>() };
    let result = unsafe {
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::sigaddset(&mut set, libc::SIGHUP);
        libc::sigaddset(&mut set, libc::SIGQUIT);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut())
    };
    if result == 0 {
        Ok(set)
    } else {
        Err(io::Error::from_raw_os_error(result))
    }
}

fn spawn_signal_forwarder(
    signal_set: libc::sigset_t,
    child_pid: Arc<AtomicI32>,
    shutdown_signal: Arc<AtomicI32>,
    stop: Arc<AtomicBool>,
) {
    thread::spawn(move || loop {
        let mut signal = 0;
        let result = unsafe { libc::sigwait(&signal_set, &mut signal) };
        if result != 0 {
            return;
        }
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let pid = child_pid.load(Ordering::Relaxed);
        if pid > 0 {
            shutdown_signal.store(signal, Ordering::Relaxed);
            let _ = send_signal(pid, signal);
        }
    });
}

trait ExitStatusSignal {
    fn signal(&self) -> Option<i32>;
}

impl ExitStatusSignal for std::process::ExitStatus {
    fn signal(&self) -> Option<i32> {
        std::os::unix::process::ExitStatusExt::signal(self)
    }
}
