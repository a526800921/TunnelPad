use super::{Failure, Result};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

fn error() -> Failure {
    Failure::new(2, "local", "state_unsafe")
}
pub fn directory(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::create_dir_all(path).map_err(|_| error())?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|_| error())?;
    }
    let m = fs::symlink_metadata(path).map_err(|_| error())?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0 {
        return Err(error());
    }
    Ok(())
}
pub fn file(path: &Path, create: bool) -> Result<File> {
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| error())?;
    let m = f.metadata().map_err(|_| error())?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
        || m.nlink() != 1
    {
        return Err(error());
    }
    Ok(f)
}
pub fn read<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(error()),
        _ => {}
    }
    let mut body = Vec::new();
    file(path, false)?
        .take(65537)
        .read_to_end(&mut body)
        .map_err(|_| error())?;
    if body.len() > 65536 {
        return Err(error());
    }
    serde_json::from_slice(&body).map(Some).map_err(|_| error())
}
pub fn write<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    if fs::symlink_metadata(path).is_ok() {
        file(path, false)?;
    }
    let temp = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temp)
        .map_err(|_| error())?;
    let outcome = (|| {
        f.write_all(&serde_json::to_vec(value).map_err(|_| error())?)
            .map_err(|_| error())?;
        f.sync_all().map_err(|_| error())?;
        fs::rename(&temp, path).map_err(|_| error())?;
        File::open(path.parent().ok_or_else(error)?)
            .and_then(|f| f.sync_all())
            .map_err(|_| error())
    })();
    if outcome.is_err() {
        let _ = fs::remove_file(temp);
    }
    outcome
}
pub fn remove(path: &Path) -> Result<()> {
    file(path, false)?;
    fs::remove_file(path).map_err(|_| error())?;
    File::open(path.parent().ok_or_else(error)?)
        .and_then(|f| f.sync_all())
        .map_err(|_| error())
}
