//! [WI27] The Server switch: which CFW this app talks to, and which worker files it uses.
//!
//! This is the one place that decides it. The owner's choice is saved in the app's own config
//! folder (never in `~/.cfw-render`) and read once at startup, so nothing switches halfway: a new
//! choice takes effect after a restart. Production is the default and keeps every path, base and
//! label exactly as before.
//!
//! ```text
//!                  Production (default)             Local dev
//!   state dir      ~/.cfw-render                    ~/.cfw-render-dev/render-state
//!   settings file  <state dir>/cfw-render.env       ~/.cfw-render-dev/cfw-render.env
//!   render home    ~/CFW Render                     ~/.cfw-render-dev/render-home
//!   (logs, tools, setup marker under the render home; Local dev's three match the cfw-social seed)
//!   launchd job    com.cfw.render                   com.cfw.render.dev (never installed here)
//!   API base       env, env file, app.cfw.social    env file, else http://localhost:3005
//!   web base       env, API base, app.cfw.social    the API base
//!   chat MCP URL   https only                       http(s) on localhost / 127.0.0.1 only
//!   brand keys     Keychain com.cfw.render          Keychain com.cfw.render.dev
//! ```
//!
//! Local dev refuses any server that is not on this Mac and any folder of the production
//! install. It adds nothing visible to the home folder: everything it owns sits inside the hidden
//! `~/.cfw-render-dev` (the home folder is locked to named roots). The updater and the toolchain
//! manifest are not decided here: they stay on production.
//!
//! The Server switch itself shows only with `CFW_RENDER_DEV_TOOLS=1` at launch, in a debug build,
//! or while Local dev is already on (so it can be switched back).

use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use tauri::Url;

/// The saved choice, inside the app's config folder.
pub const CHOICE_FILE: &str = "server.json";
pub const PROD_BASE: &str = "https://app.cfw.social";
pub const DEV_BASE: &str = "http://localhost:3005";
pub const PROD_MCP_URL: &str = "https://app.cfw.social/api/v1/mcp";
pub const DEV_TOOLS_ENV: &str = "CFW_RENDER_DEV_TOOLS";
/// Everything Local dev owns sits in this hidden folder under $HOME.
macro_rules! dev_root {
    () => {
        ".cfw-render-dev"
    };
}
/// The dev worker's state folder (worker-id, pause / run-now files, tick lock), as the seed sets it.
const DEV_STATE: &str = concat!(dev_root!(), "/render-state");
const DEV_RENDER_HOME: &str = concat!(dev_root!(), "/render-home");
const DEV_ENV_FILE: &str = concat!(dev_root!(), "/cfw-render.env");
/// What the owner reads when the local worker is not loaded. The app never installs its plist.
pub const LOCAL_WORKER_HINT: &str = "The local worker isn't running. Start it with `pnpm dev:stack` in cfw-social.";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Profile {
    #[default]
    Production,
    LocalDev,
}

impl Profile {
    pub fn is_local_dev(self) -> bool {
        self == Profile::LocalDev
    }
    /// The worker's state folder, relative to the home folder.
    pub fn state_folder(self) -> &'static str {
        match self {
            Profile::Production => ".cfw-render",
            Profile::LocalDev => DEV_STATE,
        }
    }
    /// The worker's settings file, relative to the home folder (what setup looks at).
    pub fn env_file_rel(self) -> &'static str {
        match self {
            Profile::Production => ".cfw-render/cfw-render.env",
            Profile::LocalDev => DEV_ENV_FILE,
        }
    }
    /// The render home (tools, logs, outputs), relative to the home folder. Production's is the
    /// visible `CFW Render`; Local dev's stays inside its hidden folder.
    pub fn render_home_rel(self) -> &'static str {
        match self {
            Profile::Production => "CFW Render",
            Profile::LocalDev => DEV_RENDER_HOME,
        }
    }
    pub fn launchd_label(self) -> &'static str {
        match self {
            Profile::Production => "com.cfw.render",
            Profile::LocalDev => "com.cfw.render.dev",
        }
    }
    /// Keychain service for the chat companion's brand keys. A local CFW mints its own brand
    /// keys, often for the same slugs, so they must never overwrite the production ones.
    pub fn brand_key_service(self) -> &'static str {
        match self {
            Profile::Production => "com.cfw.render",
            Profile::LocalDev => "com.cfw.render.dev",
        }
    }
    pub fn app_title(self) -> &'static str {
        match self {
            Profile::Production => "CFW Render",
            Profile::LocalDev => "CFW Render (Local dev)",
        }
    }
}

