//! Toolchain install (M3-07 contract): download → verify archive sha → unpack next to the
//! destination → verify SHA256SUMS → rename into `tools/<version>` → atomically repoint `current`.
//! Only system tools by absolute path: /usr/bin/curl, /usr/bin/shasum, /usr/bin/tar.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::{Deserialize, Serialize};

pub const HOME_ENV: &str = "CFW_RENDER_HOME";
pub const MANIFEST_URL_ENV: &str = "CFW_RENDER_TOOLCHAIN_MANIFEST_URL";
pub const MANIFEST_URL: &str = "https://app.cfw.social/api/v1/desktop/toolchain/manifest.json";
const CURL: &str = "/usr/bin/curl";
const SHASUM: &str = "/usr/bin/shasum";
const TAR: &str = "/usr/bin/tar";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Archive {
    pub url: String,
    pub sha256: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: String,
    #[serde(default)]
    pub min_app_version: Option<String>,
    pub archives: std::collections::HashMap<String, Archive>,
    #[serde(default)]
    pub published_at: Option<String>,
}

impl Manifest {
    pub fn archive(&self) -> Option<&Archive> {
        self.archives.get(arch())
    }
}

pub fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        other => other,
    }
}

/// `~/CFW Render` (or `$CFW_RENDER_HOME`).
pub fn render_home() -> Result<PathBuf, String> {
    if let Some(h) = std::env::var_os(HOME_ENV).filter(|h| !h.is_empty()) {
        return Ok(PathBuf::from(h));
    }
    dirs::home_dir().map(|h| h.join("CFW Render")).ok_or_else(|| "No home folder".into())
}

pub fn tools_dir() -> Result<PathBuf, String> {
    Ok(render_home()?.join("app/tools"))
}

/// Non-https schemes are allowed only when the URL came from the env override (tests).
fn manifest_url() -> (String, bool) {
    match std::env::var(MANIFEST_URL_ENV).ok().filter(|u| !u.is_empty()) {
        Some(u) => (u, true),
        None => (MANIFEST_URL.into(), false),
    }
}

fn curl(url: &str, insecure_ok: bool) -> Command {
    let mut c = Command::new(CURL);
    let proto = if insecure_ok { "=https,http,file" } else { "=https" };
    c.args(["-fsSL", "--proto", proto, "--proto-redir", proto, url]);
    c.stdin(Stdio::null()).stderr(Stdio::null());
    c
}

pub fn fetch_manifest() -> Result<Manifest, String> {
    let (url, insecure) = manifest_url();
    let out = curl(&url, insecure).output().map_err(|e| format!("Couldn't download the tools list: {e}"))?;
    if !out.status.success() {
        return Err("The tools aren't available yet. Try again later.".into());
    }
    serde_json::from_slice(&out.stdout).map_err(|_| "The tools list couldn't be read.".into())
}

fn version_key(v: &str) -> Vec<u64> {
    v.split(|c: char| !c.is_ascii_digit()).filter(|s| !s.is_empty()).map(|s| s.parse().unwrap_or(0)).collect()
}

pub fn current_version(tools: &Path) -> Option<String> {
    let target = fs::read_link(tools.join("current")).ok()?;
    if !tools.join("current").is_dir() {
        return None;
    }
    target.file_name().map(|n| n.to_string_lossy().into_owned())
}

pub fn needed_in(tools: &Path, m: &Manifest) -> bool {
    match current_version(tools) {
        None => true,
        Some(cur) => version_key(&cur) < version_key(&m.version),
    }
}

pub fn needed(m: &Manifest) -> bool {
    tools_dir().map(|t| needed_in(&t, m)).unwrap_or(true)
}

pub fn sha256(path: &Path) -> Result<String, String> {
    let out = Command::new(SHASUM).args(["-a", "256"]).arg(path).stdin(Stdio::null()).output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("Couldn't check {}", path.display()));
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.split_whitespace().next().map(|h| h.to_ascii_lowercase()).ok_or_else(|| "Couldn't check a file".into())
}

fn safe_rel(rel: &str) -> bool {
    let p = Path::new(rel);
    !rel.is_empty() && p.is_relative() && p.components().all(|c| matches!(c, std::path::Component::Normal(_) | std::path::Component::CurDir))
}

fn walk_files(root: &Path, dir: &Path, out: &mut Vec<String>) -> std::io::Result<()> {
    for e in fs::read_dir(dir)? {
        let e = e?;
        let ft = e.file_type()?;
        if ft.is_dir() {
            walk_files(root, &e.path(), out)?;
        } else {
            out.push(e.path().strip_prefix(root).unwrap_or(&e.path()).to_string_lossy().into_owned());
        }
    }
    Ok(())
}

