//! Turn-level tests with stub `claude`/`codex`/`security` scripts. No real CLI is run.

use super::*;
use std::os::unix::fs::PermissionsExt;
use std::sync::mpsc;
use std::time::Duration;

const KEY: &str = "cfw_TESTkey_0123456789abcdef";

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/chat").join(name)
}

fn script(path: &Path, body: &str) {
    std::fs::write(path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

struct Env {
    _g: std::sync::MutexGuard<'static, ()>,
    state: tempfile::TempDir,
    bin: tempfile::TempDir,
    logs: tempfile::TempDir,
}

/// claude/codex stubs: record argv (one per line) + stdin + env, then replay a fixture.
/// `sleep` makes the stub hang after output (for cancel).
fn setup(claude_fx: &str, codex_fx: &str, sleep: bool) -> Env {
    let g = crate::control::tests::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let (state, bin, logs) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let l = logs.path().display();
    for (name, fx) in [("claude", claude_fx), ("codex", codex_fx)] {
        let tail = if sleep { "exec /bin/sleep 30\n" } else { "" };
        script(
            &bin.path().join(name),
            &format!(
                "for a in \"$@\"; do printf '%s\\n' \"$a\"; done >> '{l}/argv-{name}'\n/bin/cat > '{l}/stdin-{name}'\n/usr/bin/env > '{l}/env-{name}'\n/bin/pwd > '{l}/cwd-{name}'\n/bin/cat '{}'\n{tail}",
                fixture(fx).display()
            ),
        );
    }
    let kc = logs.path().join("keychain");
    std::fs::create_dir_all(&kc).unwrap();
    let k = kc.display();
    script(
        &bin.path().join("security"),
        &format!(
            r#"echo "$@" >> '{l}/argv-security'
if [ "$1" = "-i" ]; then
  read cmd; set -- $cmd
fi
op=$1; shift; acct=""; pw=""
while [ $# -gt 0 ]; do case "$1" in -a) acct=$2; shift 2;; -w) if [ $# -gt 1 ]; then pw=$2; shift 2; else shift; fi;; -s) shift 2;; *) shift;; esac; done
case $op in
  add-generic-password) printf '%s' "$pw" > '{k}'/"$acct";;
  find-generic-password) [ -f '{k}'/"$acct" ] && cat '{k}'/"$acct" && echo || exit 44;;
  delete-generic-password) rm -f '{k}'/"$acct";;
esac
"#
        ),
    );
    std::env::set_var("CFW_RENDER_STATE_DIR", state.path());
    std::env::set_var(crate::signin::CLI_PATH_ENV, bin.path());
    std::env::set_var(keychain::SECURITY_ENV, bin.path().join("security"));
    std::env::remove_var(MCP_URL_ENV);
    Env { _g: g, state, bin, logs }
}

fn collect(slug: &str, text: &str) -> Vec<ChatEvent> {
    let out = Mutex::new(Vec::new());
    run_turn(slug, text, &|e| out.lock().unwrap().push(e));
    out.into_inner().unwrap()
}

fn read(p: PathBuf) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

fn assert_key_absent(env: &Env, events: &[ChatEvent]) {
    let json = serde_json::to_string(events).unwrap();
    assert!(!json.contains(KEY), "key leaked into events");
    for f in walk(env.state.path()) {
        assert!(!String::from_utf8_lossy(&std::fs::read(&f).unwrap()).contains(KEY), "key in {f:?}");
    }
    assert!(!read(env.logs.path().join("argv-codex")).contains(KEY), "key on codex argv");
    assert!(!read(env.logs.path().join("argv-security")).contains(KEY), "key on security argv");
    let _ = &env.bin;
}

fn walk(d: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() { v.extend(walk(&p)) } else { v.push(p) }
    }
    v
}

fn order(env: &Env, o: &[&str]) {
    std::fs::write(env.state.path().join("engines.json"), serde_json::json!({ "order": o }).to_string()).unwrap();
}

fn kinds(ev: &[ChatEvent]) -> Vec<&str> {
    ev.iter().map(|e| e.kind.as_str()).collect()
}

