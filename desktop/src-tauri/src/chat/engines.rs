//! Provider order + skip rules, mirroring the worker.

use std::path::Path;

pub const DEFAULT_ORDER: [&str; 2] = ["codex", "claude-code"];

pub fn display(engine: &str) -> &'static str {
    match engine {
        "codex" => "ChatGPT",
        "claude-code" => "Claude",
        _ => "AI",
    }
}

/// Order from `engines.json`, falling back to codex then claude-code. Unknown names dropped.
pub fn order(state_dir: &Path) -> Vec<String> {
    let parsed: Option<Vec<String>> = std::fs::read_to_string(state_dir.join("engines.json"))
        .ok()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
        .and_then(|v| v.get("order").cloned())
        .and_then(|o| serde_json::from_value(o).ok());
    let list: Vec<String> = parsed
        .unwrap_or_default()
        .into_iter()
        .filter(|n| DEFAULT_ORDER.contains(&n.as_str()))
        .collect();
    if list.is_empty() { DEFAULT_ORDER.iter().map(|s| s.to_string()).collect() } else { list }
}

/// Engines to try, in order: skip those status.json shows not signed in or limited.
/// With no status.json every engine in the order is tried.
pub fn usable(state_dir: &Path) -> Vec<String> {
    let status = std::fs::read_to_string(state_dir.join("status.json"))
        .ok()
        .and_then(|raw| crate::state::parse_status(&raw).ok());
    order(state_dir)
        .into_iter()
        .filter(|name| match &status {
            None => true,
            Some(s) => match s.engines.iter().find(|e| &e.name == name) {
                Some(e) => e.signed_in && !e.is_limited(),
                None => true,
            },
        })
        .collect()
}

pub fn next_after(list: &[String], current: &str) -> Option<String> {
    let i = list.iter().position(|n| n == current)?;
    list.get(i + 1).cloned()
}

const CODEX_LIMIT: &[&str] =
    &["usage limit", "rate limit reached", "you've hit your usage limit", "try again at", "try again in", "limit resets"];
const CLAUDE_LIMIT: &[&str] =
    &["usage limit", "rate limit", "you've reached your usage limit", "you've reached your message limit", "limit will reset", "resets at"];

pub fn is_limit(engine: &str, msg: &str) -> bool {
    let m = msg.to_lowercase().replace('\u{2019}', "'");
    let phrases = if engine == "codex" { CODEX_LIMIT } else { CLAUDE_LIMIT };
    phrases.iter().any(|p| m.contains(p))
}
