//! [M3-06a] Support: uninstall, send logs, crash reports. Logic is plain std +
//! regex so it unit-tests without Tauri; the `#[tauri::command]` wrappers sit at
//! the bottom. Keys are never put on any argv: curl reads headers from a 0600
//! file that is removed right after.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::control;

const MAX_FRAMES: usize = 200;
const MAX_FRAME_LEN: usize = 300;

// ── redaction (parity with bin/cfw-render-redact.py) ──────────────────────

fn rules() -> &'static [(Regex, &'static str)] {
    static R: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    R.get_or_init(|| {
        [
            (r"cfw_render_[A-Za-z0-9_]+", "cfw_render_[redacted]"),
            (r"cfw_[A-Za-z0-9_]{8,}", "cfw_[redacted]"),
            (r"sk-ant-[A-Za-z0-9_-]{16,}", "sk-ant-[redacted]"),
            (r"sk-[A-Za-z0-9_-]{16,}", "sk-[redacted]"),
            (r"AIza[0-9A-Za-z_-]{30,}", "AIza[redacted]"),
            (r"xai-[A-Za-z0-9]{20,}", "xai-[redacted]"),
            (r"Bearer [A-Za-z0-9._-]{16,}", "Bearer [redacted]"),
            (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[email]"),
            (r#"([?&](?:token|key|sig|signature|auth|code|password)=)[^&\s#"']*"#, "${1}[redacted]"),
            (r"/Users/[^/\s]+/", "/Users/[user]/"),
        ]
        .into_iter()
        .map(|(p, r)| (Regex::new(p).expect("valid redaction regex"), r))
        .collect()
    })
}

/// Same rules, same order as `bin/cfw-render-redact.py`.
pub fn redact(text: &str) -> String {
    rules().iter().fold(text.to_string(), |acc, (rx, rep)| rx.replace_all(&acc, *rep).into_owned())
}

// ── paths / settings ──────────────────────────────────────────────────────

fn home() -> Result<PathBuf, String> {
    dirs::home_dir().ok_or_else(|| "could not locate the home directory".into())
}

/// env `CFW_RENDER_INSTALLER` → `~/CFW Render/app/install/install.sh`.
pub fn installer_path() -> Result<PathBuf, String> {
    if let Some(p) = std::env::var_os("CFW_RENDER_INSTALLER").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(p));
    }
    Ok(home()?.join("CFW Render/app/install/install.sh"))
}

/// env `CFW_RENDER_CTL` → `~/CFW Render/app/bin/cfw-render-ctl.sh`.
pub fn ctl_path() -> Result<PathBuf, String> {
    if let Some(p) = std::env::var_os("CFW_RENDER_CTL").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(p));
    }
    Ok(home()?.join("CFW Render/app/bin/cfw-render-ctl.sh"))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SupportSettings {
    pub share_crash_reports: bool,
}

impl Default for SupportSettings {
    fn default() -> Self {
        SupportSettings { share_crash_reports: true }
    }
}

pub fn read_settings(state: &Path) -> SupportSettings {
    fs::read_to_string(state.join("app-settings.json"))
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("shareCrashReports").and_then(Value::as_bool))
        .map(|b| SupportSettings { share_crash_reports: b })
        .unwrap_or_default()
}

pub fn write_settings(state: &Path, s: &SupportSettings) -> Result<(), String> {
    let path = state.join("app-settings.json");
    let mut v: Value = fs::read_to_string(&path).ok().and_then(|r| serde_json::from_str(&r).ok()).unwrap_or(Value::Object(Default::default()));
    if !v.is_object() {
        v = Value::Object(Default::default());
    }
    v["shareCrashReports"] = Value::Bool(s.share_crash_reports);
    write_private(&path, serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?.as_bytes())
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(d) = path.parent() {
        fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let mut f = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path).map_err(|e| e.to_string())?;
    f.write_all(bytes).map_err(|e| e.to_string())
}

/// Last `KEY=value` in an env file, quotes stripped.
fn env_value(file: &Path, key: &str) -> Option<String> {
    let raw = fs::read_to_string(file).ok()?;
    raw.lines()
        .filter_map(|l| l.trim_start().strip_prefix(key)?.strip_prefix('=').map(|v| v.trim().trim_matches('"').to_string()))
        .last()
        .filter(|v| !v.is_empty())
}

// ── crash reports ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CrashReport {
    pub app_version: String,
    pub macos_version: String,
    pub exception_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub frames: Vec<String>,
}

