//! AI provider sign-in via the vendor CLI's OWN login (D106). The app never reads, copies or stores
//! `~/.codex/` or `~/.claude/` and never runs its own OAuth: it spawns `codex login` / `claude auth login`
//! and polls the CLI's status command by exit code only.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;

pub const CLI_PATH_ENV: &str = "CFW_RENDER_CLI_PATH";
pub const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(300);
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum SigninError {
    #[error("unknown provider: {0}")]
    UnknownEngine(String),
    #[error("{0} is not installed on this computer")]
    NotInstalled(String),
    #[error("could not run {0}")]
    Spawn(String),
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SigninState {
    Waiting,
    Connected,
    Timeout,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SigninEvent {
    pub engine: String,
    pub state: SigninState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

pub struct Cli {
    pub bin: &'static str,
    pub login: &'static [&'static str],
    pub status: &'static [&'static str],
    pub logout: &'static [&'static str],
}

/// Allow-list. Anything not here is rejected.
pub fn cli_for(engine: &str) -> Result<Cli, SigninError> {
    match engine {
        "codex" => Ok(Cli { bin: "codex", login: &["login"], status: &["login", "status"], logout: &["logout"] }),
        "claude-code" => Ok(Cli {
            bin: "claude",
            login: &["auth", "login"],
            status: &["auth", "status"],
            logout: &["auth", "logout"],
        }),
        other => Err(SigninError::UnknownEngine(other.to_string())),
    }
}

/// GUI apps get a minimal PATH, so prefer known install locations. The env override replaces it all.
pub fn search_path() -> OsString {
    if let Some(p) = std::env::var_os(CLI_PATH_ENV) {
        return p;
    }
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join("CFW Render/app/tools/current/bin"));
    }
    dirs.push("/opt/homebrew/bin".into());
    dirs.push("/usr/local/bin".into());
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/bin"));
    }
    if let Some(inherited) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&inherited));
    }
    std::env::join_paths(dirs).unwrap_or_default()
}

pub(crate) fn resolve(bin: &str, path: &OsString) -> Option<PathBuf> {
    std::env::split_paths(path).map(|d| d.join(bin)).find(|p| p.is_file())
}

/// Minimal environment: PATH (so the CLI finds node etc.), HOME, USER, LANG. Nothing else is passed.
pub(crate) fn command(exe: &Path, args: &[&str], path: &OsString) -> Command {
    let mut c = Command::new(exe);
    c.args(args).env_clear().env("PATH", path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    for k in ["HOME", "USER", "LANG"] {
        if let Some(v) = std::env::var_os(k) {
            c.env(k, v);
        }
    }
    c
}

fn status_ok(exe: &Path, cli: &Cli, path: &OsString) -> bool {
    command(exe, cli.status, path).status().is_ok_and(|s| s.success())
}

#[derive(Clone, Default)]
pub struct Session {
    cancel: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

impl Session {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        if let Some(mut c) = self.child.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    static S: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// Blocking sign-in. Emits `waiting`, then exactly one terminal event.
pub fn run_sign_in(
    engine: &str,
    path: &OsString,
    session: &Session,
    timeout: Duration,
    interval: Duration,
    emit: &dyn Fn(SigninEvent),
) -> Result<SigninState, SigninError> {
    let cli = cli_for(engine)?;
    let exe = resolve(cli.bin, path).ok_or_else(|| SigninError::NotInstalled(cli.bin.into()))?;
    let ev = |state, message: Option<String>| emit(SigninEvent { engine: engine.to_string(), state, message });
    let child = command(&exe, cli.login, path).spawn().map_err(|_| SigninError::Spawn(cli.bin.into()))?;
    *session.child.lock().unwrap() = Some(child);
    ev(SigninState::Waiting, None);

    let start = Instant::now();
    let state = loop {
        if session.cancel.load(Ordering::SeqCst) {
            break SigninState::Cancelled;
        }
        if status_ok(&exe, &cli, path) {
            break SigninState::Connected;
        }
        if start.elapsed() >= timeout {
            break SigninState::Timeout;
        }
        std::thread::sleep(interval);
    };
    if let Some(mut c) = session.child.lock().unwrap().take() {
        let _ = c.kill();
        let _ = c.wait();
    }
    ev(state, None);
    Ok(state)
}

pub fn run_sign_out(engine: &str, path: &OsString) -> Result<bool, SigninError> {
    let cli = cli_for(engine)?;
    let exe = resolve(cli.bin, path).ok_or_else(|| SigninError::NotInstalled(cli.bin.into()))?;
    command(&exe, cli.logout, path).status().map(|s| s.success()).map_err(|_| SigninError::Spawn(cli.bin.into()))
}

/// Gemini: the CLI (checked v0.x, `gemini --help`) has NO `login`/`auth status`/`logout` subcommand — sign-in
/// happens inside its interactive TUI (`/auth`). So "Sign in" opens Terminal running `gemini`, and "connected"
/// comes from the worker's `status.engines[gemini].signedIn`, not from a local status probe.
pub const GEMINI: &str = "gemini";

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Writes a private `.command` script that runs the resolved `gemini` and opens it with Terminal.
pub fn gemini_terminal_script(exe: &Path, dir: &Path) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let script = dir.join("cfw-render-gemini-signin.command");
    std::fs::write(&script, format!("#!/bin/sh\nexec {}\n", sh_quote(&exe.display().to_string())))?;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700))?;
    Ok(script)
}

