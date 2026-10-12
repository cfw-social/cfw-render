//! Pure model of the worker's `status.json`. No tauri imports — fully unit-tested.

use chrono::{DateTime, Duration, Local, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
pub enum StateError {
    #[error("status.json is not valid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("status.json has a missing or zero schemaVersion")]
    MissingSchemaVersion,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct StatusFile {
    pub schema_version: u32,
    pub written_at: Option<DateTime<Utc>>,
    pub last_check_at: Option<DateTime<Utc>>,
    pub computer: Computer,
    pub capacity: Capacity,
    pub engines: Vec<Engine>,
    pub active_engine: Option<String>,
    pub requests: Vec<Request>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Computer {
    pub worker_id: String,
    pub version: String,
    pub paused: bool,
    pub pause_reason: Option<String>,
    pub on_battery: bool,
    pub allow_battery: bool,
    pub update_required: bool,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Capacity {
    pub running: u32,
    pub max: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Engine {
    pub name: String,
    pub signed_in: bool,
    pub limit: String,
    pub resets_at: Option<DateTime<Utc>>,
}

impl Engine {
    pub fn is_limited(&self) -> bool {
        self.limit == "limited"
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Request {
    pub order_id: String,
    pub step_id: String,
    pub step_index: u32,
    pub step_count: u32,
    pub engine: String,
    pub started_at: Option<DateTime<Utc>>,
}

pub fn parse_status(s: &str) -> Result<StatusFile, StateError> {
    let status: StatusFile = serde_json::from_str(s)?;
    if status.schema_version == 0 {
        return Err(StateError::MissingSchemaVersion);
    }
    Ok(status)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Liveness {
    Running,
    NotRunning,
}

pub const STALE_AFTER_SECS: i64 = 180;

pub fn liveness(status: Option<&StatusFile>, now: DateTime<Utc>) -> Liveness {
    let Some(s) = status else { return Liveness::NotRunning };
    match s.last_check_at.or(s.written_at) {
        Some(t) if now - t <= Duration::seconds(STALE_AFTER_SECS) => Liveness::Running,
        _ => Liveness::NotRunning,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum IconState {
    Working,
    Idle,
    Attention,
}

pub fn icon_state(status: Option<&StatusFile>, now: DateTime<Utc>) -> (IconState, String) {
    let attention = |m: &str| (IconState::Attention, m.to_string());
    let s = match (status, liveness(status, now)) {
        (Some(s), Liveness::Running) => s,
        _ => return attention("Worker not running"),
    };
    if s.computer.update_required {
        return attention("Update this computer");
    }
    if s.computer.paused {
        return if s.computer.pause_reason.as_deref() == Some("battery") {
            attention("On battery")
        } else {
            attention("Paused")
        };
    }
    let signed_in: Vec<&Engine> = s.engines.iter().filter(|e| e.signed_in).collect();
    if signed_in.is_empty() {
        return attention("No AI provider signed in");
    }
    if signed_in.iter().all(|e| e.is_limited()) {
        return attention("AI limit reached");
    }
    let n = (s.requests.len() as u32).max(s.capacity.running);
    if n > 0 {
        let noun = if n == 1 { "request" } else { "requests" };
        return (IconState::Working, format!("Working — {n} {noun}"));
    }
    (IconState::Idle, "Idle".to_string())
}

pub fn display_name(engine: &str) -> &str {
    match engine {
        "codex" => "ChatGPT",
        "claude-code" => "Claude",
        other => other,
    }
}

fn local_hhmm(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%H:%M").to_string()
}

pub fn provider_line(status: Option<&StatusFile>) -> String {
    const NONE: &str = "No AI provider signed in";
    let Some(s) = status else { return NONE.to_string() };
    let signed_in: Vec<&Engine> = s.engines.iter().filter(|e| e.signed_in).collect();
    if signed_in.is_empty() {
        return NONE.to_string();
    }
    let active = s.active_engine.as_deref();
    let using = signed_in
        .iter()
        .find(|e| !e.is_limited() && Some(e.name.as_str()) == active)
        .or_else(|| signed_in.iter().find(|e| !e.is_limited()));
    let limited: Vec<String> = signed_in
        .iter()
        .filter(|e| e.is_limited())
        .map(|e| match e.resets_at {
            Some(t) => format!("{} limited until {}", display_name(&e.name), local_hhmm(t)),
            None => format!("{} limited", display_name(&e.name)),
        })
        .collect();
    match (limited.is_empty(), using) {
        (true, Some(u)) => format!("AI: {}, ok", display_name(&u.name)),
        (false, Some(u)) => format!("AI: {}, using {}", limited.join(", "), display_name(&u.name)),
        (_, None) => format!("AI: {}", limited.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 11, 12, 0, 0).unwrap()
    }

    fn fresh() -> StatusFile {
        StatusFile {
            schema_version: 1,
            last_check_at: Some(now() - Duration::seconds(10)),
            engines: vec![Engine { name: "claude-code".into(), signed_in: true, limit: "ok".into(), resets_at: None }],
            ..Default::default()
        }
    }

    const FULL: &str = r#"{ "schemaVersion": 1, "writtenAt": "2026-10-11T11:59:50Z", "lastCheckAt": "2026-10-11T11:59:55Z",
      "computer": { "workerId": "w1", "version": "1.0.0", "paused": false, "pauseReason": null, "onBattery": false,
                    "allowBattery": false, "updateRequired": false, "lastError": null },
      "capacity": { "running": 1, "max": 1 },
      "engines": [ { "name": "codex", "signedIn": true, "limit": "limited", "resetsAt": "2026-10-11T15:40:00Z" },
                   { "name": "claude-code", "signedIn": true, "limit": "ok" } ],
      "activeEngine": "claude-code",
      "requests": [ { "orderId": "o1", "stepId": "s1", "stepIndex": 3, "stepCount": 5, "engine": "claude-code", "startedAt": "2026-10-11T11:58:00Z" } ] }"#;

    #[test]
    fn parses_full() {
        let s = parse_status(FULL).unwrap();
        assert_eq!(s.computer.worker_id, "w1");
        assert_eq!(s.capacity, Capacity { running: 1, max: 1 });
        assert_eq!(s.engines[0].resets_at, Some(Utc.with_ymd_and_hms(2026, 10, 11, 15, 40, 0).unwrap()));
        assert_eq!(s.engines[1].resets_at, None);
        assert_eq!(s.requests[0].step_index, 3);
        assert_eq!(s.active_engine.as_deref(), Some("claude-code"));
    }

    #[test]
    fn parses_partial() {
        let s = parse_status(r#"{"schemaVersion":1,"computer":{"paused":true}}"#).unwrap();
        assert!(s.computer.paused);
        assert!(s.engines.is_empty());
        assert_eq!(s.last_check_at, None);
        assert_eq!(s.active_engine, None);
    }

    #[test]
    fn rejects_missing_or_zero_schema_version() {
        assert!(matches!(parse_status("{}"), Err(StateError::MissingSchemaVersion)));
        assert!(matches!(parse_status(r#"{"schemaVersion":0}"#), Err(StateError::MissingSchemaVersion)));
        assert!(matches!(parse_status("nope"), Err(StateError::Json(_))));
    }

    #[test]
    fn liveness_rules() {
        assert_eq!(liveness(Some(&fresh()), now()), Liveness::Running);
        let mut old = fresh();
        old.last_check_at = Some(now() - Duration::minutes(4));
        assert_eq!(liveness(Some(&old), now()), Liveness::NotRunning);
        let mut fallback = fresh();
        fallback.last_check_at = None;
        fallback.written_at = Some(now() - Duration::seconds(30));
        assert_eq!(liveness(Some(&fallback), now()), Liveness::Running);
        fallback.written_at = None;
        assert_eq!(liveness(Some(&fallback), now()), Liveness::NotRunning);
        assert_eq!(liveness(None, now()), Liveness::NotRunning);
    }

    fn st(s: &StatusFile) -> (IconState, String) {
        icon_state(Some(s), now())
    }

    #[test]
    fn icon_state_branches() {
        assert_eq!(icon_state(None, now()), (IconState::Attention, "Worker not running".into()));
        assert_eq!(st(&fresh()), (IconState::Idle, "Idle".into()));

        let mut s = fresh();
        s.computer.update_required = true;
        assert_eq!(st(&s), (IconState::Attention, "Update this computer".into()));

        let mut s = fresh();
        s.computer.paused = true;
        s.computer.pause_reason = Some("owner".into());
        assert_eq!(st(&s), (IconState::Attention, "Paused".into()));
        s.computer.pause_reason = Some("battery".into());
        assert_eq!(st(&s), (IconState::Attention, "On battery".into()));

        let mut s = fresh();
        s.engines[0].signed_in = false;
        assert_eq!(st(&s), (IconState::Attention, "No AI provider signed in".into()));

        let mut s = fresh();
        s.engines[0].limit = "limited".into();
        assert_eq!(st(&s), (IconState::Attention, "AI limit reached".into()));

        let mut s = fresh();
        s.requests.push(Request::default());
        assert_eq!(st(&s), (IconState::Working, "Working — 1 request".into()));
        let mut s = fresh();
        s.capacity.running = 2;
        assert_eq!(st(&s), (IconState::Working, "Working — 2 requests".into()));
    }

    #[test]
    fn provider_lines() {
        let s = parse_status(FULL).unwrap();
        let t = local_hhmm(Utc.with_ymd_and_hms(2026, 10, 11, 15, 40, 0).unwrap());
        assert_eq!(provider_line(Some(&s)), format!("AI: ChatGPT limited until {t}, using Claude"));
        assert_eq!(provider_line(Some(&fresh())), "AI: Claude, ok");
        assert_eq!(provider_line(None), "No AI provider signed in");
        let mut s = fresh();
        s.engines[0].signed_in = false;
        assert_eq!(provider_line(Some(&s)), "No AI provider signed in");
    }
}
