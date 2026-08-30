//! C ABI 面（阶段 1 冻结，ABI 版本 1）。
//!
//! # 所有权与生命周期规则（冻结）
//!
//! 1. 所有 `tp_*` 返回的 `char *` 由 Rust 侧分配（`CString::into_raw`），
//!    调用方必须用 [`tp_string_free`] 释放；禁止对返回指针使用 `free()`。
//! 2. 调用方传入的 `const char *` 必须是 NUL 结尾的合法 UTF-8；Rust 只在
//!    调用期间借用，不保留、不释放调用方内存。
//! 3. 返回 `NULL` 表示调用失败；此时 [`tp_last_error`] 返回最近一次错误的
//!    JSON（`{"code":N,"message":"..."}`，code 见 `error_code`）。错误状态
//!    随下一次 `tp_*` 调用更新：成功即清除。
//! 4. Rust 侧不持有任何跨调用状态（除 last-error 槽位），不启动线程；
//!    并发与取消语义由 Swift 侧拥有（见计划「阶段 1 契约冻结」）。

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::{error_code, TpError, ABI_VERSION};

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_last_error(error: &TpError) {
    let json = serde_json::to_string(error).unwrap_or_else(|_| {
        format!("{{\"code\":{},\"message\":\"error serialization failed\"}}", error.code)
    });
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(json));
}

fn clear_last_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn take_last_error() -> Option<CString> {
    LAST_ERROR.with(|slot| slot.borrow_mut().take())
        .and_then(|json| CString::new(json).ok())
}

