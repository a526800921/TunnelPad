//! 阶段 5 Rust owner 的 C ABI。
//!
//! 旧 `tp_*` ABI v1 保持不变；`tp_core_*` 提供长期 opaque handle + JSON
//! command，供 Swift 生产适配层接入。

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::ptr;

use crate::launchctl::{LaunchCtlExecutor, SystemProcessRunner};
use crate::owner::CoreOwner;
use crate::paths::TunnelPaths;
use crate::{error_code, TpError};

thread_local! {
    static OWNER_LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub struct TpCoreHandle {
    owner: CoreOwner<LaunchCtlExecutor<SystemProcessRunner>>,
}

fn set_error(error: &TpError) {
    let json = serde_json::to_string(error).unwrap_or_else(|_| {
        format!(
            "{{\"code\":{},\"message\":\"owner error serialization failed\"}}",
            error.code
        )
    });
    OWNER_LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(json));
}

fn clear_error() {
    OWNER_LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn finish(result: Result<String, TpError>) -> *mut c_char {
    match result {
        Ok(value) => match CString::new(value) {
            Ok(value) => {
                clear_error();
                value.into_raw()
            }
            Err(_) => {
                set_error(&TpError::new(
                    error_code::INVALID_JSON,
                    "owner 输出包含 NUL 字节",
                ));
                ptr::null_mut()
            }
        },
        Err(error) => {
            set_error(&error);
            ptr::null_mut()
        }
    }
}

unsafe fn read_utf8<'a>(input: *const c_char, label: &str) -> Result<&'a str, TpError> {
    if input.is_null() {
        return Err(TpError::new(
            error_code::INVALID_ARGUMENT,
            format!("{label} 指针为 NULL"),
        ));
    }
    CStr::from_ptr(input).to_str().map_err(|_| {
        TpError::new(
            error_code::INVALID_ARGUMENT,
            format!("{label} 不是合法 UTF-8"),
        )
    })
}

/// owner 原型版本，与历史 `tp_abi_version()==1` 并列，避免在 Step 0 阶段
/// 破坏现有 shadow bridge。
#[no_mangle]
pub extern "C" fn tp_core_abi_version() -> u32 {
    1
}

/// 创建 Rust Core owner。`home` 为测试可注入的用户 home；传 NULL 时使用
/// 当前进程的 HOME。创建会读取并校验 config.json，含 app 配置时 fail-closed。
#[no_mangle]
pub unsafe extern "C" fn tp_core_create(home: *const c_char) -> *mut TpCoreHandle {
    let home_path = if home.is_null() {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| TpError::new(error_code::INVALID_ARGUMENT, "HOME 未设置"))
    } else {
        read_utf8(home, "home").map(PathBuf::from)
    };
    let result = home_path.and_then(|path| {
        CoreOwner::new(TunnelPaths::new(path), LaunchCtlExecutor::default())
            .map(|owner| Box::new(TpCoreHandle { owner }))
    });
    match result {
        Ok(handle) => {
            clear_error();
            Box::into_raw(handle)
        }
        Err(error) => {
            set_error(&error);
            ptr::null_mut()
        }
    }
}

/// 执行一个 UTF-8 JSON owner 命令，成功与操作级失败都返回 JSON；仅传输
/// 层失败返回 NULL，随后可调用 `tp_core_last_error()`。
#[no_mangle]
pub unsafe extern "C" fn tp_core_command(
    handle: *mut TpCoreHandle,
    command: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        set_error(&TpError::new(
            error_code::INVALID_ARGUMENT,
            "owner handle 为 NULL",
        ));
        return ptr::null_mut();
    }
    let command = match read_utf8(command, "owner command") {
        Ok(command) => command,
        Err(error) => {
            set_error(&error);
            return ptr::null_mut();
        }
    };
    let owner = &(*handle).owner;
    finish(owner.execute_json(command))
}

/// 关闭 owner 并停止所有受管 launchd 隧道。调用方必须确保 handle 不再使用。
#[no_mangle]
pub unsafe extern "C" fn tp_core_shutdown(handle: *mut TpCoreHandle) -> *mut c_char {
    if handle.is_null() {
        set_error(&TpError::new(
            error_code::INVALID_ARGUMENT,
            "owner handle 为 NULL",
        ));
        return ptr::null_mut();
    }
    let response =
        serde_json::to_string(&(*handle).owner.execute(crate::owner::CoreCommand::Shutdown))
            .map_err(|error| TpError::new(error_code::INVALID_JSON, error.to_string()));
    finish(response)
}

