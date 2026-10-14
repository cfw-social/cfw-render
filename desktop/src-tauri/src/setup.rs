//! First-run setup: optional toolchain install, then `install.sh --mode byoa --non-interactive --from-app`.
//! The brand key goes ONLY to the installer's stdin; it is never stored, logged, or emitted.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

use crate::{signin, toolchain};

pub const INSTALLER_ENV: &str = "CFW_RENDER_INSTALLER";
const ARGS: [&str; 5] = ["--mode", "byoa", "--non-interactive", "--from-app", ""];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetupEvent {
    pub step: String,
    pub state: String,
    #[serde(default)]
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pct: Option<u8>,
}

impl SetupEvent {
    fn new(step: &str, state: &str, message: impl Into<String>) -> Self {
        Self { step: step.into(), state: state.into(), message: message.into(), action: None, pct: None }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    pub installed: bool,
    pub adoptable: bool,
}

static CHILD: Mutex<Option<Child>> = Mutex::new(None);
static CANCELLED: AtomicBool = AtomicBool::new(false);

pub fn valid_key(k: &str) -> bool {
    let Some(rest) = k.strip_prefix("cfw_") else { return false };
    (8..=200).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

fn setup_marker() -> Option<PathBuf> {
    toolchain::render_home().ok().map(|h| h.join("app/.setup-complete"))
}

pub fn status_at(home: &Path, marker: Option<&Path>) -> SetupStatus {
    let env_has_key = std::fs::read_to_string(home.join(".cfw-render/cfw-render.env"))
        .map(|s| s.lines().any(|l| l.trim_start().starts_with("CFW_RENDER_WORKER_KEY=")))
        .unwrap_or(false);
    let plist = home.join("Library/LaunchAgents/com.cfw.render.plist").is_file();
    SetupStatus { installed: marker.is_some_and(|m| m.exists()), adoptable: env_has_key && plist }
}

pub fn setup_status() -> SetupStatus {
    match dirs::home_dir() {
        Some(h) => status_at(&h, setup_marker().as_deref()),
        None => SetupStatus { installed: false, adoptable: false },
    }
}

/// env override → bundled `<Resources>/worker/install/install.sh` → `~/CFW Render/app/install/install.sh`.
pub fn installer_path(resource_dir: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os(INSTALLER_ENV).filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let bundled = resource_dir.map(|r| r.join("worker/install/install.sh"));
    let home = toolchain::render_home().ok().map(|h| h.join("app/install/install.sh"));
    [bundled, home].into_iter().flatten().find(|p| p.is_file())
}

pub fn exit_message(code: Option<i32>, stderr_tail: &str) -> String {
    match code {
        Some(3) => "No AI engine is signed in. Sign in to ChatGPT or Claude and try again.".into(),
        Some(4) => "A tool CFW Render needs is missing. Install the tools and try again.".into(),
        Some(5) => "That brand key wasn't accepted. Copy it again from CFW and paste it here.".into(),
        Some(6) => "Couldn't reach CFW. Check your internet connection and try again.".into(),
        Some(7) => "The test render didn't finish. Try again.".into(),
        _ if stderr_tail.trim().is_empty() => "Setup didn't finish. Try again.".into(),
        _ => format!("Setup didn't finish: {}", stderr_tail.trim()),
    }
}

/// Run the installer; `key` (if any) is written to stdin then dropped. Emits each JSON line and a final `result`.
pub fn run_installer(installer: &Path, key: Option<String>, emit: &dyn Fn(SetupEvent)) -> Result<bool, String> {
    if !installer.is_file() {
        return Err("The CFW Render installer wasn't found. Reinstall the app and try again.".into());
    }
    let mut guard = CHILD.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return Err("Setup is already running.".into());
    }
    CANCELLED.store(false, Ordering::SeqCst);
    let mut cmd = signin::command(installer, &ARGS[..4], &signin::search_path());
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("Couldn't start the installer: {e}"))?;
    let mut stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    *guard = Some(child);
    drop(guard);

