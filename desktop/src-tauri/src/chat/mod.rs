//! Companion chat: one non-interactive, streaming CLI run per turn, CFW as the only MCP server.

pub mod engines;
pub mod keychain;
pub mod session;
pub mod stream;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};

use stream::Event;

pub const MCP_URL_ENV: &str = "CFW_RENDER_MCP_URL";
pub const DEFAULT_MCP_URL: &str = "https://app.cfw.social/api/v1/mcp";
/// Env var the codex child reads the brand key from (`env_http_headers`), so it never hits argv.
pub const CODEX_KEY_ENV: &str = "CFW_BRAND_KEY";

pub fn valid_slug(slug: &str) -> bool {
    (1..=64).contains(&slug.len()) && slug.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

pub fn mcp_url() -> String {
    std::env::var(MCP_URL_ENV).ok().filter(|u| u.starts_with("https://")).unwrap_or_else(|| DEFAULT_MCP_URL.into())
}

pub fn mcp_host() -> String {
    let u = mcp_url();
    u.trim_start_matches("https://").split(['/', '?', '#']).next().unwrap_or("").to_string()
}

/// Only `https://` on the MCP host may be opened.
pub fn allowed_url(url: &str) -> bool {
    let prefix = format!("https://{}", mcp_host());
    url.strip_prefix(&prefix).is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
        && !url.chars().any(|c| c.is_whitespace() || c.is_control())
}

fn state_dir() -> Result<PathBuf, String> {
    crate::control::state_dir().map_err(|e| e.to_string())
}

// ---------- brands.json ({slug,name} only) ----------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Brand {
    pub slug: String,
    pub name: String,
}

fn brands_path(dir: &Path) -> PathBuf {
    session::companion_root(dir).join("brands.json")
}

pub fn brands() -> Result<Vec<Brand>, String> {
    let dir = state_dir()?;
    Ok(std::fs::read_to_string(brands_path(&dir)).ok().and_then(|r| serde_json::from_str(&r).ok()).unwrap_or_default())
}

fn save_brands(list: &[Brand]) -> Result<(), String> {
    let dir = state_dir()?;
    let root = session::companion_root(&dir);
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    session::write_private(&brands_path(&dir), &serde_json::to_vec(list).expect("strings"))
}

pub fn add_brand(slug: &str, name: &str, key: &str) -> Result<Vec<Brand>, String> {
    if !valid_slug(slug) {
        return Err("Brand id must be lowercase letters, digits and dashes.".into());
    }
    let name = name.trim();
    if name.is_empty() || name.len() > 120 {
        return Err("Enter a brand name.".into());
    }
    keychain::put(slug, key)?;
    session::brand_dir(&state_dir()?, slug)?;
    let mut list = brands()?;
    list.retain(|b| b.slug != slug);
    list.push(Brand { slug: slug.into(), name: name.into() });
    save_brands(&list)?;
    Ok(list)
}

pub fn remove_brand(slug: &str) -> Result<Vec<Brand>, String> {
    if !valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let _ = cancel(slug);
    keychain::delete(slug)?;
    let dir = session::companion_root(&state_dir()?).join(slug);
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    let mut list = brands()?;
    list.retain(|b| b.slug != slug);
    save_brands(&list)?;
    Ok(list)
}

// ---------- events to the webview ----------

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ChatEvent {
    pub slug: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engine: Option<String>,
}

fn ev(slug: &str, kind: &str, engine: Option<&str>) -> ChatEvent {
    ChatEvent { slug: slug.into(), kind: kind.into(), engine: engine.map(str::to_string), ..Default::default() }
}

// ---------- running a turn ----------

pub fn claude_mcp_config(url: &str, key: &str) -> String {
    serde_json::json!({ "mcpServers": { "cfw": { "type": "http", "url": url, "headers": { "x-api-key": key } } } }).to_string()
}