// ── the profile this run uses ─────────────────────────────────────────────

static ACTIVE: OnceLock<Profile> = OnceLock::new();
static STARTUP_ERROR: OnceLock<String> = OnceLock::new();
static DEV_TOOLS: OnceLock<bool> = OnceLock::new();

/// The profile fixed at startup. Production until [`init`] runs (and in unit tests).
pub fn active() -> Profile {
    ACTIVE.get().copied().unwrap_or_default()
}

/// Startup only: read the saved choice once and fix it for this run. A choice that cannot be read
/// starts Production (today's behaviour) and the reason is shown in Settings, not hidden.
pub fn init(config_dir: Option<&Path>) -> Profile {
    let _ = DEV_TOOLS.set(std::env::var(DEV_TOOLS_ENV).as_deref() == Ok("1"));
    let chosen = match config_dir {
        Some(d) => read_choice(d),
        None => Err("could not find the app's settings folder".into()),
    };
    let p = match chosen {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cfw-render: {e}; starting on Production");
            let _ = STARTUP_ERROR.set(e);
            Profile::Production
        }
    };
    *ACTIVE.get_or_init(|| p)
}

#[derive(Serialize, Deserialize)]
struct Choice {
    server: Profile,
}

/// The saved choice. No file means Production.
pub fn read_choice(config_dir: &Path) -> Result<Profile, String> {
    match std::fs::read_to_string(config_dir.join(CHOICE_FILE)) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Profile::Production),
        Err(e) => Err(format!("could not read the Server setting: {e}")),
        Ok(raw) => serde_json::from_str::<Choice>(&raw)
            .map(|c| c.server)
            .map_err(|_| "the saved Server setting is not valid".to_string()),
    }
}

pub fn write_choice(config_dir: &Path, p: Profile) -> Result<(), String> {
    let body = serde_json::to_vec(&Choice { server: p }).expect("serialising an enum");
    crate::control::write_atomic(config_dir, CHOICE_FILE, &body).map_err(|e| e.to_string())
}

/// Actions that act on the production install (installer, uninstall, send logs) are off in Local dev.
pub fn production_only_for(p: Profile, what: &str) -> Result<(), String> {
    if p.is_local_dev() {
        Err(format!("{what} is off in Local dev, so the production setup on this Mac is not touched."))
    } else {
        Ok(())
    }
}

pub fn production_only(what: &str) -> Result<(), String> {
    production_only_for(active(), what)
}