#[test]
fn claude_turn_streams_and_saves_session() {
    let env = setup("claude-turn.jsonl", "codex-turn.jsonl", false);
    add_brand("brand-a", "Brand A", KEY).unwrap();
    order(&env, &["claude-code", "codex"]);
    let ev = collect("brand-a", "what's waiting?");
    assert_eq!(kinds(&ev), ["tool", "link", "text", "done"], "{ev:?}");
    assert_eq!(ev[0].name.as_deref(), Some("list_compositions"));
    assert_eq!(ev[1].url.as_deref(), Some("https://app.cfw.social/brand-a/compositions/c1"));
    assert!(ev[2].text.as_deref().unwrap().starts_with("You have one draft"));
    let dir = env.state.path().join("companion/brand-a");
    assert_eq!(session::load(&dir).get("claude-code").map(String::as_str), Some("claude-sess-1"));
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(dir.join("session.json")).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(read(env.logs.path().join("stdin-claude")), "what's waiting?");
    let argv = read(env.logs.path().join("argv-claude"));
    assert!(argv.contains("--strict-mcp-config") && argv.contains("https://app.cfw.social/api/v1/mcp"));
    assert_eq!(read(env.logs.path().join("cwd-claude")).trim(), std::fs::canonicalize(&dir).unwrap().to_str().unwrap());
    // claude has no env-indirection for MCP headers: the inline config carries the key (argv only).
    assert!(argv.contains(KEY));
    assert_key_absent(&env, &ev);

    // Second turn resumes the saved session.
    collect("brand-a", "and now?");
    assert!(read(env.logs.path().join("argv-claude")).contains("--resume\nclaude-sess-1\n"));
}

#[test]
fn codex_turn_uses_env_header_and_resumes() {
    let env = setup("claude-turn.jsonl", "codex-turn.jsonl", false);
    add_brand("brand-a", "Brand A", KEY).unwrap();
    let ev = collect("brand-a", "hi");
    assert_eq!(kinds(&ev), ["tool", "link", "text", "done"], "{ev:?}");
    assert_eq!(ev[0].name.as_deref(), Some("list_runs"));
    assert_eq!(ev[0].engine.as_deref(), Some("codex"));
    let argv = read(env.logs.path().join("argv-codex"));
    assert!(argv.contains("mcp_servers.cfw.env_http_headers.x-api-key=\"CFW_BRAND_KEY\""));
    assert!(argv.contains("--skip-git-repo-check"));
    let child_env = read(env.logs.path().join("env-codex"));
    assert!(child_env.contains(&format!("CFW_BRAND_KEY={KEY}")));
    let names: Vec<&str> = child_env.lines().filter_map(|l| l.split('=').next()).collect();
    for n in &names {
        assert!(["HOME", "PATH", "CFW_BRAND_KEY", "PWD", "SHLVL", "_", "OLDPWD"].contains(n), "unexpected env {n}");
    }
    assert_key_absent(&env, &ev);
    collect("brand-a", "again");
    assert!(read(env.logs.path().join("argv-codex")).contains("exec\nresume\n"));
    assert!(read(env.logs.path().join("argv-codex")).contains("codex-thread-1\n-\n"));
}

#[test]
fn codex_limit_fails_over_to_claude_with_one_notice() {
    let env = setup("claude-turn.jsonl", "codex-limit.jsonl", false);
    add_brand("brand-a", "Brand A", KEY).unwrap();
    let ev = collect("brand-a", "hi");
    let notices: Vec<_> = ev.iter().filter(|e| e.kind == "notice").collect();
    assert_eq!(notices.len(), 1);
    assert_eq!(notices[0].text.as_deref(), Some("ChatGPT reached its limit; continuing with Claude."));
    assert_eq!(ev.last().unwrap().kind, "done");
    assert_eq!(ev.last().unwrap().engine.as_deref(), Some("claude-code"));
    assert_eq!(read(env.logs.path().join("stdin-claude")), "hi");
    assert!(!ev.iter().any(|e| e.kind == "error"));
    assert_key_absent(&env, &ev);
}

