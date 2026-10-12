//! Control files the app writes into the state dir. Pure std — no tauri imports.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const STATE_DIR_ENV: &str = "CFW_RENDER_STATE_DIR";

#[derive(Debug, thiserror::Error)]
pub enum ControlError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("could not locate the home directory")]
    NoHome,
    #[error("invalid engine name: {0:?}")]
    BadEngineName(String),
}

pub fn state_dir() -> Result<PathBuf, ControlError> {
    if let Some(d) = std::env::var_os(STATE_DIR_ENV).filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(d));
    }
    dirs::home_dir().map(|h| h.join(".cfw-render")).ok_or(ControlError::NoHome)
}

/// Atomic write: temp file in the same dir (mode 0600) then rename.
fn write_atomic(dir: &Path, name: &str, contents: &[u8]) -> Result<(), ControlError> {
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{name}.tmp-{}", std::process::id()));
    let result = (|| {
        let mut f = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
        f.write_all(contents)?;
        f.sync_all()?;
        fs::rename(&tmp, dir.join(name))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    Ok(result?)
}

fn remove_if_exists(path: PathBuf) -> Result<(), ControlError> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

fn set_flag(name: &str, on: bool) -> Result<(), ControlError> {
    let dir = state_dir()?;
    if on {
        write_atomic(&dir, name, b"")
    } else {
        remove_if_exists(dir.join(name))
    }
}

pub fn set_paused(paused: bool) -> Result<(), ControlError> {
    set_flag("paused", paused)
}

pub fn set_allow_battery(allow: bool) -> Result<(), ControlError> {
    set_flag("allow-battery", allow)
}

pub fn run_now() -> Result<(), ControlError> {
    set_flag("run-now", true)
}

fn valid_engine_name(n: &str) -> bool {
    (1..=40).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Writes `engines.json` = `{"order": [...]}` — provider order only, never keys.
pub fn write_engine_order(order: &[String]) -> Result<(), ControlError> {
    if let Some(bad) = order.iter().find(|n| !valid_engine_name(n)) {
        return Err(ControlError::BadEngineName(bad.clone()));
    }
    let body = serde_json::to_vec(&serde_json::json!({ "order": order })).expect("serialising strings");
    write_atomic(&state_dir()?, "engines.json", &body)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    pub(crate) static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_dir() -> (MutexGuard<'static, ()>, tempfile::TempDir) {
        let g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        std::env::set_var(STATE_DIR_ENV, d.path());
        (g, d)
    }

    fn mode(p: &Path) -> u32 {
        fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn state_dir_honours_env() {
        let (_g, d) = with_dir();
        assert_eq!(state_dir().unwrap(), d.path());
    }

    #[test]
    fn flags_toggle_with_0600() {
        let (_g, d) = with_dir();
        for (name, set) in [("paused", set_paused as fn(bool) -> _), ("allow-battery", set_allow_battery)] {
            let p = d.path().join(name);
            set(true).unwrap();
            assert!(p.exists());
            assert_eq!(fs::read(&p).unwrap(), b"");
            assert_eq!(mode(&p), 0o600);
            set(false).unwrap();
            assert!(!p.exists());
            set(false).unwrap(); // idempotent
        }
        run_now().unwrap();
        assert_eq!(mode(&d.path().join("run-now")), 0o600);
    }

    #[test]
    fn engine_order_exact_content() {
        let (_g, d) = with_dir();
        write_engine_order(&["claude-code".into(), "codex".into()]).unwrap();
        let p = d.path().join("engines.json");
        assert_eq!(fs::read_to_string(&p).unwrap(), r#"{"order":["claude-code","codex"]}"#);
        assert_eq!(mode(&p), 0o600);
        // no stray temp files
        assert_eq!(fs::read_dir(d.path()).unwrap().count(), 1);
    }

    #[test]
    fn engine_order_rejects_bad_names() {
        let (_g, d) = with_dir();
        for bad in ["", "Codex", "sk-ant-abc/def", "a b", &"x".repeat(41)] {
            assert!(matches!(write_engine_order(&[bad.to_string()]), Err(ControlError::BadEngineName(_))));
        }
        assert!(!d.path().join("engines.json").exists());
    }
}
