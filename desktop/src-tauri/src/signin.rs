//! AI provider sign-in (D106). The app never reads, copies or writes the owner's `~/.codex/` or `~/.claude/`
//! and never runs its own OAuth. Each engine signs in the vendor's own way:
//!
//! - **Codex** uses the CLI's own login. The app spawns `codex login` and checks `codex login status` by
//!   exit code only.
//! - **Claude Code** is authenticated by a long-lived token. The app runs `claude setup-token`: the CLI opens
//!   the browser, serves its own OAuth callback and shows the token only after the owner approves. The app
//!   reads the token off the CLI's screen in memory and saves it in the login Keychain (service
//!   `com.cfw.render`, account `claude-code`, through `apikeys`). The render worker reads the item and hands
//!   the token to each Claude step's environment only. The `setup-token` run gets a fresh private
//!   `CLAUDE_CONFIG_DIR` (0700, under the temp folder) that is deleted afterwards, so `~/.claude` is never
//!   read or written. "Signed in" means the Keychain item exists; sign-out deletes it. The token never goes on
//!   argv (the Keychain write uses stdin), into logs, events or return values.
//!
//!   `setup-token` is a screen program, and three facts about it (CLI 2.1.303, seen 2026-11-04) shape the code:
//!   1. It draws only to a terminal. With pipes for stdin and stdout it prints nothing at all, ever, so it is
//!      run in a pseudo-terminal (a wide one, so nothing wraps) that the app never writes to.
//!   2. Its renderer is a diffing one: it skips cells that already show the right character and moves the
//!      cursor instead. Stripping the escape codes from the byte stream therefore loses characters (spaces,
//!      and a token read `sk-ant-at01-`, missing its `o`). Every byte goes through a terminal emulator
//!      (`vt100`), and the token is read from the rebuilt screen, as the owner would see it.
//!   3. It does not exit after it shows the token. So the app takes the token off the screen once it is fully
//!      drawn, saves it, and stops the CLI itself (its whole process group; it has its own session). "Fully
//!      drawn" means the token string has stayed the same for a short while (300 ms) with the "set
//!      CLAUDE_CODE_OAUTH_TOKEN" hint line on a later row, or for a much longer while (3 s) with no such line.
//!      A token that is still being drawn is never saved by the first rule alone: a hint line only proves that
//!      something was drawn below the token, not that the token row is finished.
//!
//!   The emulator is also a safety boundary. `vt100` 0.17.0 panics on some input (a U+FE0F emoji selector in
//!   the last column that is later drawn over), and the release build aborts on a panic, so U+FE0F is removed
//!   from the byte stream before the parser sees it (see `Vs16Filter`).
//! - **Gemini** has no login command; sign-in happens in its own terminal UI (see below).
//!
//! A Codex login process owns the browser's OAuth callback port, so it is never killed while it is still
//! working: if the machine is already signed in, no login process is started at all; otherwise the login
//! runs until it exits by itself, the owner cancels, or the time limit passes. A process that is still
//! alive after status has passed for the `grace` period is stopped (the CLI sometimes lingers). `claude
//! setup-token` is stopped by Cancel, by the time limit, or, because it never exits by itself, by the app once
//! it has saved the token.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
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

/// Shown when `claude setup-token` ended and its screen held no token.
const NO_TOKEN: &str = "The sign-in ended without a token.";
/// Shown when the screen held a token-shaped string the Keychain code would not store.
const BAD_TOKEN: &str = "The sign-in returned a token this app cannot store.";
/// How often the `setup-token` process and its screen are checked. In-process, so it can be quick.
const TOKEN_POLL_MAX: Duration = Duration::from_millis(250);
/// After the process ends, how long to wait for the reader to see the end of its output.
const READER_WAIT: Duration = Duration::from_secs(2);
/// How long the token string must stay the same on the screen before it counts as fully drawn, when the hint
/// line is on a later row. The hint line alone is not proof: a renderer may draw it before the token row is
/// finished. The wait makes the rest of the token arrive first.
pub const TOKEN_QUIET: Duration = Duration::from_millis(300);
/// The same, when there is no hint line below the token (a CLI version that words it differently). Much
/// longer, because nothing else says the token is complete.
pub const TOKEN_QUIET_NO_HINT: Duration = Duration::from_secs(3);
/// The terminal `setup-token` draws in. Wide, so the sign-in link and the token never wrap; tall enough for
/// its whole screen. Nothing is ever typed into it.
const TERM_ROWS: u16 = 50;
const TERM_COLS: u16 = 500;
/// `TERM` for the CLI. It is the only addition to the minimal environment besides the config folder.
const TERM: &str = "xterm-256color";
/// The line the CLI draws below the token: "Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=...".
const TOKEN_HINT: &str = "CLAUDE_CODE_OAUTH_TOKEN";
/// How long the reader waits for output before it checks whether it was told to stop.
const READ_SLICE_MS: i32 = 100;

/// macOS `TIOCSCTTY` (`_IO('t', 97)`: make the terminal the caller's controlling terminal) and `TIOCSWINSZ`
/// (`_IOW('t', 103, struct winsize)`: set its size). The `libc` crate has no values for macOS; the other Unixes
/// it knows are used as they are.
#[cfg(target_os = "macos")]
const TIOCSCTTY: libc::c_ulong = 0x2000_7461;
#[cfg(target_os = "macos")]
const TIOCSWINSZ: libc::c_ulong = 0x8008_7467;
#[cfg(not(target_os = "macos"))]
use libc::{TIOCSCTTY, TIOCSWINSZ};

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

/// The sign-in process a [`Session`] holds. `own_group` is set for a process started as the leader of its own
/// session (the `claude setup-token` one): stopping it then stops its whole process group, so nothing it
/// started keeps the sign-in link's port or its terminal.
struct Running {
    child: Child,
    own_group: bool,
}

