//! API keys for key-based AI providers (M3-08). Stored in the login Keychain (service `com.cfw.render`,
//! account `<engine>`). The key goes to `security -i` on stdin only — never argv, logs, events or return values.
//!
//! Claude Code's long-lived sign-in token lives in the same Keychain, under the account `claude-code`. It is
//! not an API-key engine: the key form (the Tauri commands below) never writes it, and the `*_with` functions
//! accept it only so `signin` can save, check and delete it. The `security` executable is always passed in
//! (`sec`), so tests hand in a stub instead of setting process-wide environment variables.

use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::chat::keychain::{SECURITY_ENV, SERVICE};
use crate::signin::CLAUDE_CODE;

/// Engine → where to get a key. Mirrors `desktop/src/providers/registry.ts`.
pub const KEY_ENGINES: &[(&str, &str)] = &[
    ("gemini", "https://aistudio.google.com/apikey"),
    ("zai", "https://z.ai/manage-apikey/apikey-list"),
    ("moonshot", "https://platform.moonshot.ai/console/api-keys"),
    ("minimax", "https://www.minimax.io/platform/user-center/basic-information/interface-key"),
    ("xai", "https://console.x.ai"),
    ("openrouter", "https://openrouter.ai/keys"),
];

pub const LIMITS_FILE: &str = "engine-limits.json";

pub fn key_url(engine: &str) -> Result<&'static str, String> {
    KEY_ENGINES.iter().find(|(e, _)| *e == engine).map(|(_, u)| *u).ok_or_else(|| format!("unknown provider: {engine}"))
}