#[test]
fn skips_engines_not_signed_in_or_limited() {
    let env = setup("claude-turn.jsonl", "codex-turn.jsonl", false);
    let s = serde_json::json!({"schema":1,"engines":[{"name":"codex","signedIn":true,"limit":"limited"},{"name":"claude-code","signedIn":true,"limit":"ok"}]});
    std::fs::write(env.state.path().join("status.json"), s.to_string()).unwrap();
    assert_eq!(engines::usable(env.state.path()), ["claude-code"]);
    let s = serde_json::json!({"schema":1,"engines":[{"name":"codex","signedIn":false},{"name":"claude-code","signedIn":false}]});
    std::fs::write(env.state.path().join("status.json"), s.to_string()).unwrap();
    add_brand("brand-a", "Brand A", KEY).unwrap();
    let ev = collect("brand-a", "hi");
    assert_eq!(kinds(&ev), ["error"]);
}

#[test]
fn cancel_kills_the_child() {
    let env = setup("claude-turn.jsonl", "codex-turn.jsonl", true);
    add_brand("brand-a", "Brand A", KEY).unwrap();
    let (tx, rx) = mpsc::channel();
    send("brand-a".into(), "hi".into(), move |e| tx.send(e).unwrap()).unwrap();
    // wait for output then cancel (stub hangs in `sleep 30`)
    loop {
        let e = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        if e.kind == "text" {
            break;
        }
    }
    let start = std::time::Instant::now();
    assert!(cancel("brand-a").unwrap());
    let last = loop {
        let e = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        if e.kind != "link" {
            break e;
        }
    };
    assert_eq!(last.kind, "cancelled");
    assert!(start.elapsed() < Duration::from_secs(5));
    assert!(!cancel("brand-a").unwrap());
    let _ = env;
}

#[test]
fn bad_slugs_rejected() {
    let _env = setup("claude-turn.jsonl", "codex-turn.jsonl", false);
    for s in ["../x", "", "A", "a/b", &"a".repeat(65)] {
        assert!(!valid_slug(s));
        assert!(add_brand(s, "X", KEY).is_err());
        assert!(send(s.into(), "hi".into(), |_| {}).is_err());
        assert!(remove_brand(s).is_err());
        assert!(keychain::get(s).is_err());
    }
    assert!(valid_slug("brand-a-2"));
}

#[test]
fn keychain_roundtrip_and_remove_brand() {
    let env = setup("claude-turn.jsonl", "codex-turn.jsonl", false);
    assert!(keychain::put("brand-a", "cfw_x\nadd-generic-password").is_err());
    assert!(keychain::put("brand-a", "nope").is_err());
    let list = add_brand("brand-a", "Brand A", KEY).unwrap();
    assert_eq!(list, vec![Brand { slug: "brand-a".into(), name: "Brand A".into() }]);
    assert_eq!(keychain::get("brand-a").unwrap(), KEY);
    let raw = read(env.state.path().join("companion/brands.json"));
    assert_eq!(raw, r#"[{"slug":"brand-a","name":"Brand A"}]"#);
    assert!(read(env.logs.path().join("argv-security")).contains("-i"));
    assert_key_absent(&env, &[]);
    assert!(remove_brand("brand-a").unwrap().is_empty());
    assert!(keychain::get("brand-a").is_err());
    assert!(!env.state.path().join("companion/brand-a").exists());
}

#[test]
fn parsers_and_urls() {
    let host = "app.cfw.social";
    assert_eq!(stream::parse_codex(r#"{"type":"turn.failed","error":{"message":"boom"}}"#, host), [stream::Event::Error("boom".into())]);
    assert!(matches!(stream::parse_claude(r#"{"type":"result","is_error":true,"result":"You've reached your usage limit"}"#, host)[0], stream::Event::LimitHit(_)));
    assert!(stream::links("see https://evil.com/x and https://app.cfw.social.evil.com/y", host).is_empty());
    assert!(allowed_url("https://app.cfw.social/a/b"));
    assert!(!allowed_url("http://app.cfw.social/a"));
    assert!(!allowed_url("https://app.cfw.social.evil.com/"));
    assert!(!allowed_url("https://app.cfw.social@evil.com/"));
    assert!(engines::is_limit("codex", "Try again at 5pm"));
    assert!(!engines::is_limit("codex", "all good"));
}
