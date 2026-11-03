//! AI provider sign-in (D106). The app never reads, copies or writes the owner's `~/.codex/` or `~/.claude/`
//! and never runs its own OAuth. Each engine signs in the vendor's own way:
//!
//! - **Codex** uses the CLI's own login. The app spawns `codex login` and checks `codex login status` by
//!   exit code only.
//! - **Claude Code** is authenticated by a long-lived token. The app runs `claude setup-token`: the CLI opens
//!   the browser, serves its own OAuth callback and prints the token only after the owner approves. The app
//!   reads that output in memory and saves the token in the login Keychain (service `com.cfw.render`, account
//!   `claude-code`, through `apikeys`). The render worker reads the item and hands the token to each Claude
//!   step's environment only. The `setup-token` run gets a fresh private `CLAUDE_CONFIG_DIR` (0700, under the
//!   temp folder) that is deleted afterwards, so `~/.claude` is never read or written. "Signed in" means the
//!   Keychain item exists; sign-out deletes it. The token never goes on argv (the Keychain write uses stdin),
//!   into logs, events or return values.
//! - **Gemini** has no login command; sign-in happens in its own terminal UI (see below).
//!
//! A Codex login process owns the browser's OAuth callback port, so it is never killed while it is still
//! working: if the machine is already signed in, no login process is started at all; otherwise the login
//! runs until it exits by itself, the owner cancels, or the time limit passes. A process that is still
//! alive after status has passed for the `grace` period is stopped (the CLI sometimes lingers). The same
//! holds for `claude setup-token`: it is only stopped by Cancel or the time limit.

use std::collections::HashMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::apikeys;

pub const CLI_PATH_ENV: &str = "CFW_RENDER_CLI_PATH";
pub const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(300);
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);
/// How long a login process may keep running after status already passes before it is stopped.
pub const SIGN_IN_GRACE: Duration = Duration::from_secs(5);
/// Engine name that is authenticated by a long-lived token saved in the Keychain (not by a CLI login).
pub const CLAUDE_CODE: &str = "claude-code";