// ── folders ───────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq, thiserror::Error)]
pub enum FolderError {
    #[error("could not locate the home directory")]
    NoHome,
    #[error("Local dev never uses the production folders; {0} points at one")]
    Production(&'static str),
}

/// `.` dropped, `..` pops: the path on paper, without the file system.
fn lexical(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Where an absolute path really points: its deepest existing ancestor canonicalized (the OS
/// resolves symlinks and `..` there), then the rest appended with `.` and `..` normalised.
/// None for a relative path, or when something exists that cannot be resolved (a broken link).
fn resolve(p: &Path) -> Option<PathBuf> {
    if !p.is_absolute() {
        return None;
    }
    let comps: Vec<Component> = p.components().collect();
    for i in (1..=comps.len()).rev() {
        let prefix: PathBuf = comps[..i].iter().collect();
        match std::fs::canonicalize(&prefix) {
            Ok(mut out) => {
                for c in &comps[i..] {
                    match c {
                        Component::CurDir => {}
                        Component::ParentDir => {
                            out.pop();
                        }
                        other => out.push(other.as_os_str()),
                    }
                }
                return Some(out);
            }
            Err(_) if std::fs::symlink_metadata(&prefix).is_ok() => return None,
            Err(_) => {}
        }
    }
    None
}

/// Equal to or under `root`, ignoring case: APFS ignores case, so `~/.CFW-render` is `~/.cfw-render`.
fn same_or_under(p: &Path, root: &Path) -> bool {
    let p = p.to_string_lossy().to_lowercase();
    let r = root.to_string_lossy().to_lowercase();
    let r = r.trim_end_matches('/');
    p == r || p.starts_with(&format!("{r}/"))
}

/// A Local dev folder must be absolute and, once case, symlinks and `..` are resolved, outside
/// `~/.cfw-render` and `~/CFW Render`. Without a home folder there is nothing to check, so refused.
fn dev_path_ok(p: &Path, home: Option<&Path>) -> bool {
    let Some(h) = home else { return false };
    let Some(real) = resolve(p) else { return false };
    let flat = lexical(p);
    let prod = Profile::Production;
    [prod.state_folder(), prod.render_home_rel()].iter().all(|rel| {
        let root = h.join(rel);
        match resolve(&root) {
            Some(real_root) => !same_or_under(&real, &real_root) && !same_or_under(&flat, &lexical(&root)),
            None => false,
        }
    })
}

/// Production: the env override, else `~/<name>`, exactly as before. Local dev: the same, but the
/// result (override or default) must pass [`dev_path_ok`].
fn folder(p: Profile, env: Option<PathBuf>, home: Option<&Path>, name: &str, var: &'static str) -> Result<PathBuf, FolderError> {
    let d = match env {
        Some(d) => d,
        None => home.map(|h| h.join(name)).ok_or(FolderError::NoHome)?,
    };
    if p.is_local_dev() && !dev_path_ok(&d, home) {
        return Err(FolderError::Production(var));
    }
    Ok(d)
}

/// The worker's state folder: `CFW_RENDER_STATE_DIR`, else `~/<state folder>`.
pub fn state_dir_for(p: Profile, env: Option<PathBuf>, home: Option<&Path>) -> Result<PathBuf, FolderError> {
    folder(p, env, home, p.state_folder(), "CFW_RENDER_STATE_DIR")
}

/// The render home: `CFW_RENDER_HOME`, else `~/<render home>`.
pub fn render_home_for(p: Profile, env: Option<PathBuf>, home: Option<&Path>) -> Result<PathBuf, FolderError> {
    folder(p, env, home, p.render_home_rel(), "CFW_RENDER_HOME")
}

/// The worker's settings file. Production: `<state dir>/cfw-render.env`, as before. Local dev:
/// `~/.cfw-render-dev/cfw-render.env`, beside (not inside) its state folder, as the seed writes it.
pub fn env_file_for(p: Profile, state_dir: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    match p {
        Profile::Production => state_dir.map(|d| d.join("cfw-render.env")),
        Profile::LocalDev => home.map(|h| h.join(DEV_ENV_FILE)),
    }
}

/// [`env_file_for`] for this run; an empty path (reads as "no file") when it can't be found.
pub fn env_file() -> PathBuf {
    let state = crate::control::state_dir().ok();
    env_file_for(active(), state.as_deref(), dirs::home_dir().as_deref()).unwrap_or_default()
}

/// What "View logs" opens: `<render home>/logs` (no env override, as before).
pub fn logs_dir_for(p: Profile, home: &Path) -> PathBuf {
    home.join(p.render_home_rel()).join("logs")
}

/// Where the private toolchain's CLIs live: `<render home>/app/tools/current/bin`.
pub fn tools_bin_for(p: Profile, home: &Path) -> PathBuf {
    home.join(p.render_home_rel()).join("app/tools/current/bin")
}

// ── servers ───────────────────────────────────────────────────────────────

/// Same rule as the worker's `cr_dev_api_base_ok`.
pub fn is_local_base(s: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^https?://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/?$").expect("local base regex")).is_match(s)
}

/// A local base plus an optional plain path (no query, fragment or spaces).
pub fn is_local_mcp(s: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^https?://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?(/[^\s?#]*)?$").expect("local mcp regex")).is_match(s)
}

/// `env` is `CFW_RENDER_API_BASE`, `file` the env file's `CFW_API_BASE` (both non-empty or None).
pub fn api_base_for(p: Profile, env: Option<String>, file: Option<String>) -> Result<String, String> {
    match p {
        Profile::Production => Ok(env.or(file).unwrap_or_else(|| PROD_BASE.into())),
        Profile::LocalDev => {
            let b = file.unwrap_or_else(|| DEV_BASE.into());
            if is_local_base(&b) {
                Ok(b)
            } else {
                Err(format!("Local dev only talks to a CFW on this Mac (http://localhost or 127.0.0.1); refusing {b}"))
            }
        }
    }
}

pub fn parse_http(s: &str) -> Option<Url> {
    Url::parse(s).ok().filter(|u| matches!(u.scheme(), "http" | "https") && u.host().is_some())
}

/// `env` is `CFW_RENDER_WEB_BASE`; `api` is the API base for the same profile.
pub fn web_base_for(p: Profile, env: Option<String>, api: Result<String, String>) -> Result<Url, String> {
    match p {
        Profile::Production => {
            if let Some(u) = env.and_then(|b| parse_http(&b)) {
                return Ok(u);
            }
            Ok(api.ok().and_then(|b| parse_http(&b)).unwrap_or_else(|| Url::parse(PROD_BASE).expect("default base")))
        }
        Profile::LocalDev => parse_http(&api?).ok_or_else(|| "Local dev has no usable server address".into()),
    }
}

/// `env` is `CFW_RENDER_MCP_URL` (non-empty or None); `api` is the API base for the same profile.
/// Production keeps today's rule: an https override or app.cfw.social. Local dev sends brand keys
/// only to a CFW on this Mac, and plain http is allowed only there.
pub fn mcp_url_for(p: Profile, env: Option<String>, api: Result<String, String>) -> Result<String, String> {
    match p {
        Profile::Production => Ok(env.filter(|u| u.starts_with("https://")).unwrap_or_else(|| PROD_MCP_URL.into())),
        Profile::LocalDev => match env {
            Some(u) if is_local_mcp(&u) => Ok(u),
            Some(u) => Err(format!("Local dev only sends brand keys to a CFW on this Mac; refusing chat server {u}")),
            None => Ok(format!("{}/api/v1/mcp", api?.trim_end_matches('/'))),
        },
    }
}

/// `localhost:3005`, `app.cfw.social`: what the badge and Settings show.
pub fn server_label(u: &Url) -> String {
    let host = u.host_str().unwrap_or_default();
    match u.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    }
}

// ── Settings view and commands ────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerView {
    /// What this run uses.
    pub active: Profile,
    /// What the next start uses.
    pub chosen: Profile,
    /// The active server, e.g. `localhost:3005`.
    pub server: Option<String>,
    pub restart_needed: bool,
    pub error: Option<String>,
    /// Whether Settings shows the switch at all.
    pub switch_visible: bool,
}

/// Normal production users never see the switch. It shows with `CFW_RENDER_DEV_TOOLS=1` at launch,
/// in a debug build, or while Local dev is on, so it can always be switched back.
pub fn switch_visible_for(active: Profile, dev_tools: bool, debug_build: bool) -> bool {
    dev_tools || debug_build || active.is_local_dev()
}

fn switch_visible() -> bool {
    switch_visible_for(active(), DEV_TOOLS.get().copied().unwrap_or(false), cfg!(debug_assertions))
}

pub fn view(
    active: Profile,
    chosen: Result<Profile, String>,
    server: Result<Url, String>,
    startup_error: Option<&str>,
    switch_visible: bool,
) -> ServerView {
    let (chosen, chosen_err) = match chosen {
        Ok(c) => (c, None),
        Err(e) => (active, Some(e)),
    };
    let (server, server_err) = match server {
        Ok(u) => (Some(server_label(&u)), None),
        Err(e) => (None, Some(e)),
    };
    ServerView {
        active,
        chosen,
        server,
        restart_needed: chosen != active,
        error: startup_error.map(str::to_string).or(chosen_err).or(server_err),
        switch_visible,
    }
}

fn config_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    use tauri::Manager;
    app.path().app_config_dir().map_err(|e| e.to_string())
}