/// 把 `Result` 转成 C ABI 返回值：成功返回堆上 C 字符串，失败返回 NULL 并记录 last-error。
fn finish(result: Result<String, TpError>) -> *mut c_char {
    match result {
        Ok(json) => match CString::new(json) {
            Ok(c) => {
                clear_last_error();
                c.into_raw()
            }
            Err(_) => {
                set_last_error(&TpError::new(error_code::INVALID_JSON, "输出包含 NUL 字节"));
                ptr::null_mut()
            }
        },
        Err(error) => {
            set_last_error(&error);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `input` 必须是 NUL 结尾的合法 UTF-8 指针，或 NULL。
unsafe fn read_input<'a>(input: *const c_char, label: &str) -> Result<&'a str, TpError> {
    if input.is_null() {
        return Err(TpError::new(error_code::INVALID_ARGUMENT, format!("{label} 输入指针为 NULL")));
    }
    CStr::from_ptr(input)
        .to_str()
        .map_err(|_| TpError::new(error_code::INVALID_ARGUMENT, format!("{label} 输入不是合法 UTF-8")))
}

/// 返回 C ABI 契约版本（当前 1）。
#[no_mangle]
pub extern "C" fn tp_abi_version() -> u32 {
    ABI_VERSION
}

/// 解析 config.json；成功返回规范化 JSON（键序与 Swift `JSONEncoder` 一致），
/// 失败返回 NULL 并记录 last-error。拒绝语义见 `parse_app_config`。
///
/// # Safety
/// `input` 必须是 NUL 结尾的合法 UTF-8 指针，或 NULL。
#[no_mangle]
pub unsafe extern "C" fn tp_config_parse(input: *const c_char) -> *mut c_char {
    let outcome = read_input(input, "config").and_then(crate::parse_app_config);
    finish(outcome)
}

/// 编码 `TunnelStatus`：
/// case 0 = running（`has_pid != 0` 时携带 pid，否则 `"pid":null`）、
/// 1 = notRunning、2 = notLoaded、3 = other（state 必填）。
///
/// # Safety
/// `state` 必须是 NUL 结尾的合法 UTF-8 指针或 NULL（仅 case 3 需要）。
#[no_mangle]
pub unsafe extern "C" fn tp_status_encode(
    status_case: u32,
    has_pid: i32,
    pid: i32,
    state: *const c_char,
) -> *mut c_char {
    let outcome = (|| {
        let state_str = if status_case == 3 {
            Some(read_input(state, "state")?)
        } else {
            None
        };
        crate::status_to_json(status_case, has_pid != 0, pid, state_str)
    })();
    finish(outcome)
}

/// 编码 `ProbeResult`：kind 0 = satisfied、1 = unexpected（携带 status）、
/// 2 = failed（reason 必填）。
///
/// # Safety
/// `reason` 必须是 NUL 结尾的合法 UTF-8 指针或 NULL（仅 kind 2 需要）。
#[no_mangle]
pub unsafe extern "C" fn tp_probe_result_encode(
    kind: u32,
    status: i32,
    reason: *const c_char,
) -> *mut c_char {
    let outcome = (|| {
        let reason_str = if kind == 2 {
            Some(read_input(reason, "reason")?)
        } else {
            None
        };
        crate::probe_result_to_json(kind, status, reason_str)
    })();
    finish(outcome)
}

/// 返回最近一次失败的错误 JSON；无失败记录或上次调用成功时返回 NULL。
/// 返回值遵循所有权规则 1（用 [`tp_string_free`] 释放）。
#[no_mangle]
pub extern "C" fn tp_last_error() -> *mut c_char {
    match take_last_error() {
        Some(c) => c.into_raw(),
        None => {
            // 无错误时保持 last-error 槽位为空，不视为新调用结果。
            ptr::null_mut()
        }
    }
}

/// 释放 `tp_*` 返回的字符串。NULL 是合法输入（no-op）。
///
/// # Safety
/// `s` 必须来自本 crate 的 `tp_*` 返回值，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn tp_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error_code;

    #[test]
    fn abi_version_is_frozen() {
        assert_eq!(tp_abi_version(), 1);
    }

    #[test]
    fn config_parse_roundtrip_via_ffi() {
        let input = CString::new(r#"{"version":1,"tunnels":[{"id":"web","name":"web","command":["/usr/bin/ssh","-N"]}]}"#).unwrap();
        let raw = unsafe { tp_config_parse(input.as_ptr()) };
        assert!(!raw.is_null());
        let out = unsafe { CStr::from_ptr(raw) }.to_string_lossy().to_string();
        unsafe { tp_string_free(raw) };
        assert!(out.contains("\"keepAlive\":true"));
        assert!(out.contains("\"throttleInterval\":10"));
        // 释放后的指针不得再读（所有权规则 1）；这里只验证 free(NULL) 安全。
        unsafe { tp_string_free(ptr::null_mut()) };
    }

    #[test]
    fn config_parse_failure_records_last_error() {
        let bad = CString::new(r#"{"version":2,"tunnels":[]}"#).unwrap();
        let raw = unsafe { tp_config_parse(bad.as_ptr()) };
        assert!(raw.is_null());

        let err_raw = tp_last_error();
        assert!(!err_raw.is_null());
        let err = unsafe { CStr::from_ptr(err_raw) }.to_string_lossy().to_string();
        unsafe { tp_string_free(err_raw) };
        assert!(err.contains("\"code\":2"));

        // 错误被取走后再次查询为空（take 语义）。
        assert!(tp_last_error().is_null());
    }

    #[test]
    fn null_and_non_utf8_inputs_rejected() {
        let raw = unsafe { tp_config_parse(ptr::null()) };
        assert!(raw.is_null());
        assert_eq!(last_error_code(), error_code::INVALID_ARGUMENT);

        let invalid = unsafe { CStr::from_bytes_with_nul_unchecked(b"\xff\xfe\x00") };
        let raw = unsafe { tp_config_parse(invalid.as_ptr()) };
        assert!(raw.is_null());
        assert_eq!(last_error_code(), error_code::INVALID_ARGUMENT);
    }

    #[test]
    fn status_and_probe_encode_via_ffi() {
        let state = CString::new("weird").unwrap();
        let raw = unsafe { tp_status_encode(0, 1, 1234, ptr::null()) };
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_bytes(), br#"{"case":"running","pid":1234}"#);
        unsafe { tp_string_free(raw) };

        let raw = unsafe { tp_status_encode(3, 0, 0, state.as_ptr()) };
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_bytes(), br#"{"case":"other","state":"weird"}"#);
        unsafe { tp_string_free(raw) };

        let raw = unsafe { tp_status_encode(3, 0, 0, ptr::null()) };
        assert!(raw.is_null());
        assert_eq!(last_error_code(), error_code::INVALID_ARGUMENT);

        let raw = unsafe { tp_probe_result_encode(2, 0, state.as_ptr()) };
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_bytes(), br#"{"case":"failed","reason":"weird"}"#);
        unsafe { tp_string_free(raw) };
    }

    /// 便捷读取 last-error code 的测试辅助。
    fn last_error_code() -> u32 {
        let raw = tp_last_error();
        if raw.is_null() {
            return 0;
        }
        let json = unsafe { CStr::from_ptr(raw) }.to_string_lossy().to_string();
        unsafe { tp_string_free(raw) };
        serde_json::from_str::<serde_json::Value>(&json)
            .ok()
            .and_then(|v| v["code"].as_u64())
            .map(|c| c as u32)
            .unwrap_or(0)
    }
}
