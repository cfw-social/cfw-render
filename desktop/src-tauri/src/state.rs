//! Pure model of the worker's `status.json`. No tauri imports — fully unit-tested.

use chrono::{DateTime, Duration, Local, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
pub enum StateError {
    #[error("status.json is not valid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("status.json has a missing or zero schema")]
    MissingSchema,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct StatusFile {
    pub schema: u32,
    pub worker_version: Option<String>,
    pub engines: Vec<Engine>,
    pub active_engine: Option<String>,
    pub computer: Computer,
    pub brands: Vec<Brand>,
    pub now: Vec<NowItem>,
    pub next: Vec<NextItem>,
    pub recent: Vec<RecentItem>,
    pub last_check_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Engine {
    pub name: String,
    pub label: Option<String>,
    pub auth: Option<String>,
    pub signed_in: bool,
    pub limit: Limit,
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Limit {
    Ok,
    Limited,
    #[default]
    #[serde(other)]
    Unknown,
}

impl Engine {
    pub fn is_limited(&self) -> bool {
        self.limit == Limit::Limited
    }
    pub fn display(&self) -> &str {
        match self.label.as_deref() {
            Some(l) if !l.is_empty() => l,
            _ => display_name(&self.name),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Computer {
    pub name: Option<String>,
    pub max: u32,
    pub running: u32,
    pub on_battery: bool,
    pub paused: bool,
    pub pause_reason: Option<String>,
    pub update_required: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Brand {
    pub id: String,
    pub name: String,
    pub serving: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct NowItem {
    pub short_code: Option<String>,
    pub brand: Option<String>,
    pub recipe: Option<String>,
    pub step: Option<u32>,
    pub steps: Option<u32>,
    pub step_label: Option<String>,
    pub pct: Option<f64>,
    pub started_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct NextItem {
    pub short_code: Option<String>,
    pub brand: Option<String>,
    pub recipe: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunResult {
    Done,
    Stopped,
    #[default]
    #[serde(other)]
    Failed,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct RecentItem {
    pub short_code: Option<String>,
    pub brand: Option<String>,
    pub result: RunResult,
    pub finished_at: Option<DateTime<Utc>>,
}

pub fn parse_status(s: &str) -> Result<StatusFile, StateError> {
    let status: StatusFile = serde_json::from_str(s)?;
    if status.schema == 0 {
        return Err(StateError::MissingSchema);
    }
    Ok(status)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Liveness {
    Running,
    NotRunning,
}

pub const STALE_AFTER_SECS: i64 = 180;

/// `mtime` is the status file's modification time, used only when `lastCheckAt` is absent.
pub fn liveness(status: Option<&StatusFile>, mtime: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Liveness {
    let Some(s) = status else { return Liveness::NotRunning };
    match s.last_check_at.or(mtime) {
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

pub fn icon_state(
    status: Option<&StatusFile>,
    mtime: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> (IconState, String) {
    let attention = |m: &str| (IconState::Attention, m.to_string());
    let s = match (status, liveness(status, mtime, now)) {
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
    let n = (s.now.len() as u32).max(s.computer.running);
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
            Some(t) => format!("{} limited until {}", e.display(), local_hhmm(t)),
            None => format!("{} limited", e.display()),
        })
        .collect();
    match (limited.is_empty(), using) {
        (true, Some(u)) => format!("AI: {}, ok", u.display()),
        (false, Some(u)) => format!("AI: {}, using {}", limited.join(", "), u.display()),
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

    fn eng(name: &str, limit: Limit) -> Engine {
        Engine { name: name.into(), signed_in: true, limit, ..Default::default() }
    }

    fn fresh() -> StatusFile {
        StatusFile {
            schema: 1,
            last_check_at: Some(now() - Duration::seconds(10)),
            engines: vec![eng("claude-code", Limit::Ok)],
            ..Default::default()
        }
    }

    const FULL: &str = r#"{ "schema": 1, "workerVersion": "1.0.0",
      "engines": [
        { "name": "codex", "label": "ChatGPT", "auth": "signin", "signedIn": true, "limit": "limited", "resetsAt": "2026-10-11T15:40:00Z" },
        { "name": "claude-code", "label": "Claude", "auth": "signin", "signedIn": true, "limit": "ok", "resetsAt": null } ],
      "activeEngine": "claude-code",
      "computer": { "name": "Priya's Mac", "max": 4, "running": 1, "onBattery": false, "paused": false, "pauseReason": null, "updateRequired": false },
      "brands": [{ "id": "b_1", "name": "Brand A", "serving": true }],
      "now":  [{ "shortCode": "R-7KQ4", "brand": "Brand A", "recipe": "Spotlight reel", "step": 5, "steps": 7, "stepLabel": "Render scenes", "pct": 62, "startedAt": "2026-10-11T11:58:00Z" }],
      "next": [{ "shortCode": "R-C1", "brand": "Brand C", "recipe": "Carousel" }],
      "recent": [{ "shortCode": "R-6TT1", "brand": "Brand A", "result": "done", "finishedAt": "2026-10-11T11:00:00Z" },
                 { "shortCode": null, "brand": null, "result": "exploded" }],
      "lastCheckAt": "2026-10-11T11:59:55Z",
      "lastError": null }"#;

    #[test]
    fn parses_full() {
        let s = parse_status(FULL).unwrap();
        assert_eq!(s.worker_version.as_deref(), Some("1.0.0"));
        assert_eq!(s.computer.max, 4);
        assert_eq!(s.computer.name.as_deref(), Some("Priya's Mac"));
        assert_eq!(s.engines[0].resets_at, Some(Utc.with_ymd_and_hms(2026, 10, 11, 15, 40, 0).unwrap()));
        assert_eq!(s.engines[0].limit, Limit::Limited);
        assert_eq!(s.engines[1].resets_at, None);
        assert_eq!(s.brands[0].name, "Brand A");
        assert_eq!(s.now[0].step, Some(5));
        assert_eq!(s.now[0].pct, Some(62.0));
        assert_eq!(s.next[0].recipe.as_deref(), Some("Carousel"));
        assert_eq!(s.recent[0].result, RunResult::Done);
        assert_eq!(s.recent[1].result, RunResult::Failed);
        assert_eq!(s.recent[1].short_code, None);
        assert_eq!(s.active_engine.as_deref(), Some("claude-code"));
    }

    #[test]
    fn parses_partial() {
        let s = parse_status(r#"{"schema":1,"computer":{"paused":true}}"#).unwrap();
        assert!(s.computer.paused);
        assert!(s.engines.is_empty() && s.now.is_empty() && s.recent.is_empty());
        assert_eq!(s.last_check_at, None);
        assert_eq!(s.active_engine, None);
    }

    #[test]
    fn rejects_missing_or_zero_schema() {
        assert!(matches!(parse_status("{}"), Err(StateError::MissingSchema)));
        assert!(matches!(parse_status(r#"{"schema":0}"#), Err(StateError::MissingSchema)));
        assert!(matches!(parse_status(r#"{"schemaVersion":1}"#), Err(StateError::MissingSchema)));
        assert!(matches!(parse_status("nope"), Err(StateError::Json(_))));
    }

    #[test]
    fn null_resets_at_and_unknown_limit() {
        let s = parse_status(r#"{"schema":1,"engines":[{"name":"x","signedIn":true,"limit":"weird","resetsAt":null},{"name":"y"}]}"#).unwrap();
        assert_eq!(s.engines[0].limit, Limit::Unknown);
        assert_eq!(s.engines[0].resets_at, None);
        assert_eq!(s.engines[1].limit, Limit::Unknown);
    }

    #[test]
    fn ignores_unknown_keys() {
        let s = parse_status(r#"{"schema":1,"future":{"a":1},"computer":{"gpu":"m4","max":2},"engines":[{"name":"codex","extra":true}]}"#).unwrap();
        assert_eq!(s.computer.max, 2);
        assert_eq!(s.engines[0].name, "codex");
    }

    #[test]
    fn liveness_rules() {
        assert_eq!(liveness(Some(&fresh()), None, now()), Liveness::Running);
        let mut old = fresh();
        old.last_check_at = Some(now() - Duration::minutes(4));
        // lastCheckAt wins over a fresh mtime
        assert_eq!(liveness(Some(&old), Some(now()), now()), Liveness::NotRunning);
        let mut fallback = fresh();
        fallback.last_check_at = None;
        assert_eq!(liveness(Some(&fallback), Some(now() - Duration::seconds(30)), now()), Liveness::Running);
        assert_eq!(liveness(Some(&fallback), Some(now() - Duration::minutes(5)), now()), Liveness::NotRunning);
        assert_eq!(liveness(Some(&fallback), None, now()), Liveness::NotRunning);
        assert_eq!(liveness(None, Some(now()), now()), Liveness::NotRunning);
    }

    fn st(s: &StatusFile) -> (IconState, String) {
        icon_state(Some(s), None, now())
    }

    #[test]
    fn icon_state_branches() {
        assert_eq!(icon_state(None, None, now()), (IconState::Attention, "Worker not running".into()));
        let mut stale = fresh();
        stale.last_check_at = Some(now() - Duration::minutes(10));
        assert_eq!(st(&stale), (IconState::Attention, "Worker not running".into()));
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
        s.engines.clear();
        assert_eq!(st(&s), (IconState::Attention, "No AI provider signed in".into()));

        let mut s = fresh();
        s.engines[0].limit = Limit::Limited;
        assert_eq!(st(&s), (IconState::Attention, "AI limit reached".into()));
        s.engines.push(eng("codex", Limit::Unknown));
        assert_eq!(st(&s).0, IconState::Idle);

        let mut s = fresh();
        s.now.push(NowItem::default());
        assert_eq!(st(&s), (IconState::Working, "Working — 1 request".into()));
        let mut s = fresh();
        s.computer.running = 2;
        assert_eq!(st(&s), (IconState::Working, "Working — 2 requests".into()));
    }

    #[test]
    fn provider_lines() {
        let s = parse_status(FULL).unwrap();
        let t = local_hhmm(Utc.with_ymd_and_hms(2026, 10, 11, 15, 40, 0).unwrap());
        assert_eq!(provider_line(Some(&s)), format!("AI: ChatGPT limited until {t}, using Claude"));
        assert_eq!(provider_line(Some(&fresh())), "AI: Claude, ok");
        let mut custom = fresh();
        custom.engines[0].label = Some("Claude Max".into());
        assert_eq!(provider_line(Some(&custom)), "AI: Claude Max, ok");
        assert_eq!(provider_line(None), "No AI provider signed in");
        let mut s = fresh();
        s.engines[0].signed_in = false;
        assert_eq!(provider_line(Some(&s)), "No AI provider signed in");
    }
}