/// Shown when `claude setup-token` ended and its output held no token.
const NO_TOKEN: &str = "The sign-in ended without a token.";
/// Shown when the output held a token-shaped string the Keychain code would not store.
const BAD_TOKEN: &str = "The sign-in returned a token this app cannot store.";
/// How often the `setup-token` process is checked. In-process (`try_wait`), so it can be quick.
const TOKEN_POLL_MAX: Duration = Duration::from_millis(250);
/// After the process ends, how long to wait for the output readers to reach end-of-file.
const READER_WAIT: Duration = Duration::from_secs(2);
/// Most output kept from one pipe. The token is a few hundred bytes; the rest is read and dropped.
const CAPTURE_MAX: usize = 256 * 1024;

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum SigninError {
    #[error("unknown provider: {0}")]
    UnknownEngine(String),
    #[error("{0} is not installed on this computer")]
    NotInstalled(String),
    #[error("could not run {0}")]
    Spawn(String),
    #[error("could not create a private folder for the sign-in: {0}")]
    PrivateDir(String),
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

/// Allow-list of engines that sign in through their CLI's own login. Anything not here is rejected.
/// (Claude Code uses a Keychain token instead, see the module doc.)
pub fn cli_for(engine: &str) -> Result<Cli, SigninError> {
    match engine {
        "codex" => Ok(Cli { bin: "codex", login: &["login"], status: &["login", "status"], logout: &["logout"] }),
        other => Err(SigninError::UnknownEngine(other.to_string())),
    }
}

/// Every engine this module can sign in: the CLI-login engines and Claude Code.
fn check_engine(engine: &str) -> Result<(), SigninError> {
    if engine == CLAUDE_CODE {
        return Ok(());
    }
    cli_for(engine).map(|_| ())
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

/// Everything a sign-in needs besides the engine: where to find the CLIs, and the `security` executable that
/// owns the Keychain. Production code builds it with [`Env::system`]; tests build it by hand with stubs, so
/// they never set process-wide environment variables or touch the real Keychain.
#[derive(Debug, Clone)]
pub struct Env {
    pub path: OsString,
    pub security: OsString,
}

impl Env {
    pub fn system() -> Env {
        Env { path: search_path(), security: apikeys::security_exe() }
    }
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

/// One resolved CLI-login engine: its executable, its commands, and the PATH it runs with.
struct Tool<'a> {
    exe: PathBuf,
    cli: Cli,
    path: &'a OsString,
}

impl<'a> Tool<'a> {
    fn open(engine: &str, env: &'a Env) -> Result<Tool<'a>, SigninError> {
        let cli = cli_for(engine)?;
        let exe = resolve(cli.bin, &env.path).ok_or_else(|| SigninError::NotInstalled(cli.bin.into()))?;
        Ok(Tool { exe, cli, path: &env.path })
    }

    fn command(&self, args: &[&str]) -> Command {
        command(&self.exe, args, self.path)
    }

    fn status_ok(&self) -> bool {
        self.command(self.cli.status).status().is_ok_and(|s| s.success())
    }
}

/// The output pipes of a process started by [`Session::start`] (only the ones that were piped).
struct Pipes {
    out: Option<ChildStdout>,
    err: Option<ChildStderr>,
}

#[derive(Clone, Default)]
pub struct Session {
    cancel: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

enum ChildState {
    Running,
    Exited,
    /// Taken out of the session by `cancel`.
    Gone,
}

impl Session {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        self.stop_child();
    }

    /// Spawn the sign-in process and keep it in the session, unless the sign-in was cancelled first (then
    /// `Ok(None)`: nothing was started, so no browser opens). The cancel check, the spawn and the store all
    /// happen under the child lock, and `cancel` takes that lock after it sets its flag, so a cancel can never
    /// slip in between and leave a process running.
    fn start(&self, spawn: impl FnOnce() -> std::io::Result<Child>) -> std::io::Result<Option<Pipes>> {
        let mut slot = self.child.lock().unwrap();
        if self.cancel.load(Ordering::SeqCst) {
            return Ok(None);
        }
        let mut child = spawn()?;
        let pipes = Pipes { out: child.stdout.take(), err: child.stderr.take() };
        *slot = Some(child);
        Ok(Some(pipes))
    }

    fn stop_child(&self) {
        if let Some(mut c) = self.child.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    fn child_state(&self) -> ChildState {
        match self.child.lock().unwrap().as_mut() {
            None => ChildState::Gone,
            Some(c) => match c.try_wait() {
                Ok(None) => ChildState::Running,
                _ => ChildState::Exited,
            },
        }
    }
}

fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    static S: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// Blocking sign-in. Emits one terminal event, preceded by `waiting` when a sign-in process was started.
///
/// - Already signed in (Codex: status passes; Claude Code: the Keychain item exists): emits `connected` and
///   returns. Nothing is started.
/// - Cancelled before the process starts (for example during that check): emits `cancelled`. Nothing is started.
/// - Codex: the login process is left alone while it works. The sign-in ends when the owner cancels
///   (`cancelled`); the process exits (`connected` if status passes now, else `failed`); status has passed for
///   `grace` while the process still runs (the process is stopped, `connected`); or `timeout` passes (the
///   process is stopped, `timeout`).
/// - Claude Code: see [`run_claude_sign_in`]. `grace` does not apply.
pub fn run_sign_in(
    engine: &str,
    env: &Env,
    session: &Session,
    timeout: Duration,
    interval: Duration,
    grace: Duration,
    emit: &dyn Fn(SigninEvent),
) -> Result<SigninState, SigninError> {
    if engine == CLAUDE_CODE {
        return run_claude_sign_in(env, session, timeout, interval, emit);
    }
    let tool = Tool::open(engine, env)?;
    let ev = |state, message: Option<String>| emit(SigninEvent { engine: engine.to_string(), state, message });
    if tool.status_ok() {
        ev(SigninState::Connected, None);
        return Ok(SigninState::Connected);
    }
    // The status check can take a while. A Cancel (or a second Sign in) that arrived meanwhile must not open a browser.
    let started = session
        .start(|| tool.command(tool.cli.login).spawn())
        .map_err(|_| SigninError::Spawn(tool.cli.bin.into()))?;
    if started.is_none() {
        ev(SigninState::Cancelled, None);
        return Ok(SigninState::Cancelled);
    }
    ev(SigninState::Waiting, None);
    let start = Instant::now();
    let mut connected_since: Option<Instant> = None;
    let (state, message) = loop {
        if session.cancel.load(Ordering::SeqCst) {
            break (SigninState::Cancelled, None);
        }
        match session.child_state() {
            ChildState::Gone => break (SigninState::Cancelled, None),
            ChildState::Exited if tool.status_ok() => break (SigninState::Connected, None),
            ChildState::Exited => {
                break (SigninState::Failed, Some("The sign-in ended before it connected.".to_string()));
            }
            ChildState::Running => {}
        }
        if tool.status_ok() {
            let since = *connected_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= grace {
                break (SigninState::Connected, None);
            }
        }
        if start.elapsed() >= timeout {
            break (SigninState::Timeout, None);
        }
        std::thread::sleep(interval);
    };
    session.stop_child();
    ev(state, message);
    Ok(state)
}

/// A fresh private folder (0700) under the temp folder, removed with everything in it when dropped. It is the
/// `CLAUDE_CONFIG_DIR` of one `claude setup-token` run, so the CLI never touches `~/.claude`.
struct PrivateDir(PathBuf);

impl PrivateDir {
    fn create() -> std::io::Result<PrivateDir> {
        use std::os::unix::fs::DirBuilderExt;
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or_default();
        let name = format!(
            "cfw-render-{}-{}-{nanos}-claude-token",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        );
        let path = std::env::temp_dir().join(name);
        // Not `create_dir_all`: an existing folder (or link) at this path is an error, never reused.
        std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(PrivateDir(path))
    }
}

impl Drop for PrivateDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Reads one pipe of the `setup-token` process into memory on its own thread (so a full pipe never blocks the
/// process). Keeps at most `CAPTURE_MAX` bytes and drops the rest.
struct Capture {
    buf: Arc<Mutex<Vec<u8>>>,
    reader: std::thread::JoinHandle<()>,
}

impl Capture {
    fn start(mut pipe: impl Read + Send + 'static) -> Capture {
        let buf = Arc::new(Mutex::new(Vec::new()));
        let sink = buf.clone();
        let reader = std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        let mut v = sink.lock().unwrap();
                        let room = CAPTURE_MAX.saturating_sub(v.len());
                        v.extend_from_slice(&chunk[..n.min(room)]);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        });
        Capture { buf, reader }
    }

    /// What was read, once the reader reached end-of-file or `wait` has passed. A leftover process that still
    /// holds the pipe open cannot hang the sign-in: the reader is left behind and ends when the pipe closes.
    fn finish(self, wait: Duration) -> Vec<u8> {
        let end = Instant::now() + wait;
        while !self.reader.is_finished() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        self.buf.lock().unwrap().clone()
    }
}

/// The first Claude OAuth token in `output`: `sk-ant-oat01-` followed by at least 20 token characters.
fn extract_token(output: &str) -> Option<&str> {
    static RX: OnceLock<regex::Regex> = OnceLock::new();
    let rx = RX.get_or_init(|| regex::Regex::new(r"sk-ant-oat01-[A-Za-z0-9_-]{20,}").expect("token regex"));
    rx.find(output).map(|m| m.as_str())
}

/// Claude Code is signed in when its token is in the Keychain.
fn token_saved(env: &Env) -> Result<bool, SigninError> {
    apikeys::present_with(&env.security, CLAUDE_CODE).map_err(|_| SigninError::Spawn("security".into()))
}

/// Turn the output of an ended `setup-token` run into the terminal state: save the token it printed, or fail.
/// Neither the token nor any text of the output goes into the message.
fn save_printed_token(env: &Env, out: Option<Capture>, err: Option<Capture>) -> (SigninState, Option<String>) {
    let mut bytes = Vec::new();
    for capture in [out, err].into_iter().flatten() {
        bytes.extend(capture.finish(READER_WAIT));
        bytes.push(b'\n');
    }
    let text = String::from_utf8_lossy(&bytes);
    let Some(token) = extract_token(&text) else {
        return (SigninState::Failed, Some(NO_TOKEN.to_string()));
    };
    if !apikeys::valid_key(token) {
        return (SigninState::Failed, Some(BAD_TOKEN.to_string()));
    }
    match apikeys::save_with(&env.security, CLAUDE_CODE, token) {
        Ok(()) => (SigninState::Connected, None),
        Err(e) => (SigninState::Failed, Some(e)),
    }
}

/// Claude Code sign-in with a long-lived token (blocking). Emits one terminal event, preceded by `waiting`
/// once `claude setup-token` runs.
///
/// - The Keychain item already exists: `connected`; nothing is started.
/// - Otherwise `claude setup-token` runs with the minimal environment plus a fresh private `CLAUDE_CONFIG_DIR`
///   (deleted at the end), no stdin, and both output pipes read into memory. It lives in the session, so Cancel
///   stops it. When it exits, the first token in its output is saved to the Keychain (`connected`); no token
///   or an unusable one is `failed`; a Keychain error is `failed` with that error. Cancel is `cancelled`.
///   `timeout` passing stops the process (`timeout`).
fn run_claude_sign_in(
    env: &Env,
    session: &Session,
    timeout: Duration,
    interval: Duration,
    emit: &dyn Fn(SigninEvent),
) -> Result<SigninState, SigninError> {
    let ev = |state, message: Option<String>| emit(SigninEvent { engine: CLAUDE_CODE.to_string(), state, message });
    if token_saved(env)? {
        ev(SigninState::Connected, None);
        return Ok(SigninState::Connected);
    }
    let exe = resolve("claude", &env.path).ok_or_else(|| SigninError::NotInstalled("claude".into()))?;
    let dir = PrivateDir::create().map_err(|e| SigninError::PrivateDir(e.to_string()))?;
    let mut cmd = command(&exe, &["setup-token"], &env.path);
    // The only addition to the minimal environment: a throwaway config folder, so `~/.claude` stays untouched.
    cmd.env("CLAUDE_CONFIG_DIR", &dir.0).stdout(Stdio::piped()).stderr(Stdio::piped());
    // As for Codex: a Cancel that arrived during the Keychain check must not open a browser.
    let Some(pipes) = session.start(|| cmd.spawn()).map_err(|_| SigninError::Spawn("claude".into()))? else {
        ev(SigninState::Cancelled, None);
        return Ok(SigninState::Cancelled);
    };
    let out = pipes.out.map(Capture::start);
    let err = pipes.err.map(Capture::start);
    ev(SigninState::Waiting, None);
    let start = Instant::now();
    let poll = interval.min(TOKEN_POLL_MAX);
    let (state, message) = loop {
        if session.cancel.load(Ordering::SeqCst) {
            break (SigninState::Cancelled, None);
        }
        match session.child_state() {
            ChildState::Gone => break (SigninState::Cancelled, None),
            ChildState::Exited => break save_printed_token(env, out, err),
            ChildState::Running => {}
        }
        if start.elapsed() >= timeout {
            break (SigninState::Timeout, None);
        }
        std::thread::sleep(poll);
    };
    session.stop_child();
    drop(dir);
    ev(state, message);
    Ok(state)
}

/// Sign out. Codex runs its CLI's `logout`; Claude Code deletes its Keychain item. Returns whether the
/// engine is signed out afterwards (Claude Code) or whether the CLI succeeded (Codex).
pub fn run_sign_out(engine: &str, env: &Env) -> Result<bool, SigninError> {
    if engine == CLAUDE_CODE {
        apikeys::remove_with(&env.security, CLAUDE_CODE).map_err(|_| SigninError::Spawn("security".into()))?;
        return Ok(!token_saved(env)?);
    }
    let tool = Tool::open(engine, env)?;
    tool.command(tool.cli.logout).status().map(|s| s.success()).map_err(|_| SigninError::Spawn(tool.cli.bin.into()))
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

/// Is `engine` signed in? Claude Code: its Keychain item exists. Codex: its CLI's status passes.
pub fn provider_status(engine: &str) -> Result<bool, SigninError> {
    if engine == GEMINI {
        return Ok(false);
    }
    provider_status_in(engine, &Env::system())
}

fn provider_status_in(engine: &str, env: &Env) -> Result<bool, SigninError> {
    if engine == CLAUDE_CODE {
        return token_saved(env);
    }
    match Tool::open(engine, env) {
        Ok(tool) => Ok(tool.status_ok()),
        Err(SigninError::NotInstalled(_)) => Ok(false),
        Err(e) => Err(e),
    }
}

/// Start a background sign-in; a previous attempt for the same engine is cancelled first.
pub fn start_sign_in(engine: String, emit: impl Fn(SigninEvent) + Send + 'static) -> Result<(), SigninError> {
    if engine == GEMINI {
        return gemini_sign_in(&emit);
    }
    check_engine(&engine)?;
    let session = Session::default();
    if let Some(old) = sessions().lock().unwrap().insert(engine.clone(), session.clone()) {
        old.cancel();
    }
    std::thread::spawn(move || {
        let env = Env::system();
        if let Err(e) = run_sign_in(&engine, &env, &session, SIGN_IN_TIMEOUT, POLL_INTERVAL, SIGN_IN_GRACE, &emit) {
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
    check_engine(engine)?;
    if let Some(s) = sessions().lock().unwrap().remove(engine) {
        s.cancel();
    }
    Ok(())
}

pub fn sign_out(engine: &str) -> Result<bool, SigninError> {
    if engine == GEMINI {
        return Err(SigninError::Spawn("gemini (sign out inside the Gemini CLI with /auth)".into()));
    }
    run_sign_out(engine, &Env::system())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const MS: Duration = Duration::from_millis(50);
    /// A timeout or grace that must never end a test by itself. Generous: the bound suite runs these tests
    /// beside a 60-minute bash suite, where a stub process can take seconds to start.
    const LONG: Duration = Duration::from_secs(120);
    /// How long a sign-in that ends by the process exiting may take under that load (below LONG, so a
    /// run that only ended because the timeout fired still fails the bound).
    const LOAD: Duration = Duration::from_secs(90);
    /// 13-character prefix + 30 token characters.
    const TOKEN: &str = "sk-ant-oat01-TESTTOKEN0123456789abcdefXYZ_-";

    /// What the stub `codex login` does. `M` is the "signed in" marker the stub `status` looks for; `PID` is
    /// written by the stubs that hang, so a test can tell whether the process is gone.
    #[derive(Clone, Copy)]
    enum Login {
        /// Create M and exit at once.
        Marker,
        /// Create M, work for a moment, create D, exit by itself (D proves it was not killed early).
        MarkerSlow,
        /// Create M, then keep running (the CLI lingering after it signed in).
        MarkerThenHang,
        /// Exit 1 without creating M.
        Fail,
        /// Keep running without creating M (the owner never finishes in the browser).
        Hang,
    }

    impl Login {
        fn body(self) -> &'static str {
            match self {
                Login::Marker => "touch '@D@/M'",
                Login::MarkerSlow => "touch '@D@/M'; sleep 0.4; touch '@D@/D'",
                Login::MarkerThenHang => "touch '@D@/M'; echo $$ > '@D@/PID'; exec sleep 30",
                Login::Fail => "exit 1",
                Login::Hang => "echo $$ > '@D@/PID'; exec sleep 30",
            }
        }
    }

    /// What the stub `claude setup-token` does after it recorded its environment.
    #[derive(Clone, Copy)]
    enum Setup {
        /// Two banner lines (one per pipe), then the token line, then exit 0 -- the approved sign-in.
        Token,
        /// Banner lines, exit 1, no token.
        Fail,
        /// Banner lines, exit 0, no token.
        NoToken,
        /// A token-looking string that is far too long to store.
        BadToken,
        /// Keep running without printing anything (the owner never approves in the browser).
        Hang,
    }

    impl Setup {
        fn body(self) -> &'static str {
            match self {
                Setup::Token => {
                    "sleep 0.3; echo 'Opening your browser to sign in...'; echo 'Waiting for approval...' >&2; \
                     echo 'Your token:'; echo '@TOKEN@'; echo 'Store it somewhere safe.'; exit 0"
                }
                Setup::Fail => "echo 'Opening your browser to sign in...'; echo 'Sign-in failed.' >&2; exit 1",
                Setup::NoToken => "echo 'Opening your browser to sign in...'; echo 'Done.' >&2; exit 0",
                Setup::BadToken => "printf 'sk-ant-oat01-%0400d\\n' 7; exit 0",
                Setup::Hang => "echo $$ > '@D@/PID'; exec sleep 30",
            }
        }
    }

    /// Every call appends `"$1 $2"` to LOG. `SLOWCHECK` makes the status check take a while.
    const CODEX_STUB: &str = r#"#!/bin/sh
echo "$1 $2" >> '@D@/LOG'
case "$1 $2" in
"login status") [ -f '@D@/SLOWCHECK' ] && sleep 0.6; [ -f '@D@/M' ];;
"login ") @LOGIN@;;
"logout ") rm -f '@D@/M'; touch '@D@/OUT';;
esac
"#;

    /// Every call appends its first argument to CALLS. `setup-token` records the folder it was given, that
    /// folder's listing (mode), HOME, and the NAMES of its environment variables, then does `@SETUP@`.
    const CLAUDE_STUB: &str = r#"#!/bin/sh
echo "$1" >> '@D@/CALLS'
[ "$1" = setup-token ] || exit 2
echo "$CLAUDE_CONFIG_DIR" > '@D@/CFGDIR'
ls -ld "$CLAUDE_CONFIG_DIR" > '@D@/CFGLS'
echo "$HOME" > '@D@/HOMEV'
env | sed 's/=.*//' | sort > '@D@/ENVNAMES'
@SETUP@
"#;

    /// Stub `security`: argv to SECARGV, stdin of `-i` to SECSTDIN, and a fake store of one file per account
    /// holding what `-w` was given. `SAVEFAILS` makes `-i` fail; `SLOWCHECK` makes every call slow.
    const SECURITY_STUB: &str = r#"#!/bin/sh
echo "$@" >> '@D@/SECARGV'
[ -f '@D@/SLOWCHECK' ] && sleep 0.6
case "$1" in
-i)
  if [ -f '@D@/SAVEFAILS' ]; then cat > /dev/null; exit 1; fi
  cat >> '@D@/SECSTDIN'
  acct=$(tail -n1 '@D@/SECSTDIN' | sed 's/.* -a \([^ ]*\) .*/\1/')
  tail -n1 '@D@/SECSTDIN' | sed 's/.* -w //' > "@D@/store-$acct";;
find-generic-password) [ -f "@D@/store-$5" ];;
delete-generic-password) rm -f "@D@/store-$5";;
esac
"#;

    /// Stub `codex`, `claude` and `security` in a temp dir, plus an `Env` that points at them.
    struct Fx {
        dir: tempfile::TempDir,
        env: Env,
    }

    impl Fx {
        fn new(login: Login, setup: Setup) -> Fx {
            let dir = tempfile::tempdir().unwrap();
            let d = dir.path().display().to_string();
            for (name, template) in [("codex", CODEX_STUB), ("claude", CLAUDE_STUB), ("security", SECURITY_STUB)] {
                let script = template
                    .replace("@LOGIN@", login.body())
                    .replace("@SETUP@", setup.body())
                    .replace("@TOKEN@", TOKEN)
                    .replace("@D@", &d);
                let p = dir.path().join(name);
                std::fs::write(&p, script).unwrap();
                std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let env = Env { path: OsString::from(format!("{d}:/bin:/usr/bin")), security: dir.path().join("security").into() };
            Fx { dir, env }
        }

        fn codex(login: Login) -> Fx {
            Fx::new(login, Setup::Token)
        }

        fn claude(setup: Setup) -> Fx {
            Fx::new(Login::Marker, setup)
        }

        fn file(&self, name: &str) -> String {
            std::fs::read_to_string(self.dir.path().join(name)).unwrap_or_default()
        }

        fn touch(&self, name: &str) {
            std::fs::write(self.dir.path().join(name), "").unwrap();
        }

        fn exists(&self, name: &str) -> bool {
            self.dir.path().join(name).exists()
        }

        /// Everything the codex stub was asked.
        fn log(&self) -> String {
            self.file("LOG")
        }

        /// How many times `codex login` was started.
        fn logins(&self) -> usize {
            self.log().lines().filter(|l| *l == "login ").count()
        }

        /// How many times `claude setup-token` was started (and whether anything else was run).
        fn setups(&self) -> usize {
            self.file("CALLS").lines().filter(|l| *l == "setup-token").count()
        }

        /// Is the Claude token in the stubbed Keychain? Returns it.
        fn stored_token(&self) -> Option<String> {
            self.exists("store-claude-code").then(|| self.file("store-claude-code").trim().to_string())
        }

        /// The throwaway `CLAUDE_CONFIG_DIR` the stub `setup-token` was given.
        fn config_dir(&self) -> PathBuf {
            PathBuf::from(self.file("CFGDIR").trim())
        }

        /// Is the hanging stub's process still running? Call only after `run_sign_in` returned: it kills and
        /// reaps its child, so a stub that never got to write its pid is dead too.
        fn pid_alive(&self) -> bool {
            let Ok(pid) = std::fs::read_to_string(self.dir.path().join("PID")) else { return false };
            Command::new("/bin/sh").args(["-c", "kill -0 \"$0\" 2>/dev/null", pid.trim()]).status().unwrap().success()
        }

        fn wait_for(&self, what: &str, ready: impl Fn() -> bool) {
            let deadline = Instant::now() + LOAD;
            while !ready() {
                assert!(Instant::now() < deadline, "never happened: {what}");
                std::thread::sleep(MS);
            }
        }

        fn sign_in(&self, engine: &str, timeout: Duration, grace: Duration) -> Run {
            let events = Arc::new(Mutex::new(Vec::new()));
            let e2 = events.clone();
            let start = Instant::now();
            let result = run_sign_in(engine, &self.env, &Session::default(), timeout, MS, grace, &move |e| {
                e2.lock().unwrap().push(e)
            });
            let events = events.lock().unwrap().clone();
            Run { result, events, elapsed: start.elapsed() }
        }

        /// Run a sign-in on its own thread under `session`; the events are collected as they come.
        fn sign_in_in_background(&self, engine: &'static str, session: &Session, timeout: Duration) -> Background {
            let events = Arc::new(Mutex::new(Vec::new()));
            let (e2, env, s2) = (events.clone(), self.env.clone(), session.clone());
            let thread = std::thread::spawn(move || {
                run_sign_in(engine, &env, &s2, timeout, MS, LONG, &move |e| e2.lock().unwrap().push(e))
            });
            Background { thread, events }
        }
    }

    struct Run {
        result: Result<SigninState, SigninError>,
        events: Vec<SigninEvent>,
        elapsed: Duration,
    }

    impl Run {
        fn states(&self) -> Vec<SigninState> {
            self.events.iter().map(|e| e.state).collect()
        }

        /// Every event as the JSON the front end receives.
        fn json(&self) -> String {
            self.events.iter().map(|e| serde_json::to_string(e).unwrap()).collect::<Vec<_>>().join("\n")
        }
    }

    struct Background {
        thread: std::thread::JoinHandle<Result<SigninState, SigninError>>,
        events: Arc<Mutex<Vec<SigninEvent>>>,
    }

    impl Background {
        fn finish(self) -> Run {
            let start = Instant::now();
            let result = self.thread.join().unwrap();
            let events = self.events.lock().unwrap().clone();
            Run { result, events, elapsed: start.elapsed() }
        }
    }

    fn started(session: &Session) -> bool {
        session.child.lock().unwrap().is_some()
    }

    use SigninState::{Cancelled, Connected, Failed, Timeout, Waiting};

    // ---- Codex: the CLI's own login ----

    #[test]
    fn codex_already_signed_in_connects_without_starting_a_login() {
        let fx = Fx::codex(Login::Hang);
        fx.touch("M");
        let run = fx.sign_in("codex", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Connected]);
        assert_eq!(run.events[0].engine, "codex");
        assert_eq!(run.events[0].message, None);
        assert_eq!(fx.logins(), 0, "a login was started: {}", fx.log());
        assert!(fx.log().contains("login status"), "status was never asked");
        assert!(!fx.exists("PID"), "a login process ran");
    }

    #[test]
    fn codex_login_that_exits_by_itself_is_never_killed_early() {
        let fx = Fx::codex(Login::MarkerSlow);
        // A long grace: only the process exiting on its own can end this sign-in.
        let run = fx.sign_in("codex", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert!(fx.exists("D"), "the login was cut off before it finished");
        assert_eq!(fx.logins(), 1);
        assert!(run.elapsed < LOAD);
    }

    #[test]
    fn codex_login_that_exits_at_once_connects() {
        let fx = Fx::codex(Login::Marker);
        let run = fx.sign_in("codex", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert_eq!(fx.logins(), 1);
    }

    #[test]
    fn codex_lingering_login_is_stopped_only_after_the_grace_period() {
        let fx = Fx::codex(Login::MarkerThenHang);
        let grace = Duration::from_millis(400);
        let run = fx.sign_in("codex", LONG, grace);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert!(run.elapsed >= grace, "stopped the login after {:?}, before the grace", run.elapsed);
        assert!(run.elapsed < LOAD, "took {:?}", run.elapsed);
        assert!(!fx.pid_alive(), "the login process is still running");
    }

    #[test]
    fn codex_login_that_ends_without_signing_in_fails() {
        let fx = Fx::codex(Login::Fail);
        let run = fx.sign_in("codex", LONG, LONG);
        assert_eq!(run.result, Ok(Failed));
        assert_eq!(run.states(), vec![Waiting, Failed]);
        assert_eq!(run.events[1].message.as_deref(), Some("The sign-in ended before it connected."));
        assert_eq!(fx.logins(), 1);
        assert!(run.elapsed < LOAD);
    }

    #[test]
    fn codex_sign_in_times_out_and_stops_the_login() {
        let fx = Fx::codex(Login::Hang);
        let run = fx.sign_in("codex", Duration::from_millis(300), LONG);
        assert_eq!(run.result, Ok(Timeout));
        assert_eq!(run.states(), vec![Waiting, Timeout]);
        assert!(!fx.pid_alive(), "the login process is still running");
    }

    #[test]
    fn codex_cancel_kills_the_login() {
        let fx = Fx::codex(Login::Hang);
        let session = Session::default();
        let bg = fx.sign_in_in_background("codex", &session, LONG);
        // Wait (the machine may be busy) until the login process is running under the session.
        fx.wait_for("the login process started", || started(&session) && fx.exists("PID"));
        std::thread::sleep(Duration::from_millis(200));
        assert!(started(&session), "the sign-in let go of the login by itself");
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert_eq!(run.states(), vec![Waiting, Cancelled]);
        assert!(session.child.lock().unwrap().is_none());
        assert!(!fx.pid_alive(), "the login process is still running");
    }

    #[test]
    fn codex_cancel_during_the_status_check_starts_no_login() {
        let fx = Fx::codex(Login::Hang);
        fx.touch("SLOWCHECK");
        let session = Session::default();
        let bg = fx.sign_in_in_background("codex", &session, LONG);
        // The status check is under way (and slow); the owner cancels (or signs in again) meanwhile.
        fx.wait_for("the status check started", || fx.log().contains("login status"));
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert_eq!(run.states(), vec![Cancelled]);
        assert_eq!(fx.logins(), 0, "a login was started after the cancel: {}", fx.log());
        assert!(!fx.exists("PID"), "a login process ran");
        assert!(!started(&session));
    }

    #[test]
    fn codex_sign_out_runs_the_cli_logout_and_status_follows_the_cli() {
        let fx = Fx::codex(Login::Marker);
        assert_eq!(provider_status_in("codex", &fx.env), Ok(false));
        fx.touch("M");
        assert_eq!(provider_status_in("codex", &fx.env), Ok(true));
        assert_eq!(run_sign_out("codex", &fx.env), Ok(true));
        assert!(fx.exists("OUT"));
        assert!(!fx.exists("M"));
        assert_eq!(provider_status_in("codex", &fx.env), Ok(false));
        assert!(!fx.exists("SECARGV"), "codex touched the Keychain");
    }

    // ---- Claude Code: a long-lived token in the Keychain ----

    #[test]
    fn claude_token_is_saved_and_connects() {
        let fx = Fx::claude(Setup::Token);
        let home = std::env::var("HOME").unwrap_or_default();
        assert_eq!(provider_status_in("claude-code", &fx.env), Ok(false));
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert!(run.events.iter().all(|e| e.engine == "claude-code" && e.message.is_none()), "{:?}", run.events);
        assert!(run.elapsed >= Duration::from_millis(250), "connected before the process finished: {:?}", run.elapsed);

        // The stubbed Keychain holds the token; nothing else saw it.
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert_eq!(provider_status_in("claude-code", &fx.env), Ok(true));
        let seen = format!("{}\n{}\n{}", run.json(), fx.file("SECARGV"), fx.file("CALLS"));
        assert!(!seen.contains("sk-ant") && !seen.contains("TESTTOKEN"), "the token leaked:\n{seen}");
        assert!(fx.file("SECSTDIN").contains("-s com.cfw.render -a claude-code -w sk-ant-oat01-"), "saved on stdin");

        // Only `setup-token` ran: no `auth login`, `auth status` or `auth logout`.
        assert_eq!(fx.file("CALLS"), "setup-token\n");

        // It ran in a throwaway folder under the temp dir: private while it ran, gone afterwards, never ~/.claude.
        let cfg = fx.config_dir();
        assert!(cfg.starts_with(std::env::temp_dir()), "{cfg:?} is not under {:?}", std::env::temp_dir());
        assert!(cfg.to_string_lossy().ends_with("-claude-token"), "{cfg:?}");
        assert!(!home.is_empty() && !cfg.starts_with(Path::new(&home).join(".claude")), "{cfg:?} is inside ~/.claude");
        assert_ne!(cfg, Path::new(&home).join(".claude"));
        assert!(fx.file("CFGLS").starts_with("drwx------"), "folder was not private: {}", fx.file("CFGLS"));
        assert!(!cfg.exists(), "the throwaway folder was left behind: {cfg:?}");
        // HOME is still passed (the CLI needs it); only the config folder points elsewhere.
        assert_eq!(fx.file("HOMEV").trim(), home);
    }

    #[test]
    fn claude_setup_token_gets_the_minimal_environment_plus_its_folder() {
        let fx = Fx::claude(Setup::Token);
        assert_eq!(fx.sign_in("claude-code", LONG, LONG).result, Ok(Connected));
        let names: Vec<String> = fx.file("ENVNAMES").lines().map(str::to_string).collect();
        for needed in ["PATH", "HOME", "CLAUDE_CONFIG_DIR"] {
            assert!(names.iter().any(|n| n == needed), "{needed} missing from {names:?}");
        }
        for n in &names {
            let up = n.to_uppercase();
            let secretish = ["TOKEN", "KEY", "SECRET", "ANTHROPIC", "CFW", "CLAUDE_CODE"].iter().any(|s| up.contains(s));
            assert!(!secretish || n == "CLAUDE_CONFIG_DIR", "unexpected variable {n} in {names:?}");
        }
    }

    #[test]
    fn claude_already_saved_connects_without_running_setup_token() {
        let fx = Fx::claude(Setup::Hang);
        fx.touch("store-claude-code");
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Connected]);
        assert_eq!(run.events[0].message, None);
        assert_eq!(fx.setups(), 0);
        assert_eq!(fx.file("CALLS"), "", "the claude CLI was run");
        assert!(!fx.exists("PID"));
        assert!(!fx.exists("SECSTDIN"), "something was saved");
    }

    #[test]
    fn claude_setup_token_that_ends_without_a_token_fails() {
        for setup in [Setup::Fail, Setup::NoToken] {
            let fx = Fx::claude(setup);
            let run = fx.sign_in("claude-code", LONG, LONG);
            assert_eq!(run.result, Ok(Failed));
            assert_eq!(run.states(), vec![Waiting, Failed]);
            assert_eq!(run.events[1].message.as_deref(), Some("The sign-in ended without a token."));
            assert_eq!(fx.setups(), 1);
            assert_eq!(fx.stored_token(), None);
            assert_eq!(provider_status_in("claude-code", &fx.env), Ok(false));
            assert!(!fx.config_dir().exists(), "the throwaway folder was left behind");
        }
    }

    #[test]
    fn claude_unusable_token_fails_and_saves_nothing() {
        let fx = Fx::claude(Setup::BadToken);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Failed));
        assert_eq!(run.states(), vec![Waiting, Failed]);
        assert_eq!(run.events[1].message.as_deref(), Some("The sign-in returned a token this app cannot store."));
        assert!(!run.json().contains("sk-ant"), "the output leaked into an event");
        assert!(!fx.exists("SECSTDIN"), "something was saved");
        assert!(!fx.config_dir().exists());
    }

    #[test]
    fn claude_keychain_error_fails_with_its_text_and_no_token() {
        let fx = Fx::claude(Setup::Token);
        fx.touch("SAVEFAILS");
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Failed));
        assert_eq!(run.states(), vec![Waiting, Failed]);
        assert_eq!(run.events[1].message.as_deref(), Some("Couldn't save the key to the Keychain."));
        let seen = format!("{}\n{}", run.json(), fx.file("SECARGV"));
        assert!(!seen.contains("sk-ant") && !seen.contains("TESTTOKEN"), "the token leaked:\n{seen}");
        assert_eq!(fx.stored_token(), None);
        assert!(!fx.config_dir().exists());
    }

    #[test]
    fn claude_cancel_kills_setup_token_and_removes_its_folder() {
        let fx = Fx::claude(Setup::Hang);
        let session = Session::default();
        let bg = fx.sign_in_in_background("claude-code", &session, LONG);
        fx.wait_for("setup-token is running", || started(&session) && fx.exists("PID"));
        let cfg = fx.config_dir();
        assert!(cfg.exists(), "no folder while setup-token runs");
        std::thread::sleep(Duration::from_millis(200));
        assert!(started(&session), "the sign-in let go of setup-token by itself");
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert_eq!(run.states(), vec![Waiting, Cancelled]);
        assert!(session.child.lock().unwrap().is_none());
        assert!(!fx.pid_alive(), "setup-token is still running");
        assert!(!cfg.exists(), "the throwaway folder was left behind");
        assert_eq!(fx.stored_token(), None);
    }

    #[test]
    fn claude_sign_in_times_out_and_stops_setup_token() {
        let fx = Fx::claude(Setup::Hang);
        let run = fx.sign_in("claude-code", Duration::from_millis(400), LONG);
        assert_eq!(run.result, Ok(Timeout));
        assert_eq!(run.states(), vec![Waiting, Timeout]);
        assert!(!fx.pid_alive(), "setup-token is still running");
        assert!(!fx.config_dir().exists(), "the throwaway folder was left behind");
        assert_eq!(fx.stored_token(), None);
    }

    #[test]
    fn claude_cancel_during_the_keychain_check_starts_nothing() {
        let fx = Fx::claude(Setup::Hang);
        fx.touch("SLOWCHECK");
        let session = Session::default();
        let bg = fx.sign_in_in_background("claude-code", &session, LONG);
        fx.wait_for("the Keychain check started", || fx.exists("SECARGV"));
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert_eq!(run.states(), vec![Cancelled]);
        assert_eq!(fx.file("CALLS"), "", "setup-token was started after the cancel");
        assert!(!started(&session));
    }

    #[test]
    fn claude_status_follows_the_keychain_item_and_sign_out_deletes_it() {
        let fx = Fx::claude(Setup::Token);
        assert_eq!(provider_status_in("claude-code", &fx.env), Ok(false));
        assert_eq!(fx.sign_in("claude-code", LONG, LONG).result, Ok(Connected));
        assert_eq!(provider_status_in("claude-code", &fx.env), Ok(true));
        assert_eq!(run_sign_out("claude-code", &fx.env), Ok(true));
        assert_eq!(fx.stored_token(), None);
        assert_eq!(provider_status_in("claude-code", &fx.env), Ok(false));
        // Signing out when nothing is saved is fine, and it never runs the CLI (no `claude auth logout`).
        assert_eq!(run_sign_out("claude-code", &fx.env), Ok(true));
        assert_eq!(fx.file("CALLS"), "setup-token\n");
        assert!(fx.file("SECARGV").contains("delete-generic-password -s com.cfw.render -a claude-code"));
    }

    #[test]
    fn claude_status_and_sign_out_do_not_need_the_cli() {
        let fx = Fx::claude(Setup::Token);
        let env = Env { path: OsString::from("/nonexistent"), ..fx.env.clone() };
        fx.touch("store-claude-code");
        assert_eq!(provider_status_in("claude-code", &env), Ok(true));
        assert_eq!(run_sign_out("claude-code", &env), Ok(true));
        assert_eq!(provider_status_in("claude-code", &env), Ok(false));
    }

    #[test]
    fn claude_is_not_a_cli_login_engine() {
        assert!(matches!(cli_for("claude-code"), Err(SigninError::UnknownEngine(e)) if e == "claude-code"));
        assert!(cli_for("codex").is_ok());
        // ...but it is a valid engine to sign in, and to cancel.
        assert!(check_engine("claude-code").is_ok());
        assert!(cancel_sign_in("claude-code").is_ok());
    }

    #[test]
    fn missing_cli_is_not_installed() {
        let fx = Fx::new(Login::Marker, Setup::Token);
        let env = Env { path: OsString::from("/nonexistent"), ..fx.env.clone() };
        let r = run_sign_in("codex", &env, &Session::default(), MS, MS, MS, &|_| {});
        assert_eq!(r, Err(SigninError::NotInstalled("codex".into())));
        let r = run_sign_in("claude-code", &env, &Session::default(), MS, MS, MS, &|_| {});
        assert_eq!(r, Err(SigninError::NotInstalled("claude".into())));
        assert_eq!(provider_status_in("codex", &env), Ok(false));
        assert_eq!(provider_status_in("claude-code", &env), Ok(false));
        assert!(!fx.exists("CALLS") && !fx.exists("LOG"), "a CLI ran");
    }

    // ---- Helpers ----

    #[test]
    fn extract_token_finds_the_first_oauth_token() {
        let long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_-0123";
        assert_eq!(extract_token(&format!("a\nsk-ant-oat01-{long}\nb")), Some(&*format!("sk-ant-oat01-{long}")));
        // In a sentence, and ending at the first character a token cannot hold.
        assert_eq!(
            extract_token(&format!("token: \x1b[1msk-ant-oat01-{long}\x1b[0m done")),
            Some(&*format!("sk-ant-oat01-{long}"))
        );
        // The first one wins.
        assert_eq!(
            extract_token(&format!("sk-ant-oat01-{long}\nsk-ant-oat01-{long}zzzz")),
            Some(&*format!("sk-ant-oat01-{long}"))
        );
        // Too short, wrong kind, or absent.
        assert_eq!(extract_token("sk-ant-oat01-short"), None);
        assert_eq!(extract_token(&format!("sk-ant-api03-{long}")), None);
        assert_eq!(extract_token("Opening your browser...\nDone."), None);
        assert_eq!(extract_token(""), None);
    }

    #[test]
    fn command_passes_only_the_minimal_env() {
        let path = OsString::from("/usr/bin");
        let c = command(Path::new("/bin/true"), &["x"], &path);
        let envs: Vec<(String, Option<OsString>)> =
            c.get_envs().map(|(k, v)| (k.to_string_lossy().into_owned(), v.map(|v| v.to_os_string()))).collect();
        assert!(envs.contains(&("PATH".to_string(), Some(path.clone()))));
        for (k, _) in &envs {
            assert!(["PATH", "HOME", "USER", "LANG"].contains(&k.as_str()), "unexpected env {k}");
        }
    }

    #[test]
    fn private_dir_is_private_unique_and_removed_with_its_contents() {
        let a = PrivateDir::create().unwrap();
        let b = PrivateDir::create().unwrap();
        assert_ne!(a.0, b.0);
        for d in [&a, &b] {
            assert!(d.0.starts_with(std::env::temp_dir()), "{:?}", d.0);
            assert_eq!(std::fs::metadata(&d.0).unwrap().permissions().mode() & 0o777, 0o700);
        }
        std::fs::create_dir_all(a.0.join("nested/deeper")).unwrap();
        std::fs::write(a.0.join("nested/deeper/file"), "x").unwrap();
        let (pa, pb) = (a.0.clone(), b.0.clone());
        drop(a);
        assert!(!pa.exists(), "contents were left behind");
        assert!(pb.exists(), "dropping one removed the other");
        drop(b);
        assert!(!pb.exists());
    }

    #[test]
    fn unknown_engine_rejected() {
        let fx = Fx::new(Login::Marker, Setup::Token);
        let r = run_sign_in("nope", &fx.env, &Session::default(), MS, MS, MS, &|_| {});
        assert_eq!(r, Err(SigninError::UnknownEngine("nope".into())));
        assert!(run_sign_out("../codex", &fx.env).is_err());
        assert!(cancel_sign_in("rm").is_err());
        assert!(start_sign_in("x".into(), |_| {}).is_err());
        assert!(provider_status_in("x", &fx.env).is_err());
        assert!(!fx.exists("LOG") && !fx.exists("CALLS") && !fx.exists("SECARGV"), "something ran");
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
}
