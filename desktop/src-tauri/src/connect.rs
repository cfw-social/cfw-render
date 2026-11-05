//! Browser-approval connect: store the minted `cfw_render_` key in the Keychain.
//! HTTP for code/poll lives in the TypeScript setup UI; this module only handles
//! the Keychain write/revoke and the API base the UI should call.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::Serialize;

use crate::chat::keychain;
use crate::support;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectStoreResult {
    pub brand_slug: Option<String>,
}

fn env_file() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".cfw-render/cfw-render.env")
}

/// Same private state dir the installer uses for connection.json / worker-id.
fn state_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".cfw-render")
}

/// API origin for `/api/v1/connect/*` (env override → settings file → prod).
/// A Local dev refusal is returned. This does not substitute the production host.
#[tauri::command]
pub fn connect_api_base() -> Result<String, String> {
    support::api_base(&env_file())
}

/// Save the approved render key to the login Keychain (account `render-worker`).
/// Never logs the key. Optionally records brandSlug in connection.json (no key).
#[tauri::command]
pub fn connect_store_worker_key(key: String, brand_slug: Option<String>) -> Result<ConnectStoreResult, String> {
    let trimmed = key.trim().to_string();
    drop(key);
    keychain::put_worker(&trimmed)?;
    drop(trimmed);

    let slug = brand_slug
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty() && crate::chat::valid_slug(s))
        .map(|s| s.to_string());
    if let Some(ref s) = slug {
        write_connection_hint(s);
    }
    Ok(ConnectStoreResult { brand_slug: slug })
}

/// Revoke the Keychain render key (SetupScreen Back / reconnect) and delete
/// the Keychain item. Best-effort revoke: always clears Keychain so a new
/// mint cannot leave two live keys on this Mac.
#[tauri::command]
pub fn connect_revoke_worker_key() -> Result<(), String> {
    let key = match keychain::get_worker() {
        Ok(k) => k,
        Err(_) => {
            let _ = keychain::delete_worker();
            return Ok(());
        }
    };
    let base = match support::api_base(&env_file()) {
        Ok(base) => base,
        Err(err) => {
            // Still drop the Keychain item. A refused local server is not a reason
            // to call the production host, and not a reason to keep the old key.
            drop(key);
            let _ = keychain::delete_worker();
            return Err(err);
        }
    };
    let revoke_result = revoke_this_computer(&base, &key);
    drop(key);
    let _ = keychain::delete_worker();
    revoke_result
}

/// POST revoke_this_computer; key travels in a 0600 header file, never argv.
fn revoke_this_computer(base: &str, key: &str) -> Result<(), String> {
    let dir = std::env::temp_dir().join(format!(
        "cfw-render-revoke-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    let hdr = dir.join("h");
    support::write_private(&hdr, format!("cfw-render-key: {key}\n").as_bytes())?;
    let url = format!("{}/api/v1/mcp", base.trim_end_matches('/'));
    let out = Command::new(support::curl_cmd())
        .args([
            "-sS",
            "--max-time",
            "15",
            "-X",
            "POST",
            &url,
            "-H",
        ])
        .arg(format!("@{}", hdr.display()))
        .args([
            "-H",
            "content-type: application/json",
            "-H",
            "accept: application/json, text/event-stream",
            "-d",
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"revoke_this_computer","arguments":{}}}"#,
        ])
        .stdin(Stdio::null())
        .output();
    let _ = fs::remove_dir_all(&dir);
    let out = out.map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err("Could not disconnect the previous key.".into());
    }
    let body = String::from_utf8_lossy(&out.stdout);
    let ok = body.contains(r#""ok":true"#) || body.contains(r#""ok": true"#);
    if ok {
        Ok(())
    } else {
        Err("Could not disconnect the previous key.".into())
    }
}

fn write_connection_hint(brand_slug: &str) {
    // Same path install/from-app.sh writes: ~/.cfw-render/connection.json
    let path = state_dir().join("connection.json");
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let body = serde_json::json!({
        "scope": "brand",
        "keyName": null,
        "keyHint": null,
        "brandSlug": brand_slug,
        "connectedAt": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
    });
    let tmp = path.with_extension("json.tmp");
    if fs::write(&tmp, body.to_string()).is_ok() {
        let _ = fs::rename(&tmp, &path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::keychain::{valid_render_key, SECURITY_ENV, WORKER_ACCOUNT};

    #[test]
    fn worker_account_name_is_render_worker() {
        assert_eq!(WORKER_ACCOUNT, "render-worker");
        assert!(valid_render_key("cfw_render_testhostkey01"));
        assert!(!valid_render_key("cfw_brandkeyonly01"));
    }

    #[test]
    fn store_rejects_non_render_key_without_touching_keychain() {
        let err = connect_store_worker_key("cfw_not_a_render_key".into(), None).unwrap_err();
        assert!(err.contains("Render key"), "{err}");
    }

    #[test]
    fn revoke_with_empty_keychain_is_ok_and_calls_delete() {
        // Share control::ENV_LOCK with chat/apikeys Keychain tests so
        // CFW_RENDER_SECURITY_CMD cannot race across threads.
        let _g = crate::control::tests::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        struct Clear;
        impl Drop for Clear {
            fn drop(&mut self) {
                std::env::remove_var(SECURITY_ENV);
            }
        }
        let _clear = Clear;
        let d = tempfile::tempdir().unwrap();
        let log = d.path().join("sec.log");
        let sec = d.path().join("security");
        std::fs::write(
            &sec,
            format!(
                "#!/bin/bash\necho \"$*\" >> '{}'\n[[ \"$1\" == find-generic-password ]] && exit 44\nexit 0\n",
                log.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&sec, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        std::env::set_var(SECURITY_ENV, &sec);
        assert!(connect_revoke_worker_key().is_ok());
        let logged = std::fs::read_to_string(&log).unwrap_or_default();
        assert!(logged.contains("find-generic-password"), "{logged}");
        assert!(logged.contains("delete-generic-password"), "{logged}");
        assert!(logged.contains("render-worker"), "{logged}");
    }
}