fn is_app_frame(f: &str) -> bool {
    f.contains("cfw_render_app") || f.contains("CFW Render")
}

/// `redact`, but the app's own crate names (`cfw_render_app`, `cfw_render_app_lib`)
/// survive: they match the render-key shape, yet they are what makes a frame useful.
fn redact_crash(text: &str) -> String {
    // Whole words only, so a key that merely starts `cfw_render_app…` is still redacted.
    static CRATE: OnceLock<Regex> = OnceLock::new();
    let rx = CRATE.get_or_init(|| Regex::new(r"\bcfw_render_app(_lib)?\b").expect("crate regex"));
    redact(&rx.replace_all(text, "\u{1}CRA${1}\u{1}")).replace("\u{1}CRA_lib\u{1}", "cfw_render_app_lib").replace("\u{1}CRA\u{1}", "cfw_render_app")
}

fn finish(app: String, os: String, exc: String, msg: Option<String>, frames: Vec<String>) -> CrashReport {
    let frames = frames
        .into_iter()
        .filter(|f| is_app_frame(f))
        .take(MAX_FRAMES)
        .map(|f| redact_crash(&f).chars().take(MAX_FRAME_LEN).collect())
        .collect();
    CrashReport {
        app_version: redact_crash(&app),
        macos_version: redact_crash(&os),
        exception_type: redact_crash(&exc),
        message: msg.map(|m| redact_crash(&m).chars().take(2000).collect()),
        frames,
    }
}

/// `.ips` (JSON header line + JSON body) or legacy text `.crash`.
pub fn reduce_crash(raw: &str) -> Option<CrashReport> {
    let (head, body) = raw.split_once('\n').unwrap_or((raw, ""));
    if let (Ok(h), Ok(b)) = (serde_json::from_str::<Value>(head), serde_json::from_str::<Value>(body)) {
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let app = s(&h, "app_version");
        let os = b.pointer("/osVersion/train").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| s(&h, "os_version"));
        let exc = b.get("exception").map(|e| {
            let t = s(e, "type");
            let sig = s(e, "signal");
            if sig.is_empty() { t } else { format!("{t} ({sig})") }
        }).unwrap_or_default();
        let msg = b.pointer("/exception/subtype").and_then(Value::as_str)
            .or_else(|| b.pointer("/termination/indicator").and_then(Value::as_str))
            .map(str::to_string);
        let images: Vec<String> = b.get("usedImages").and_then(Value::as_array).map(|a| a.iter().map(|i| s(i, "name")).collect()).unwrap_or_default();
        let mut frames = Vec::new();
        for t in b.get("threads").and_then(Value::as_array).into_iter().flatten() {
            for f in t.get("frames").and_then(Value::as_array).into_iter().flatten() {
                let img = f.get("imageIndex").and_then(Value::as_u64).and_then(|i| images.get(i as usize)).cloned().unwrap_or_default();
                let sym = s(f, "symbol");
                let off = f.get("imageOffset").and_then(Value::as_u64).unwrap_or(0);
                frames.push(format!("{img} {sym} +{off}").trim().to_string());
            }
        }
        return Some(finish(app, os, exc, msg, frames));
    }
    // Legacy text format.
    let field = |k: &str| raw.lines().find_map(|l| l.strip_prefix(k).map(|v| v.trim().to_string()));
    let exc = field("Exception Type:")?;
    let frame_rx = Regex::new(r"^\d+\s+\S").expect("frame regex");
    let frames = raw.lines().filter(|l| frame_rx.is_match(l)).map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).collect();
    Some(finish(field("Version:").unwrap_or_default(), field("OS Version:").unwrap_or_default(), exc, field("Termination Reason:"), frames))
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn mtime_secs(p: &Path) -> u64 {
    fs::metadata(p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0)
}

/// Crash files named `CFW Render*.ips|.crash` in `reports` modified after the
/// scan time stored in `<state>/crash-scan.json`; the scan time is then moved
/// to `now`. Returns the reduced reports (the caller decides whether to post).
pub fn scan_new_crashes(reports: &Path, state: &Path, now: u64) -> Vec<CrashReport> {
    let scan_file = state.join("crash-scan.json");
    let last = fs::read_to_string(&scan_file).ok()
        .and_then(|r| serde_json::from_str::<Value>(&r).ok())
        .and_then(|v| v.get("lastScan").and_then(Value::as_u64));
    let mut found: Vec<(u64, PathBuf)> = fs::read_dir(reports).into_iter().flatten().flatten()
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            name.starts_with("CFW Render") && (name.ends_with(".ips") || name.ends_with(".crash"))
        })
        .map(|p| (mtime_secs(&p), p))
        // First ever scan: only look back a day so old crashes aren't flooded in.
        .filter(|(m, _)| *m > last.unwrap_or_else(|| now.saturating_sub(86_400)))
        .collect();
    found.sort();
    let _ = write_private(&scan_file, serde_json::json!({ "lastScan": now }).to_string().as_bytes());
    found.iter().filter_map(|(_, p)| fs::read_to_string(p).ok()).filter_map(|r| reduce_crash(&r)).collect()
}

