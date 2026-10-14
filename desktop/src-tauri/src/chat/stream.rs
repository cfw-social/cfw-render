//! Pure parsers: one stdout line from a CLI → zero or more chat events.

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Text(String),
    ToolCall { name: String },
    Link { label: String, url: String },
    SessionId(String),
    Done,
    LimitHit(String),
    Error(String),
}

/// `https://<host>...` URLs in `text`, cut at whitespace/quotes/brackets and trailing punctuation.
pub fn links(text: &str, host: &str) -> Vec<Event> {
    let prefix = format!("https://{host}");
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(i) = rest.find(&prefix) {
        let tail = &rest[i..];
        let end = tail.find(|c: char| c.is_whitespace() || "\"'<>()[]{}`\\".contains(c)).unwrap_or(tail.len());
        let url = tail[..end].trim_end_matches(['.', ',', ';', ':', '!', '?']);
        let after = &tail[prefix.len()..url.len().max(prefix.len())];
        if after.is_empty() || after.starts_with('/') {
            let ev = Event::Link { label: label_for(url), url: url.to_string() };
            if !out.contains(&ev) {
                out.push(ev);
            }
        }
        rest = &tail[end.max(1)..];
    }
    out
}

fn label_for(url: &str) -> String {
    let path = url.splitn(4, '/').nth(3).unwrap_or("");
    let last = path.split(['?', '#']).next().unwrap_or("").trim_end_matches('/').rsplit('/').next().unwrap_or("");
    if last.is_empty() { "Open in CFW".into() } else { format!("Open {last}") }
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_string)
}

fn mcp_name(raw: &str) -> String {
    // claude names MCP tools `mcp__<server>__<tool>`.
    raw.rsplit("__").next().unwrap_or(raw).to_string()
}

pub fn parse_claude(line: &str, host: &str) -> Vec<Event> {
    let Ok(v) = serde_json::from_str::<Value>(line.trim()) else { return vec![] };
    let mut out = Vec::new();
    match v.get("type").and_then(Value::as_str) {
        Some("system") if s(&v, "subtype").as_deref() == Some("init") => {
            if let Some(id) = s(&v, "session_id") {
                out.push(Event::SessionId(id));
            }
        }
        Some("assistant") => {
            for c in v.pointer("/message/content").and_then(Value::as_array).into_iter().flatten() {
                match c.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        let t = s(c, "text").unwrap_or_default();
                        if super::engines::is_limit("claude-code", &t) && v.get("error").is_some() {
                            out.push(Event::LimitHit(t));
                            continue;
                        }
                        let l = links(&t, host);
                        out.push(Event::Text(t));
                        out.extend(l);
                    }
                    Some("tool_use") => out.push(Event::ToolCall { name: mcp_name(&s(c, "name").unwrap_or_default()) }),
                    _ => {}
                }
            }
        }
        Some("user") => {
            // tool results: surface links only.
            if let Some(content) = v.pointer("/message/content") {
                out.extend(links(&content.to_string(), host));
            }
        }
        Some("result") => {
            let msg = s(&v, "result").unwrap_or_default();
            let is_err = v.get("is_error").and_then(Value::as_bool).unwrap_or(false);
            if is_err && super::engines::is_limit("claude-code", &msg) {
                out.push(Event::LimitHit(msg));
            } else if is_err {
                out.push(Event::Error(msg));
            } else {
                out.push(Event::Done);
            }
        }
        _ => {}
    }
    out
}

pub fn parse_codex(line: &str, host: &str) -> Vec<Event> {
    let Ok(v) = serde_json::from_str::<Value>(line.trim()) else { return vec![] };
    let mut out = Vec::new();
    match v.get("type").and_then(Value::as_str) {
        Some("thread.started") => {
            if let Some(id) = s(&v, "thread_id") {
                out.push(Event::SessionId(id));
            }
        }
        Some("item.completed") => {
            let item = v.get("item").cloned().unwrap_or(Value::Null);
            match item.get("type").and_then(Value::as_str) {
                Some("agent_message") => {
                    let t = s(&item, "text").unwrap_or_default();
                    let l = links(&t, host);
                    out.push(Event::Text(t));
                    out.extend(l);
                }
                Some("mcp_tool_call") => {
                    out.push(Event::ToolCall { name: s(&item, "tool").unwrap_or_default() });
                    if let Some(r) = item.get("result") {
                        out.extend(links(&r.to_string(), host));
                    }
                }
                _ => {}
            }
        }
        Some("turn.completed") => out.push(Event::Done),
        Some("error") | Some("turn.failed") => {
            let msg = s(&v, "message").or_else(|| v.pointer("/error/message").and_then(Value::as_str).map(str::to_string)).unwrap_or_default();
            out.push(if super::engines::is_limit("codex", &msg) { Event::LimitHit(msg) } else { Event::Error(msg) });
        }
        _ => {}
    }
    out
}