fn gemini_sign_in(emit: &dyn Fn(SigninEvent)) -> Result<(), SigninError> {
    let path = search_path();
    let exe = resolve(GEMINI, &path).ok_or_else(|| SigninError::NotInstalled(GEMINI.into()))?;
    let dir = tempfile_dir().map_err(|_| SigninError::Spawn(GEMINI.into()))?;
    let script = gemini_terminal_script(&exe, &dir).map_err(|_| SigninError::Spawn(GEMINI.into()))?;
    Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&script)
        .status()
        .map_err(|_| SigninError::Spawn(GEMINI.into()))?;
    emit(SigninEvent {
        engine: GEMINI.into(),
        state: SigninState::Cancelled,
        message: Some("Finish signing in to Gemini in the Terminal window (type /auth). It connects automatically.".into()),
    });
    Ok(())
}

fn tempfile_dir() -> std::io::Result<PathBuf> {
    let d = std::env::temp_dir().join(format!("cfw-render-{}", std::process::id()));
    std::fs::create_dir_all(&d)?;
    Ok(d)
}

pub fn provider_status(engine: &str) -> Result<bool, SigninError> {
    if engine == GEMINI {
        return Ok(false);
    }
    let cli = cli_for(engine)?;
    let path = search_path();
    Ok(resolve(cli.bin, &path).is_some_and(|exe| status_ok(&exe, &cli, &path)))
}

/// Start a background sign-in; a previous attempt for the same engine is cancelled first.
pub fn start_sign_in(engine: String, emit: impl Fn(SigninEvent) + Send + 'static) -> Result<(), SigninError> {
    if engine == GEMINI {
        return gemini_sign_in(&emit);
    }
    cli_for(&engine)?;
    let session = Session::default();
    if let Some(old) = sessions().lock().unwrap().insert(engine.clone(), session.clone()) {
        old.cancel();
    }
    std::thread::spawn(move || {
        let path = search_path();
        if let Err(e) = run_sign_in(&engine, &path, &session, SIGN_IN_TIMEOUT, POLL_INTERVAL, &emit) {
            emit(SigninEvent { engine: engine.clone(), state: SigninState::Failed, message: Some(e.to_string()) });
        }
        let mut map = sessions().lock().unwrap();
        if map.get(&engine).is_some_and(|s| Arc::ptr_eq(&s.cancel, &session.cancel)) {
            map.remove(&engine);
        }
    });
    Ok(())
}

pub fn cancel_sign_in(engine: &str) -> Result<(), SigninError> {
    if engine == GEMINI {
        return Ok(());
    }
    cli_for(engine)?;
    if let Some(s) = sessions().lock().unwrap().remove(engine) {
        s.cancel();
    }
    Ok(())
}

