//! [M3-05a] Self-update. The updater is OFF while `plugins.updater.pubkey` in
//! tauri.conf.json is still the placeholder (dev and unsigned CI builds).
//! Otherwise: check on launch and every 24 h; install only between requests
//! and only when "Automatic updates" is on; after an update relaunch, refresh
//! the worker files with the bundled `install.sh --from-app --update`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager, Runtime};

use crate::state::{self, Liveness, StatusFile};

pub const PUBKEY_PLACEHOLDER: &str = "REPLACE_WITH_MINISIGN_PUBKEY";
const SETTINGS_FILE: &str = "app-settings.json";
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
const WAIT_RECHECK: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Decision {
    Install,
    Wait,
    Off,
}

/// Pure decision: install now, wait for the running request(s), or never.
/// A stale/missing status file means no worker is running → nothing to wait for.
pub fn should_install(enabled: bool, auto: bool, status: Option<&StatusFile>, mtime: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Decision {
    if !enabled || !auto {
        return Decision::Off;
    }
    match status {
        Some(s) if state::liveness(status, mtime, now) == Liveness::Running && (!s.now.is_empty() || s.computer.running > 0) => Decision::Wait,
        _ => Decision::Install,
    }
}

/// The updater is enabled only when a real public key is configured.
pub fn pubkey_enabled(pubkey: Option<&str>) -> bool {
    matches!(pubkey.map(str::trim), Some(k) if !k.is_empty() && k != PUBKEY_PLACEHOLDER)
}

fn configured_pubkey<R: Runtime>(app: &AppHandle<R>) -> Option<String> {
    app.config().plugins.0.get("updater")?.get("pubkey")?.as_str().map(str::to_owned)
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSettings {
    pub auto_update: bool,
}

fn read_json(state: &Path) -> Value {
    std::fs::read_to_string(state.join(SETTINGS_FILE)).ok().and_then(|r| serde_json::from_str(&r).ok()).filter(Value::is_object).unwrap_or_else(|| Value::Object(Default::default()))
}

pub fn read_update_settings(state: &Path) -> UpdateSettings {
    UpdateSettings { auto_update: read_json(state).get("autoUpdate").and_then(Value::as_bool).unwrap_or(true) }
}

/// Merge `autoUpdate` into app-settings.json (other keys kept), mode 0600.
pub fn write_auto_update(state: &Path, on: bool) -> Result<(), String> {
    let mut v = read_json(state);
    v["autoUpdate"] = Value::Bool(on);
    crate::support::write_private(&state.join(SETTINGS_FILE), serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?.as_bytes())
}

fn state_dir() -> Result<PathBuf, String> {
    crate::control::state_dir().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_update_settings() -> Result<UpdateSettings, String> {
    Ok(read_update_settings(&state_dir()?))
}

#[tauri::command]
pub fn set_auto_update(enabled: bool) -> Result<(), String> {
    write_auto_update(&state_dir()?, enabled)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheck {
    pub enabled: bool,
    pub available: bool,
    pub version: Option<String>,
}

#[tauri::command]
pub async fn check_for_update(app: AppHandle) -> Result<UpdateCheck, String> {
    if !ENABLED.load(Ordering::Relaxed) {
        return Ok(UpdateCheck { enabled: false, available: false, version: None });
    }
    use tauri_plugin_updater::UpdaterExt;
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?;
    Ok(UpdateCheck { enabled: true, available: update.is_some(), version: update.map(|u| u.version) })
}

static ENABLED: AtomicBool = AtomicBool::new(false);

fn current_decision(auto: bool) -> Decision {
    let dir = state_dir().ok();
    let path = dir.as_ref().map(|d| d.join("status.json"));
    let status = path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|r| state::parse_status(&r).ok());
    let mtime = path.as_ref().and_then(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok()).map(DateTime::<Utc>::from);
    should_install(ENABLED.load(Ordering::Relaxed), auto, status.as_ref(), mtime, Utc::now())
}

/// One check: Ok(true) when an update is pending but must wait.
async fn check_once(app: &AppHandle) -> Result<bool, String> {
    use tauri_plugin_updater::UpdaterExt;
    let Some(update) = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())? else {
        return Ok(false);
    };
    let auto = state_dir().map(|d| read_update_settings(&d).auto_update).unwrap_or(true);
    match current_decision(auto) {
        Decision::Off => Ok(false),
        Decision::Wait => Ok(true),
        Decision::Install => {
            update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
            app.restart();
        }
    }
}

/// After an app update, refresh `~/CFW Render/app` from the bundled worker.
/// Runs once per app version; only when the worker is installed.
fn refresh_worker_after_update(app: &AppHandle) {
    let version = app.package_info().version.to_string();
    let Ok(dir) = state_dir() else { return };
    let synced = read_json(&dir).get("workerSyncedVersion").and_then(Value::as_str).map(str::to_owned);
    if synced.as_deref() == Some(version.as_str()) || !crate::setup::setup_status().installed {
        return;
    }
    let Ok(res) = app.path().resource_dir() else { return };
    let installer = res.join("worker/install/install.sh");
    if !installer.is_file() {
        return;
    }
    let ok = std::process::Command::new("/bin/bash")
        .arg(&installer)
        .args(["--mode", "byoa", "--non-interactive", "--from-app", "--update"])
        .stdin(std::process::Stdio::null())
        .output()
        .map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains("\"Updated\""))
        .unwrap_or(false);
    if ok {
        let mut v = read_json(&dir);
        v["workerSyncedVersion"] = Value::String(version);
        if let Ok(s) = serde_json::to_string_pretty(&v) {
            let _ = crate::support::write_private(&dir.join(SETTINGS_FILE), s.as_bytes());
        }
    } else {
        eprintln!("cfw-render: worker refresh after update failed");
    }
}

/// Called once from `setup()`: registers the updater + process plugins and,
/// when a real pubkey is configured, starts the check loop.
pub fn start(app: &AppHandle) {
    let _ = app.plugin(tauri_plugin_process::init());
    if !pubkey_enabled(configured_pubkey(app).as_deref()) {
        eprintln!("cfw-render: updater disabled (no signing key configured)");
        return;
    }
    if let Err(e) = app.plugin(tauri_plugin_updater::Builder::new().build()) {
        eprintln!("cfw-render: updater unavailable: {e}");
        return;
    }
    ENABLED.store(true, Ordering::Relaxed);
    let handle = app.clone();
    std::thread::spawn(move || {
        refresh_worker_after_update(&handle);
        loop {
            let waiting = tauri::async_runtime::block_on(check_once(&handle)).unwrap_or_else(|e| {
                eprintln!("cfw-render: update check failed: {e}");
                false
            });
            std::thread::sleep(if waiting { WAIT_RECHECK } else { CHECK_EVERY });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn status(running: u32, now_items: usize, at: DateTime<Utc>) -> StatusFile {
        let mut raw = serde_json::json!({"schema":1,"computer":{"running":running},"lastCheckAt":at,"now":[]});
        for _ in 0..now_items {
            raw["now"].as_array_mut().unwrap().push(serde_json::json!({"shortCode":"R-1"}));
        }
        state::parse_status(&raw.to_string()).unwrap()
    }

    #[test]
    fn should_install_table() {
        let now = Utc::now();
        let idle = status(0, 0, now);
        let busy = status(1, 1, now);
        let enabled = pubkey_enabled(Some(PUBKEY_PLACEHOLDER));
        assert!(!enabled && !pubkey_enabled(None) && !pubkey_enabled(Some("  ")) && pubkey_enabled(Some("dW50cnVzdGVk")));
        assert_eq!(should_install(enabled, true, Some(&idle), None, now), Decision::Off, "placeholder pubkey");
        assert_eq!(should_install(true, false, Some(&idle), None, now), Decision::Off, "auto off");
        assert_eq!(should_install(true, true, Some(&busy), None, now), Decision::Wait, "running request");
        assert_eq!(should_install(true, true, Some(&status(1, 0, now)), None, now), Decision::Wait, "running count");
        assert_eq!(should_install(true, true, Some(&status(0, 1, now)), None, now), Decision::Wait, "now item");
        assert_eq!(should_install(true, true, Some(&idle), None, now), Decision::Install, "idle");
        assert_eq!(should_install(true, true, None, None, now), Decision::Install, "no worker");
        let stale = status(1, 1, now - chrono::Duration::hours(1));
        assert_eq!(should_install(true, true, Some(&stale), None, now), Decision::Install, "dead worker");
    }

    #[test]
    fn settings_round_trip_0600_keeps_other_keys() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_update_settings(d.path()), UpdateSettings { auto_update: true });
        std::fs::write(d.path().join(SETTINGS_FILE), r#"{"shareCrashReports":false}"#).unwrap();
        write_auto_update(d.path(), false).unwrap();
        assert_eq!(read_update_settings(d.path()), UpdateSettings { auto_update: false });
        let mode = std::fs::metadata(d.path().join(SETTINGS_FILE)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(!crate::support::read_settings(d.path()).share_crash_reports);
        write_auto_update(d.path(), true).unwrap();
        assert!(read_update_settings(d.path()).auto_update);
        assert_eq!(serde_json::to_string(&UpdateSettings { auto_update: true }).unwrap(), r#"{"autoUpdate":true}"#);
    }
}
