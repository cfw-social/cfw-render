//! Per-brand companion folder (0700) and per-provider session ids (session.json, 0600).

use std::collections::BTreeMap;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn companion_root(state_dir: &Path) -> PathBuf {
    state_dir.join("companion")
}

fn mkdir_private(p: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(p)?;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))
}

pub fn brand_dir(state_dir: &Path, slug: &str) -> Result<PathBuf, String> {
    if !super::valid_slug(slug) {
        return Err("invalid brand".into());
    }
    let root = companion_root(state_dir);
    mkdir_private(&root).map_err(|e| e.to_string())?;
    let d = root.join(slug);
    mkdir_private(&d).map_err(|e| e.to_string())?;
    Ok(d)
}

pub fn write_private(path: &Path, body: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(body).map_err(|e| e.to_string())?;
    }
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub type Sessions = BTreeMap<String, String>;

pub fn load(dir: &Path) -> Sessions {
    std::fs::read_to_string(dir.join("session.json")).ok().and_then(|r| serde_json::from_str(&r).ok()).unwrap_or_default()
}

pub fn save_id(dir: &Path, engine: &str, id: &str) -> Result<(), String> {
    let mut s = load(dir);
    s.insert(engine.to_string(), id.to_string());
    write_private(&dir.join("session.json"), &serde_json::to_vec(&s).expect("strings"))
}