pub fn sign_out(engine: &str) -> Result<bool, SigninError> {
    if engine == GEMINI {
        return Err(SigninError::Spawn("gemini (sign out inside the Gemini CLI with /auth)".into()));
    }
    run_sign_out(engine, &search_path())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// Stub CLIs: `status` exits 1 until a marker exists; `login` creates it (or blocks if `block`).
    fn stubs(block: bool) -> (tempfile::TempDir, OsString) {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().display();
        let login = if block { "exec sleep 30".to_string() } else { format!("touch '{d}/M'") };
        let codex = format!(
            "#!/bin/sh\ncase \"$1 $2\" in\n\"login status\") [ -f '{d}/M' ];;\n\"login \") {login};;\n\"logout \") rm -f '{d}/M'; touch '{d}/OUT';;\nesac\n"
        );
        let claude = format!(
            "#!/bin/sh\n[ \"$1\" = auth ] || exit 2\ncase \"$2\" in\nstatus) [ -f '{d}/M' ];;\nlogin) {login};;\nlogout) rm -f '{d}/M'; touch '{d}/OUT';;\nesac\n"
        );
        for (n, s) in [("codex", codex), ("claude", claude)] {
            let p = dir.path().join(n);
            std::fs::write(&p, s).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = OsString::from(format!("{}:/bin:/usr/bin", dir.path().display()));
        (dir, path)
    }

    fn collect() -> (Arc<Mutex<Vec<SigninState>>>, impl Fn(SigninEvent)) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let l = log.clone();
        (log, move |e: SigninEvent| l.lock().unwrap().push(e.state))
    }

    const MS: Duration = Duration::from_millis(50);

    #[test]
    fn sign_in_succeeds_for_both() {
        for engine in ["codex", "claude-code"] {
            let (_d, path) = stubs(false);
            let (log, emit) = collect();
            let r = run_sign_in(engine, &path, &Session::default(), Duration::from_secs(10), MS, &emit);
            assert_eq!(r, Ok(SigninState::Connected), "{engine}");
            assert_eq!(*log.lock().unwrap(), vec![SigninState::Waiting, SigninState::Connected]);
        }
    }

    #[test]
    fn sign_in_times_out() {
        let (_d, path) = stubs(true);
        let (log, emit) = collect();
        let r = run_sign_in("codex", &path, &Session::default(), Duration::from_millis(300), MS, &emit);
        assert_eq!(r, Ok(SigninState::Timeout));
        assert_eq!(log.lock().unwrap().last(), Some(&SigninState::Timeout));
    }

    #[test]
    fn sign_in_cancel_kills_login() {
        let (_d, path) = stubs(true);
        let session = Session::default();
        let s2 = session.clone();
        let t = std::thread::spawn(move || {
            run_sign_in("claude-code", &path, &s2, Duration::from_secs(20), MS, &|_| {})
        });
        std::thread::sleep(Duration::from_millis(300));
        assert!(session.child.lock().unwrap().is_some());
        session.cancel();
        assert_eq!(t.join().unwrap(), Ok(SigninState::Cancelled));
        assert!(session.child.lock().unwrap().is_none());
    }

    #[test]
    fn unknown_engine_rejected() {
        let (_d, path) = stubs(false);
        let r = run_sign_in("nope", &path, &Session::default(), MS, MS, &|_| {});
        assert_eq!(r, Err(SigninError::UnknownEngine("nope".into())));
        assert!(run_sign_out("../codex", &path).is_err());
        assert!(cancel_sign_in("rm").is_err());
        assert!(start_sign_in("x".into(), |_| {}).is_err());
    }

    #[test]
    fn gemini_script_runs_quoted_cli() {
        let d = tempfile::tempdir().unwrap();
        let s = gemini_terminal_script(Path::new("/opt/it's/gemini"), d.path()).unwrap();
        assert_eq!(std::fs::read_to_string(&s).unwrap(), "#!/bin/sh\nexec '/opt/it'\\''s/gemini'\n");
        assert_eq!(std::fs::metadata(&s).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(provider_status(GEMINI), Ok(false));
        assert!(cancel_sign_in(GEMINI).is_ok());
    }

    #[test]
    fn missing_cli_is_not_installed() {
        let r = run_sign_in("codex", &OsString::from("/nonexistent"), &Session::default(), MS, MS, &|_| {});
        assert_eq!(r, Err(SigninError::NotInstalled("codex".into())));
    }

    #[test]
    fn sign_out_invokes_logout() {
        for engine in ["codex", "claude-code"] {
            let (d, path) = stubs(false);
            std::fs::write(d.path().join("M"), "").unwrap();
            assert_eq!(run_sign_out(engine, &path), Ok(true));
            assert!(d.path().join("OUT").exists());
            assert!(!d.path().join("M").exists());
        }
    }
}
