//! C ABI for the Swift shell. Config text is passed on every call and
//! re-parsed; it is a few lines, so this costs microseconds.
//! Returned strings are owned by the caller and must go back via `mako_free`.

use crate::{blocked, parse_config, resolve, set_setting, trails, Config};
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
pub extern "C" fn mako_max_trails(cfg: *const c_char) -> u32 {
    config(cfg).max_trails as u32
}

/// The highest max_trails the config accepts.
#[no_mangle]
pub extern "C" fn mako_trail_limit() -> u32 {
    trails::MAX_TRAILS as u32
}

/// Config text with `key = value` set; the shell writes it back to the file.
#[no_mangle]
pub extern "C" fn mako_set_setting(cfg: *const c_char, key: *const c_char, value: *const c_char) -> *mut c_char {
    out(Some(unsafe { set_setting(text(cfg), text(key), text(value)) }))
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

/// What the shell gets back from every trails call: the new state to keep and save,
/// the sidebar rows and every page id (collapsed ones included), or an error (the shell then keeps the state it had).
fn trails_reply(result: Result<trails::Trails, trails::Error>) -> *mut c_char {
    let json = match result {
        Ok(state) => serde_json::json!({
            "rows": trails::rows(&state),
            "pages": state.nodes.keys().collect::<Vec<_>>(),
            "state": state,
        }),
        Err(e) => serde_json::json!({ "error": e.to_string() }),
    };
    out(Some(json.to_string()))
}

/// Validates saved trails JSON (empty or NULL = a fresh, empty state).
#[no_mangle]
pub extern "C" fn mako_trails_load(state: *const c_char) -> *mut c_char {
    let text = unsafe { text(state) };
    trails_reply(if text.is_empty() { Ok(trails::Trails::default()) } else { trails::load(text) })
}

/// Applies one action (JSON, see trails::Action) to a state. Pure: same inputs, same reply.
#[no_mangle]
pub extern "C" fn mako_trails_apply(cfg: *const c_char, state: *const c_char, action: *const c_char) -> *mut c_char {
    let result = trails::load(unsafe { text(state) }).and_then(|s| {
        let action = serde_json::from_str(unsafe { text(action) }).map_err(|e| trails::Error::Invalid(format!("action: {e}")))?;
        trails::apply(&s, &action, config(cfg).max_trails)
    });
    trails_reply(result)
}

#[no_mangle]
pub extern "C" fn mako_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(f: impl FnOnce() -> *mut c_char) -> serde_json::Value {
        let p = f();
        let v = serde_json::from_str(unsafe { text(p) }).unwrap();
        mako_free(p);
        v
    }
    fn c(s: &str) -> CString { CString::new(s).unwrap() }

    fn config_error(config: &str) -> Option<String> {
        let config = c(config);
        let p = mako_config_error(config.as_ptr());
        let error = (!p.is_null()).then(|| unsafe { text(p) }.to_string());
        mako_free(p);
        error
    }

    #[test]
    fn config_error_names_the_first_issue_and_counts_the_rest() {
        assert_eq!(config_error("max_trails = 2\nblock x.com\n"), None);
        assert_eq!(config_error("max_trails = 2\ncolour = red\n").unwrap(), "config line 2: unknown setting: `colour = red`");
        assert_eq!(
            config_error("max_trails = 2\ncolour = red\nblok a.com\nblock b.com 09:00-25:00\n").unwrap(),
            "config line 2: unknown setting: `colour = red` (and 2 more)"
        );
    }

    #[test]
    fn a_bad_line_does_not_unblock_through_the_c_abi() {
        let (config, host) = (c("colour = red\nblock x.com 09:00-25:00\nmax_trails = 2\n"), c("x.com"));
        let reason = mako_blocked(config.as_ptr(), host.as_ptr(), 6, 3 * 60);
        assert_eq!(unsafe { text(reason) }, "x.com is blocked.");
        mako_free(reason);
        assert_eq!(mako_max_trails(config.as_ptr()), 2);
    }

    #[test]
    fn trails_round_trip_through_the_c_abi() {
        let fresh = call(|| mako_trails_load(std::ptr::null()));
        assert_eq!(fresh["rows"].as_array().unwrap().len(), 0);
        let cfg = c("max_trails = 1");
        let apply = |state: &serde_json::Value, action: &str| {
            let (s, a) = (c(&state.to_string()), c(action));
            call(|| mako_trails_apply(cfg.as_ptr(), s.as_ptr(), a.as_ptr()))
        };
        let one = apply(&fresh["state"], r#"{"type":"open_trail","url":"https://a.test/"}"#);
        let two = apply(&one["state"], r#"{"type":"open_child","parent":1,"url":"https://b.test/"}"#);
        assert_eq!(two["rows"][1]["depth"], 1);
        assert_eq!(two["rows"][1]["active"], true);
        assert_eq!(apply(&two["state"], r#"{"type":"open_trail","url":"x"}"#)["error"], "trail cap reached (1)");
        let closed = apply(&two["state"], r#"{"type":"close","id":2}"#);
        let back = apply(&closed["state"], r#"{"type":"undo_close"}"#);
        assert_eq!(back["state"], two["state"]);
        assert!(apply(&two["state"], "{}")["error"].as_str().unwrap().starts_with("invalid trails state: action"));
        let garbage = c("{");
        assert!(call(|| mako_trails_load(garbage.as_ptr()))["error"].is_string());
    }
}