impl Running {
    fn stop(mut self) {
        // The group id is the leader's pid, and a pid is not reused while its zombie is unreaped, so the
        // group is signalled only while the leader is still unreaped: it can never be somebody else's group.
        // (A leader that already exited and was reaped leaves nothing worth chasing; `own_group` is never set
        // for a process that shares the app's own group, which this must never signal.)
        if self.own_group && matches!(self.child.try_wait(), Ok(None)) {
            if let Ok(pgid) = libc::pid_t::try_from(self.child.id()) {
                // SAFETY: plain syscall. `pgid > 0` is the pid of our own child, which called `setsid`.
                unsafe { libc::killpg(pgid, libc::SIGKILL) };
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Clone, Default)]
pub struct Session {
    cancel: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Running>>>,
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
    /// `Ok(false)`: nothing was started, so no browser opens). The cancel check, the spawn and the store all
    /// happen under the child lock, and `cancel` takes that lock after it sets its flag, so a cancel can never
    /// slip in between and leave a process running. `own_group` says the process leads its own session (see
    /// [`Running`]).
    fn start(&self, own_group: bool, spawn: impl FnOnce() -> std::io::Result<Child>) -> std::io::Result<bool> {
        let mut slot = self.child.lock().unwrap();
        if self.cancel.load(Ordering::SeqCst) {
            return Ok(false);
        }
        *slot = Some(Running { child: spawn()?, own_group });
        Ok(true)
    }

    fn stop_child(&self) {
        if let Some(running) = self.child.lock().unwrap().take() {
            running.stop();
        }
    }

    fn child_state(&self) -> ChildState {
        match self.child.lock().unwrap().as_mut() {
            None => ChildState::Gone,
            Some(r) => match r.child.try_wait() {
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
        .start(false, || tool.command(tool.cli.login).spawn())
        .map_err(|_| SigninError::Spawn(tool.cli.bin.into()))?;
    if !started {
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

/// A new pseudo-terminal: `(master, slave)`. The CLI gets the slave as its terminal; the app only reads the
/// master. Both are opened close-on-exec, and the master non-blocking, in the `open` call itself (not with a
/// later `fcntl`), so there is no moment in which a process that another thread of the app starts could inherit
/// either one. A stray copy of the slave would keep the terminal open after the CLI is gone, and a stray copy
/// of the master would keep the whole terminal alive. The master does not block because the reader polls it,
/// and a wake-up with nothing to read must not leave the reader stuck in `read`.
fn open_pty() -> std::io::Result<(OwnedFd, OwnedFd)> {
    // `ptsname` answers with a buffer shared by the whole process; the lock keeps two sign-ins from sharing it.
    static PTSNAME: Mutex<()> = Mutex::new(());
    let _one_at_a_time = PTSNAME.lock().unwrap_or_else(|e| e.into_inner());
    let last_error = std::io::Error::last_os_error;
    // SAFETY: `open` with a NUL-terminated path; the result is checked before it is used.
    let fd = unsafe {
        libc::open(c"/dev/ptmx".as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC | libc::O_NONBLOCK)
    };
    if fd == -1 {
        return Err(last_error());
    }
    // SAFETY: `fd` is new and owned by nobody else.
    let master = unsafe { OwnedFd::from_raw_fd(fd) };
    // SAFETY: plain calls on the master we own. `ptsname` returns a NUL-terminated name that stays valid until
    // the next `ptsname` call; it is copied while the lock is held.
    let name = unsafe {
        if libc::grantpt(fd) == -1 || libc::unlockpt(fd) == -1 {
            return Err(last_error());
        }
        let name = libc::ptsname(fd);
        if name.is_null() {
            return Err(last_error());
        }
        std::ffi::CStr::from_ptr(name).to_owned()
    };
    // SAFETY: `open` with the NUL-terminated name just copied.
    let slave = unsafe { libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if slave == -1 {
        return Err(last_error());
    }
    // SAFETY: `slave` is new and owned by nobody else.
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };
    let size = libc::winsize { ws_row: TERM_ROWS, ws_col: TERM_COLS, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: `ioctl` reads one `winsize` through the pointer, and `size` outlives the call.
    if unsafe { libc::ioctl(slave.as_raw_fd(), TIOCSWINSZ as _, &size) } == -1 {
        return Err(last_error());
    }
    Ok((master, slave))
}

/// Make `slave` the terminal of `cmd`: its stdin, stdout and stderr, and (as the leader of a new session) its
/// controlling terminal, which is what a program that draws a screen expects.
fn attach_terminal(cmd: &mut Command, slave: &OwnedFd) -> std::io::Result<()> {
    cmd.stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave.try_clone()?));
    // SAFETY: the closure runs between `fork` and `exec`, so it makes only async-signal-safe calls (`setsid`,
    // `ioctl`) and allocates nothing.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            // Descriptor 0 is the slave by now.
            if libc::ioctl(0, TIOCSCTTY as _, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}

/// Is there something to read on `fd`, or has the other end gone (so a read reports the end)? Waits at most
/// `READ_SLICE_MS`.
fn readable(fd: RawFd) -> std::io::Result<bool> {
    let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid `pollfd`, and the count says so.
    match unsafe { libc::poll(&mut p, 1, READ_SLICE_MS) } {
        0 => Ok(false),
        n if n > 0 => Ok(true),
        _ => {
            let e = std::io::Error::last_os_error();
            // A signal cut the wait short: nothing to read yet.
            if e.kind() == std::io::ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(e)
            }
        }
    }
}

/// U+FE0F (VARIATION SELECTOR-16, "show the emoji form") in UTF-8.
const VS16: [u8; 3] = [0xEF, 0xB8, 0x8F];

/// Takes every U+FE0F out of the CLI's output before the emulator sees it. `vt100` 0.17.0 panics (an `unwrap` on
/// a cell that is not there, screen.rs:938) when that character widens a glyph in the last column and the cell
/// is drawn over later; the release build aborts on a panic, so the whole app would die in the middle of the
/// sign-in. The character only asks for an emoji look. The screen the app needs holds a plain ASCII token, so
/// nothing is lost. The three bytes can arrive in two reads, so a held-back start of one waits for the next.
#[derive(Default)]
struct Vs16Filter {
    /// One or two bytes at the end of the last chunk that could be the start of U+FE0F.
    held: Vec<u8>,
}

impl Vs16Filter {
    fn clean(&mut self, chunk: &[u8]) -> Vec<u8> {
        let mut bytes = std::mem::take(&mut self.held);
        bytes.extend_from_slice(chunk);
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            let rest = &bytes[i..];
            if rest.starts_with(&VS16) {
                i += VS16.len();
            } else if VS16.starts_with(rest) {
                // Fewer than three bytes are left and they are the start of U+FE0F: wait for the rest.
                self.held = rest.to_vec();
                break;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        out
    }
}

/// Feed one read of the CLI's output to the parser, minus U+FE0F. Every byte the emulator sees comes through here.
fn feed(parser: &mut vt100::Parser, filter: &mut Vs16Filter, chunk: &[u8]) {
    parser.process(&filter.clean(chunk));
}

/// The screen of the `setup-token` terminal, and when it last changed.
struct Drawn {
    parser: vt100::Parser,
    last_output: Instant,
    /// The reader saw the end of the output (the CLI closed its terminal), or failed, or was told to stop.
    ended: bool,
}

/// How long a token must stay the same before it counts as fully drawn: the first for a token with the hint
/// line on a later row, the second for a token without one.
#[derive(Clone, Copy)]
struct Quiet {
    hinted: Duration,
    bare: Duration,
}

impl Quiet {
    const DEFAULT: Quiet = Quiet { hinted: TOKEN_QUIET, bare: TOKEN_QUIET_NO_HINT };

    fn ready(self, hinted: bool, unchanged_for: Duration) -> bool {
        unchanged_for >= if hinted { self.hinted } else { self.bare }
    }
}

/// A terminal emulator for the `setup-token` run. Its own thread reads the master all the time (so the CLI
/// never blocks on a full terminal) and feeds every byte to a `vt100` parser, which rebuilds the screen the way
/// a real terminal would. Nothing is ever written back to the terminal. Dropping it stops the reader.
struct Emulator {
    drawn: Arc<Mutex<Drawn>>,
    stop: Arc<AtomicBool>,
    /// The token string seen at the last check, and when it was first seen.
    seen: Option<(String, Instant)>,
}

impl Emulator {
    fn start(master: OwnedFd) -> Emulator {
        let drawn = Arc::new(Mutex::new(Drawn {
            parser: vt100::Parser::new(TERM_ROWS, TERM_COLS, 0),
            last_output: Instant::now(),
            ended: false,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let (sink, halt) = (drawn.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut master = File::from(master);
            let mut filter = Vs16Filter::default();
            let mut chunk = [0u8; 4096];
            while !halt.load(Ordering::SeqCst) {
                match readable(master.as_raw_fd()) {
                    Ok(true) => {}
                    Ok(false) => continue,
                    Err(_) => break,
                }
                match master.read(&mut chunk) {
                    // The end of the output. Once the CLI closed its side, macOS reads 0 bytes where Linux
                    // fails with EIO; the error arm below covers that.
                    Ok(0) => break,
                    Ok(n) => {
                        let mut d = sink.lock().unwrap();
                        feed(&mut d.parser, &mut filter, &chunk[..n]);
                        d.last_output = Instant::now();
                    }
                    Err(e) if matches!(e.kind(), std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock) => {}
                    Err(_) => break,
                }
            }
            sink.lock().unwrap().ended = true;
        });
        Emulator { drawn, stop, seen: None }
    }

    /// The token, once it is fully drawn while the CLI still runs: its string has not changed for `quiet.hinted`
    /// with the hint line on a later row, or for `quiet.bare` without one. Called every poll, so a change of
    /// the string (more of the token drawn, or the screen redrawn) starts the wait again. A token that is
    /// still being drawn is never returned.
    fn finished_token(&mut self, quiet: Quiet) -> Option<String> {
        let (token, hinted) = {
            let d = self.drawn.lock().unwrap();
            let text = d.parser.screen().contents();
            match find_token(&text) {
                Some(found) => (found.token.to_string(), found.hinted),
                None => {
                    self.seen = None;
                    return None;
                }
            }
        };
        let since = match &self.seen {
            Some((same, since)) if *same == token => *since,
            _ => {
                let now = Instant::now();
                self.seen = Some((token.clone(), now));
                now
            }
        };
        quiet.ready(hinted, since.elapsed()).then_some(token)
    }

    /// The token on the screen after the CLI ended. Once the reader has seen the end of the output (it is given
    /// `wait` for that) nothing more can be drawn, so whatever token is on the screen is whole. If the end
    /// never came (a leftover process holds the terminal open), only a token with the hint line below it
    /// counts.
    fn final_token(&self, wait: Duration) -> Option<String> {
        let end = Instant::now() + wait;
        while !self.drawn.lock().unwrap().ended && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        let d = self.drawn.lock().unwrap();
        let text = d.parser.screen().contents();
        let found = find_token(&text)?;
        (d.ended || found.hinted).then(|| found.token.to_string())
    }
}

impl Drop for Emulator {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

/// A token found on the screen.
struct Found<'a> {
    token: &'a str,
    /// The hint line (see `TOKEN_HINT`) is on a later row than the token. That is a sign, not proof, that the
    /// token is complete: see `TOKEN_QUIET`.
    hinted: bool,
}

/// The first Claude OAuth token on `screen`: `sk-ant-oat01-` followed by at least 20 token characters.
fn find_token(screen: &str) -> Option<Found<'_>> {
    static RX: OnceLock<regex::Regex> = OnceLock::new();
    let rx = RX.get_or_init(|| regex::Regex::new(r"sk-ant-oat01-[A-Za-z0-9_-]{20,}").expect("token regex"));
    let m = rx.find(screen)?;
    // Rows of the screen text are separated by a newline (rows that wrapped are not), and the token holds none.
    // So the hint counts only when it comes after the end of the token's own line.
    let hinted = screen[m.end()..].split_once('\n').is_some_and(|(_, below)| below.contains(TOKEN_HINT));
    Some(Found { token: m.as_str(), hinted })
}

/// Claude Code is signed in when its token is in the Keychain.
fn token_saved(env: &Env) -> Result<bool, SigninError> {
    apikeys::present_with(&env.security, CLAUDE_CODE).map_err(|_| SigninError::Spawn("security".into()))
}

/// Save the token the screen showed, or fail. Neither the token nor any text of the screen goes into the
/// message.
fn save_token(env: &Env, token: &str) -> (SigninState, Option<String>) {
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
/// - Otherwise `claude setup-token` runs in its own pseudo-terminal session (see the module doc) with the
///   minimal environment plus `TERM` and a fresh private `CLAUDE_CONFIG_DIR` (deleted at the end). It lives in
///   the session, so Cancel stops it. As soon as the screen shows a fully drawn token (see the module doc), it
///   is saved to the Keychain and the CLI is stopped (it never exits by itself): `connected`; an unusable
///   token is `failed`; a Keychain error is `failed` with that error. If the CLI exits first, a token left on
///   its final screen is saved the same way, and none is `failed`. Cancel is `cancelled`. `timeout` passing
///   stops the process (`timeout`).
fn run_claude_sign_in(
    env: &Env,
    session: &Session,
    timeout: Duration,
    interval: Duration,
    emit: &dyn Fn(SigninEvent),
) -> Result<SigninState, SigninError> {
    claude_sign_in(env, session, timeout, interval, Quiet::DEFAULT, emit)
}

/// [`run_claude_sign_in`] with the times the token must stay unchanged given.
fn claude_sign_in(
    env: &Env,
    session: &Session,
    timeout: Duration,
    interval: Duration,
    quiet: Quiet,
    emit: &dyn Fn(SigninEvent),
) -> Result<SigninState, SigninError> {
    let ev = |state, message: Option<String>| emit(SigninEvent { engine: CLAUDE_CODE.to_string(), state, message });
    if token_saved(env)? {
        ev(SigninState::Connected, None);
        return Ok(SigninState::Connected);
    }
    let exe = resolve("claude", &env.path).ok_or_else(|| SigninError::NotInstalled("claude".into()))?;
    let dir = PrivateDir::create().map_err(|e| SigninError::PrivateDir(e.to_string()))?;
    let (master, slave) = open_pty().map_err(|_| SigninError::Spawn("claude".into()))?;
    let mut cmd = command(&exe, &["setup-token"], &env.path);
    // The additions to the minimal environment: a terminal type, and a throwaway config folder so `~/.claude`
    // stays untouched.
    cmd.env("CLAUDE_CONFIG_DIR", &dir.0).env("TERM", TERM);
    attach_terminal(&mut cmd, &slave).map_err(|_| SigninError::Spawn("claude".into()))?;
    // As for Codex: a Cancel that arrived during the Keychain check must not open a browser.
    let started = session.start(true, || cmd.spawn()).map_err(|_| SigninError::Spawn("claude".into()))?;
    // The command and `slave` hold the app's copies of the terminal's CLI side. They go now, so the master
    // sees the end of the output when the CLI is gone.
    drop(cmd);
    drop(slave);
    if !started {
        ev(SigninState::Cancelled, None);
        return Ok(SigninState::Cancelled);
    }
    let mut screen = Emulator::start(master);
    ev(SigninState::Waiting, None);
    let start = Instant::now();
    let poll = interval.min(TOKEN_POLL_MAX);
    let (state, message) = loop {
        if session.cancel.load(Ordering::SeqCst) {
            break (SigninState::Cancelled, None);
        }
        match session.child_state() {
            ChildState::Gone => break (SigninState::Cancelled, None),
            ChildState::Exited => {
                break match screen.final_token(READER_WAIT) {
                    Some(token) => save_token(env, &token),
                    None => (SigninState::Failed, Some(NO_TOKEN.to_string())),
                };
            }
            ChildState::Running => {}
        }
        if let Some(token) = screen.finished_token(quiet) {
            break save_token(env, &token);
        }
        if start.elapsed() >= timeout {
            break (SigninState::Timeout, None);
        }
        std::thread::sleep(poll);
    };
    session.stop_child();
    drop(screen);
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

    /// What the stub `claude setup-token` does once it found itself on a terminal.
    #[derive(Clone, Copy)]
    enum Setup {
        /// The real screen: the sign-in link and the paste prompt, then (after the owner approved) the success
        /// text, the token on its own line and the hint line below it. Then it keeps running: the real CLI
        /// never exits by itself.
        Token,
        /// The same, but the token is drawn the way the real diffing renderer draws it: over the row that held
        /// the paste prompt, skipping the cell that already shows the `o`. Then it keeps running.
        Diff,
        /// The token comes in two writes with a pause between them (1.5 s, longer than the old 1 s fallback and
        /// shorter than `TOKEN_QUIET_NO_HINT`), the hint line with the second. Then it keeps running.
        Split,
        /// A renderer that draws the hint line BEFORE it finishes the token row: 25 of the 30 token characters,
        /// the hint line below them, a pause (0.6 s), then back up to the token row for the rest. Then it keeps
        /// running. `HINTED` marks the moment the hint line is on screen with the half token above it, `DONE` the
        /// moment the token is whole.
        HintFirst,
        /// Draws the input that makes `vt100` 0.17.0 panic (a U+FE0F emoji in the last column that is then drawn
        /// over; `VS16_PANIC_INPUT`), clears the screen and draws the success screen. Then it keeps running.
        Vs16,
        /// The token with no hint line below it. Then it keeps running. `DRAWN` marks the moment it is on screen.
        TokenNoHint,
        /// 3000 lines of noise (the screen scrolls), then the success screen. Then it keeps running.
        Flood,
        /// The token with no hint line, then exit 0.
        TokenThenExit,
        /// The paste prompt, exit 1, no token.
        Fail,
        /// The paste prompt, exit 0, no token.
        NoToken,
        /// A token-looking string that is far too long to store, then exit 0.
        BadToken,
        /// The paste prompt, then keep running (the owner never approves in the browser).
        Hang,
        /// Like `Hang`, with a helper process in the same group (`CHILDPID`) that outlives a lone kill.
        HangWithHelper,
    }

    /// What the real CLI draws before the owner approves: no newline after the prompt.
    const PROMPT_SCREEN: &str = r#"printf 'Welcome to Claude Code\n\nOpening browser to sign in...\n\n'
printf 'Browser did not open? Use the url below to sign in\n\nhttps://claude.example/oauth/authorize?x=1\n\n'
printf 'Paste code here if prompted >'
"#;
    /// What it draws below the token once the owner approved.
    const HINT_SCREEN: &str = r#"printf '\n\nStore this token securely. You will not be able to see it again.\n\n'
printf 'Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>\n'
"#;
    const SUCCESS_SCREEN: &str = r#"printf '\n\nLong-lived authentication token created successfully!\n\nYour OAuth token (valid for 1 year):\n'
"#;

    impl Setup {
        fn body(self) -> String {
            let pid = "echo $$ > '@D@/PID'\n";
            let hang = "exec sleep 600\n";
            match self {
                Setup::Token => {
                    format!("{pid}{PROMPT_SCREEN}sleep 0.3\n{SUCCESS_SCREEN}printf '@TOKEN@\\n'\n{HINT_SCREEN}{hang}")
                }
                // Rewrite the prompt row in place: back one row and to column 0, `sk-ant-` over "Paste c", a
                // cursor move over the `o` that "code" already left in that cell, then the rest of the token.
                Setup::Diff => format!(
                    "{pid}{PROMPT_SCREEN}printf '\\n\\033[1A\\r'\nsleep 0.2\nprintf 'sk-ant-'\nprintf '\\033[1C'\n\
                     printf '@TOKEN_TAIL@'\n{HINT_SCREEN}{hang}"
                ),
                Setup::Split => format!(
                    "{pid}{SUCCESS_SCREEN}printf '@TOKEN_HEAD@'\ntouch '@D@/HALF'\nsleep 1.5\n\
                     printf '@TOKEN_REST@'\n{HINT_SCREEN}{hang}"
                ),
                Setup::HintFirst => format!(
                    "{pid}{SUCCESS_SCREEN}printf '@TOKEN_HEAD@'\n{HINT_SCREEN}touch '@D@/HINTED'\nsleep 0.6\n\
                     printf '\\033[5A\\033[@HEAD_COL@G@TOKEN_REST@'\ntouch '@D@/DONE'\n{hang}"
                ),
                Setup::Vs16 => format!(
                    "{pid}printf '\\033[;33317H'\nprintf '\\033[22303d'\nprintf '\\342\\235\\244\\357\\270\\217'\n\
                     printf '\\033[?6l'\nprintf '\\033M'\nprintf '\\033[478;11061f'\nprintf '\\033[2;27b'\n\
                     printf '\\033[2J\\033[H'\n{SUCCESS_SCREEN}printf '@TOKEN@\\n'\n{HINT_SCREEN}{hang}"
                ),
                Setup::TokenNoHint => {
                    format!("{pid}{PROMPT_SCREEN}{SUCCESS_SCREEN}printf '@TOKEN@\\n'\ntouch '@D@/DRAWN'\n{hang}")
                }
                Setup::Flood => format!(
                    "{pid}i=0; while [ $i -lt 3000 ]; do echo \"noise noise noise noise noise $i\"; i=$((i+1)); done\n\
                     {SUCCESS_SCREEN}printf '@TOKEN@\\n'\n{HINT_SCREEN}{hang}"
                ),
                Setup::TokenThenExit => format!("{SUCCESS_SCREEN}printf '@TOKEN@\\n'\nexit 0\n"),
                Setup::Fail => format!("{PROMPT_SCREEN}echo\necho 'Sign-in failed.' >&2\nexit 1\n"),
                Setup::NoToken => format!("{PROMPT_SCREEN}echo\necho 'Done.' >&2\nexit 0\n"),
                Setup::BadToken => "printf 'sk-ant-oat01-%0400d\\n' 7\nexit 0\n".to_string(),
                Setup::Hang => format!("{pid}{PROMPT_SCREEN}{hang}"),
                Setup::HangWithHelper => {
                    format!("trap '' HUP\nsleep 120 &\necho $! > '@D@/CHILDPID'\n{pid}{PROMPT_SCREEN}wait\n")
                }
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
    /// folder's listing (mode), HOME, and the NAMES of its environment variables. Then, like the real CLI, it
    /// draws only if stdin and stdout are terminals (without them it prints nothing, ever, and never exits).
    /// On a terminal it records TERM, the terminal's size (SIZE), whether it can open its controlling terminal
    /// (CTTY) and its own pid, process group and terminal (PSLINE), then does `@SETUP@`.
    const CLAUDE_STUB: &str = r#"#!/bin/sh
echo "$1" >> '@D@/CALLS'
[ "$1" = setup-token ] || exit 2
echo "$CLAUDE_CONFIG_DIR" > '@D@/CFGDIR'
ls -ld "$CLAUDE_CONFIG_DIR" > '@D@/CFGLS'
echo "$HOME" > '@D@/HOMEV'
env | sed 's/=.*//' | sort > '@D@/ENVNAMES'
if [ -t 0 ] && [ -t 1 ]; then
  echo "$TERM" > '@D@/TERMV'
  stty size > '@D@/SIZE'
  (: < /dev/tty) 2>/dev/null && touch '@D@/CTTY'
  ps -o pid=,pgid=,tty= -p $$ > '@D@/PSLINE'
else
  exec sleep 600
fi
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
                    .replace("@SETUP@", &setup.body())
                    .replace("@TOKEN@", TOKEN)
                    .replace("@TOKEN_TAIL@", &TOKEN[8..])
                    .replace("@TOKEN_HEAD@", &TOKEN[..38])
                    .replace("@TOKEN_REST@", &TOKEN[38..])
                    .replace("@HEAD_COL@", &(TOKEN[..38].len() + 1).to_string())
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
            self.pid_alive_in("PID")
        }

        /// Is the process whose pid the stub wrote to `file` still running?
        fn pid_alive_in(&self, file: &str) -> bool {
            let Ok(pid) = std::fs::read_to_string(self.dir.path().join(file)) else { return false };
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

        /// A Claude Code sign-in with the times the token must stay unchanged given (the real ones are
        /// `Quiet::DEFAULT`).
        fn claude_quiet(&self, timeout: Duration, quiet: Quiet) -> Run {
            let events = Arc::new(Mutex::new(Vec::new()));
            let e2 = events.clone();
            let start = Instant::now();
            let result = claude_sign_in(&self.env, &Session::default(), timeout, MS, quiet, &move |e| {
                e2.lock().unwrap().push(e)
            });
            let events = events.lock().unwrap().clone();
            Run { result, events, elapsed: start.elapsed() }
        }

        /// [`Fx::claude_quiet`] on its own thread under `session`.
        fn claude_quiet_in_background(&self, session: &Session, timeout: Duration, quiet: Quiet) -> Background {
            let events = Arc::new(Mutex::new(Vec::new()));
            let (e2, env, s2) = (events.clone(), self.env.clone(), session.clone());
            let thread = std::thread::spawn(move || {
                claude_sign_in(&env, &s2, timeout, MS, quiet, &move |e| e2.lock().unwrap().push(e))
            });
            Background { thread, events }
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
        assert!(run.elapsed >= Duration::from_millis(250), "connected before the token was drawn: {:?}", run.elapsed);
        assert!(run.elapsed < LOAD, "took {:?}", run.elapsed);
        // The CLI never exits by itself after it shows the token: the app stopped it.
        assert!(fx.exists("PID") && !fx.pid_alive(), "setup-token is still running");

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
        for needed in ["PATH", "HOME", "TERM", "CLAUDE_CONFIG_DIR"] {
            assert!(names.iter().any(|n| n == needed), "{needed} missing from {names:?}");
        }
        for n in &names {
            let up = n.to_uppercase();
            let secretish = ["TOKEN", "KEY", "SECRET", "ANTHROPIC", "CFW", "CLAUDE_CODE"].iter().any(|s| up.contains(s));
            assert!(!secretish || n == "CLAUDE_CONFIG_DIR", "unexpected variable {n} in {names:?}");
        }
    }

    #[test]
    fn claude_setup_token_draws_in_a_wide_terminal_of_its_own() {
        let fx = Fx::claude(Setup::Token);
        assert_eq!(fx.sign_in("claude-code", LONG, LONG).result, Ok(Connected));
        // The stub prints nothing unless stdin and stdout are terminals, so getting here proves both are.
        assert_eq!(fx.file("SIZE").trim(), "50 500", "the terminal is not the size the screen is read at");
        assert_eq!(fx.file("TERMV").trim(), "xterm-256color");
        assert!(fx.exists("CTTY"), "setup-token has no controlling terminal");
        // It leads its own process group (its pid is the group id), which is what makes stopping the group safe,
        // and that group has a terminal.
        let ps = fx.file("PSLINE");
        let cols: Vec<&str> = ps.split_whitespace().collect();
        assert!(cols.len() == 3 && cols[0] == cols[1], "not the leader of its own process group: {ps:?}");
        assert!(cols[2].starts_with("tty"), "no terminal: {ps:?}");
    }

    #[test]
    fn the_pseudo_terminal_is_close_on_exec_and_its_master_does_not_block() {
        let (master, slave) = open_pty().unwrap();
        let flags = |fd: &OwnedFd, what: libc::c_int| {
            // SAFETY: plain `fcntl` query on a descriptor that stays open for the call.
            let f = unsafe { libc::fcntl(fd.as_raw_fd(), what) };
            assert_ne!(f, -1, "{}", std::io::Error::last_os_error());
            f
        };
        for (name, fd) in [("master", &master), ("slave", &slave)] {
            assert_ne!(flags(fd, libc::F_GETFD) & libc::FD_CLOEXEC, 0, "{name} would be inherited by other processes");
        }
        assert_ne!(flags(&master, libc::F_GETFL) & libc::O_NONBLOCK, 0, "the reader could get stuck in `read`");
        assert_eq!(flags(&slave, libc::F_GETFL) & libc::O_NONBLOCK, 0, "the CLI's end must block like a terminal");
        // Nothing written, nothing to read: a read on the master reports that it would block.
        let err = File::from(master.try_clone().unwrap()).read(&mut [0u8; 8]).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
    }

    #[test]
    fn claude_token_drawn_over_the_prompt_row_with_cursor_moves_is_read_whole() {
        // The diffing renderer skips the cell that already shows the `o`; stripping escape codes would give
        // `sk-ant-at01-...`. The emulated screen has the whole token.
        let fx = Fx::claude(Setup::Diff);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert_eq!(fx.file("SECSTDIN").matches("add-generic-password").count(), 1);
        assert!(fx.exists("PID") && !fx.pid_alive(), "setup-token is still running (it never exits by itself)");
        assert!(!fx.config_dir().exists(), "the throwaway folder was left behind");
        let seen = format!("{}\n{}\n{}", run.json(), fx.file("SECARGV"), fx.file("CALLS"));
        assert!(!seen.contains("sk-ant") && !seen.contains("TESTTOKEN"), "the token leaked:\n{seen}");
    }

    #[test]
    fn claude_half_drawn_token_is_never_saved() {
        // 25 of the 30 token characters, a pause of 1.5 s (longer than the 1 s the first version waited, shorter
        // than `TOKEN_QUIET_NO_HINT`), then the rest and the hint line. The real wait times, no hint line while
        // the token is half drawn: nothing may be saved until the token is whole.
        let fx = Fx::claude(Setup::Split);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert!(fx.exists("HALF"));
        assert!(run.elapsed >= Duration::from_millis(1400), "saved before the token was whole: {:?}", run.elapsed);
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        let saved = fx.file("SECSTDIN");
        assert_eq!(saved.matches("add-generic-password").count(), 1, "more than one save:\n{saved}");
        assert!(saved.trim_end().ends_with(&format!("-w {TOKEN}")), "not the whole token");
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_hint_line_drawn_before_the_token_row_is_finished_does_not_finish_the_token() {
        // The hint line is on screen, below a half token, for 0.6 s; then the rest of the token is drawn. The
        // hint line alone must not be enough: the token string has to stay the same for the hinted wait (2.5 s
        // here, far longer than the stub's pause so that a busy machine cannot stretch the pause past it).
        let fx = Fx::claude(Setup::HintFirst);
        let run = fx.claude_quiet(LONG, Quiet { hinted: Duration::from_millis(2500), bare: LONG });
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert!(fx.exists("HINTED") && fx.exists("DONE"));
        assert!(run.elapsed >= Duration::from_millis(2500), "saved after only {:?}", run.elapsed);
        let saved = fx.file("SECSTDIN");
        assert_eq!(saved.matches("add-generic-password").count(), 1, "more than one save:\n{saved}");
        assert!(saved.trim_end().ends_with(&format!("-w {TOKEN}")), "not the whole token");
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_cli_output_that_would_crash_the_emulator_is_survived() {
        // The input that makes `vt100` 0.17.0 panic (see `Vs16Filter`), drawn by the stub through the real
        // terminal and reader thread, followed by the usual token. A panic would kill the reader thread and
        // fail the sign-in (and abort the whole app in a release build).
        let fx = Fx::claude(Setup::Vs16);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_token_without_the_hint_line_is_not_taken_while_the_screen_may_still_change() {
        let fx = Fx::claude(Setup::TokenNoHint);
        let session = Session::default();
        let bg = fx.claude_quiet_in_background(&session, LONG, Quiet { hinted: LONG, bare: LONG });
        fx.wait_for("the token is on the screen", || fx.exists("DRAWN"));
        std::thread::sleep(Duration::from_millis(500));
        assert!(started(&session), "the sign-in let go of setup-token by itself");
        assert!(!fx.exists("SECSTDIN"), "a token with nothing below it was saved at once");
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert_eq!(run.states(), vec![Waiting, Cancelled]);
        assert_eq!(fx.stored_token(), None);
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_token_without_the_hint_line_is_saved_once_the_screen_has_been_still() {
        let fx = Fx::claude(Setup::TokenNoHint);
        let run = fx.sign_in("claude-code", LONG, LONG);
        let done = std::time::SystemTime::now();
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        // Measured from the moment the stub drew the token (not from the start of the sign-in, which a busy
        // machine can delay by seconds): the long wait, give or take the stub's own few milliseconds.
        let drawn = std::fs::metadata(fx.dir.path().join("DRAWN")).unwrap().modified().unwrap();
        let waited = done.duration_since(drawn).unwrap();
        assert!(
            waited + Duration::from_millis(200) >= TOKEN_QUIET_NO_HINT,
            "saved {waited:?} after the token was drawn"
        );
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_token_after_a_screen_full_of_scrolling_output_is_found() {
        let fx = Fx::claude(Setup::Flood);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert!(!fx.pid_alive(), "setup-token is still running");
    }

    #[test]
    fn claude_token_left_on_the_final_screen_is_saved_when_the_cli_exits() {
        let fx = Fx::claude(Setup::TokenThenExit);
        let run = fx.sign_in("claude-code", LONG, LONG);
        assert_eq!(run.result, Ok(Connected));
        assert_eq!(run.states(), vec![Waiting, Connected]);
        assert_eq!(fx.stored_token().as_deref(), Some(TOKEN));
        assert!(run.elapsed < LOAD, "took {:?}", run.elapsed);
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
            assert!(!fx.exists("SECSTDIN"), "something was saved");
            assert_eq!(provider_status_in("claude-code", &fx.env), Ok(false));
            assert!(!fx.config_dir().exists(), "the throwaway folder was left behind");
            assert!(!run.json().contains("Sign-in failed") && !run.json().contains("Paste"), "screen text leaked");
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
        assert!(!fx.pid_alive(), "setup-token is still running");
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
    fn claude_cancel_stops_everything_in_the_clis_process_group() {
        let fx = Fx::claude(Setup::HangWithHelper);
        let session = Session::default();
        let bg = fx.sign_in_in_background("claude-code", &session, LONG);
        fx.wait_for("setup-token and its helper are running", || {
            started(&session) && fx.exists("PID") && fx.exists("CHILDPID")
        });
        assert!(fx.pid_alive() && fx.pid_alive_in("CHILDPID"), "the stubs are not running");
        session.cancel();
        let run = bg.finish();
        assert_eq!(run.result, Ok(Cancelled));
        assert!(!fx.pid_alive(), "setup-token is still running");
        // The helper is not our child: its zombie is reaped by init, a moment after the kill.
        fx.wait_for("the helper was stopped", || !fx.pid_alive_in("CHILDPID"));
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
    fn find_token_finds_the_first_oauth_token_and_the_hint_line_below_it() {
        let tok = |s: &str| find_token(s).map(|f| f.token.to_string());
        let long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_-0123";
        assert_eq!(tok(&format!("a\nsk-ant-oat01-{long}\nb")), Some(format!("sk-ant-oat01-{long}")));
        // In a sentence, and ending at the first character a token cannot hold.
        assert_eq!(
            tok(&format!("token: \x1b[1msk-ant-oat01-{long}\x1b[0m done")),
            Some(format!("sk-ant-oat01-{long}"))
        );
        // The first one wins.
        assert_eq!(
            tok(&format!("sk-ant-oat01-{long}\nsk-ant-oat01-{long}zzzz")),
            Some(format!("sk-ant-oat01-{long}"))
        );
        // Too short, wrong kind, or absent.
        assert_eq!(tok("sk-ant-oat01-short"), None);
        assert_eq!(tok(&format!("sk-ant-api03-{long}")), None);
        assert_eq!(tok("Opening your browser...\nDone."), None);
        assert_eq!(tok(""), None);
        // The hint line counts only when it is below the token.
        assert!(!find_token(&format!("sk-ant-oat01-{long}\nStore it.")).unwrap().hinted);
        assert!(find_token(&format!("sk-ant-oat01-{long}\n\nexport CLAUDE_CODE_OAUTH_TOKEN=<token>")).unwrap().hinted);
        assert!(!find_token(&format!("export CLAUDE_CODE_OAUTH_TOKEN=<token>\nsk-ant-oat01-{long}")).unwrap().hinted);
        // ...and on a later row: on the token's own row it proves nothing about the row being finished.
        assert!(!find_token(&format!("sk-ant-oat01-{long} export CLAUDE_CODE_OAUTH_TOKEN=<token>")).unwrap().hinted);
        let both = format!("sk-ant-oat01-{long} CLAUDE_CODE_OAUTH_TOKEN\nCLAUDE_CODE_OAUTH_TOKEN");
        assert!(find_token(&both).unwrap().hinted);
    }

    #[test]
    fn a_token_counts_as_drawn_after_the_short_wait_with_a_hint_row_and_the_long_wait_without() {
        let q = Quiet::DEFAULT;
        assert!(TOKEN_QUIET < TOKEN_QUIET_NO_HINT);
        assert!(!q.ready(true, TOKEN_QUIET - Duration::from_millis(1)));
        assert!(q.ready(true, TOKEN_QUIET));
        assert!(!q.ready(false, TOKEN_QUIET), "a bare token was taken after the short wait");
        assert!(!q.ready(false, TOKEN_QUIET_NO_HINT - Duration::from_millis(1)));
        assert!(q.ready(false, TOKEN_QUIET_NO_HINT));
        assert!(!q.ready(true, Duration::ZERO) && !q.ready(false, Duration::ZERO));
    }

    /// `VS16_PANIC_INPUT` as the bytes the CLI would write.
    fn vs16_panic_bytes() -> Vec<u8> {
        VS16_PANIC_INPUT.concat().into_bytes()
    }

    /// The input that makes `vt100` 0.17.0 panic at the app's terminal size (found by the independent review): a
    /// narrow glyph plus U+FE0F in the last column, which `vt100` widens, drawn over after a reverse index.
    const VS16_PANIC_INPUT: [&str; 7] =
        ["\x1b[;33317H", "\x1b[22303d", "\u{2764}\u{fe0f}", "\x1b[?6l", "\x1bM", "\x1b[478;11061f", "\x1b[2;27b"];

    #[test]
    fn the_input_that_crashes_vt100_still_does_so_unfiltered() {
        // Keeps the next test honest: if `vt100` is fixed, or this input stops reproducing, this fails and the
        // filter (and its tests) can be revisited. The panic message goes to the captured test output.
        let crashed = std::panic::catch_unwind(|| {
            let mut parser = vt100::Parser::new(TERM_ROWS, TERM_COLS, 0);
            for part in VS16_PANIC_INPUT {
                parser.process(part.as_bytes());
            }
        });
        assert!(crashed.is_err(), "vt100 did not panic on the known input");
    }

    #[test]
    fn the_input_that_crashes_vt100_is_survived_through_the_filter_in_every_chunking() {
        let bytes = vs16_panic_bytes();
        for size in 1..=9 {
            let mut parser = vt100::Parser::new(TERM_ROWS, TERM_COLS, 0);
            let mut filter = Vs16Filter::default();
            for chunk in bytes.chunks(size) {
                feed(&mut parser, &mut filter, chunk);
            }
            let _ = parser.screen().contents();
        }
    }

    #[test]
    fn vs16_filter_removes_every_fe0f_wherever_the_reads_are_cut() {
        // Raw bytes, so that lone pieces of the three bytes (EF, EF B8) can sit among other text and other
        // multi-byte characters. `Z` at the end keeps the filter from holding back a trailing start of U+FE0F.
        let input: &[u8] =
            b"a\xEF\xB8\x8Fb\xEF\xB8\x8F\xEF\xB8\x8Fc\xEF\xB8x\xEF\xEFy\xE2\x9D\xA4\xEF\xB8\x8F\xF0\x9F\x98\x80\xEF\xB8\x8F\xEF\xB8\xEF\xB8\x8FZ";
        let want: &[u8] = b"abc\xEF\xB8x\xEF\xEFy\xE2\x9D\xA4\xF0\x9F\x98\x80\xEF\xB8Z";
        let run = |sizes: &[usize]| {
            let mut filter = Vs16Filter::default();
            let (mut out, mut at, mut i) = (Vec::new(), 0, 0);
            while at < input.len() {
                let end = (at + sizes[i % sizes.len()]).min(input.len());
                out.extend(filter.clean(&input[at..end]));
                at = end;
                i += 1;
            }
            out
        };
        assert_eq!(run(&[input.len()]), want, "whole");
        for size in 1..=8 {
            assert_eq!(run(&[size]), want, "chunks of {size}");
        }
        assert_eq!(run(&[1, 2, 3]), want);
        assert_eq!(run(&[2, 1, 1, 4]), want);
        // Every single cut point.
        for cut in 0..=input.len() {
            let mut filter = Vs16Filter::default();
            let mut out = filter.clean(&input[..cut]);
            out.extend(filter.clean(&input[cut..]));
            assert_eq!(out, want, "cut at {cut}");
        }
        // A start of U+FE0F that never continues is not lost when more output follows.
        let mut filter = Vs16Filter::default();
        assert_eq!(filter.clean(b"x\xEF\xB8"), b"x");
        assert_eq!(filter.clean(b"y"), b"\xEF\xB8y");
    }

    /// Final bytes of the control sequences the fuzz test writes: cursor moves, scrolling, erase, insert and delete,
    /// repeat, modes, regions.
    #[rustfmt::skip]
    const FUZZ_FINALS: [&str; 30] = [
        "H", "f", "A", "B", "C", "D", "E", "F", "G", "`", "a", "d", "e", "@", "P", "L", "M", "S", "T", "X", "b", "J",
        "K", "r", "m", "h", "l", "s", "u", "n",
    ];
    /// Text and short escape sequences the fuzz test writes: wide, combining and emoji characters, some with U+FE0F.
    #[rustfmt::skip]
    const FUZZ_TEXTS: [&str; 30] = [
        "x", "\t", "\x08", "\r", "\n", "\x1bD", "\x1bM", "\x1bE", "\x1b7", "\x1b8", "\x1b(0q\x1b(B", "\x0e", "\x0f",
        "\x1b[?1049h", "\x1b[?1049l", "\x1b[?6h", "\x1b[?6l", "\x1b[?7l", "\x1b[?7h", "\u{2713}", "\u{273b}",
        "\u{b7}", "\u{2588}", "\u{4e2d}", "e\u{301}", "\u{1f600}", "\u{2764}\u{fe0f}", "\u{2764}\u{fe0f}", "\u{fe0f}",
        "\u{1f600}\u{fe0f}",
    ];

    #[test]
    fn random_screen_programs_with_emoji_selectors_do_not_crash_the_emulator() {
        // A fixed-seed fuzz of the same kind the review used: cursor moves, scrolling, erase, insert and delete,
        // wide and combining characters, emoji with U+FE0F, all cut into random chunks. Deterministic.
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let num = |r: u64| match r % 5 {
            0 => String::new(),
            1 => "0".to_string(),
            2 => (r % 3).to_string(),
            3 => (r % 60).to_string(),
            _ => (490 + r % 20).to_string(),
        };
        for _round in 0..300 {
            let mut bytes: Vec<u8> = Vec::new();
            for _ in 0..200 {
                let r = next();
                match r % 3 {
                    0 => {
                        bytes.extend(b"\x1b[");
                        if r % 7 == 0 {
                            bytes.push(b'?');
                        }
                        bytes.extend(num(next()).bytes());
                        if r % 2 == 0 {
                            bytes.push(b';');
                            bytes.extend(num(next()).bytes());
                        }
                        bytes.extend(FUZZ_FINALS[(next() % FUZZ_FINALS.len() as u64) as usize].bytes());
                    }
                    1 => bytes.extend(FUZZ_TEXTS[(next() % FUZZ_TEXTS.len() as u64) as usize].bytes()),
                    _ => (0..next() % 8).for_each(|_| bytes.push(b'a' + (next() % 26) as u8)),
                }
            }
            let mut parser = vt100::Parser::new(TERM_ROWS, TERM_COLS, 0);
            let mut filter = Vs16Filter::default();
            let mut at = 0;
            while at < bytes.len() {
                let end = (at + 1 + (next() % 64) as usize).min(bytes.len());
                feed(&mut parser, &mut filter, &bytes[at..end]);
                at = end;
            }
            let _ = parser.screen().contents();
        }
    }

    #[test]
    fn emulated_screen_has_the_token_that_stripping_escape_codes_would_get_wrong() {
        // The row "Paste code here if prompted >" is rewritten in place: `sk-ant-`, then a cursor move over the
        // `o` that "code" left at column 7, then the rest of the token. Fed in tiny chunks, as a pipe might.
        let bytes = format!(
            "Paste code here if prompted >\r\n\x1b[1A\rsk-ant-\x1b[1C{}\r\n\r\nexport CLAUDE_CODE_OAUTH_TOKEN=<token>",
            &TOKEN[8..]
        );
        let mut parser = vt100::Parser::new(TERM_ROWS, TERM_COLS, 0);
        for chunk in bytes.as_bytes().chunks(5) {
            parser.process(chunk);
        }
        let screen = parser.screen().contents();
        let found = find_token(&screen).expect("no token on the emulated screen");
        assert_eq!(found.token, TOKEN);
        assert!(found.hinted);

        let stripped = regex::Regex::new(r"\x1b\[[0-9;]*[A-Za-z]").unwrap().replace_all(&bytes, "").into_owned();
        assert!(stripped.contains("sk-ant-at01-"), "stripping did not lose the o: {stripped}");
        assert!(find_token(&stripped).is_none(), "the old way of reading would have found a token");
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
