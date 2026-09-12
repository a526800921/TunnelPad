mod process;
mod store;
mod transaction;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tunnelpad_core::launchctl::{
    ProcessIdentityError, ProcessIdentityReading, SystemProcessIdentityReader,
};

type Result<T> = std::result::Result<T, Failure>;
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    version: u8,
    stage: String,
    category: String,
    retry_hint: u64,
    sanitized_code: String,
    exit_code: i32,
}
impl Failure {
    fn new(exit_code: i32, category: &str, code: &str) -> Self {
        Self {
            version: 1,
            stage: match exit_code {
                2 => "local",
                3 => "probe",
                4 => "read",
                5 => "authorize",
                6 => "revoke",
                7 => "lock",
                _ => "complete",
            }
            .into(),
            category: category.into(),
            retry_hint: match category {
                "auth" => 1800,
                "local" | "unknown" => 300,
                "success" => 0,
                _ => 5,
            },
            sanitized_code: code.into(),
            exit_code,
        }
    }
}
fn env(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.into())
}
#[derive(Clone)]
struct Config {
    region: String,
    group: String,
    profile: String,
    credentials: String,
    curl: String,
    aliyun: String,
    endpoints: [String; 2],
    state: PathBuf,
    legacy: PathBuf,
    resource: String,
}
impl Config {
    fn load() -> Result<Self> {
        let region = env("ALIBABA_REGION_ID", "").trim().to_owned();
        let group = env("ECS_SECURITY_GROUP_ID", "").trim().to_owned();
        let credentials = env("TUNNELPAD_ALIYUN_CONFIG", "");
        if region.is_empty()
            || group.is_empty()
            || !fs::metadata(&credentials).is_ok_and(|m| m.is_file())
            || fs::File::open(&credentials).is_err()
        {
            return Err(Failure::new(2, "local", "configuration_missing"));
        }
        let resource = hash(&format!(
            "{}:{}{}:{}",
            region.len(),
            region,
            group.len(),
            group
        ));
        let home = env("HOME", "");
        if home.is_empty() {
            return Err(Failure::new(2, "local", "home_missing"));
        }
        let c = Self {
            region,
            group,
            profile: env("ALIBABA_PROFILE", "tunnelpad-ecs-sync"),
            credentials,
            curl: env("CURL_BIN", "curl"),
            aliyun: env("ALIYUN_BIN", "aliyun"),
            endpoints: [
                env("TUNNELPAD_IP_ENDPOINT_1", "https://myip.ipip.net"),
                env("TUNNELPAD_IP_ENDPOINT_2", "https://ip.3322.net"),
            ],
            state: PathBuf::from(env(
                "TUNNELPAD_PREFLIGHT_STATE_DIR",
                &format!("{home}/Library/Application Support/TunnelPad/preflight"),
            )),
            legacy: PathBuf::from(env(
                "TUNNELPAD_LOCK_DIR",
                &format!("{}/tunnelpad-ecs-ssh-ip.lock", env("TMPDIR", "/tmp")),
            )),
            resource,
        };
        for bin in [&c.curl, &c.aliyun] {
            if !executable(bin) {
                return Err(Failure::new(2, "local", "dependency_unavailable"));
            }
        }
        Ok(c)
    }
    fn path(&self, suffix: &str) -> PathBuf {
        self.state.join(format!("{}.{}", self.resource, suffix))
    }
}
fn executable(bin: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let paths: Vec<PathBuf> = if bin.contains('/') {
        vec![bin.into()]
    } else {
        std::env::split_paths(&env("PATH", ""))
            .map(|p| p.join(bin))
            .collect()
    };
    paths
        .iter()
        .any(|p| fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0))
}
// Stable identity hash only; journal stores original identity and rejects collisions.
fn hash(text: &str) -> String {
    let mut h = 0xcbf29ce484222325u64;
    for b in text.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}
