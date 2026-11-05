//! Keys in the login Keychain.
//! Brand keys use account `brand:<slug>`. Production service is `com.cfw.render`;
//! local dev keeps its own brand keys under `com.cfw.render.dev` (see `profile`).
//! The render worker key uses service `com.cfw.render` and account `render-worker`.
//! The key never goes on argv: writes go through `security -i` on stdin.

use std::io::Write;
use std::process::{Command, Stdio};

/// AI provider keys (`apikeys`) stay here in every profile: the worker reads them from this service.
pub const SERVICE: &str = "com.cfw.render";
pub const WORKER_ACCOUNT: &str = "render-worker";
pub const SECURITY_ENV: &str = "CFW_RENDER_SECURITY_CMD";

fn service() -> &'static str {
    crate::profile::active().brand_key_service()
}

fn security() -> Command {
    let exe = std::env::var_os(SECURITY_ENV).filter(|v| !v.is_empty()).unwrap_or_else(|| "/usr/bin/security".into());
    let mut c = Command::new(exe);
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c
}

/// `cfw_` + 8..200 of `[A-Za-z0-9_-]` (CFW keys are base64url, so `-` occurs) —
/// still no whitespace/newline, so nothing can inject a `security -i` command.
pub fn valid_key(key: &str) -> bool {
    let Some(rest) = key.strip_prefix("cfw_") else { return false };
    (8..=200).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Computer-scoped render worker key from browser-approval connect.
pub fn valid_render_key(key: &str) -> bool {
    let Some(rest) = key.strip_prefix("cfw_render_") else { return false };
    (8..=200).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn account(slug: &str) -> String {
    format!("brand:{slug}")
}

fn put_account(svc: &str, account: &str, key: &str) -> Result<(), String> {
    let mut child = security().arg("-i").stdin(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    {
        let mut stdin = child.stdin.take().ok_or("no stdin")?;
        let line = format!("add-generic-password -U -s {svc} -a {account} -w {key}\n");
        stdin.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    }
    let st = child.wait().map_err(|e| e.to_string())?;
    if st.success() { Ok(()) } else { Err("Couldn't save the key to the Keychain.".into()) }
}

fn get_account(svc: &str, account: &str) -> Result<String, String> {
    let out = security()
        .args(["find-generic-password", "-s", svc, "-a", account, "-w"])
        .stdout(Stdio::piped())
        .output()
        .map_err(|e| e.to_string())?;
    let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() { Ok(key) } else { Err("No key saved.".into()) }
}

pub fn put(slug: &str, key: &str) -> Result<(), String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    if !valid_key(key) {
        return Err("That doesn't look like a CFW brand key.".into());
    }
    // Brand keys follow the active profile. The worker key stays on `SERVICE`.
    put_account(service(), &account(slug), key)
}

pub fn get(slug: &str) -> Result<String, String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let key = get_account(service(), &account(slug)).map_err(|_| "No key saved for this brand.".to_string())?;
    if valid_key(&key) { Ok(key) } else { Err("No key saved for this brand.".into()) }
}

pub fn delete(slug: &str) -> Result<(), String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let _ = security().args(["delete-generic-password", "-s", service(), "-a", &account(slug)]).status();
    Ok(())
}

/// Store the computer-scoped `cfw_render_` key from browser-approval connect.
pub fn put_worker(key: &str) -> Result<(), String> {
    if !valid_render_key(key) {
        return Err("That doesn't look like a CFW Render key.".into());
    }
    put_account(SERVICE, WORKER_ACCOUNT, key)
}

/// Read the computer-scoped render worker key (account `render-worker`).
pub fn get_worker() -> Result<String, String> {
    let key = get_account(SERVICE, WORKER_ACCOUNT).map_err(|_| "No render key saved.".to_string())?;
    if valid_render_key(&key) { Ok(key) } else { Err("No render key saved.".into()) }
}

pub fn delete_worker() -> Result<(), String> {
    let _ = security().args(["delete-generic-password", "-s", SERVICE, "-a", WORKER_ACCOUNT]).status();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{valid_key, valid_render_key, WORKER_ACCOUNT};

    #[test]
    fn brand_key_shape() {
        assert!(valid_key("cfw_abcdefgh"));
        // CFW keys are base64url: '-' must be accepted.
        assert!(valid_key("cfw_Ab3-xY_9kLmN-pQrS"));
        assert!(!valid_key("cfw_short"));
        // nothing that could break out of a `security -i` line
        assert!(!valid_key("cfw_abc def gh"));
        assert!(!valid_key("cfw_abcdefgh\nadd-generic-password"));
        assert!(!valid_key("xyz_abcdefgh"));
    }

    #[test]
    fn render_worker_account_and_key_shape() {
        assert_eq!(WORKER_ACCOUNT, "render-worker");
        assert!(valid_render_key("cfw_render_abcdefgh"));
        assert!(valid_render_key("cfw_render_Ab3-xY_9kLmN-pQrS"));
        assert!(!valid_render_key("cfw_abcdefgh"));
        assert!(!valid_render_key("cfw_render_short"));
        assert!(!valid_render_key("cfw_render_abc def"));
        assert!(!valid_render_key("cfw_render_abcdefgh\nadd-generic-password"));
    }
}
