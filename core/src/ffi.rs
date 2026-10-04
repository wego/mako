//! C ABI for the Swift shell. Config text is passed on every call and
//! re-parsed; it is a few lines, so this costs microseconds.
//! Returned strings are owned by the caller and must go back via `mako_free`.

use crate::{blocked, parse_config, resolve, Config};
use std::ffi::{c_char, CStr, CString};

unsafe fn text<'a>(p: *const c_char) -> &'a str {
    if p.is_null() { "" } else { CStr::from_ptr(p).to_str().unwrap_or("") }
}

fn out(s: Option<String>) -> *mut c_char {
    s.and_then(|s| CString::new(s).ok()).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn config(p: *const c_char) -> Config {
    parse_config(unsafe { text(p) }).unwrap_or_default()
}

/// Parse error for the config text, or NULL if valid.
#[no_mangle]
pub extern "C" fn mako_config_error(config: *const c_char) -> *mut c_char {
    out(parse_config(unsafe { text(config) }).err())
}

#[no_mangle]
pub extern "C" fn mako_restore_session(cfg: *const c_char) -> bool {
    config(cfg).restore_session
}

#[no_mangle]
pub extern "C" fn mako_max_tabs(cfg: *const c_char) -> u32 {
    config(cfg).max_tabs as u32
}

/// URL for omnibox input, or NULL for empty input.
#[no_mangle]
pub extern "C" fn mako_resolve(cfg: *const c_char, input: *const c_char) -> *mut c_char {
    out(resolve(&config(cfg), unsafe { text(input) }))
}

/// Block reason for `host`, or NULL if allowed. weekday 0 = Monday.
#[no_mangle]
pub extern "C" fn mako_blocked(cfg: *const c_char, host: *const c_char, weekday: u8, minute: u16) -> *mut c_char {
    out(blocked(&config(cfg), unsafe { text(host) }, weekday, minute))
}

#[no_mangle]
pub extern "C" fn mako_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
