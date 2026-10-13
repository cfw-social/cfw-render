//! Embedded app.cfw.social in a child webview (`web`) of the `main` window, right of the 208px rail.
//!
//! Security: the child loads a remote URL; `capabilities/*.json` grant nothing to remote origins
//! (no `remote` key) nor to the `web` label, so Tauri's IPC ACL rejects every invoke from it.

use tauri::webview::{NewWindowResponse, WebviewBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, Url, WebviewUrl};

pub const LABEL: &str = "web";
pub const RAIL_WIDTH: f64 = 208.0;
const DEFAULT_BASE: &str = "https://app.cfw.social";

fn user_agent() -> String {
    format!(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 CFWRender/{}",
        env!("CARGO_PKG_VERSION")
    )
}

fn parse_http(s: &str) -> Option<Url> {
    Url::parse(s).ok().filter(|u| matches!(u.scheme(), "http" | "https") && u.host().is_some())
}

/// `CFW_RENDER_WEB_BASE` → API base (env / worker env file) → app.cfw.social.
pub fn web_base() -> Url {
    if let Some(u) = std::env::var("CFW_RENDER_WEB_BASE").ok().filter(|b| !b.is_empty()).and_then(|b| parse_http(&b)) {
        return u;
    }
    let env_file = crate::control::state_dir().map(|d| d.join("cfw-render.env")).unwrap_or_default();
    parse_http(&crate::support::api_base(&env_file)).unwrap_or_else(|| Url::parse(DEFAULT_BASE).expect("default base"))
}

