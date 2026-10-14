//! Brand keys in the login Keychain (service `com.cfw.render`, account `brand:<slug>`).
//! The key never goes on argv: writes go through `security -i` on stdin.

use std::io::Write;
use std::process::{Command, Stdio};

pub const SERVICE: &str = "com.cfw.render";
pub const SECURITY_ENV: &str = "CFW_RENDER_SECURITY_CMD";

fn security() -> Command {
    let exe = std::env::var_os(SECURITY_ENV).filter(|v| !v.is_empty()).unwrap_or_else(|| "/usr/bin/security".into());
    let mut c = Command::new(exe);
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c
}

/// `cfw_` + 8..200 of `[A-Za-z0-9_]` — also guarantees no whitespace/newline can inject a command.
pub fn valid_key(key: &str) -> bool {
    let Some(rest) = key.strip_prefix("cfw_") else { return false };
    (8..=200).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

fn account(slug: &str) -> String {
    format!("brand:{slug}")
}

pub fn put(slug: &str, key: &str) -> Result<(), String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    if !valid_key(key) {
        return Err("That doesn't look like a CFW brand key.".into());
    }
    let mut child = security().arg("-i").stdin(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    {
        let mut stdin = child.stdin.take().ok_or("no stdin")?;
        let line = format!("add-generic-password -U -s {SERVICE} -a {} -w {key}\n", account(slug));
        stdin.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    }
    let st = child.wait().map_err(|e| e.to_string())?;
    if st.success() { Ok(()) } else { Err("Couldn't save the key to the Keychain.".into()) }
}

pub fn get(slug: &str) -> Result<String, String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let out = security()
        .args(["find-generic-password", "-s", SERVICE, "-a", &account(slug), "-w"])
        .stdout(Stdio::piped())
        .output()
        .map_err(|e| e.to_string())?;
    let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() && valid_key(&key) { Ok(key) } else { Err("No key saved for this brand.".into()) }
}

pub fn delete(slug: &str) -> Result<(), String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let _ = security().args(["delete-generic-password", "-s", SERVICE, "-a", &account(slug)]).status();
    Ok(())
}