    if let (Some(mut si), Some(k)) = (stdin.take(), key) {
        let _ = si.write_all(k.as_bytes());
        let _ = si.write_all(b"\n");
        drop(k);
    } // stdin closed here (also when no key: empty stdin).
    drop(stdin);

    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = e.read_to_string(&mut s);
        }
        s.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").to_string()
    });
    let mut saw_ready = false;
    if let Some(out) = stdout {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(ev) = serde_json::from_str::<SetupEvent>(line.trim()) {
                saw_ready |= ev.step == "ready" && ev.state == "done";
                emit(ev);
            }
        }
    }
    let status = CHILD.lock().unwrap_or_else(|e| e.into_inner()).take().and_then(|mut c| c.wait().ok());
    let tail = err_thread.join().unwrap_or_default();
    if CANCELLED.swap(false, Ordering::SeqCst) {
        emit(SetupEvent::new("result", "failed", "Setup was cancelled."));
        return Ok(false);
    }
    let code = status.and_then(|s| s.code());
    if code == Some(0) {
        if !saw_ready {
            emit(SetupEvent::new("ready", "done", "Ready"));
        }
        emit(SetupEvent::new("result", "done", "Ready"));
        Ok(true)
    } else {
        emit(SetupEvent::new("result", "failed", exit_message(code, &tail)));
        Ok(false)
    }
}

/// Validate → optional tools → installer. The key lives only in this call's stack.
pub fn run_setup(installer: Option<PathBuf>, brand_key: String, install_tools: bool, emit: &dyn Fn(SetupEvent)) -> Result<bool, String> {
    if !valid_key(brand_key.trim()) {
        return Err("That doesn't look like a brand key. It starts with cfw_.".into());
    }
    let installer = installer.ok_or("The CFW Render installer wasn't found. Reinstall the app and try again.")?;
    if install_tools {
        install_tools_step(emit)?;
    }
    let key = brand_key.trim().to_string();
    drop(brand_key);
    run_installer(&installer, Some(key), emit)
}

fn install_tools_step(emit: &dyn Fn(SetupEvent)) -> Result<(), String> {
    let fail = |m: String| {
        emit(SetupEvent::new("tools", "failed", m.clone()));
        emit(SetupEvent::new("result", "failed", m.clone()));
        m
    };
    let m = toolchain::fetch_manifest().map_err(fail)?;
    if !toolchain::needed(&m) {
        emit(SetupEvent::new("tools", "done", "Tools are up to date"));
        return Ok(());
    }
    emit(SetupEvent::new("tools", "started", "Installing tools"));
    toolchain::install(&m, &|pct, msg| emit(SetupEvent { pct: Some(pct), ..SetupEvent::new("tools", "started", msg) }))
        .map_err(fail)?;
    emit(SetupEvent::new("tools", "done", "Tools installed"));
    Ok(())
}

pub fn cancel() -> bool {
    let mut g = CHILD.lock().unwrap_or_else(|e| e.into_inner());
    match g.as_mut() {
        Some(c) => {
            CANCELLED.store(true, Ordering::SeqCst);
            c.kill().is_ok()
        }
        None => false,
    }
}

fn mark_installed() {
    if let Some(m) = setup_marker() {
        if let Some(p) = m.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        let _ = std::fs::write(m, b"");
    }
}

fn finish(r: Result<bool, String>, emit: &dyn Fn(SetupEvent)) {
    match r {
        Ok(true) => mark_installed(),
        Ok(false) => {}
        Err(e) => emit(SetupEvent::new("result", "failed", e)),
    }
}

fn emitter(app: AppHandle) -> impl Fn(SetupEvent) {
    move |ev| {
        let _ = app.emit("setup-step", ev);
    }
}

#[tauri::command]
pub fn get_setup_status() -> SetupStatus {
    setup_status()
}