#[derive(Serialize, Deserialize)]
struct Marker {
    version: u8,
    supervisor: i32,
    birth: u128,
    worker: i32,
}
fn dead(pid: i32, birth: Option<u128>) -> bool {
    match SystemProcessIdentityReader.read(pid) {
        Err(ProcessIdentityError::NotFound) => true,
        Ok(i) => birth.is_some_and(|b| i.start_time_micros != b),
        _ => false,
    }
}
fn group_gone(pid: i32) -> bool {
    pid == 0
        || (unsafe { libc::kill(-pid, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH))
}
static CANCEL: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: i32) {
    CANCEL.store(true, Ordering::Relaxed);
}
fn supervisor(c: &Config, check: bool) -> Result<()> {
    store::directory(&c.state)?;
    let lock = store::file(&c.path("lock"), true)?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(Failure::new(7, "transient", "lock_busy"));
    }
    unsafe {
        libc::fcntl(lock.as_raw_fd(), libc::F_SETFD, 0);
    }
    let marker = c.legacy.join("owner.json");
    if c.legacy.exists() {
        store::directory(&c.legacy)
            .map_err(|_| Failure::new(7, "unknown", "legacy_lock_unknown"))?;
        let old: Marker = store::read(&marker)?
            .ok_or_else(|| Failure::new(7, "unknown", "legacy_lock_unknown"))?;
        if old.version != 1 || !dead(old.supervisor, Some(old.birth)) || !group_gone(old.worker) {
            return Err(Failure::new(7, "transient", "lock_busy"));
        }
        store::remove(&marker)?;
        fs::remove_dir(&c.legacy).map_err(|_| Failure::new(7, "unknown", "legacy_lock_unknown"))?;
    }
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&c.legacy)
        .map_err(|_| Failure::new(7, "transient", "lock_busy"))?;
    let own = SystemProcessIdentityReader
        .read(std::process::id() as i32)
        .map_err(|_| Failure::new(7, "unknown", "identity_unavailable"))?;
    let mut mark = Marker {
        version: 1,
        supervisor: own.pid,
        birth: own.start_time_micros,
        worker: 0,
    };
    store::write(&marker, &mark)?;
    unsafe {
        libc::signal(libc::SIGTERM, cancel as *const () as usize);
        libc::signal(libc::SIGINT, cancel as *const () as usize);
    }
    let mut command = Command::new(
        std::env::current_exe().map_err(|_| Failure::new(2, "local", "helper_missing"))?,
    );
    command
        .arg("--worker")
        .arg(if check { "check" } else { "sync" })
        .env("TUNNELPAD_GUARDIAN", own.pid.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let mut child = command
        .spawn()
        .map_err(|_| Failure::new(2, "local", "worker_spawn"))?;
    mark.worker = child.id() as i32;
    let publish = store::write(&marker, &mark);
    let mut stdout = child.stdout.take().unwrap();
    process::nonblocking(&stdout);
    let mut output = Vec::new();
    let limit = env("TUNNELPAD_PREFLIGHT_TIMEOUT_MS", "30000")
        .parse::<u64>()
        .unwrap_or(30000)
        .clamp(1, 30000);
    let deadline = Instant::now() + Duration::from_millis(limit);
    let mut outcome = publish.and_then(|_| loop {
        if CANCEL.load(Ordering::Relaxed) {
            break Err(Failure::new(7, "cancelled", "cancelled"));
        }
        if Instant::now() >= deadline {
            break Err(Failure::new(3, "transient", "deadline"));
        }
        process::drain(&mut stdout, &mut output)?;
        if output.contains(&b'\n') {
            break serde_json::from_slice::<Failure>(&output)
                .map_err(|_| Failure::new(4, "unknown", "worker_result"))
                .and_then(|r| if r.exit_code == 0 { Ok(()) } else { Err(r) });
        }
        if child.try_wait().ok().flatten().is_some() {
            break Err(Failure::new(4, "unknown", "worker_exit"));
        }
        std::thread::sleep(Duration::from_millis(5));
    });
    // The inherited flock remains held until every process in this attempt has ended.
    unsafe {
        libc::kill(-mark.worker, libc::SIGTERM);
    }
    let grace = Instant::now() + Duration::from_secs(2);
    while Instant::now() < grace {
        let _ = child.try_wait();
        if group_gone(mark.worker) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if !group_gone(mark.worker) {
        unsafe {
            libc::kill(-mark.worker, libc::SIGKILL);
        }
    }
    let grace = Instant::now() + Duration::from_secs(2);
    while Instant::now() < grace {
        let _ = child.try_wait();
        if group_gone(mark.worker) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if group_gone(mark.worker) {
        store::remove(&marker)?;
        fs::remove_dir(&c.legacy).map_err(|_| Failure::new(7, "unknown", "lock_cleanup"))?;
    } else {
        outcome = Err(Failure::new(7, "unknown", "cleanup_unconfirmed"));
    }
    outcome
}
fn worker(c: &Config, check: bool) -> ! {
    let parent = env("TUNNELPAD_GUARDIAN", "").parse::<i32>().unwrap_or(0);
    let started = Instant::now();
    loop {
        process::guard(parent);
        if let Ok(Some(mark)) = store::read::<Marker>(&c.legacy.join("owner.json")) {
            if mark.worker == std::process::id() as i32 && mark.supervisor == parent {
                break;
            }
        }
        if started.elapsed() > Duration::from_secs(2) {
            std::process::exit(7);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let result = transaction::sync(c, check, parent, started + Duration::from_secs(30))
        .err()
        .unwrap_or_else(|| Failure::new(0, "success", "synchronized"));
    println!("{}", serde_json::to_string(&result).unwrap());
    let _ = std::io::stdout().flush();
    loop {
        process::guard(parent);
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[derive(Serialize, Deserialize)]
struct LastLog {
    category: String,
    code: String,
    at: u64,
}
fn record_result(c: &Config, status: &Failure) -> Result<()> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let log = env("TUNNELPAD_LOG_FILE", "");
    if log.is_empty() || !c.state.is_dir() {
        return Ok(());
    }
    let lock = store::file(&c.path("lock"), false)?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Ok(());
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let previous: Option<LastLog> = store::read(&c.path("last-log"))?;
    if previous.is_some_and(|p| {
        p.category == status.category
            && p.code == status.sanitized_code
            && now.saturating_sub(p.at) < 1800
    }) {
        return Ok(());
    }
    let mut file = store::file(std::path::Path::new(&log), true)?;
    unsafe {
        libc::fcntl(file.as_raw_fd(), libc::F_SETFL, libc::O_APPEND);
    }
    writeln!(
        file,
        "preflight {} {}",
        status.category, status.sanitized_code
    )
    .map_err(|_| Failure::new(2, "local", "log_unavailable"))?;
    store::write(
        &c.path("last-log"),
        &LastLog {
            category: status.category.clone(),
            code: status.sanitized_code.clone(),
            at: now,
        },
    )
}

pub fn main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json_result = args.iter().any(|a| a == "--result-json");
    let result = (|| {
        let c = Config::load()?;
        if args.first().is_some_and(|a| a == "--worker") {
            worker(&c, args.get(1).is_some_and(|a| a == "check"));
        }
        if args.iter().any(|a| {
            !matches!(
                a.as_str(),
                "--check" | "--local-check" | "--resource" | "--result-json"
            )
        }) {
            return Err(Failure::new(2, "local", "arguments"));
        }
        if args.iter().any(|a| a == "--resource") {
            println!("{}", json!({"version":1,"resource":c.resource}));
            return Ok(());
        }
        if args.iter().any(|a| a == "--local-check") {
            return Ok(());
        }
        supervisor(&c, args.iter().any(|a| a == "--check"))
    })();
    let status = result
        .err()
        .unwrap_or_else(|| Failure::new(0, "success", "synchronized"));
    if !args.iter().any(|a| a == "--resource") {
        if json_result {
            println!("{}", serde_json::to_string(&status).unwrap());
        } else {
            println!("前置检查：{}", status.sanitized_code);
        }
        if let Ok(config) = Config::load() {
            let _ = record_result(&config, &status);
        }
    }
    status.exit_code
}