/// 释放 owner；NULL 安全。释放后不得再次调用该 handle。
#[no_mangle]
pub unsafe extern "C" fn tp_core_destroy(handle: *mut TpCoreHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
        clear_error();
    }
}

/// owner 专用最近错误；返回字符串仍用 `tp_string_free` 释放。
#[no_mangle]
pub extern "C" fn tp_core_last_error() -> *mut c_char {
    OWNER_LAST_ERROR
        .with(|slot| slot.borrow_mut().take())
        .and_then(|value| CString::new(value).ok())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::fs;

    fn temp_home(label: &str) -> PathBuf {
        let home =
            std::env::temp_dir().join(format!("tp-owner-ffi-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&home).unwrap();
        home
    }

    unsafe fn take_string(raw: *mut c_char) -> String {
        assert!(!raw.is_null());
        let value = CStr::from_ptr(raw).to_string_lossy().into_owned();
        crate::ffi::tp_string_free(raw);
        value
    }

    unsafe fn take_error() -> Value {
        let raw = tp_core_last_error();
        let value = take_string(raw);
        serde_json::from_str(&value).unwrap()
    }

    #[test]
    fn core_ffi_roundtrip_and_shutdown_lifecycle() {
        let home = temp_home("roundtrip");
        let home_input = CString::new(home.to_str().unwrap()).unwrap();
        let handle = unsafe { tp_core_create(home_input.as_ptr()) };
        assert!(!handle.is_null());
        assert!(tp_core_last_error().is_null());

        let snapshot_input = CString::new(r#"{"op":"snapshot"}"#).unwrap();
        let snapshot = unsafe { take_string(tp_core_command(handle, snapshot_input.as_ptr())) };
        let snapshot: Value = serde_json::from_str(&snapshot).unwrap();
        assert_eq!(snapshot["ok"], true);
        assert_eq!(
            snapshot["result"]["config"]["tunnels"],
            Value::Array(vec![])
        );

        let shutdown = unsafe { take_string(tp_core_shutdown(handle)) };
        let shutdown: Value = serde_json::from_str(&shutdown).unwrap();
        assert_eq!(shutdown["ok"], true);
        assert_eq!(shutdown["result"]["operation"], "shutdown");

        unsafe {
            tp_core_destroy(handle);
            tp_core_destroy(ptr::null_mut());
        }
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn core_ffi_rejects_null_and_non_utf8_inputs() {
        let raw = unsafe { tp_core_command(ptr::null_mut(), ptr::null()) };
        assert!(raw.is_null());
        let error = unsafe { take_error() };
        assert_eq!(error["code"], error_code::INVALID_ARGUMENT);

        let invalid_home = unsafe { CStr::from_bytes_with_nul_unchecked(b"\xff\xfe\0") };
        let handle = unsafe { tp_core_create(invalid_home.as_ptr()) };
        assert!(handle.is_null());
        let error = unsafe { take_error() };
        assert_eq!(error["code"], error_code::INVALID_ARGUMENT);

        let raw = unsafe { tp_core_shutdown(ptr::null_mut()) };
        assert!(raw.is_null());
        let error = unsafe { take_error() };
        assert_eq!(error["code"], error_code::INVALID_ARGUMENT);
    }

    #[test]
    fn core_ffi_command_error_is_cleared_by_success() {
        let home = temp_home("command-error");
        let home_input = CString::new(home.to_str().unwrap()).unwrap();
        let handle = unsafe { tp_core_create(home_input.as_ptr()) };
        assert!(!handle.is_null());

        let invalid_command = CString::new("not-json").unwrap();
        let raw = unsafe { tp_core_command(handle, invalid_command.as_ptr()) };
        assert!(raw.is_null());
        let error = unsafe { take_error() };
        assert_eq!(error["code"], error_code::OWNER_COMMAND);

        let snapshot_input = CString::new(r#"{"op":"snapshot"}"#).unwrap();
        let raw = unsafe { tp_core_command(handle, snapshot_input.as_ptr()) };
        let snapshot = unsafe { take_string(raw) };
        assert!(snapshot.contains("\"ok\":true"));
        assert!(tp_core_last_error().is_null());

        unsafe { tp_core_destroy(handle) };
        let _ = fs::remove_dir_all(home);
    }
}