fn api_base(env_file: &Path) -> String {
    std::env::var("CFW_RENDER_API_BASE").ok().filter(|b| !b.is_empty())
        .or_else(|| env_value(env_file, "CFW_API_BASE"))
        .unwrap_or_else(|| "https://app.cfw.social".into())
}

fn curl_cmd() -> String {
    std::env::var("CFW_RENDER_CURL").ok().filter(|c| !c.is_empty()).unwrap_or_else(|| "/usr/bin/curl".into())
}

/// POST one crash report. The key goes in a 0600 header file (`-H @file`) and
/// the body in a temp file; both are removed when this returns.
pub fn post_crash(state: &Path, report: &CrashReport, occurred_at: Option<&str>) -> Result<(), String> {
    let env_file = state.join("cfw-render.env");
    let key = env_value(&env_file, "CFW_RENDER_WORKER_KEY").ok_or("this computer has no render key")?;
    let dir = tempfile_dir()?;
    let hdr = dir.join("h");
    write_private(&hdr, format!("cfw-render-key: {key}\ncontent-type: application/json\n").as_bytes())?;
    let mut body = serde_json::to_value(report).map_err(|e| e.to_string())?;
    if let Some(at) = occurred_at {
        body["occurredAt"] = Value::String(at.into());
    }
    let body_file = dir.join("b");
    write_private(&body_file, body.to_string().as_bytes())?;
    let url = format!("{}/api/v1/computers/crash", api_base(&env_file).trim_end_matches('/'));
    let out = Command::new(curl_cmd())
        .args(["-sS", "--max-time", "30", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", &url])
        .arg("-H").arg(format!("@{}", hdr.display()))
        .arg("--data-binary").arg(format!("@{}", body_file.display()))
        .output();
    let _ = fs::remove_dir_all(&dir);
    let out = out.map_err(|e| e.to_string())?;
    let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() && code.starts_with('2') { Ok(()) } else { Err(format!("crash upload failed (HTTP {code})")) }
}

fn tempfile_dir() -> Result<PathBuf, String> {
    let d = std::env::temp_dir().join(format!("cfw-render-crash-{}-{}", std::process::id(), now_secs()));
    fs::create_dir_all(&d).map_err(|e| e.to_string())?;
    fs::set_permissions(&d, std::os::unix::fs::PermissionsExt::from_mode(0o700)).map_err(|e| e.to_string())?;
    Ok(d)
}

/// Scan + (if sharing is on) post. Returns how many reports were posted.
pub fn crash_scan_in(reports: &Path, state: &Path, now: u64) -> usize {
    let found = scan_new_crashes(reports, state, now);
    if !read_settings(state).share_crash_reports {
        return 0;
    }
    found.iter().filter(|r| post_crash(state, r, None).is_ok()).count()
}

// ── worker ctl / installer ────────────────────────────────────────────────

fn run_ctl(args: &[&str]) -> Result<String, String> {
    let out = Command::new(ctl_path()?).args(args).stdin(Stdio::null()).output().map_err(|e| format!("could not run CFW Render: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(err.trim().trim_start_matches("cfw-render-ctl: ").to_string())
    }
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LogsPreview {
    pub size_bytes: u64,
    pub path: String,
}

pub fn parse_preview(stdout: &str) -> Option<LogsPreview> {
    let get = |k: &str| stdout.lines().find_map(|l| l.strip_prefix(k).map(|v| v.trim().to_string()));
    Some(LogsPreview { size_bytes: get("size:")?.parse().ok()?, path: get("path:")? })
}

pub fn parse_reference(stdout: &str) -> Option<String> {
    stdout.lines().find_map(|l| l.strip_prefix("Reference: ")).and_then(|r| r.split_whitespace().next()).map(str::to_string)
}

/// `/Applications/CFW Render.app` when `exe` lives inside a `.app` bundle.
pub fn app_bundle_of(exe: &Path) -> Option<PathBuf> {
    exe.ancestors().find(|a| a.extension().and_then(|e| e.to_str()) == Some("app")).map(Path::to_path_buf)
}

// ── Tauri commands ────────────────────────────────────────────────────────

fn state() -> Result<PathBuf, String> {
    control::state_dir().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_support_settings() -> Result<SupportSettings, String> {
    Ok(read_settings(&state()?))
}

#[tauri::command]
pub fn set_share_crash_reports(enabled: bool) -> Result<(), String> {
    write_settings(&state()?, &SupportSettings { share_crash_reports: enabled })
}

#[tauri::command]
pub async fn crash_scan() -> Result<usize, String> {
    let reports = home()?.join("Library/Logs/DiagnosticReports");
    let st = state()?;
    tauri::async_runtime::spawn_blocking(move || crash_scan_in(&reports, &st, now_secs())).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn send_logs_preview() -> Result<LogsPreview, String> {
    let out = tauri::async_runtime::spawn_blocking(|| run_ctl(&["send-logs", "--dry"])).await.map_err(|e| e.to_string())??;
    parse_preview(&out).ok_or_else(|| "CFW Render could not gather the logs".into())
}

#[derive(Debug, Serialize)]
pub struct LogsSent {
    pub reference: String,
}

#[tauri::command]
pub async fn send_logs() -> Result<LogsSent, String> {
    let out = tauri::async_runtime::spawn_blocking(|| run_ctl(&["send-logs", "--yes"])).await.map_err(|e| e.to_string())??;
    parse_reference(&out).map(|reference| LogsSent { reference }).ok_or_else(|| "CFW did not send a reference".into())
}

#[tauri::command]
pub async fn uninstall(app: tauri::AppHandle, delete_outputs: bool) -> Result<(), String> {
    use tauri::Emitter;
    let installer = installer_path()?;
    let emitter = app.clone();
    tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
        let mut cmd = Command::new(&installer);
        cmd.args(["--uninstall", "--non-interactive", "--from-app"]);
        if delete_outputs {
            cmd.arg("--delete-outputs");
        }
        let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| format!("could not start the uninstaller: {e}"))?;
        if let Some(out) = child.stdout.take() {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    let _ = emitter.emit("uninstall-step", v);
                }
            }
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!("the uninstaller stopped (exit {})", status.code().unwrap_or(-1)));
        }
        if let Some(bundle) = std::env::current_exe().ok().as_deref().and_then(app_bundle_of) {
            let script = format!("tell application \"Finder\" to delete POSIX file \"{}\"", bundle.display().to_string().replace('\\', "\\\\").replace('"', "\\\""));
            let _ = Command::new("/usr/bin/osascript").args(["-e", &script]).output();
        }
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())??;
    app.exit(0);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn fixture(name: &str) -> String {
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
    }

    #[test]
    fn redaction_parity_with_python_fixture() {
        assert_eq!(redact(&fixture("redact-input.txt")), fixture("redact-expected.txt"));
    }

    #[test]
    fn reduces_ips_keeping_only_app_frames() {
        let r = reduce_crash(&fixture("crash-sample.ips")).unwrap();
        assert_eq!(r.app_version, "0.1.0");
        assert_eq!(r.macos_version, "macOS 15.3.1");
        assert_eq!(r.exception_type, "EXC_BAD_ACCESS (SIGSEGV)");
        assert_eq!(r.message.as_deref(), Some("KERN_INVALID_ADDRESS at 0x0000000000000010"));
        assert_eq!(r.frames.len(), 2);
        assert!(r.frames.iter().all(|f| f.contains("cfw_render_app")));
        assert!(r.frames.iter().all(|f| !f.contains("libsystem") && !f.contains("vasanth")));
        assert!(r.frames[0].contains("/Users/[user]/") || !r.frames[0].contains("/Users/"));
    }

    #[test]
    fn reduces_legacy_crash_text() {
        let raw = "Version: 0.1.0 (1)\nOS Version: macOS 14.5\nException Type: EXC_CRASH (SIGABRT)\n\n0   libsystem_kernel.dylib 0x1 __pthread_kill + 8\n1   cfw_render_app 0x2 cfw_render_app::run + 12\n";
        let r = reduce_crash(raw).unwrap();
        assert_eq!(r.exception_type, "EXC_CRASH (SIGABRT)");
        assert_eq!(r.frames, vec!["1 cfw_render_app 0x2 cfw_render_app::run + 12".to_string()]);
        assert_eq!(redact_crash("cfw_render_app_lib::x cfw_render_appSECRET9"), "cfw_render_app_lib::x cfw_render_[redacted]");
    }

    fn put(dir: &Path, name: &str, body: &str, mtime: u64) {
        let p = dir.join(name);
        fs::write(&p, body).unwrap();
        let t = UNIX_EPOCH + std::time::Duration::from_secs(mtime);
        fs::File::options().write(true).open(&p).unwrap().set_modified(t).unwrap();
    }

    #[test]
    fn scans_only_files_newer_than_last_scan() {
        let reports = tempfile::tempdir().unwrap();
        let st = tempfile::tempdir().unwrap();
        let ips = fixture("crash-sample.ips");
        put(reports.path(), "CFW Render-2026-10-01-old.ips", &ips, 1_000);
        put(reports.path(), "CFW Render-2026-10-12-new.ips", &ips, 3_000);
        put(reports.path(), "Safari-2026-10-12.ips", &ips, 3_000);
        fs::write(st.path().join("crash-scan.json"), r#"{"lastScan":2000}"#).unwrap();
        assert_eq!(scan_new_crashes(reports.path(), st.path(), 4_000).len(), 1);
        // the scan time moved forward: nothing is found again
        assert_eq!(scan_new_crashes(reports.path(), st.path(), 5_000).len(), 0);
    }

    fn stub_curl(dir: &Path) -> PathBuf {
        let log = dir.join("curl.log");
        let stub = dir.join("curl");
        fs::write(&stub, format!("#!/bin/bash\necho \"$@\" >> '{}'\nfor a in \"$@\"; do [[ $a == @* ]] && cat \"${{a#@}}\" >> '{}'; done\nprintf 200\n", log.display(), dir.join("bodies.log").display())).unwrap();
        fs::set_permissions(&stub, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        stub
    }

    #[test]
    fn share_off_posts_nothing_share_on_posts_without_key_on_argv() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let reports = tempfile::tempdir().unwrap();
        let st = tempfile::tempdir().unwrap();
        let tools = tempfile::tempdir().unwrap();
        std::env::set_var("CFW_RENDER_CURL", stub_curl(tools.path()));
        std::env::set_var("CFW_RENDER_API_BASE", "http://127.0.0.1:9");
        fs::write(st.path().join("cfw-render.env"), "CFW_RENDER_WORKER_KEY=cfw_render_supersecret1\n").unwrap();
        put(reports.path(), "CFW Render-a.ips", &fixture("crash-sample.ips"), now_secs() - 10);

        write_settings(st.path(), &SupportSettings { share_crash_reports: false }).unwrap();
        assert!(!read_settings(st.path()).share_crash_reports);
        assert_eq!(crash_scan_in(reports.path(), st.path(), now_secs()), 0);
        assert!(!tools.path().join("curl.log").exists());

        write_settings(st.path(), &SupportSettings { share_crash_reports: true }).unwrap();
        fs::remove_file(st.path().join("crash-scan.json")).unwrap();
        assert_eq!(crash_scan_in(reports.path(), st.path(), now_secs()), 1);
        let argv = fs::read_to_string(tools.path().join("curl.log")).unwrap();
        assert!(argv.contains("/api/v1/computers/crash") && !argv.contains("supersecret"));
        let bodies = fs::read_to_string(tools.path().join("bodies.log")).unwrap();
        assert!(bodies.contains("cfw-render-key: cfw_render_supersecret1"));
        assert!(bodies.contains("\"exceptionType\":\"EXC_BAD_ACCESS (SIGSEGV)\""));
        std::env::remove_var("CFW_RENDER_CURL");
        std::env::remove_var("CFW_RENDER_API_BASE");
    }

    #[test]
    fn settings_default_on() {
        let st = tempfile::tempdir().unwrap();
        assert!(read_settings(st.path()).share_crash_reports);
    }

    #[test]
    fn parses_ctl_output_and_bundle_path() {
        assert_eq!(parse_preview("size: 812\npath: /tmp/x.tar.gz\n"), Some(LogsPreview { size_bytes: 812, path: "/tmp/x.tar.gz".into() }));
        assert_eq!(parse_reference("Log bundle: 1 bytes\nReference: LOG-AB12 — quote it to CFW support.\n").as_deref(), Some("LOG-AB12"));
        assert_eq!(app_bundle_of(Path::new("/Applications/CFW Render.app/Contents/MacOS/cfw_render_app")), Some(PathBuf::from("/Applications/CFW Render.app")));
        assert_eq!(app_bundle_of(Path::new("/Users/x/target/debug/cfw_render_app")), None);
    }
}