fn valid_slug(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 63
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

pub fn section_url(base: &Url, slug: Option<&str>, section: &str) -> Result<Url, String> {
    let slug = match slug {
        Some(s) if !valid_slug(s) => return Err(format!("invalid brand slug: {s:?}")),
        other => other,
    };
    let path = match (section, slug) {
        ("all", _) => "/all".to_string(),
        ("login", _) => "/login".to_string(),
        ("home" | "reviews" | "assistant" | "posts", None) => "/".to_string(),
        ("home", Some(s)) => format!("/{s}"),
        ("reviews" | "assistant" | "posts", Some(s)) => format!("/{s}/{section}"),
        _ => return Err(format!("unknown section: {section:?}")),
    };
    base.join(&path).map_err(|e| e.to_string())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavDecision {
    Allow,
    OpenExternal,
    Block,
}

pub fn nav_decision(base: &Url, target: &Url) -> NavDecision {
    if target.as_str() == "about:blank" {
        return NavDecision::Allow;
    }
    if !matches!(target.scheme(), "http" | "https") {
        return NavDecision::Block;
    }
    if target.scheme() == base.scheme()
        && target.host_str() == base.host_str()
        && target.port_or_known_default() == base.port_or_known_default()
    {
        NavDecision::Allow
    } else {
        NavDecision::OpenExternal
    }
}

fn open_external(url: &Url) {
    if matches!(url.scheme(), "http" | "https") {
        let _ = std::process::Command::new("/usr/bin/open").arg(url.as_str()).spawn();
    }
}

fn child_bounds(app: &AppHandle) -> Option<(LogicalPosition<f64>, LogicalSize<f64>)> {
    let w = app.get_window("main")?;
    let scale = w.scale_factor().ok()?;
    let size = w.inner_size().ok()?.to_logical::<f64>(scale);
    Some((LogicalPosition::new(RAIL_WIDTH, 0.0), LogicalSize::new((size.width - RAIL_WIDTH).max(0.0), size.height)))
}

/// Re-place the child right of the rail at full height (called on main-window resize).
pub fn layout(app: &AppHandle) {
    let (Some(wv), Some((pos, size))) = (app.get_webview(LABEL), child_bounds(app)) else { return };
    let _ = wv.set_position(pos);
    let _ = wv.set_size(size);
}

#[tauri::command]
pub fn web_show(app: AppHandle, section: String, slug: Option<String>) -> Result<(), String> {
    let base = web_base();
    let url = section_url(&base, slug.as_deref(), &section)?;
    match app.get_webview(LABEL) {
        Some(wv) => wv.navigate(url).map_err(|e| e.to_string())?,
        None => {
            let main = app.get_window("main").ok_or("main window not found")?;
            let (pos, size) = child_bounds(&app).ok_or("main window has no size")?;
            let nav_base = base.clone();
            let builder = WebviewBuilder::new(LABEL, WebviewUrl::External(url))
                .user_agent(&user_agent())
                .on_navigation(move |u| match nav_decision(&nav_base, u) {
                    NavDecision::Allow => true,
                    NavDecision::OpenExternal => {
                        open_external(u);
                        false
                    }
                    NavDecision::Block => false,
                })
                .on_new_window(|u, _features| {
                    open_external(&u);
                    NewWindowResponse::Deny
                });
            main.add_child(builder, pos, size).map_err(|e| e.to_string())?;
        }
    }
    layout(&app);
    app.get_webview(LABEL).ok_or("web view missing")?.show().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn web_hide(app: AppHandle) -> Result<(), String> {
    match app.get_webview(LABEL) {
        Some(wv) => wv.hide().map_err(|e| e.to_string()),
        None => Ok(()),
    }
}

#[tauri::command]
pub fn web_reload(app: AppHandle) -> Result<(), String> {
    match app.get_webview(LABEL) {
        Some(wv) => wv.reload().map_err(|e| e.to_string()),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Url {
        Url::parse("https://app.cfw.social").unwrap()
    }
    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn section_urls() {
        let b = base();
        let s = |sec| section_url(&b, Some("acme-co"), sec).unwrap().to_string();
        assert_eq!(s("home"), "https://app.cfw.social/acme-co");
        assert_eq!(s("reviews"), "https://app.cfw.social/acme-co/reviews");
        assert_eq!(s("assistant"), "https://app.cfw.social/acme-co/assistant");
        assert_eq!(s("posts"), "https://app.cfw.social/acme-co/posts");
        assert_eq!(s("all"), "https://app.cfw.social/all");
        assert_eq!(s("login"), "https://app.cfw.social/login");
        for sec in ["home", "reviews", "assistant", "posts"] {
            assert_eq!(section_url(&b, None, sec).unwrap().to_string(), "https://app.cfw.social/");
        }
        assert_eq!(section_url(&b, None, "all").unwrap().path(), "/all");
        assert!(section_url(&b, Some("../x"), "home").is_err());
        assert!(section_url(&b, Some("A B"), "home").is_err());
        assert!(section_url(&b, Some("-x"), "home").is_err());
        assert!(section_url(&b, Some(&"a".repeat(64)), "home").is_err());
        assert!(section_url(&b, Some("acme"), "settings").is_err());
    }

    #[test]
    fn nav_decisions() {
        let b = base();
        assert_eq!(nav_decision(&b, &u("https://app.cfw.social/acme/posts?x=1")), NavDecision::Allow);
        assert_eq!(nav_decision(&b, &u("about:blank")), NavDecision::Allow);
        assert_eq!(nav_decision(&b, &u("https://example.com/")), NavDecision::OpenExternal);
        assert_eq!(nav_decision(&b, &u("http://app.cfw.social/")), NavDecision::OpenExternal);
        assert_eq!(nav_decision(&b, &u("https://app.cfw.social:8443/")), NavDecision::OpenExternal);
        assert_eq!(nav_decision(&b, &u("javascript:alert(1)")), NavDecision::Block);
        assert_eq!(nav_decision(&b, &u("file:///etc/passwd")), NavDecision::Block);
        assert_eq!(nav_decision(&b, &u("cfw://x")), NavDecision::Block);
    }

    #[test]
    fn capabilities_grant_nothing_to_remote_or_web() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("capabilities");
        let mut n = 0;
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.extension().and_then(|x| x.to_str()) != Some("json") {
                continue;
            }
            n += 1;
            let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
            assert!(v.get("remote").is_none(), "{p:?} has a remote section");
            for key in ["windows", "webviews"] {
                if let Some(list) = v.get(key).and_then(|l| l.as_array()) {
                    assert!(list.iter().all(|w| w != LABEL && w != "*"), "{p:?} grants {key} to web");
                }
            }
        }
        assert!(n > 0);
    }
}