fn current_view(app: &tauri::AppHandle) -> ServerView {
    let chosen = config_dir(app).and_then(|d| read_choice(&d));
    view(active(), chosen, crate::web::web_base(), STARTUP_ERROR.get().map(String::as_str), switch_visible())
}

#[tauri::command]
pub fn get_server_profile(app: tauri::AppHandle) -> ServerView {
    current_view(&app)
}

/// Saves the choice for the next start. Nothing switches until the app restarts.
#[tauri::command]
pub fn set_server_profile(app: tauri::AppHandle, server: Profile) -> Result<ServerView, String> {
    if !switch_visible() {
        return Err("The Server switch is not available in this app.".into());
    }
    write_choice(&config_dir(&app)?, server)?;
    Ok(current_view(&app))
}

#[tauri::command]
pub fn restart_app(app: tauri::AppHandle) {
    app.restart()
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/owner";
    const DEV_ROOT: &str = dev_root!();

    fn home() -> Option<&'static Path> {
        Some(Path::new(HOME))
    }

    #[test]
    fn default_is_production_with_todays_values() {
        assert_eq!(Profile::default(), Profile::Production);
        assert_eq!(active(), Profile::Production, "unit tests never call init");
        let p = Profile::Production;
        assert_eq!(state_dir_for(p, None, home()).unwrap(), Path::new("/Users/owner/.cfw-render"));
        assert_eq!(render_home_for(p, None, home()).unwrap(), Path::new("/Users/owner/CFW Render"));
        let st = Path::new("/x/state");
        assert_eq!(env_file_for(p, Some(st), home()).unwrap(), Path::new("/x/state/cfw-render.env"), "beside the state dir, as before");
        assert_eq!(p.env_file_rel(), ".cfw-render/cfw-render.env");
        assert!(!switch_visible_for(p, false, false), "plain production never sees the switch");
        assert_eq!(logs_dir_for(p, Path::new(HOME)), Path::new("/Users/owner/CFW Render/logs"));
        assert_eq!(tools_bin_for(p, Path::new(HOME)), Path::new("/Users/owner/CFW Render/app/tools/current/bin"));
        assert_eq!(p.launchd_label(), "com.cfw.render");
        assert_eq!(p.brand_key_service(), "com.cfw.render");
        assert_eq!(api_base_for(p, None, None).unwrap(), "https://app.cfw.social");
        assert_eq!(web_base_for(p, None, api_base_for(p, None, None)).unwrap().as_str(), "https://app.cfw.social/");
        assert_eq!(mcp_url_for(p, None, api_base_for(p, None, None)).unwrap(), "https://app.cfw.social/api/v1/mcp");
        assert!(production_only_for(p, "Uninstall").is_ok());
    }

    #[test]
    fn production_keeps_its_overrides() {
        let p = Profile::Production;
        // env, then env file, then app.cfw.social; any host is fine in Production.
        assert_eq!(api_base_for(p, Some("https://staging.example".into()), Some("http://x".into())).unwrap(), "https://staging.example");
        assert_eq!(api_base_for(p, None, Some("https://other.example".into())).unwrap(), "https://other.example");
        assert_eq!(state_dir_for(p, Some("/Users/owner/.cfw-render".into()), home()).unwrap(), Path::new("/Users/owner/.cfw-render"));
        assert_eq!(state_dir_for(p, None, None), Err(FolderError::NoHome));
        let web = web_base_for(p, Some("https://web.example".into()), Ok("https://api.example".into())).unwrap();
        assert_eq!(web.as_str(), "https://web.example/");
        assert_eq!(web_base_for(p, None, Ok("not a url".into())).unwrap().as_str(), "https://app.cfw.social/");
    }

    #[test]
    fn local_dev_paths_and_labels() {
        let p = Profile::LocalDev;
        // The three the cfw-social seed writes for the dev worker.
        assert_eq!(state_dir_for(p, None, home()).unwrap(), Path::new("/Users/owner/.cfw-render-dev/render-state"));
        assert_eq!(render_home_for(p, None, home()).unwrap(), Path::new("/Users/owner/.cfw-render-dev/render-home"));
        let st = state_dir_for(p, None, home()).unwrap();
        assert_eq!(env_file_for(p, Some(&st), home()).unwrap(), Path::new("/Users/owner/.cfw-render-dev/cfw-render.env"));
        assert_eq!(Path::new(HOME).join(p.env_file_rel()), Path::new("/Users/owner/.cfw-render-dev/cfw-render.env"));
        assert_eq!(logs_dir_for(p, Path::new(HOME)), Path::new("/Users/owner/.cfw-render-dev/render-home/logs"));
        assert_eq!(tools_bin_for(p, Path::new(HOME)), Path::new("/Users/owner/.cfw-render-dev/render-home/app/tools/current/bin"));
        assert_eq!(p.launchd_label(), "com.cfw.render.dev");
        assert_eq!(p.brand_key_service(), "com.cfw.render.dev");
        assert_eq!(p.app_title(), "CFW Render (Local dev)");
        let base = api_base_for(p, None, None).unwrap();
        assert_eq!(base, "http://localhost:3005");
        assert_eq!(server_label(&web_base_for(p, None, Ok(base.clone())).unwrap()), "localhost:3005");
        assert_eq!(mcp_url_for(p, None, Ok(base)).unwrap(), "http://localhost:3005/api/v1/mcp");
        // The env file may move it to another local port.
        assert_eq!(api_base_for(p, None, Some("http://127.0.0.1:3010/".into())).unwrap(), "http://127.0.0.1:3010/");
        assert!(production_only_for(p, "Uninstall").unwrap_err().contains("off in Local dev"));
    }

    #[test]
    fn local_dev_adds_nothing_to_home_but_its_hidden_folder() {
        // The home folder is locked to named roots: every folder Local dev resolves sits inside
        // ~/.cfw-render-dev, never directly under $HOME.
        let p = Profile::LocalDev;
        let h = Path::new(HOME);
        let render_home = render_home_for(p, None, home()).unwrap();
        let resolved = [
            state_dir_for(p, None, home()).unwrap(),
            render_home.clone(),
            logs_dir_for(p, h),
            tools_bin_for(p, h),
            render_home.join("app/tools"),            // toolchain::tools_dir
            render_home.join("app/.setup-complete"),  // setup marker
            env_file_for(p, None, home()).unwrap(),
            h.join(p.env_file_rel()),
        ];
        for path in resolved {
            let first = path.strip_prefix(h).unwrap().components().next().unwrap();
            assert_eq!(first.as_os_str(), DEV_ROOT, "{path:?} is not inside ~/.cfw-render-dev");
        }
        for rel in [DEV_STATE, DEV_RENDER_HOME, DEV_ENV_FILE] {
            assert!(rel.starts_with(&format!("{DEV_ROOT}/")), "{rel}");
        }
    }

    /// A temp HOME with a real `~/.cfw-render` and `~/CFW Render`, so symlinks can point into them.
    fn temp_home() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join(".cfw-render/sub")).unwrap();
        std::fs::create_dir_all(d.path().join("CFW Render/app")).unwrap();
        std::fs::create_dir_all(d.path().join(".cfw-render-dev")).unwrap();
        d
    }

    #[test]
    fn guard_ignores_case() {
        let d = temp_home();
        let h = Some(d.path());
        for bad in [".CFW-RENDER", ".Cfw-Render/sub", ".cfw-render/SUB/new", "cfw render", "CFW RENDER/app/tools", "Cfw Render/New"] {
            let p = d.path().join(bad);
            assert!(state_dir_for(Profile::LocalDev, Some(p.clone()), h).is_err(), "{bad}");
            assert!(render_home_for(Profile::LocalDev, Some(p), h).is_err(), "{bad}");
        }
        assert!(state_dir_for(Profile::LocalDev, Some(d.path().join(".CFW-render-dev/x")), h).is_ok());
    }

    #[test]
    fn guard_resolves_dot_dot() {
        let d = temp_home();
        let h = Some(d.path());
        for bad in [".cfw-render-dev/../.cfw-render", ".cfw-render-dev/./../CFW Render/app", ".cfw-render-dev/missing/../../.cfw-render/x",
                    "nope/../.cfw-render"] {
            assert!(state_dir_for(Profile::LocalDev, Some(d.path().join(bad)), h).is_err(), "{bad}");
        }
        assert!(state_dir_for(Profile::LocalDev, Some(d.path().join(".cfw-render-dev/a/../render-state")), h).is_ok());
    }

    #[test]
    fn guard_follows_symlinks() {
        let d = temp_home();
        let h = Some(d.path());
        let dev = d.path().join(".cfw-render-dev");
        std::os::unix::fs::symlink(d.path().join(".cfw-render"), dev.join("state-link")).unwrap();
        std::os::unix::fs::symlink(d.path().join("CFW Render/app"), dev.join("home-link")).unwrap();
        std::os::unix::fs::symlink(d.path().join(".cfw-render/gone"), dev.join("broken-link")).unwrap();
        for bad in ["state-link", "state-link/render-state", "home-link", "home-link/tools", "broken-link", "broken-link/x"] {
            assert!(state_dir_for(Profile::LocalDev, Some(dev.join(bad)), h).is_err(), "{bad}");
        }
        // The hidden folder itself linked into production: even the defaults are refused.
        let d2 = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d2.path().join(".cfw-render")).unwrap();
        std::os::unix::fs::symlink(d2.path().join(".cfw-render"), d2.path().join(".cfw-render-dev")).unwrap();
        assert!(state_dir_for(Profile::LocalDev, None, Some(d2.path())).is_err());
        assert!(render_home_for(Profile::LocalDev, None, Some(d2.path())).is_err());
        // Production defaults are never checked: unchanged.
        assert!(state_dir_for(Profile::Production, None, Some(d2.path())).is_ok());
        // A link to an ordinary folder is fine.
        std::fs::create_dir_all(d.path().join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(d.path().join("elsewhere"), dev.join("ok-link")).unwrap();
        assert!(state_dir_for(Profile::LocalDev, Some(dev.join("ok-link/state")), h).is_ok());
    }

    #[test]
    fn guard_refuses_relative_paths() {
        let d = temp_home();
        for bad in ["relative/dir", ".cfw-render-dev/render-state", "./x", ""] {
            assert!(state_dir_for(Profile::LocalDev, Some(bad.into()), Some(d.path())).is_err(), "{bad:?}");
            assert!(render_home_for(Profile::LocalDev, Some(bad.into()), Some(d.path())).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn switch_shows_only_for_dev_tools_debug_or_local_dev() {
        assert!(!switch_visible_for(Profile::Production, false, false));
        assert!(switch_visible_for(Profile::Production, true, false), "CFW_RENDER_DEV_TOOLS=1");
        assert!(switch_visible_for(Profile::Production, false, true), "debug build");
        assert!(switch_visible_for(Profile::LocalDev, false, false), "so it can be switched back");
    }

    #[test]
    fn local_dev_refuses_production_folders() {
        let p = Profile::LocalDev;
        for bad in ["/Users/owner/.cfw-render", "/Users/owner/.cfw-render/sub", "/Users/owner/CFW Render", "/Users/owner/CFW Render/app",
                    "/Users/owner/.cfw-render-dev/../.cfw-render", "relative/dir"] {
            assert_eq!(state_dir_for(p, Some(bad.into()), home()), Err(FolderError::Production("CFW_RENDER_STATE_DIR")), "{bad}");
            assert_eq!(render_home_for(p, Some(bad.into()), home()), Err(FolderError::Production("CFW_RENDER_HOME")), "{bad}");
        }
        // Look-alike names are separate folders.
        assert_eq!(state_dir_for(p, Some("/Users/owner/.cfw-render-dev".into()), home()).unwrap(), Path::new("/Users/owner/.cfw-render-dev"));
        assert_eq!(render_home_for(p, Some("/tmp/cfw dev".into()), home()).unwrap(), Path::new("/tmp/cfw dev"));
        // No home to check against: refused, never assumed safe.
        assert!(state_dir_for(p, Some("/tmp/x".into()), None).is_err());
    }

    #[test]
    fn local_dev_refuses_a_non_local_api_base() {
        let p = Profile::LocalDev;
        for bad in ["https://app.cfw.social", "http://localhost.evil.com:3005", "http://10.0.0.5:3005", "http://localhost:3005/api",
                    "http://user@localhost:3005", "ftp://localhost:3005", "http://localhost:123456"] {
            let e = api_base_for(p, None, Some(bad.into())).unwrap_err();
            assert!(e.contains("refusing"), "{bad}: {e}");
            // A refused base never falls back to production for the web view or chat.
            assert!(web_base_for(p, None, Err(e.clone())).is_err());
            assert!(mcp_url_for(p, None, Err(e)).is_err());
        }
        // The process env override is not a Local dev input: the env file decides.
        assert_eq!(api_base_for(p, Some("https://app.cfw.social".into()), None).unwrap(), "http://localhost:3005");
        // CFW_RENDER_WEB_BASE cannot point Local dev's web view elsewhere either.
        let web = web_base_for(p, Some("https://app.cfw.social".into()), Ok("http://localhost:3005".into())).unwrap();
        assert_eq!(web.as_str(), "http://localhost:3005/");
    }

    #[test]
    fn production_refuses_an_http_chat_url() {
        let p = Profile::Production;
        let api = || api_base_for(p, None, None);
        assert_eq!(mcp_url_for(p, Some("http://localhost:3005/api/v1/mcp".into()), api()).unwrap(), PROD_MCP_URL);
        assert_eq!(mcp_url_for(p, Some("http://127.0.0.1:3005/api/v1/mcp".into()), api()).unwrap(), PROD_MCP_URL);
        assert_eq!(mcp_url_for(p, Some("https://mcp.example/api/v1/mcp".into()), api()).unwrap(), "https://mcp.example/api/v1/mcp");
    }

    #[test]
    fn local_dev_chat_url_is_local_only() {
        let p = Profile::LocalDev;
        let api = || Ok("http://localhost:3005".to_string());
        assert_eq!(mcp_url_for(p, Some("http://localhost:4000/api/v1/mcp".into()), api()).unwrap(), "http://localhost:4000/api/v1/mcp");
        assert_eq!(mcp_url_for(p, Some("http://127.0.0.1:3005".into()), api()).unwrap(), "http://127.0.0.1:3005");
        for bad in ["https://app.cfw.social/api/v1/mcp", "http://evil.example/api/v1/mcp", "http://localhost:3005/x?y=1", "http://localhost:3005/a b"] {
            assert!(mcp_url_for(p, Some(bad.into()), api()).is_err(), "{bad}");
        }
    }

    #[test]
    fn choice_round_trip_and_bad_files() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_choice(d.path()).unwrap(), Profile::Production, "no file is Production");
        write_choice(d.path(), Profile::LocalDev).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join(CHOICE_FILE)).unwrap(), r#"{"server":"localDev"}"#);
        assert_eq!(read_choice(d.path()).unwrap(), Profile::LocalDev);
        write_choice(d.path(), Profile::Production).unwrap();
        assert_eq!(read_choice(d.path()).unwrap(), Profile::Production);
        for bad in ["", "{}", r#"{"server":"staging"}"#, "nope"] {
            std::fs::write(d.path().join(CHOICE_FILE), bad).unwrap();
            assert!(read_choice(d.path()).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn view_reports_restart_and_errors() {
        let dev = Url::parse("http://localhost:3005").unwrap();
        let v = view(Profile::Production, Ok(Profile::LocalDev), Ok(Url::parse(PROD_BASE).unwrap()), None, true);
        assert_eq!((v.restart_needed, v.server.as_deref(), v.error.as_deref()), (true, Some("app.cfw.social"), None));
        let v = view(Profile::LocalDev, Ok(Profile::LocalDev), Ok(dev.clone()), None, true);
        assert!(!v.restart_needed);
        assert_eq!(v.server.as_deref(), Some("localhost:3005"));
        let json = serde_json::to_value(&v).unwrap();
        assert_eq!(json, serde_json::json!({"active":"localDev","chosen":"localDev","server":"localhost:3005","restartNeeded":false,"error":null,"switchVisible":true}));
        let v = view(Profile::Production, Err("bad file".into()), Ok(dev), Some("startup"), false);
        assert_eq!((v.chosen, v.restart_needed, v.error.as_deref(), v.switch_visible), (Profile::Production, false, Some("startup"), false));
        let v = view(Profile::LocalDev, Ok(Profile::LocalDev), Err("refusing x".into()), None, true);
        assert_eq!((v.server, v.error.as_deref()), (None, Some("refusing x")));
    }
}