#[tauri::command]
pub fn setup_run(app: AppHandle, brand_key: String, install_tools: bool) -> Result<(), String> {
    if !valid_key(brand_key.trim()) {
        return Err("That doesn't look like a brand key. It starts with cfw_.".into());
    }
    let installer = installer_path(app.path().resource_dir().ok().as_deref());
    std::thread::spawn(move || {
        let emit = emitter(app);
        finish(run_setup(installer, brand_key, install_tools, &emit), &emit);
    });
    Ok(())
}

/// Final event for `setup_install_tools`.
pub fn tools_result_event(r: &Result<(), String>) -> SetupEvent {
    match r {
        Ok(()) => SetupEvent::new("tools_result", "done", "Tools installed"),
        Err(e) => SetupEvent::new("tools_result", "failed", e.clone()),
    }
}

/// Install only the private toolchain (codex/gemini CLIs) — usable before AI sign-in.
#[tauri::command]
pub fn setup_install_tools(app: AppHandle) {
    std::thread::spawn(move || {
        let emit = emitter(app);
        let r = install_tools_step(&emit);
        emit(tools_result_event(&r));
    });
}

#[tauri::command]
pub fn setup_adopt(app: AppHandle) -> Result<(), String> {
    let installer = installer_path(app.path().resource_dir().ok().as_deref())
        .ok_or("The CFW Render installer wasn't found. Reinstall the app and try again.")?;
    std::thread::spawn(move || {
        let emit = emitter(app);
        finish(run_installer(&installer, None, &emit), &emit);
    });
    Ok(())
}

#[tauri::command]
pub fn setup_cancel() -> bool {
    cancel()
}

/// Tools size for the consent line; `None` when the manifest isn't published.
#[tauri::command]
pub async fn setup_tools_size() -> Option<u64> {
    toolchain::fetch_manifest().ok().and_then(|m| m.archive().map(|a| a.size_bytes))
}