/// `^[A-Za-z0-9._\-]{16,300}$` — also rules out whitespace/newlines that could inject a `security -i` command.
pub fn valid_key(key: &str) -> bool {
    (16..=300).contains(&key.len()) && key.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Engines whose secret is kept in the Keychain: the API-key engines, plus Claude Code's sign-in token.
fn stored_engine(engine: &str) -> Result<(), String> {
    if engine == CLAUDE_CODE {
        return Ok(());
    }
    key_url(engine).map(|_| ())
}

/// The `security` executable: `CFW_RENDER_SECURITY_CMD` when set, else the system one.
pub(crate) fn security_exe() -> OsString {
    std::env::var_os(SECURITY_ENV).filter(|v| !v.is_empty()).unwrap_or_else(|| "/usr/bin/security".into())
}

fn security(exe: &OsStr) -> Command {
    let mut c = Command::new(exe);
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c
}

pub fn save(engine: &str, key: &str) -> Result<(), String> {
    key_url(engine)?;
    save_with(&security_exe(), engine, key)
}

/// `engine` may also be Claude Code (its sign-in token); the checked `[A-Za-z0-9._-]{16,300}` shape still applies.
pub(crate) fn save_with(sec: &OsStr, engine: &str, key: &str) -> Result<(), String> {
    stored_engine(engine)?;
    if !valid_key(key) {
        return Err("That doesn't look like an API key.".into());
    }
    let mut child = security(sec).arg("-i").stdin(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    {
        let mut stdin = child.stdin.take().ok_or("no stdin")?;
        let line = format!("add-generic-password -U -s {SERVICE} -a {engine} -w {key}\n");
        stdin.write_all(line.as_bytes()).map_err(|_| "Couldn't save the key to the Keychain.".to_string())?;
    }
    let st = child.wait().map_err(|e| e.to_string())?;
    if st.success() { Ok(()) } else { Err("Couldn't save the key to the Keychain.".into()) }
}

pub fn remove(engine: &str) -> Result<(), String> {
    key_url(engine)?;
    remove_with(&security_exe(), engine)
}

pub(crate) fn remove_with(sec: &OsStr, engine: &str) -> Result<(), String> {
    stored_engine(engine)?;
    let _ = security(sec).args(["delete-generic-password", "-s", SERVICE, "-a", engine]).status();
    Ok(())
}

/// Exit code only; no `-w`, so the secret is never read.
pub fn present(engine: &str) -> Result<bool, String> {
    key_url(engine)?;
    present_with(&security_exe(), engine)
}

pub(crate) fn present_with(sec: &OsStr, engine: &str) -> Result<bool, String> {
    stored_engine(engine)?;
    Ok(security(sec).args(["find-generic-password", "-s", SERVICE, "-a", engine]).status().is_ok_and(|s| s.success()))
}

/// Drop `engine` from `engine-limits.json` (top-level key and/or under `engines`). Atomic, 0600.
pub fn clear_limit_in(dir: &Path, engine: &str) -> Result<(), String> {
    if !KEY_ENGINES.iter().any(|(e, _)| *e == engine) && !["codex", "claude-code"].contains(&engine) {
        return Err(format!("unknown provider: {engine}"));
    }
    let path = dir.join(LIMITS_FILE);
    let Ok(raw) = std::fs::read(&path) else { return Ok(()) };
    let mut v: serde_json::Value = serde_json::from_slice(&raw).map_err(|e| e.to_string())?;
    let mut changed = false;
    if let Some(o) = v.as_object_mut() {
        changed |= o.remove(engine).is_some();
        if let Some(e) = o.get_mut("engines").and_then(|e| e.as_object_mut()) {
            changed |= e.remove(engine).is_some();
        }
    }
    if !changed {
        return Ok(());
    }
    let out = serde_json::to_vec_pretty(&v).map_err(|e| e.to_string())?;
    crate::control::write_atomic(dir, LIMITS_FILE, &out).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn provider_key_save(engine: String, key: String) -> Result<(), String> {
    save(&engine, &key)
}

#[tauri::command]
pub async fn provider_key_remove(engine: String) -> Result<(), String> {
    remove(&engine)
}

#[tauri::command]
pub async fn provider_key_present(engine: String) -> Result<bool, String> {
    present(&engine)
}

#[tauri::command]
pub fn provider_clear_limit(engine: String) -> Result<(), String> {
    clear_limit_in(&crate::control::state_dir().map_err(|e| e.to_string())?, &engine)
}

/// Opens ONLY the registry's key URL for `engine` (https).
#[tauri::command]
pub fn open_provider_key_url(engine: String) -> Result<(), String> {
    let url = key_url(&engine)?;
    if !url.starts_with("https://") {
        return Err("refusing non-https url".into());
    }
    Command::new("/usr/bin/open").arg(url).status().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    
    const KEY: &str = "sk-or-v1.ABCdef_0123456789-xyz";

    /// Stub `security`: records argv + stdin to files; keeps a fake store keyed by account.
    fn stub() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().display();
        let s = format!(
            r#"#!/bin/sh
echo "$@" >> '{p}/argv'
case "$1" in
-i) cat >> '{p}/stdin'; acct=$(tail -n1 '{p}/stdin' | sed 's/.* -a \([^ ]*\) .*/\1/'); touch "{p}/store-$acct";;
find-generic-password) [ -f "{p}/store-$5" ];;
delete-generic-password) rm -f "{p}/store-$5";;
esac
"#
        );
        let f = d.path().join("security");
        std::fs::write(&f, s).unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o755)).unwrap();
        d
    }

    fn sec(d: &tempfile::TempDir) -> OsString {
        d.path().join("security").into()
    }

    #[test]
    fn save_present_remove_round_trip() {
        let d = stub();
        assert_eq!(present_with(&sec(&d), "openrouter"), Ok(false));
        save_with(&sec(&d), "openrouter", KEY).unwrap();
        assert_eq!(present_with(&sec(&d), "openrouter"), Ok(true));
        assert_eq!(present_with(&sec(&d), "xai"), Ok(false));
        remove_with(&sec(&d), "openrouter").unwrap();
        assert_eq!(present_with(&sec(&d), "openrouter"), Ok(false));
        let argv = std::fs::read_to_string(d.path().join("argv")).unwrap();
        assert!(!argv.contains(KEY), "key leaked to argv");
        assert!(argv.lines().all(|l| !l.contains("-w")));
        let stdin = std::fs::read_to_string(d.path().join("stdin")).unwrap();
        assert!(stdin.contains("-s com.cfw.render -a openrouter -w"));
    }

    #[test]
    fn rejects_before_spawn() {
        let d = stub();
        assert!(save_with(&sec(&d), "codex", KEY).is_err());
        assert!(save_with(&sec(&d), "../x", KEY).is_err());
        for bad in ["short", "has space in it 12345", "newline\nadd-generic-password-xx", &"a".repeat(301)] {
            assert!(save_with(&sec(&d), "xai", bad).is_err(), "{bad:?}");
        }
        assert!(remove_with(&sec(&d), "rm").is_err());
        assert!(present_with(&sec(&d), "nope").is_err());
        assert!(open_provider_key_url("evil".into()).is_err());
        assert!(!d.path().join("argv").exists(), "spawned despite rejection");
    }

    #[test]
    fn claude_token_is_stored_like_a_key_but_never_through_the_key_form() {
        let d = stub();
        const TOKEN: &str = "sk-ant-oat01-TESTTOKEN0123456789abcdefXYZ_-";
        assert_eq!(present_with(&sec(&d), "claude-code"), Ok(false));
        save_with(&sec(&d), "claude-code", TOKEN).unwrap();
        assert_eq!(present_with(&sec(&d), "claude-code"), Ok(true));
        assert_eq!(present_with(&sec(&d), "openrouter"), Ok(false));
        remove_with(&sec(&d), "claude-code").unwrap();
        assert_eq!(present_with(&sec(&d), "claude-code"), Ok(false));
        let argv = std::fs::read_to_string(d.path().join("argv")).unwrap();
        assert!(!argv.contains(TOKEN), "token leaked to argv");
        let stdin = std::fs::read_to_string(d.path().join("stdin")).unwrap();
        assert!(stdin.contains("-s com.cfw.render -a claude-code -w"));
        // The key form's public entry points check `key_url` first (before any `security` call), and that
        // refuses Claude and Codex. The shape rule still applies to the token.
        assert!(key_url("claude-code").is_err());
        assert!(key_url("codex").is_err());
        assert!(save_with(&sec(&d), "claude-code", "short").is_err());
        assert!(save_with(&sec(&d), "claude-code", "sk-ant-oat01-has space in it 12345").is_err());
    }

    #[test]
    fn clear_limit_removes_only_that_engine() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join(LIMITS_FILE);
        std::fs::write(&p, r#"{"xai":{"limit":"limited","reason":"credit"},"codex":{"limit":"limited"}}"#).unwrap();
        clear_limit_in(d.path(), "xai").unwrap();
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
        assert!(v.get("xai").is_none());
        assert!(v.get("codex").is_some());
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(clear_limit_in(d.path(), "../etc").is_err());
        assert!(clear_limit_in(tempfile::tempdir().unwrap().path(), "xai").is_ok());
    }
}
