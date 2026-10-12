//! Tauri shell: tray, state-dir watcher, and commands. Logic lives in `state` / `control`.

pub mod control;
pub mod state;

use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WindowEvent, Wry};

use state::{IconState, Liveness, StatusFile};

const TRAY_ID: &str = "main";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusPayload {
    pub status: Option<StatusFile>,
    pub liveness: Liveness,
    pub icon_state: IconState,
    pub tooltip: String,
    pub provider_line: String,
}

struct AppState {
    pause_item: MenuItem<Wry>,
    _watcher: Mutex<Option<RecommendedWatcher>>,
}

fn read_status(dir: &Path) -> (Option<StatusFile>, Option<DateTime<Utc>>) {
    let path = dir.join("status.json");
    let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok().map(DateTime::<Utc>::from);
    let status = std::fs::read_to_string(&path).ok().and_then(|raw| state::parse_status(&raw).ok());
    (status, mtime)
}

fn current_payload() -> StatusPayload {
    let (status, mtime) = control::state_dir().ok().map(|d| read_status(&d)).unwrap_or((None, None));
    let now = Utc::now();
    let (icon_state, tooltip) = state::icon_state(status.as_ref(), mtime, now);
    StatusPayload {
        liveness: state::liveness(status.as_ref(), mtime, now),
        provider_line: state::provider_line(status.as_ref()),
        status,
        icon_state,
        tooltip,
    }
}

fn tray_title(s: IconState) -> &'static str {
    match s {
        IconState::Working => "●",
        IconState::Idle => "",
        IconState::Attention => "!",
    }
}

/// Re-read status.json, update the tray, and push the payload to the webview.
fn refresh(app: &AppHandle) {
    let p = current_payload();
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_tooltip(Some(format!("CFW Render — {}\n{}", p.tooltip, p.provider_line)));
        let _ = tray.set_title(Some(tray_title(p.icon_state)));
    }
    if let Some(st) = app.try_state::<AppState>() {
        let paused = p.status.as_ref().is_some_and(|s| s.computer.paused) || is_pause_file_present();
        let _ = st.pause_item.set_text(if paused { "Resume" } else { "Pause" });
    }
    let _ = app.emit("status", p);
}

fn is_pause_file_present() -> bool {
    control::state_dir().is_ok_and(|d| d.join("paused").exists())
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

fn err(e: control::ControlError) -> String {
    e.to_string()
}

fn toggle_panel(app: &AppHandle, rect: tauri::Rect) {
    let Some(w) = app.get_webview_window("panel") else { return };
    if w.is_visible().unwrap_or(false) {
        let _ = w.hide();
        return;
    }
    let scale = w.scale_factor().unwrap_or(1.0);
    let pos = rect.position.to_physical::<f64>(scale);
    let size = rect.size.to_physical::<f64>(scale);
    let width = w.outer_size().map(|s| s.width as f64).unwrap_or(360.0 * scale);
    let x = pos.x + size.width / 2.0 - width / 2.0;
    let y = pos.y + size.height;
    let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    let _ = w.show();
    let _ = w.set_focus();
}

#[tauri::command]
fn open_main(app: AppHandle, section: String) {
    if let Some(p) = app.get_webview_window("panel") {
        let _ = p.hide();
    }
    show_main(&app);
    let _ = app.emit_to("main", "navigate", section);
}

#[tauri::command]
fn start_worker() -> Result<(), String> {
    control::start_worker().map_err(err)
}

#[tauri::command]
fn open_logs() -> Result<(), String> {
    control::open_logs().map_err(err)
}

#[tauri::command]
fn get_status() -> StatusPayload {
    current_payload()
}

#[tauri::command]
fn set_paused(app: AppHandle, paused: bool) -> Result<(), String> {
    control::set_paused(paused).map_err(err)?;
    refresh(&app);
    Ok(())
}

#[tauri::command]
fn set_allow_battery(allow: bool) -> Result<(), String> {
    control::set_allow_battery(allow).map_err(err)
}

#[tauri::command]
fn run_now() -> Result<(), String> {
    control::run_now().map_err(err)
}

#[tauri::command]
fn set_engine_order(order: Vec<String>) -> Result<(), String> {
    control::write_engine_order(&order).map_err(err)
}

fn build_tray(app: &AppHandle) -> tauri::Result<(TrayIcon, MenuItem<Wry>)> {
    let open = MenuItem::with_id(app, "open", "Open CFW Render", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause", true, None::<&str>)?;
    let run = MenuItem::with_id(app, "run-now", "Run now", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &pause, &run, &sep, &quit])?;

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .tooltip("CFW Render")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                toggle_panel(tray.app_handle(), rect);
            }
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "pause" => {
                let _ = control::set_paused(!is_pause_file_present());
                refresh(app);
            }
            "run-now" => {
                let _ = control::run_now();
            }
            "quit" => app.exit(0),
            _ => {}
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    Ok((builder.build(app)?, pause))
}

fn start_watcher(app: &AppHandle) -> Option<RecommendedWatcher> {
    let dir = control::state_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    let handle = app.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if res.is_ok() {
            refresh(&handle);
        }
    })
    .ok()?;
    watcher.watch(&dir, RecursiveMode::NonRecursive).ok()?;
    Some(watcher)
}

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            get_status,
            set_paused,
            set_allow_battery,
            run_now,
            set_engine_order,
            open_main,
            start_worker,
            open_logs
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let handle = app.handle().clone();
            let (_tray, pause_item) = build_tray(&handle)?;
            let watcher = start_watcher(&handle);
            app.manage(AppState { pause_item, _watcher: Mutex::new(watcher) });

            // Liveness re-check: a dead worker produces no file events.
            let ticker = handle.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_secs(30));
                refresh(&ticker);
            });

            refresh(&handle);
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            WindowEvent::Focused(false) if window.label() == "panel" => {
                let _ = window.hide();
            }
            _ => {}
        })
        .run(tauri::generate_context!())
        .expect("error while running CFW Render");
}
