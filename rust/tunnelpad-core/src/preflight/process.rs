use super::{Failure, Result};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub fn nonblocking<T: AsRawFd>(pipe: &T) {
    unsafe {
        let flags = libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}
pub fn drain<T: Read>(pipe: &mut T, out: &mut Vec<u8>) -> Result<bool> {
    let mut buf = [0u8; 8192];
    loop {
        match pipe.read(&mut buf) {
            Ok(0) => return Ok(true),
            Ok(n) => {
                if out.len() + n > 1024 * 1024 {
                    return Err(Failure::new(4, "unknown", "response_limit"));
                }
                out.extend_from_slice(&buf[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(Failure::new(4, "unknown", "response_io")),
        }
    }
}
pub fn alive_parent(parent: i32) -> bool {
    unsafe { libc::getppid() == parent && libc::kill(parent, 0) == 0 }
}
pub fn guard(parent: i32) {
    if !alive_parent(parent) {
        unsafe {
            libc::kill(-libc::getpgrp(), libc::SIGKILL);
        }
        std::process::exit(7);
    }
}
pub fn run(bin: &str, args: &[String], parent: i32, deadline: Instant) -> Result<(bool, Vec<u8>)> {
    guard(parent);
    if Instant::now() >= deadline {
        return Err(Failure::new(3, "transient", "deadline"));
    }
    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| Failure::new(2, "local", "dependency_unavailable"))?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    nonblocking(&stdout);
    nonblocking(&stderr);
    let mut out = Vec::new();
    let mut err = Vec::new();
    let result = (|| loop {
        guard(parent);
        let eof = drain(&mut stdout, &mut out)?;
        let err_eof = drain(&mut stderr, &mut err)?;
        if let Some(status) = child
            .try_wait()
            .map_err(|_| Failure::new(3, "unknown", "process_wait"))?
        {
            if eof && err_eof {
                out.extend_from_slice(&err);
                return Ok((status.success(), out));
            }
        }
        if Instant::now() >= deadline {
            return Err(Failure::new(3, "transient", "deadline"));
        }
        std::thread::sleep(Duration::from_millis(5));
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}