/// argv for one turn (excluding the binary). The prompt always goes on stdin.
/// claude: the key is inside the inline `--mcp-config` JSON (claude has no env-indirection for headers).
/// codex: `env_http_headers` names an env var; the key is only in the child's env.
pub fn turn_args(engine: &str, url: &str, key: &str, resume: Option<&str>) -> Vec<String> {
    let mut a: Vec<String> = Vec::new();
    if engine == "codex" {
        a.push("exec".into());
        if resume.is_some() {
            a.push("resume".into());
        }
        a.extend([
            "--json".into(),
            "--skip-git-repo-check".into(),
            "-c".into(),
            format!("mcp_servers.cfw.url={}", toml_str(url)),
            "-c".into(),
            format!("mcp_servers.cfw.env_http_headers.x-api-key={}", toml_str(CODEX_KEY_ENV)),
        ]);
        if let Some(id) = resume {
            a.push(id.into());
        }
        a.push("-".into());
    } else {
        a.extend(["-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config"].map(String::from));
        if let Some(id) = resume {
            a.extend(["--resume".into(), id.into()]);
        }
        // Last: --mcp-config is variadic.
        a.extend(["--mcp-config".into(), claude_mcp_config(url, key)]);
    }
    a
}

fn toml_str(s: &str) -> String {
    serde_json::to_string(s).expect("string")
}

struct Running {
    child: Arc<Mutex<Child>>,
    cancelled: Arc<AtomicBool>,
}

fn running() -> &'static Mutex<HashMap<String, Running>> {
    static R: OnceLock<Mutex<HashMap<String, Running>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

pub fn cancel(slug: &str) -> Result<bool, String> {
    if !valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let r = running().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(run) = r.get(slug) {
        run.cancelled.store(true, Ordering::SeqCst);
        let _ = run.child.lock().unwrap_or_else(|e| e.into_inner()).kill();
        return Ok(true);
    }
    Ok(false)
}

enum Outcome {
    Done,
    Limit,
    Failed(String),
    Cancelled,
}

fn run_one(slug: &str, engine: &str, text: &str, key: &str, dir: &Path, emit: &dyn Fn(ChatEvent)) -> Outcome {
    let path = crate::signin::search_path();
    let bin = if engine == "codex" { "codex" } else { "claude" };
    let Some(exe) = crate::signin::resolve(bin, &path) else {
        return Outcome::Failed(format!("{} isn't installed.", engines::display(engine)));
    };
    let resume = session::load(dir).get(engine).cloned();
    let url = mcp_url();
    let host = mcp_host();
    let args = turn_args(engine, &url, key, resume.as_deref());
    let argv: Vec<&str> = args.iter().map(String::as_str).collect();
    let mut cmd = crate::signin::command(&exe, &argv, &path);
    cmd.env_remove("USER").env_remove("LANG").current_dir(dir).stdin(Stdio::piped()).stdout(Stdio::piped());
    if engine == "codex" {
        cmd.env(CODEX_KEY_ENV, key);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(e.to_string()),
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(text.as_bytes());
    }
    let stdout = child.stdout.take();
    let child = Arc::new(Mutex::new(child));
    let cancelled = Arc::new(AtomicBool::new(false));
    running().lock().unwrap_or_else(|e| e.into_inner()).insert(slug.into(), Running { child: child.clone(), cancelled: cancelled.clone() });

    let mut outcome = None;
    let mut seen_links: Vec<String> = Vec::new();
    if let Some(out) = stdout {
        for line in BufReader::new(out).lines() {
            let Ok(line) = line else { break };
            let events = if engine == "codex" { stream::parse_codex(&line, &host) } else { stream::parse_claude(&line, &host) };
            for e in events {
                let mut ce = ev(slug, "", Some(engine));
                match e {
                    Event::Text(t) => {
                        ce.kind = "text".into();
                        ce.text = Some(t.replace(key, "[hidden]"));
                    }
                    Event::ToolCall { name } => {
                        ce.kind = "tool".into();
                        ce.name = Some(name);
                    }
                    Event::Link { label, url } => {
                        if seen_links.contains(&url) {
                            continue;
                        }
                        seen_links.push(url.clone());
                        ce.kind = "link".into();
                        ce.text = Some(label);
                        ce.url = Some(url);
                    }
                    Event::SessionId(id) => {
                        let _ = session::save_id(dir, engine, &id);
                        continue;
                    }
                    Event::Done => {
                        outcome.get_or_insert(Outcome::Done);
                        continue;
                    }
                    Event::LimitHit(_) => {
                        outcome = Some(Outcome::Limit);
                        let _ = child.lock().unwrap_or_else(|e| e.into_inner()).kill();
                        continue;
                    }
                    Event::Error(m) => {
                        outcome.get_or_insert(Outcome::Failed(m.replace(key, "[hidden]")));
                        continue;
                    }
                }
                emit(ce);
            }
            if matches!(outcome, Some(Outcome::Limit)) {
                break;
            }
        }
    }
    let status = child.lock().unwrap_or_else(|e| e.into_inner()).wait();
    running().lock().unwrap_or_else(|e| e.into_inner()).remove(slug);
    if cancelled.load(Ordering::SeqCst) {
        return Outcome::Cancelled;
    }
    match outcome {
        Some(o) => o,
        None if status.is_ok_and(|s| s.success()) => Outcome::Done,
        None => Outcome::Failed(format!("{} stopped unexpectedly.", engines::display(engine))),
    }
}