#[tauri::command]
pub fn open_setup(app: AppHandle) {
    if let Some(w) = app.get_webview_window("setup") {
        #[cfg(target_os = "macos")]
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    const KEY: &str = "cfw_SECRETkey_1234567890";
    static SERIAL: Mutex<()> = Mutex::new(());

    fn stub(dir: &Path, body: &str) -> PathBuf {
        let p = dir.join("install.sh");
        let rec = dir.display();
        std::fs::write(
            &p,
            format!("#!/bin/sh\necho \"$@\" > '{rec}/argv'\n/usr/bin/env > '{rec}/env'\n/bin/cat > '{rec}/stdin'\necho 'human log' >&2\n{body}\n"),
        )
        .unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn collect() -> (Arc<Mutex<Vec<SetupEvent>>>, impl Fn(SetupEvent)) {
        let v = Arc::new(Mutex::new(Vec::new()));
        let v2 = v.clone();
        (v, move |e| v2.lock().unwrap().push(e))
    }

    #[test]
    fn key_format() {
        assert!(valid_key("cfw_abcdefgh"));
        assert!(!valid_key("cfw_short"));
        assert!(!valid_key("cfw_abc def gh"));
        assert!(!valid_key("xyz_abcdefgh"));
    }

    #[test]
    fn happy_path_key_only_on_stdin() {
        let _s = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let p = stub(
            d.path(),
            r#"for s in checking installing connecting test_render; do echo "{\"step\":\"$s\",\"state\":\"started\",\"message\":\"$s\"}"; echo "{\"step\":\"$s\",\"state\":\"done\",\"message\":\"ok\"}"; done
echo 'not json'
echo '{"step":"ready","state":"done","message":"Ready"}'
exit 0"#,
        );
        let (evs, emit) = collect();
        assert!(run_setup(Some(p), KEY.into(), false, &emit).unwrap());
        let evs = evs.lock().unwrap().clone();
        let steps: Vec<String> = evs.iter().map(|e| format!("{}:{}", e.step, e.state)).collect();
        assert_eq!(steps.first().unwrap(), "checking:started");
        assert_eq!(&steps[steps.len() - 2..], ["ready:done", "result:done"]);
        assert_eq!(steps.len(), 10, "{steps:?}");
        let all = serde_json::to_string(&evs).unwrap();
        assert!(!all.contains(KEY) && !all.contains("human log"));
        let argv = std::fs::read_to_string(d.path().join("argv")).unwrap();
        assert_eq!(argv.trim(), "--mode byoa --non-interactive --from-app");
        assert!(!std::fs::read_to_string(d.path().join("env")).unwrap().contains(KEY));
        assert_eq!(std::fs::read_to_string(d.path().join("stdin")).unwrap(), format!("{KEY}\n"));
    }

    #[test]
    fn exit_5_maps_to_bad_key() {
        let _s = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let p = stub(d.path(), r#"echo '{"step":"connecting","state":"failed","message":"Key rejected"}'; exit 5"#);
        let (evs, emit) = collect();
        run_setup(Some(p), KEY.into(), false, &emit).unwrap();
        let last = evs.lock().unwrap().last().unwrap().clone();
        assert_eq!(last.state, "failed");
        assert!(last.message.contains("brand key wasn't accepted"));
    }

    #[test]
    fn adopt_uses_empty_stdin() {
        let _s = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let p = stub(d.path(), r#"echo '{"step":"ready","state":"done","message":"Already set up"}'; exit 0"#);
        let (evs, emit) = collect();
        run_installer(&p, None, &emit).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join("stdin")).unwrap(), "");
        let evs = evs.lock().unwrap();
        assert_eq!(evs[0].message, "Already set up");
        assert_eq!(evs.last().unwrap().step, "result");
    }

    #[test]
    fn bad_key_rejected_before_spawn() {
        let d = tempfile::tempdir().unwrap();
        let p = stub(d.path(), "exit 0");
        let (evs, emit) = collect();
        assert!(run_setup(Some(p), "nope".into(), false, &emit).is_err());
        assert!(!d.path().join("argv").exists());
        assert!(evs.lock().unwrap().is_empty());
    }

    #[test]
    fn cancel_kills_child() {
        let _s = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let p = stub(d.path(), "exec /bin/sleep 30");
        let (evs, emit) = collect();
        let h = std::thread::spawn(move || run_installer(&p, None, &emit));
        let start = std::time::Instant::now();
        while !cancel() {
            assert!(start.elapsed().as_secs() < 5);
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        h.join().unwrap().unwrap();
        assert!(start.elapsed().as_secs() < 10);
        assert_eq!(evs.lock().unwrap().last().unwrap().message, "Setup was cancelled.");
    }

    #[test]
    fn status_adoptable_needs_key_and_plist() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(status_at(d.path(), None), SetupStatus { installed: false, adoptable: false });
        std::fs::create_dir_all(d.path().join(".cfw-render")).unwrap();
        std::fs::write(d.path().join(".cfw-render/cfw-render.env"), "CFW_RENDER_WORKER_KEY=x\n").unwrap();
        std::fs::create_dir_all(d.path().join("Library/LaunchAgents")).unwrap();
        std::fs::write(d.path().join("Library/LaunchAgents/com.cfw.render.plist"), "").unwrap();
        let s = status_at(d.path(), None);
        assert!(s.adoptable && !s.installed);
        assert!(!serde_json::to_string(&s).unwrap().contains("=x"));
    }

    #[test]
    fn tools_result_event_maps_outcome() {
        let ok = serde_json::to_value(tools_result_event(&Ok(()))).unwrap();
        assert_eq!(ok, serde_json::json!({"step":"tools_result","state":"done","message":"Tools installed"}));
        let bad = tools_result_event(&Err("disk full".into()));
        assert_eq!((bad.step.as_str(), bad.state.as_str(), bad.message.as_str()), ("tools_result", "failed", "disk full"));
    }
}