/// Every file in the bundle must be listed in its SHA256SUMS and match.
pub fn verify_bundle(root: &Path) -> Result<(), String> {
    let sums = fs::read_to_string(root.join("SHA256SUMS")).map_err(|_| "The tools bundle has no checksum list.".to_string())?;
    let mut listed = std::collections::HashSet::new();
    for line in sums.lines().filter(|l| !l.trim().is_empty()) {
        let (hash, rel) = line.split_once("  ").ok_or("The tools checksum list is malformed.")?;
        let rel = rel.trim_start_matches("./");
        if !safe_rel(rel) {
            return Err("The tools checksum list is malformed.".into());
        }
        if sha256(&root.join(rel))? != hash.trim().to_ascii_lowercase() {
            return Err(format!("A tools file failed its check: {rel}"));
        }
        listed.insert(rel.to_string());
    }
    let mut files = Vec::new();
    walk_files(root, root, &mut files).map_err(|e| e.to_string())?;
    if let Some(extra) = files.iter().find(|f| f.as_str() != "SHA256SUMS" && !listed.contains(f.as_str())) {
        return Err(format!("An unexpected file is in the tools bundle: {extra}"));
    }
    Ok(())
}

/// Wait until no request runs: status.json `now` empty and `computer.running == 0`.
fn wait_idle(state_dir: Option<&Path>) {
    let Some(dir) = state_dir else { return };
    loop {
        let busy = fs::read_to_string(dir.join("status.json"))
            .ok()
            .and_then(|r| serde_json::from_str::<serde_json::Value>(&r).ok())
            .map(|v| {
                let now = v.get("now").and_then(|n| n.as_array()).is_some_and(|a| !a.is_empty());
                let running = v.pointer("/computer/running").and_then(|n| n.as_u64()).unwrap_or(0) > 0;
                now || running
            })
            .unwrap_or(false);
        if !busy {
            return;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn clean_tmp(tools: &Path) {
    if let Ok(rd) = fs::read_dir(tools) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().starts_with(".tmp-") {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
}

/// Install into `tools`. `progress(pct, message)`. On any error `current` is untouched and the temp dir removed.
pub fn install_into(
    tools: &Path,
    m: &Manifest,
    insecure_ok: bool,
    state_dir: Option<&Path>,
    progress: &dyn Fn(u8, &str),
) -> Result<(), String> {
    if !safe_rel(&m.version) || m.version.starts_with('.') || m.version == "current" {
        return Err("The tools list has a bad version.".into());
    }
    let archive = m.archive().ok_or("No tools are published for this Mac.")?;
    fs::create_dir_all(tools).map_err(|e| e.to_string())?;
    clean_tmp(tools);
    let tmp = tools.join(format!(".tmp-{}-{}", m.version, std::process::id()));
    let r = install_steps(tools, &tmp, m, archive, insecure_ok, state_dir, progress);
    let _ = fs::remove_dir_all(&tmp);
    r
}

fn install_steps(
    tools: &Path,
    tmp: &Path,
    m: &Manifest,
    archive: &Archive,
    insecure_ok: bool,
    state_dir: Option<&Path>,
    progress: &dyn Fn(u8, &str),
) -> Result<(), String> {
    let dest = tools.join(&m.version);
    if current_version(tools).as_deref() == Some(m.version.as_str()) {
        return Ok(());
    }
    fs::create_dir_all(tmp).map_err(|e| e.to_string())?;
    let file = tmp.join("toolchain.tar");
    progress(0, "Downloading tools");
    let mut child = curl(&archive.url, insecure_ok)
        .arg("-o")
        .arg(&file)
        .stdout(Stdio::null())
        .spawn()
        .map_err(|e| format!("Couldn't download the tools: {e}"))?;
    let status = loop {
        if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
            break s;
        }
        let got = fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        let pct = if archive.size_bytes > 0 { (got * 80 / archive.size_bytes).min(80) as u8 } else { 0 };
        progress(pct, "Downloading tools");
        std::thread::sleep(Duration::from_millis(250));
    };
    if !status.success() {
        return Err("Couldn't download the tools. Check your internet connection and try again.".into());
    }
    progress(80, "Checking tools");
    if sha256(&file)? != archive.sha256.to_ascii_lowercase() {
        return Err("The tools download failed its check. Try again.".into());
    }
    let x = tmp.join("x");
    fs::create_dir_all(&x).map_err(|e| e.to_string())?;
    // macOS 13+ bsdtar autodetects zstd/gzip with -xf (this tar has no --zstd flag).
    let ok = Command::new(TAR)
        .arg("-xf")
        .arg(&file)
        .arg("-C")
        .arg(&x)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| e.to_string())?
        .success();
    if !ok {
        return Err("Couldn't unpack the tools.".into());
    }
    progress(90, "Checking tools");
    verify_bundle(&x)?;
    if dest.exists() {
        fs::remove_dir_all(&dest).map_err(|e| e.to_string())?;
    }
    fs::rename(&x, &dest).map_err(|e| e.to_string())?;
    wait_idle(state_dir);
    let link_tmp = tools.join(format!(".current-{}", std::process::id()));
    let _ = fs::remove_file(&link_tmp);
    std::os::unix::fs::symlink(&m.version, &link_tmp).map_err(|e| e.to_string())?;
    fs::rename(&link_tmp, tools.join("current")).map_err(|e| e.to_string())?;
    if let Ok(rd) = fs::read_dir(tools) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name != m.version && name != "current" && !name.starts_with('.') && e.path().is_dir() {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
    progress(100, "Tools installed");
    Ok(())
}

pub fn install(m: &Manifest, progress: &dyn Fn(u8, &str)) -> Result<(), String> {
    let (_, insecure) = manifest_url();
    let state = crate::control::state_dir().ok();
    install_into(&tools_dir()?, m, insecure, state.as_deref(), progress)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle(root: &Path, version: &str, tamper: bool) -> (Manifest, PathBuf) {
        let src = root.join(format!("src-{version}"));
        fs::create_dir_all(src.join("bin")).unwrap();
        fs::write(src.join("bin/hello"), format!("#!/bin/sh\necho {version}\n")).unwrap();
        let h = sha256(&src.join("bin/hello")).unwrap();
        fs::write(src.join("SHA256SUMS"), format!("{h}  bin/hello\n")).unwrap();
        if tamper {
            fs::write(src.join("bin/hello"), "tampered").unwrap();
        }
        let tarball = root.join(format!("tc-{version}.tar.gz"));
        assert!(Command::new(TAR).arg("-czf").arg(&tarball).arg("-C").arg(&src).arg(".").status().unwrap().success());
        let mut archives = std::collections::HashMap::new();
        archives.insert(
            arch().to_string(),
            Archive {
                url: format!("file://{}", tarball.display()),
                sha256: sha256(&tarball).unwrap(),
                size_bytes: fs::metadata(&tarball).unwrap().len(),
            },
        );
        (Manifest { version: version.into(), min_app_version: None, archives, published_at: None }, tarball)
    }

    fn no_tmp(tools: &Path) -> bool {
        fs::read_dir(tools).unwrap().flatten().all(|e| !e.file_name().to_string_lossy().starts_with('.'))
    }

    #[test]
    fn happy_path_then_upgrade_removes_old() {
        let d = tempfile::tempdir().unwrap();
        let tools = d.path().join("tools");
        let (m1, _) = bundle(d.path(), "1.0.0", false);
        assert!(needed_in(&tools, &m1));
        install_into(&tools, &m1, true, None, &|_, _| {}).unwrap();
        assert!(tools.join("1.0.0/bin/hello").is_file());
        assert_eq!(fs::read_link(tools.join("current")).unwrap(), PathBuf::from("1.0.0"));
        assert!(!needed_in(&tools, &m1));
        assert!(no_tmp(&tools));
        let (m2, _) = bundle(d.path(), "1.1.0", false);
        assert!(needed_in(&tools, &m2));
        install_into(&tools, &m2, true, None, &|_, _| {}).unwrap();
        assert_eq!(current_version(&tools).as_deref(), Some("1.1.0"));
        assert!(!tools.join("1.0.0").exists());
    }

    #[test]
    fn wrong_archive_sha_keeps_current() {
        let d = tempfile::tempdir().unwrap();
        let tools = d.path().join("tools");
        let (m1, _) = bundle(d.path(), "1.0.0", false);
        install_into(&tools, &m1, true, None, &|_, _| {}).unwrap();
        let (mut m2, _) = bundle(d.path(), "2.0.0", false);
        m2.archives.get_mut(arch()).unwrap().sha256 = "0".repeat(64);
        assert!(install_into(&tools, &m2, true, None, &|_, _| {}).is_err());
        assert_eq!(current_version(&tools).as_deref(), Some("1.0.0"));
        assert!(no_tmp(&tools));
    }

    #[test]
    fn tampered_bundle_file_keeps_current_and_cleans_tmp() {
        let d = tempfile::tempdir().unwrap();
        let tools = d.path().join("tools");
        let (m1, _) = bundle(d.path(), "1.0.0", false);
        install_into(&tools, &m1, true, None, &|_, _| {}).unwrap();
        fs::create_dir_all(tools.join(".tmp-leftover-1")).unwrap();
        let (m2, _) = bundle(d.path(), "2.0.0", true);
        let e = install_into(&tools, &m2, true, None, &|_, _| {}).unwrap_err();
        assert!(e.contains("failed its check"), "{e}");
        assert_eq!(current_version(&tools).as_deref(), Some("1.0.0"));
        assert!(!tools.join("2.0.0").exists());
        assert!(no_tmp(&tools));
    }

    #[test]
    fn file_url_rejected_without_override() {
        let d = tempfile::tempdir().unwrap();
        let tools = d.path().join("tools");
        let (m1, _) = bundle(d.path(), "1.0.0", false);
        assert!(install_into(&tools, &m1, false, None, &|_, _| {}).is_err());
        assert!(current_version(&tools).is_none());
    }

    #[test]
    fn fetch_manifest_via_env_override() {
        let _g = crate::control::tests::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let (m1, _) = bundle(d.path(), "1.0.0", false);
        let p = d.path().join("manifest.json");
        fs::write(&p, serde_json::to_string(&m1).unwrap()).unwrap();
        std::env::set_var(MANIFEST_URL_ENV, format!("file://{}", p.display()));
        let got = fetch_manifest();
        std::env::remove_var(MANIFEST_URL_ENV);
        assert_eq!(got.unwrap(), m1);
    }
}