/// Runs one turn synchronously with failover. `chat_send` calls this on a background thread.
pub fn run_turn(slug: &str, text: &str, emit: &dyn Fn(ChatEvent)) {
    let fail = |msg: String| {
        let mut e = ev(slug, "error", None);
        e.text = Some(msg);
        emit(e);
    };
    let (dir, key, list) = match (|| -> Result<_, String> {
        let sd = state_dir()?;
        Ok((session::brand_dir(&sd, slug)?, keychain::get(slug)?, engines::usable(&sd)))
    })() {
        Ok(v) => v,
        Err(e) => return fail(e),
    };
    let Some(mut engine) = list.first().cloned() else {
        return fail("No AI provider is connected. Sign in under AI Providers.".into());
    };
    loop {
        match run_one(slug, &engine, text, &key, &dir, emit) {
            Outcome::Done => return emit(ev(slug, "done", Some(&engine))),
            Outcome::Cancelled => return emit(ev(slug, "cancelled", Some(&engine))),
            Outcome::Failed(m) => return fail(m),
            Outcome::Limit => match engines::next_after(&list, &engine) {
                Some(next) => {
                    let mut e = ev(slug, "notice", Some(&next));
                    e.text = Some(format!(
                        "{} reached its limit; continuing with {}.",
                        engines::display(&engine),
                        engines::display(&next)
                    ));
                    emit(e);
                    engine = next;
                }
                None => return fail(format!("{} reached its limit. Try again later.", engines::display(&engine))),
            },
        }
    }
}

pub fn send(slug: String, text: String, emit: impl Fn(ChatEvent) + Send + 'static) -> Result<(), String> {
    if !valid_slug(&slug) {
        return Err("invalid brand".into());
    }
    if text.trim().is_empty() {
        return Err("Type a message first.".into());
    }
    if running().lock().unwrap_or_else(|e| e.into_inner()).contains_key(&slug) {
        return Err("Still working on the last message.".into());
    }
    std::thread::spawn(move || run_turn(&slug, &text, &emit));
    Ok(())
}

pub fn open_url(url: &str) -> Result<(), String> {
    if !allowed_url(url) {
        return Err("That link can't be opened.".into());
    }
    std::process::Command::new("/usr/bin/open").arg(url).status().map_err(|e| e.to_string())?;
    Ok(())
}
