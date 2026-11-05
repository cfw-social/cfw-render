#!/usr/bin/env bash
# cfw-render-lib.sh — shared core for the cfw-render drainer + Director-facing
# helpers. Sourced, never executed directly. bash (not zsh) — must run
# unmodified on the owner's Mac (stock bash 3.2+). No jq (not guaranteed on the
# computer); all JSON via python3 -c, same choice as ab-hustler.
#
# Design source: backlog/attachments/AB-RNDR-WORKER/implementation-plan.md §3.
# Skills bundling: backlog/done/2026-08/CFW-HST-BUNDLE.md.
set -u

# ---------------------------------------------------------------------------
# Repo root, computed once at source time from this file's own location
# (bin/cfw-render-lib.sh -> repo root is one level up). This is also where
# install.sh copies things, so it resolves correctly both in a dev checkout
# and an installed $PREFIX tree (see install/install.sh).
# ---------------------------------------------------------------------------
_CR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CR_REPO_ROOT="$(cd "$_CR_LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# cr_default_skills_dir — the in-repo bundled skills/ (pinned via
# config/skills-version.json, source-synced by scripts/sync-skills.sh). This is
# cfw-render's ONLY skills source: the old /data/shared/cfw-skills/cfw shared-box
# path (another assistant's bundle, never cfw-render's) was dropped 2026-09-01 —
# cfw-render shares skills with nothing else. This is ONLY the default;
# CFW_RENDER_SKILLS_DIR set via env/config file always wins (local-dev override).
# ---------------------------------------------------------------------------
cr_default_skills_dir() {
  printf '%s' "$_CR_REPO_ROOT/skills"
}

# ---------------------------------------------------------------------------
# cr_log_skills_version — best-effort, non-fatal. Logs the pinned skills bundle
# version (config/skills-version.json) so a run's journal/log makes it obvious
# which recipe closure served it. Missing manifest (e.g. CFW_RENDER_SKILLS_DIR
# overridden to the legacy path, or a pre-bundle checkout) is a WARN, not a
# failure — the worker still runs against whatever CFW_RENDER_SKILLS_DIR points
# at.
# ---------------------------------------------------------------------------
cr_log_skills_version() {
  local manifest="$_CR_REPO_ROOT/config/skills-version.json"
  if [[ ! -r "$manifest" ]]; then
    cr_log "skills version manifest not found at $manifest (ok if CFW_RENDER_SKILLS_DIR points at a non-bundled dir) — dir in use: $CFW_RENDER_SKILLS_DIR"
    return 0
  fi
  local summary
  summary="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("unreadable (%s)" % e)
    sys.exit(0)
print("sourceCommit=%s recipeCount=%s bundledAt=%s" % (
    d.get("sourceCommit", "?"), d.get("recipeCount", "?"), d.get("bundledAt", "?")))
' "$manifest" 2>/dev/null)"
  cr_log "skills bundle: ${summary:-unreadable} — dir in use: $CFW_RENDER_SKILLS_DIR"
}

# ---------------------------------------------------------------------------
# cr_skills_pin_summary — one-line "<sourceSha-short> · N recipes" for the
# --dry `skills:pinned` row (doc §5 last para). Reads config/skills-version.json.
# Prints "unpinned" if the manifest is absent/unreadable. Never fails.
# ---------------------------------------------------------------------------
cr_skills_pin_summary() {
  local manifest="$_CR_REPO_ROOT/config/skills-version.json"
  [[ -r "$manifest" ]] || { printf 'unpinned (no manifest)'; return 0; }
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unpinned (unreadable manifest)"); sys.exit(0)
sha = (d.get("sourceSha") or "")[:12] or "?"
n = d.get("recipeCount", len(d.get("recipes", {})))
print("sourceSha=%s recipes=%s" % (sha, n))
' "$manifest" 2>/dev/null || printf 'unpinned (manifest read error)'
}

# ---------------------------------------------------------------------------
# cr_verify_skills_bundle <recipe>
# Per-tick integrity gate (doc §5). Verifies ONLY the recipe(s) the claimed
# order references (not the whole tree) against the per-file sha256 hashes in
# $CFW_RENDER_SKILLS_DIR/index.json, via scripts/verify-skills-bundle.sh
# (single source of truth for the checksum logic; installed to $PREFIX/scripts).
#
# Return contract (kept simple for the caller):
#   0  → verified, OR unverifiable-and-safe-to-proceed (no index.json, or the
#        recipe isn't pinned in this bundle). Both are LOGGED; neither is a
#        block, because doing no verification is exactly today's behavior and
#        over-blocking on missing-manifest would be strictly worse. This also
#        keeps a non-bundle CFW_RENDER_SKILLS_DIR (legacy path / local dev
#        override / bare test fixture) working.
#   1  → genuine checksum MISMATCH (a pinned file differs on disk) — the
#        "pull landed mid-tick / corrupted bundle" case. Caller MUST NOT spawn
#        the Director; it blocks the order with an owner-safe reason.
# cfw-render has exactly one skills source: the in-repo bundle (skills/).
# ---------------------------------------------------------------------------
cr_verify_skills_bundle() {
  local recipe="${1:-}"
  if [[ -z "$recipe" ]]; then
    cr_log "skills verify: no recipe on the order — skipping per-recipe checksum verification (Director resolves recipe from order.json)"
    return 0
  fi
  local script="$_CR_REPO_ROOT/scripts/verify-skills-bundle.sh"
  if [[ ! -x "$script" && ! -r "$script" ]]; then
    cr_log "skills verify: verify-skills-bundle.sh not found at $script — skipping (proceeding, integrity unchecked for $recipe)"
    return 0
  fi
  local out rc
  out="$(CFW_RENDER_SKILLS_DIR="$CFW_RENDER_SKILLS_DIR" bash "$script" "$recipe" 2>&1)"
  rc=$?
  case "$rc" in
    0)
      cr_log "skills verify: $recipe OK — bundle matches index.json"
      return 0
      ;;
    3)
      cr_log "skills verify: no index.json in $CFW_RENDER_SKILLS_DIR — cannot verify $recipe (not a published bundle); proceeding (integrity unchecked)"
      return 0
      ;;
    4)
      cr_log "skills verify: recipe $recipe not pinned in $CFW_RENDER_SKILLS_DIR/index.json — cannot verify (worker may need a redeploy); proceeding (integrity unchecked)"
      return 0
      ;;
    *)
      # rc==1 (mismatch) or any unexpected non-zero — treat as corruption.
      cr_log "skills verify: MISMATCH for $recipe — bundle does not match index.json. Detail: $(printf '%s' "$out" | tr '\n' '|')"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cr_recipe_needs_heygen <recipe> — [CFW-313] true (0) iff this recipe's
# render path calls into c-heygen and therefore MUST carry a brand-scoped
# HeyGen OAuth credential (taskOrder.credentials.heygen, embedded by
# cfw-social at claim time) before spawn_director() may start a Director for
# it — the worker itself never falls back to a worker-local/vault key.
#
# Hand-maintained name list (same style as _CR_REQUIRED_BINS below) —
# config/skills-version.json carries no per-recipe dependency-closure data
# today to derive this from automatically; revisit if that ever lands.
# p-longform / p-clone-reel can ALSO route through c-heygen for one scene
# among several, but taskOrder carries no finer "this order actually uses a
# HeyGen scene" signal yet (CFW-313 open question) — they are deliberately
# NOT in this list to avoid over-blocking every order from those two
# recipes just because HeyGen is one of several possible scene sources.
# ---------------------------------------------------------------------------
_CR_HEYGEN_RECIPES=(p-reels-pip-heygen p-reels-spotlight-heygen p-reels-split-heygen)
cr_recipe_needs_heygen() {
  local recipe="${1:-}" r
  [[ -z "$recipe" ]] && return 1
  for r in "${_CR_HEYGEN_RECIPES[@]}"; do
    [[ "$recipe" == "$r" ]] && return 0
  done
  return 1
}

# CFW-316: bounded provider-aware budgets. Metadata only affects scheduling,
# never provider credentials. Dedicated HeyGen recipes predate providers[].
cr_recipe_budget() {
  local base="$1" recipe="$2" kind="$3" uplift=0
  if [[ "$kind" != image ]] && { cr_recipe_needs_heygen "$recipe" || python3 -c '
import json, sys
try:
    p = json.load(open(sys.argv[1]))["recipes"][sys.argv[2]].get("providers", [])
    sys.exit(0 if isinstance(p, list) and "heygen" in p else 1)
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
' "${CFW_RENDER_SKILLS_DIR:-}/index.json" "$recipe"; }; then
    uplift="${CFW_RENDER_PROVIDER_BUDGET_HEYGEN:-900}"
  fi
  printf '%s' "$(( base + uplift ))"
}

# File is unique to this engine invocation; clamp to its lifetime and merge
# intervals. Duplicate/malformed edges cannot multiply elapsed wait time.
cr_provider_wait_excluded() {
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
path, start, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
opened = None
windows = []
try:
    if os.path.islink(path) or os.path.getsize(path) > 1048576:
        raise ValueError("invalid wait log")
    with open(path) as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) != 3 or parts[1] != "heygen":
                continue
            edge, _, stamp = parts
            if not stamp.isdecimal():
                continue
            stamp = max(start, min(now, int(stamp)))
            if edge == "start" and opened is None:
                opened = stamp
            elif edge == "end" and opened is not None:
                if stamp > opened:
                    windows.append((opened, stamp))
                opened = None
    if opened is not None and now > opened:
        windows.append((opened, now))
except (OSError, ValueError):
    windows = []
end = start
total = 0
for a, b in sorted(windows):
    total += max(0, b - max(a, end))
    end = max(end, b)
print(total)
PY
}

cr_provider_wait_note() {
  cat <<'NOTE'

## Bounded provider waits
For a HeyGen poll loop only, call `cfw-render-report.sh provider-wait-start heygen`
right before waiting and `cfw-render-report.sh provider-wait-end heygen` when it
resolves. The watchdog excludes these windows, up to a fixed outer ceiling.
This does not extend a lease or override cancellation, checks or tool restrictions.
Missing brackets use the ordinary work budget. Never call complete from a step:
the harness owns ordered delivery. A legacy Director calls complete once with
all deliverables in explicit order, never a final/* glob. If delivery fails or
its reply is lost, retain artifacts; do not retry complete automatically.
NOTE
}

# ---------------------------------------------------------------------------
# cr_select_deliverables <order-dir> <harness-result-json>
#
# Prints path<TAB>role lines for cfw-render.sh complete. Role is "media" or
# "captions".
#
# Carousel (WI2.43/WI2.45): when steps/render_slides/saves/slides.json names
# count N and saves/slide_1.png … slide_N.png exist (or work/slides/slide-N.png
# whose sha256 matches slides.json), those ordered slide images are the only
# media deliverables. cover.png and slide_sheet.png stay previews and are never
# selected. Captions still come from the harness result or
# steps/captions/saves/captions.json.
#
# Otherwise (WI2.51) keep harness media, plus captions, but drop a save the
# order manifest marks "preview": true when that save is a contact sheet
# (id ends with _sheet) or the QA image id "final". Match the harness item
# by save id, or by file basename stem when the item has no id.
# Numbered graphics (image_1), cover, and video/audio stay even if the
# manifest also flags them preview: the real file is the deliverable.
# If every media path was one of those previews, print no media.
# ---------------------------------------------------------------------------
cr_select_deliverables() {
  local order_dir="$1" h_out="${2:-[]}"
  python3 -c '
import hashlib, json, os, sys

MEDIA = {"mp4", "mov", "webm", "m4v", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "wav", "m4a"}
order_dir = os.path.abspath(sys.argv[1])
try:
    items = json.loads(sys.argv[2] or "[]")
except json.JSONDecodeError:
    items = []
if not isinstance(items, list):
    items = []

def is_captions(item, path):
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    if ext != "json":
        return False
    return item.get("role") == "captions" or item.get("id") == "captions" or os.path.basename(path) == "captions.json"

def captions_path():
    for item in items:
        path = item.get("path") or ""
        if path and is_captions(item, path):
            return path
    fallback = os.path.join(order_dir, "steps", "captions", "saves", "captions.json")
    if os.path.isfile(fallback) and os.path.getsize(fallback) > 0:
        return fallback
    return ""

def order_manifest():
    path = os.path.join(order_dir, "order.json")
    if not os.path.isfile(path):
        return None
    try:
        order = json.load(open(path))
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(order, dict):
        return None
    manifest = order.get("manifest")
    if isinstance(manifest, str) and manifest:
        mpath = manifest if os.path.isabs(manifest) else os.path.join(order_dir, manifest)
        try:
            manifest = json.load(open(mpath))
        except (OSError, ValueError, json.JSONDecodeError):
            return None
    return manifest if isinstance(manifest, dict) else None

def preview_drop_ids(manifest):
    # Sheets and the QA image "final" are not deliverables. Other preview
    # flags (image_N, cover, final_video) name the file the customer gets.
    drop = set()
    if not isinstance(manifest, dict):
        return drop
    for step in manifest.get("steps") or []:
        if not isinstance(step, dict):
            continue
        for save in step.get("saves") or []:
            if not isinstance(save, dict) or save.get("preview") is not True:
                continue
            sid = save.get("id")
            kind = save.get("kind") if isinstance(save.get("kind"), str) else ""
            if not isinstance(sid, str) or not sid:
                continue
            if kind in ("video", "audio", "text", "json"):
                continue
            if sid == "final" or sid.endswith("_sheet"):
                drop.add(sid)
    return drop

PREVIEW_DROP = preview_drop_ids(order_manifest())

def item_save_id(item, path):
    sid = item.get("id")
    if isinstance(sid, str) and sid:
        return sid
    sid = item.get("saveId")
    if isinstance(sid, str) and sid:
        return sid
    return os.path.splitext(os.path.basename(path))[0]

def emit_default():
    for item in items:
        path = item.get("path") or ""
        if not path:
            continue
        ext = os.path.splitext(path)[1].lstrip(".").lower()
        if is_captions(item, path):
            print(path + "\tcaptions")
        elif ext in MEDIA:
            if item_save_id(item, path) in PREVIEW_DROP:
                continue
            print(path + "\tmedia")

# Carousel: slides.json is the ordered set contract. Prefer saves/slide_N.png,
# then work/slides/slide-N.png (work fallback must match slides.json sha256).
# Never select cover.png or slide_sheet.png.
slides_json = os.path.join(order_dir, "steps", "render_slides", "saves", "slides.json")
if os.path.isfile(slides_json):
    try:
        meta = json.load(open(slides_json))
    except (OSError, ValueError, json.JSONDecodeError):
        meta = None
    count = meta.get("count") if isinstance(meta, dict) else None
    by_n = {}
    if isinstance(meta, dict):
        for entry in meta.get("slides") or []:
            if isinstance(entry, dict) and isinstance(entry.get("n"), int) and isinstance(entry.get("sha256"), str):
                by_n[entry["n"]] = entry["sha256"].lower()
    if isinstance(count, int) and 1 <= count <= 30:
        base = os.path.join(order_dir, "steps", "render_slides")
        slides = []
        for n in range(1, count + 1):
            chosen = ""
            save_path = os.path.join(base, "saves", "slide_%d.png" % n)
            if os.path.isfile(save_path) and os.path.getsize(save_path) > 0 and not os.path.islink(save_path):
                chosen = save_path
            else:
                work_path = os.path.join(base, "work", "slides", "slide-%d.png" % n)
                if os.path.isfile(work_path) and os.path.getsize(work_path) > 0 and not os.path.islink(work_path):
                    want = by_n.get(n)
                    if want:
                        got = hashlib.sha256(open(work_path, "rb").read()).hexdigest()
                        if got == want:
                            chosen = work_path
            if not chosen:
                slides = []
                break
            slides.append(chosen)
        if len(slides) == count:
            for path in slides:
                print(path + "\tmedia")
            cap = captions_path()
            if cap:
                print(cap + "\tcaptions")
            sys.exit(0)
        # slides.json present but the ordered PNGs are missing: refuse to fall
        # back to cover.png / slide_sheet.png (smoke 10 defect).
        sys.exit(0)

emit_default()
' "$order_dir" "$h_out"
}

# Shared watchdog for Director and step engines. Finish grace is only for an
# explicit delivery invocation, not a guessed file set. No rescue upload here.
cr_budget_watchdog() {
  local pid="$1" budget="$2" wait_file="$3" root="$4" directive="${5:-}" immediate_revoke="${6:-0}"
  local started now excluded wall grace=0
  started="$(date +%s)"
  while :; do
    sleep 1
    if [[ -n "$directive" && -f "$directive" ]]; then
      case "$(cat "$directive")" in
        cancel|superseded) break ;;
        stop_after_step|report_blocked) if [[ "$immediate_revoke" == 1 ]]; then break; fi ;;
      esac
    fi
    now="$(date +%s)"; wall=$((now - started))
    excluded="$(cr_provider_wait_excluded "$wait_file" "$started" "$now")"
    [[ "$excluded" =~ ^[0-9]+$ ]] || excluded=0
    if (( wall - excluded >= budget || wall >= budget + ${CFW_RENDER_PROVIDER_WAIT_CAP:-2700} )); then
      if [[ -z "$directive" && -d "$root/.delivery-started" && ! -f "$root/.outcome" ]]; then
        grace="${CFW_RENDER_FINISH_GRACE_SECS:-90}"
      fi
      (( grace == 0 )) || sleep "$grace"
      break
    fi
  done
  cr_kill_tree "$pid" TERM
  sleep 1
  cr_kill_tree "$pid" KILL
}

# ---------------------------------------------------------------------------
# cr_default_env_file — where the settings file lives when CFW_RENDER_ENV is
# not set: ~/.cfw-render/cfw-render.env. An install from before the folder
# layout change may still keep it at the legacy ~/ecosystem/vault path; use
# that only when the new file is absent, so an existing install keeps working.
# ---------------------------------------------------------------------------
cr_default_env_file() {
  if [[ "$(cr_profile 2>/dev/null)" == dev ]]; then
    printf '%s' "$(cr_dev_home)/cfw-render.env"
    return 0
  fi
  local new="$HOME/.cfw-render/cfw-render.env"
  local legacy="$HOME/ecosystem/vault/cfw-render.env"
  if [[ ! -e "$new" && -r "$legacy" ]]; then
    printf '%s' "$legacy"
  else
    printf '%s' "$new"
  fi
}

# ---------------------------------------------------------------------------
# [WI27] Profiles. CFW_RENDER_PROFILE=dev runs a second, local-only worker next
# to the installed one: its own settings file and folders (all under the
# hidden ~/.cfw-render-dev), the server http://localhost:3005 and the launchd label
# com.cfw.render.dev. It refuses a server that is not on this computer and any
# folder of the production install, so a dev run can never touch it. Unset or
# "prod" keeps every default exactly as before.
# ---------------------------------------------------------------------------
cr_profile() {
  case "${CFW_RENDER_PROFILE:-prod}" in
    prod) printf 'prod' ;;
    dev) printf 'dev' ;;
    *) return 1 ;;
  esac
}

cr_launchd_label() {
  if [[ "$(cr_profile 2>/dev/null)" == dev ]]; then
    printf 'com.cfw.render.dev'
  else
    printf 'com.cfw.render'
  fi
}

# A dev worker talks only to a CFW on this computer.
cr_dev_api_base_ok() {
  [[ "$1" =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/?$ ]]
}

# The dev profile's folders: the same layout the cfw-social seed writes.
cr_dev_home() { printf '%s' "$HOME/.cfw-render-dev"; }
cr_dev_state_dir_default() { printf '%s' "$(cr_dev_home)/render-state"; }

# A dev worker never uses a folder of the production install. The path must be
# absolute; it is resolved (symlinks of its existing part, "." and "..") and
# compared without case, because APFS treats ~/.CFW-render as ~/.cfw-render.
cr_dev_path_ok() {
  [[ "${1:-}" == /* ]] || return 1
  python3 - "$1" "$HOME" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1]).rstrip("/").lower()
home = sys.argv[2]
for prod in (os.path.join(home, ".cfw-render"), os.path.join(home, "CFW Render")):
    prod = os.path.realpath(prod).rstrip("/").lower()
    if path == prod or path.startswith(prod + "/"):
        sys.exit(1)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Folder layout (owner's own computer, CFW_RENDER_MODE=byoa):
#   visible  "$HOME/CFW Render/"  (CFW_RENDER_HOME)
#              app/                    install prefix (install.sh --mode byoa)
#              outputs/<brand>/<date>_<order>/  a copy of each finished render,
#                                      kept after CFW confirmed the upload
#              logs/                   cfw-render.log, runs/ transcripts,
#                                      macOS schedule out/err logs
#   hidden   ~/.cfw-render/            worker-id, cfw-render.env (600),
#                                      scratch/, journal, tick lock
# Every path is overridable.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Shared render-key readers (WI17.2.2). Env first, then macOS Keychain
# (service com.cfw.render, account render-worker). CFW_RENDER_SECURITY_CMD
# overrides `security` for tests. Never print the key from a caller log line.
# ---------------------------------------------------------------------------
# cr_keychain_render_worker_key — Keychain only; empty on non-macOS / miss.
cr_keychain_render_worker_key() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  local _sec _kc
  _sec="${CFW_RENDER_SECURITY_CMD:-/usr/bin/security}"
  _kc="$("$_sec" find-generic-password -s com.cfw.render -a render-worker -w 2>/dev/null)" || _kc=""
  _kc="$(printf '%s' "$_kc" | tr -d '\r\n')"
  if [[ "$_kc" =~ ^cfw_render_[A-Za-z0-9_-]+$ ]]; then
    printf '%s' "$_kc"
  fi
}

# cr_resolve_render_worker_key [env-file] — process env, then env-file, then
# Keychain. Prints the key or empty; never exits non-zero.
cr_resolve_render_worker_key() {
  local k="${CFW_RENDER_WORKER_KEY:-}" envf="${1:-}"
  if [[ -z "$k" && -n "$envf" && -f "$envf" ]]; then
    k="$(grep -E '^[[:space:]]*CFW_RENDER_WORKER_KEY=' "$envf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  [[ -z "$k" ]] && k="$(cr_keychain_render_worker_key)"
  printf '%s' "$k"
}

# ---------------------------------------------------------------------------
# cr_load_config — env cascade: $CFW_RENDER_ENV (default
# ~/.cfw-render/cfw-render.env, see cr_default_env_file) → process env wins
# over the file (the file only fills vars that are still unset). Fails
# fast on missing required vars; never prints values.
# ---------------------------------------------------------------------------
cr_load_config() {
  # Capture every knob already set by the real process env BEFORE sourcing
  # any file, so process env always wins per the cascade — a sourced file's
  # plain `VAR=value` line would otherwise unconditionally clobber a value
  # the caller/test harness exported, regardless of "required" status.
  local _cr_vars=(
    CFW_API_BASE CFW_RENDER_WORKER_KEY CFW_RENDER_CONCURRENCY CFW_RENDER_SCRATCH
    CFW_RENDER_STATE_DIR CFW_RENDER_SKILLS_DIR CFW_RENDER_DIRECTOR_MODEL
    CFW_RENDER_FANOUT_MODELS CFW_RENDER_TIMEOUT_VIDEO CFW_RENDER_TIMEOUT_IMAGE
    CFW_RENDER_GATE_FAIL_CAP CFW_RENDER_OLLAMA_KEYS_FILE CFW_RENDER_DIRECTOR_CMD
    CFW_RENDER_MODE CFW_RENDER_WORKER_ID_FILE
    CFW_RENDER_HEARTBEAT_SECS CFW_RENDER_RENDERER_KIND CFW_RENDER_ORPHAN_GRACE_SECS
    CFW_RENDER_HOME CFW_RENDER_LOG_DIR CFW_RENDER_OUTPUTS CFW_RENDER_KEEP_OUTPUTS
    CFW_RENDER_FINISH_GRACE_SECS CFW_RENDER_PROVIDER_BUDGET_HEYGEN CFW_RENDER_PROVIDER_WAIT_CAP
    CFW_RENDER_MEDIA_BASE_URL CFW_RENDER_TEST_MEDIA_BASE_URL CFW_RENDER_LOCAL_CHECKPOINTS
    CFW_RENDER_PROFILE
  )
  local _cr_preset=() _v
  for _v in "${_cr_vars[@]}"; do
    _cr_preset+=("${!_v:-}")
  done

  local env_file="${CFW_RENDER_ENV:-$(cr_default_env_file)}"
  if [[ -r "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi

  # Process env wins over the file: restore any var that was already set
  # before sourcing.
  local _i=0
  for _v in "${_cr_vars[@]}"; do
    [[ -n "${_cr_preset[$_i]}" ]] && printf -v "$_v" '%s' "${_cr_preset[$_i]}"
    _i=$(( _i + 1 ))
  done

  # [WI27] Profile: process env, else the settings file. The dev profile fills
  # its own server and folders first, so the production defaults below never
  # apply to it.
  local profile
  if ! profile="$(cr_profile)"; then
    printf 'cfw-render: CFW_RENDER_PROFILE must be prod or dev\n' >&2
    return 1
  fi
  if [[ "$profile" == dev ]]; then
    : "${CFW_API_BASE:=http://localhost:3005}"
    : "${CFW_RENDER_STATE_DIR:=$(cr_dev_state_dir_default)}"
    : "${CFW_RENDER_SCRATCH:=$CFW_RENDER_STATE_DIR/scratch}"
    # Inside the hidden dev folder: the home folder takes no new visible root.
    : "${CFW_RENDER_HOME:=$(cr_dev_home)/render-home}"
  fi

  # [M2-04] Parallel requests (D52). Empty = measure this computer
  # (cr_capacity_max: memory + performance cores table). A value set by the
  # owner overrides the table, still capped at 6.
  : "${CFW_RENDER_CONCURRENCY:=}"
  : "${CFW_RENDER_SCRATCH:=$HOME/.cfw-render/scratch}"
  : "${CFW_RENDER_STATE_DIR:=$HOME/.cfw-render}"
  : "${CFW_RENDER_SKILLS_DIR:=$(cr_default_skills_dir)}"
  # B8: the one Playwright version recipe steps may install. Always read from the pin
  # file, never from the environment. Unreadable leaves it empty: the preflight FAILs
  # on the same file and a step that needs it stops (`${CFW_PLAYWRIGHT_PIN:?}`).
  CFW_PLAYWRIGHT_PIN="$(cr_playwright_pin_field playwright 2>/dev/null || true)"
  : "${CFW_RENDER_DIRECTOR_MODEL:=sonnet}"
  : "${CFW_RENDER_FANOUT_MODELS:=glm-5.2,kimi-k2}"
  : "${CFW_RENDER_TIMEOUT_VIDEO:=3600}"
  : "${CFW_RENDER_TIMEOUT_IMAGE:=900}"
  : "${CFW_RENDER_GATE_FAIL_CAP:=2}"
  : "${CFW_RENDER_OLLAMA_KEYS_FILE:=$HOME/ecosystem/vault/ollama-keys.env}"
  : "${CFW_RENDER_DIRECTOR_CMD:=}"
  # Deploy mode — operational only, NEVER the security boundary (the server
  # enforces that via which credential family resolves). The only mode left is
  # byoa (the owner's own computer); CFW-run server rendering was removed
  # (D118). An older settings file that still says `server` is treated as byoa.
  CFW_RENDER_MODE=byoa
  : "${CFW_RENDER_WORKER_ID_FILE:=$CFW_RENDER_STATE_DIR/worker-id}"
  # Visible folder layout (see the block above cr_load_config). byoa = the
  # owner's own computer: logs and kept renders go in "$HOME/CFW Render".
  : "${CFW_RENDER_HOME:=$HOME/CFW Render}"
  : "${CFW_RENDER_LOG_DIR:=$CFW_RENDER_HOME/logs}"
  : "${CFW_RENDER_KEEP_OUTPUTS:=1}"
  : "${CFW_RENDER_OUTPUTS:=$CFW_RENDER_HOME/outputs}"
  # [CFW-146] Heartbeat cadence (seconds) while a Director holds an order. The
  # order card in cfw-social treats silence > 3 min as "Still working — last
  # heard N min ago", so 60 s gives three chances before the owner sees that.
  # 0 disables the pulse (tests / a box that must stay silent).
  : "${CFW_RENDER_HEARTBEAT_SECS:=60}"
  # [CFW-286] After the Director's process ends with no .outcome on disk and
  # a clean exit (not a watchdog kill), how long to poll before declaring the
  # render orphaned — absorbs a background write that lands a few hundred ms
  # after the Director's own turn ended, without masking a real failure.
  : "${CFW_RENDER_ORPHAN_GRACE_SECS:=5}"
  : "${CFW_RENDER_FINISH_GRACE_SECS:=90}"
  : "${CFW_RENDER_PROVIDER_BUDGET_HEYGEN:=900}"
  : "${CFW_RENDER_PROVIDER_WAIT_CAP:=2700}"
  # Bound arithmetic inputs before launching an engine (including env overrides).
  for _v in CFW_RENDER_FINISH_GRACE_SECS CFW_RENDER_PROVIDER_BUDGET_HEYGEN CFW_RENDER_PROVIDER_WAIT_CAP CFW_RENDER_TIMEOUT_VIDEO CFW_RENDER_TIMEOUT_IMAGE; do
    if [[ ! "${!_v}" =~ ^(0|[1-9][0-9]{0,4})$ ]] || (( ${!_v} > 86400 )); then
      printf 'cfw-render: invalid bounded seconds: %s\n' "$_v" >&2
      return 1
    fi
  done
  # [CFW-146] Renderer identity shown to the owner ("Working on your Mac" /
  # "on your computer"). Derived from the platform unless set:
  #   Darwin        → mac   (the owner's laptop)
  #   otherwise     → byo   (a customer's own renderer)
  if [[ -z "${CFW_RENDER_RENDERER_KIND:-}" ]]; then
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
      CFW_RENDER_RENDERER_KIND="mac"
    else
      CFW_RENDER_RENDERER_KIND="byo"
    fi
  fi
  if [[ "$profile" == dev ]]; then
    if ! cr_dev_api_base_ok "$CFW_API_BASE"; then
      printf 'cfw-render: the dev profile only talks to CFW on this computer (http://localhost or 127.0.0.1); refusing CFW_API_BASE\n' >&2
      return 1
    fi
    for _v in CFW_RENDER_STATE_DIR CFW_RENDER_SCRATCH CFW_RENDER_HOME CFW_RENDER_LOG_DIR \
              CFW_RENDER_OUTPUTS CFW_RENDER_WORKER_ID_FILE; do
      if ! cr_dev_path_ok "${!_v}"; then
        printf 'cfw-render: the dev profile never uses the production install folders; refusing %s\n' "$_v" >&2
        return 1
      fi
    done
    if ! cr_dev_path_ok "$env_file"; then
      printf 'cfw-render: the dev profile never reads the production settings file\n' >&2
      return 1
    fi
  fi
  CFW_RENDER_PROFILE="$profile"
  export CFW_RENDER_PROFILE
  export CFW_RENDER_CONCURRENCY CFW_RENDER_SCRATCH CFW_RENDER_STATE_DIR \
    CFW_RENDER_SKILLS_DIR CFW_RENDER_DIRECTOR_MODEL CFW_RENDER_FANOUT_MODELS \
    CFW_RENDER_TIMEOUT_VIDEO CFW_RENDER_TIMEOUT_IMAGE CFW_RENDER_GATE_FAIL_CAP \
    CFW_RENDER_OLLAMA_KEYS_FILE CFW_RENDER_DIRECTOR_CMD \
    CFW_RENDER_MODE CFW_RENDER_WORKER_ID_FILE \
    CFW_RENDER_HEARTBEAT_SECS CFW_RENDER_RENDERER_KIND CFW_RENDER_ORPHAN_GRACE_SECS \
    CFW_RENDER_HOME CFW_RENDER_LOG_DIR CFW_RENDER_OUTPUTS CFW_RENDER_KEEP_OUTPUTS \
    CFW_RENDER_FINISH_GRACE_SECS CFW_RENDER_PROVIDER_BUDGET_HEYGEN CFW_RENDER_PROVIDER_WAIT_CAP \
    CFW_RENDER_MEDIA_BASE_URL CFW_RENDER_TEST_MEDIA_BASE_URL CFW_RENDER_LOCAL_CHECKPOINTS \
    CFW_PLAYWRIGHT_PIN

  # Browser-approval connect (WI17.2.2): process env wins; otherwise macOS
  # Keychain (service com.cfw.render, account render-worker). Linux / old
  # installs keep the env-file path. Shared helper: cr_keychain_render_worker_key.
  if [[ -z "${CFW_RENDER_WORKER_KEY:-}" ]]; then
    local _kc
    _kc="$(cr_keychain_render_worker_key)"
    [[ -n "$_kc" ]] && CFW_RENDER_WORKER_KEY="$_kc"
    _kc=""
  fi

  local missing=()
  [[ -z "${CFW_API_BASE:-}" ]] && missing+=("CFW_API_BASE")
  [[ -z "${CFW_RENDER_WORKER_KEY:-}" ]] && missing+=("CFW_RENDER_WORKER_KEY")
  if (( ${#missing[@]} > 0 )); then
    printf 'cfw-render: missing required config var(s): %s (checked %s, process env)\n' \
      "${missing[*]}" "$env_file" >&2
    return 1
  fi
  if [[ "$CFW_RENDER_WORKER_KEY" != cfw_render_* ]]; then
    printf 'cfw-render: CFW_RENDER_WORKER_KEY does not match expected shape ^cfw_render_ — refusing to run\n' >&2
    return 1
  fi
  mkdir -p "$CFW_RENDER_STATE_DIR" "$CFW_RENDER_SCRATCH" 2>/dev/null
  cr_prepare_visible_dirs

  cr_log_skills_version

  # workerId — STABLE per install, NOT per process (doc §6.3). A scheduled
  # tick gets a fresh PID every time, so the old `hostname:$$`
  # changed every tick and would defeat CFW-V2-068's per-workerId circuit
  # breaker (consecutiveFailures never accumulates against a moving id).
  # Order of precedence:
  #   1. an explicitly exported CFW_WORKER_ID (tests / special ops) wins;
  #   2. else the persisted install-identity file (seeded once by install.sh,
  #      lazily seeded here too so a hand-run/dev worker is also stable);
  #   3. hostname:$$ survives only as free-text forensic context in log/event
  #      MESSAGES — never as the claim identity.
  if [[ -z "${CFW_WORKER_ID:-}" ]]; then
    local _wid_file="${CFW_RENDER_WORKER_ID_FILE:-$CFW_RENDER_STATE_DIR/worker-id}"
    if [[ ! -s "$_wid_file" ]]; then
      cr_seed_worker_id "$_wid_file"
    fi
    CFW_WORKER_ID="$(tr -d '[:space:]' < "$_wid_file" 2>/dev/null)"
    # Last-ditch fallback if the file is unreadable/empty (never block a tick
    # on this) — a per-process id is worse for the breaker but better than no
    # claim identity at all; log it loudly.
    if [[ -z "$CFW_WORKER_ID" ]]; then
      CFW_WORKER_ID="$(hostname -s 2>/dev/null || hostname):$$"
      cr_log "WARN: worker-id file $_wid_file empty/unreadable — falling back to unstable $CFW_WORKER_ID (circuit breaker will not accumulate; check install)"
    fi
  fi
  export CFW_WORKER_ID
  return 0
}

# ---------------------------------------------------------------------------
# cr_seed_worker_id <file> — write a stable install identity once. uuidgen if
# present, else the kernel uuid source, else python3 uuid4, else a
# hostname+random fallback. Idempotent by the caller's `-s` guard; safe to call
# from install.sh and lazily from cr_load_config.
# ---------------------------------------------------------------------------
cr_seed_worker_id() {
  local file="$1" id=""
  mkdir -p "$(dirname "$file")" 2>/dev/null
  if command -v uuidgen >/dev/null 2>&1; then
    id="$(uuidgen 2>/dev/null)"
  fi
  if [[ -z "$id" && -r /proc/sys/kernel/random/uuid ]]; then
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  fi
  if [[ -z "$id" ]] && command -v python3 >/dev/null 2>&1; then
    id="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)"
  fi
  if [[ -z "$id" ]]; then
    id="$(hostname -s 2>/dev/null || hostname)-$$-${RANDOM}${RANDOM}"
  fi
  printf '%s\n' "$id" > "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# cr_prepare_visible_dirs — create the log + outputs folders. Never fatal: an
# install whose sandbox predates the folder layout (an old unit that cannot
# write "$HOME/CFW Render") must keep rendering, so an
# unwritable log dir falls back to the state dir and an unwritable outputs dir
# just turns off local copies, with a log line saying so.
# ---------------------------------------------------------------------------
cr_prepare_visible_dirs() {
  if ! mkdir -p "$CFW_RENDER_LOG_DIR" 2>/dev/null || [[ ! -w "$CFW_RENDER_LOG_DIR" ]]; then
    local wanted="$CFW_RENDER_LOG_DIR"
    CFW_RENDER_LOG_DIR="$CFW_RENDER_STATE_DIR"
    export CFW_RENDER_LOG_DIR
    cr_log "WARN: log folder $wanted is not writable — logging to $CFW_RENDER_LOG_DIR instead"
  fi
  if [[ "$CFW_RENDER_KEEP_OUTPUTS" == "1" ]]; then
    if ! mkdir -p "$CFW_RENDER_OUTPUTS" 2>/dev/null || [[ ! -w "$CFW_RENDER_OUTPUTS" ]]; then
      cr_log "WARN: outputs folder $CFW_RENDER_OUTPUTS is not writable — finished renders will not be kept on this computer"
      CFW_RENDER_KEEP_OUTPUTS=0
      export CFW_RENDER_KEEP_OUTPUTS
    fi
  fi
}

# ---------------------------------------------------------------------------
# cr_keep_output_dir <brand_slug> <order_id> — the folder a finished render's
# local copy goes in: "$CFW_RENDER_OUTPUTS/<brand>/<YYYY-MM-DD>_<order>".
# Prints nothing when local copies are off.
# ---------------------------------------------------------------------------
cr_keep_output_dir() {
  [[ "${CFW_RENDER_KEEP_OUTPUTS:-0}" == "1" && -n "${CFW_RENDER_OUTPUTS:-}" ]] || return 0
  printf '%s/%s/%s_%s' "$CFW_RENDER_OUTPUTS" "$1" "$(date '+%Y-%m-%d')" "$2"
}

# ---------------------------------------------------------------------------
# cr_log <msg> — timestamped append to $CFW_RENDER_LOG_DIR/cfw-render.log
# (the state dir before config load; mirrors ab-lib.sh:63).
# ---------------------------------------------------------------------------
cr_log() {
  local dir="${CFW_RENDER_LOG_DIR:-${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}}"
  mkdir -p "$dir" 2>/dev/null
  printf '%s [cfw-render] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$dir/cfw-render.log"
}

# ---------------------------------------------------------------------------
# cr_curl_with_key [curl args...]
# Run curl with the render key in a header. The key is written to a mode-600
# file and passed as -H @file. curl's argv never contains the key (WI2.102:
# process listings were showing the header value). Do not pass the key as
# another argument.
#
# Stdin is /dev/null. Job control is off and curl is started in the
# background, so this call does not pass the caller's stdin through
# (WI2.105). --data-binary @- therefore sends an empty body. Pass the body
# as an argument or as a file (@path).
#
# The file is removed when this call ends, including when curl is killed or
# this call receives TERM, INT or HUP (WI2.104). The trap lives in a subshell
# so the caller's own traps stay in place. The subshell's exit status is
# curl's.
# ---------------------------------------------------------------------------
cr_curl_with_key() {
  local rc
  (
    set +m
    hdr=""
    curl_pid=""
    # Installed before mktemp, so a signal during the call still removes the
    # key file. EXIT covers a normal curl exit; INT/TERM/HUP cover a kill of
    # this subshell while wait is blocked on curl.
    _cr_drop_hdr() {
      if [[ -n "$hdr" ]]; then
        rm -f "$hdr"
        hdr=""
      fi
      if [[ -n "$curl_pid" ]]; then
        kill "$curl_pid" 2>/dev/null || true
        curl_pid=""
      fi
    }
    trap '_cr_drop_hdr' EXIT
    trap '_cr_drop_hdr; exit 129' HUP
    trap '_cr_drop_hdr; exit 130' INT
    trap '_cr_drop_hdr; exit 143' TERM
    hdr="$(mktemp "${TMPDIR:-/tmp}/cfw-render-hdr.XXXXXX")" || exit 1
    chmod 600 "$hdr" || exit 1
    printf 'cfw-render-key: %s\n' "$CFW_RENDER_WORKER_KEY" > "$hdr" || exit 1
    curl -H "@$hdr" "$@" &
    curl_pid=$!
    if [[ -z "$curl_pid" ]]; then
      exit 1
    fi
    wait "$curl_pid"
    rc=$?
    curl_pid=""
    exit "$rc"
  )
  rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# cr_mcp_call <tool> <json-args>
# Single curl JSON-RPC wrapper against $CFW_API_BASE/api/v1/mcp (pattern:
# cfw-social/docs/mcp-brand-context-smoke.md "Manual curl reference"), headers
# cfw-render-key (via cr_curl_with_key, not argv) + accept json/SSE,
# --max-time 30, 2 retries with backoff on curl-level failure. Prints the
# unwrapped inner JSON (result.content[0].text) on stdout; non-zero exit on
# curl failure / JSON-RPC error / isError.
# ---------------------------------------------------------------------------
cr_mcp_call() {
  local tool="$1" args_json="$2"
  local url="${CFW_API_BASE%/}/api/v1/mcp"
  local body
  body="$(python3 -c '
import json, sys
tool = sys.argv[1]
args = json.loads(sys.argv[2]) if sys.argv[2] else {}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}))
' "$tool" "$args_json" 2>/dev/null)" || { printf 'cfw-render: cr_mcp_call could not build request JSON for %s\n' "$tool" >&2; return 1; }

  local attempt resp rc max_attempts=3
  # Completion has no retry acknowledgement contract: a lost response may mean
  # the dish already exists. Do not repeat this terminal write automatically.
  [[ "$tool" == complete_render_order ]] && max_attempts=1
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    resp="$(cr_curl_with_key -sS --max-time 30 -X POST "$url" \
      -H "content-type: application/json" \
      -H "accept: application/json, text/event-stream" \
      -d "$body" 2>/dev/null)"
    rc=$?
    if (( rc == 0 )) && [[ -n "$resp" ]]; then
      break
    fi
    (( attempt < max_attempts )) && sleep $(( attempt * 2 ))
  done
  if (( rc != 0 )) || [[ -z "${resp:-}" ]]; then
    printf 'cfw-render: cr_mcp_call %s — curl failed after retries (rc=%s)\n' "$tool" "$rc" >&2
    return 1
  fi

  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    env = json.loads(raw)
except Exception as e:
    print(f"cfw-render: cr_mcp_call — non-JSON response: {e}", file=sys.stderr)
    sys.exit(1)
if "error" in env:
    err = env["error"]
    print(f"cfw-render: cr_mcp_call — JSON-RPC error: {err}", file=sys.stderr)
    sys.exit(1)
result = env.get("result", {})
if result.get("isError"):
    print(f"cfw-render: cr_mcp_call — tool error: {result}", file=sys.stderr)
    sys.exit(1)
content = result.get("content", [])
if not content or "text" not in content[0]:
    # Shape only: a claim reply carries providerKeys, and the err log is plain text.
    print(f"cfw-render: cr_mcp_call — unexpected result shape (keys: {sorted(result) if isinstance(result, dict) else type(result).__name__})", file=sys.stderr)
    sys.exit(1)
# The inner text is itself JSON — validate then print verbatim.
inner = content[0]["text"]
json.loads(inner)
sys.stdout.write(inner)
' <<< "$resp"
}

# ---------------------------------------------------------------------------
# cr_mcp_call_soft <tool> <json-args> — non-exiting sibling of cr_mcp_call for
# the M1-08 step loop (which must decide what to do on a dead server rather
# than die). Same request path (POST /api/v1/mcp, same headers, 3 tries).
#   0  success              — prints the tool's text body
#   70 MCP isError/JSON-RPC — prints the error text (EX_SOFTWARE)
#   75 curl/HTTP failure    — prints nothing (EX_TEMPFAIL)
# cr_mcp_call is deliberately untouched.
# ---------------------------------------------------------------------------
cr_mcp_call_soft() {
  local tool="$1" args_json="$2"
  local url="${CFW_API_BASE%/}/api/v1/mcp"
  local body
  body="$(python3 -c '
import json, sys
tool = sys.argv[1]
args = json.loads(sys.argv[2]) if sys.argv[2] else {}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}))
' "$tool" "$args_json" 2>/dev/null)" || { printf 'cfw-render: cr_mcp_call_soft could not build request JSON for %s\n' "$tool" >&2; return 70; }

  local attempt resp rc http_code
  for attempt in 1 2 3; do
    resp="$(cr_curl_with_key -sS --max-time 30 -w '\n%{http_code}' -X POST "$url" \
      -H "content-type: application/json" \
      -H "accept: application/json, text/event-stream" \
      -d "$body" 2>/dev/null)"
    rc=$?
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    if (( rc == 0 )) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && [[ -n "$resp" ]]; then
      break
    fi
    rc=75
    (( attempt < 3 )) && sleep 1
  done
  if (( rc != 0 )); then
    printf 'cfw-render: cr_mcp_call_soft %s — unreachable/HTTP %s after retries\n' "$tool" "${http_code:-?}" >&2
    return 75
  fi

  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    env = json.loads(raw)
except Exception as e:
    print(f"non-JSON response: {e}")
    sys.exit(70)
if "error" in env:
    print(json.dumps(env["error"]))
    sys.exit(70)
result = env.get("result", {})
content = result.get("content", [])
text = content[0].get("text", "") if content and isinstance(content[0], dict) else ""
if result.get("isError"):
    print(text or json.dumps(result))
    sys.exit(70)
if not text:
    print(f"unexpected result shape (keys: {sorted(result) if isinstance(result, dict) else type(result).__name__})")
    sys.exit(70)
json.loads(text)
sys.stdout.write(text)
' <<< "$resp"
}

# cr_report_step <orderId> <workerId> <attemptId> <seq> <event> [extra-json-object]
# Merges the identity fields with <extra-json-object> (stepId/outputs/checks/
# ask/message/atIso) and calls report_render_step via cr_mcp_call_soft; same
# return codes. The reply text body ({ok,duplicate,directive,code?,error?}) is
# printed verbatim for the caller to parse.
cr_report_step() {
  local order_id="$1" worker_id="$2" attempt_id="$3" seq="$4" event="$5" extra="${6:-{\}}"
  local args
  args="$(python3 -c '
import json, sys
oid, wid, aid, seq, event, extra = sys.argv[1:7]
a = json.loads(extra) if extra.strip() else {}
if not isinstance(a, dict):
    raise SystemExit("extra must be a JSON object")
a.update({"orderId": oid, "workerId": wid, "attemptId": aid, "seq": int(seq), "event": event})
print(json.dumps(a))
' "$order_id" "$worker_id" "$attempt_id" "$seq" "$event" "$extra" 2>/dev/null)" \
    || { printf 'cfw-render: cr_report_step — bad extra JSON for seq %s\n' "$seq" >&2; return 70; }
  cr_mcp_call_soft report_render_step "$args"
}

# ---------------------------------------------------------------------------
# cr_event <orderId> <kind> <stage> <message> <pct> [model]
# Thin append_render_event wrapper. Best-effort — NEVER fails the caller;
# logs on error. stage/model may be empty strings (omitted from the call).
# ---------------------------------------------------------------------------
cr_event() {
  local order_id="$1" kind="$2" stage="$3" message="$4" pct="$5" model="${6:-}"
  local args
  args="$(python3 -c '
import json, sys
order_id, worker_id, kind, stage, message, pct, model = sys.argv[1:8]
d = {"orderId": order_id, "workerId": worker_id, "kind": kind, "message": message}
if stage:
    d["stage"] = stage
if pct != "":
    d["pct"] = int(pct)
if model:
    d["model"] = model
print(json.dumps(d))
' "$order_id" "$CFW_WORKER_ID" "$kind" "$stage" "$message" "$pct" "$model" 2>/dev/null)" || return 0
  cr_mcp_call append_render_event "$args" >/dev/null 2>>"${CFW_RENDER_LOG_DIR:-$CFW_RENDER_STATE_DIR}/cfw-render.log" || \
    cr_log "cr_event: append_render_event failed (best-effort, ignored) — order=$order_id kind=$kind stage=$stage"
  return 0
}

# ---------------------------------------------------------------------------
# cr_kill_tree <pid> [signal=TERM] — signal <pid> AND every live descendant.
# A backgrounded subshell (`cmd &`) gets no process group of its own — bash job
# control is off by default in a non-interactive script — so `kill $pid` only
# ever reaches that one wrapper. If it dies (e.g. SIGTERM, no trap) while
# blocked on ITS OWN foreground child, that child is orphaned: reparented to
# PID 1, left running, still holding whatever fds it inherited (this is how the
# render watchdog's own `sleep $timeout_secs` outlives a normal-path completion
# and wedges any caller that captures cfw-render.sh's output via `$( )` — see
# CFW-292). Worse: it means a genuinely hung render is never actually killed by
# the watchdog. Walk the tree with cr_proc_children (pgrep -P, present on both
# Linux and macOS — no new dependency) so every descendant gets the signal.
# ---------------------------------------------------------------------------
cr_kill_tree() {
  local pid="$1" sig="${2:-TERM}" kid
  for kid in $(cr_proc_children "$pid"); do
    cr_kill_tree "$kid" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# cr_proc_children <pid> — print the pids of <pid>'s live children, one per
# line. `pgrep -P` first, and its answer is final wherever it runs (exit 0 =
# children, 1 = none). Only when pgrep itself cannot run or cannot read the
# process table (exit >1: a sandbox refusing the binary, a box without it) ask
# the kernel directly through python3 — libproc proc_listchildpids on macOS,
# /proc on Linux — which needs no setuid binary. Same answer: direct children
# by parent pid, nothing matched by name. Empty output when nothing is found.
# ---------------------------------------------------------------------------
cr_proc_children() {
  local pid="$1" kids="" rc=0
  kids="$(pgrep -P "$pid" 2>/dev/null)" || rc=$?
  if (( rc <= 1 )); then
    [[ -n "$kids" ]] && printf '%s\n' "$kids"
    return 0
  fi
  python3 -c '
import ctypes, os, sys
ppid = int(sys.argv[1])
kids = []
try:
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    lib.proc_listchildpids.restype = ctypes.c_int
    size = 256
    while True:
        buf = (ctypes.c_int * size)()
        n = lib.proc_listchildpids(ppid, buf, ctypes.sizeof(buf))
        if n < 0:
            sys.exit(1)
        if n < size:
            kids = [p for p in buf[:n] if p > 0]
            break
        size *= 2
except OSError:
    # No libproc: a Linux box. /proc/<pid>/stat field 4 is the parent pid.
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/" + name + "/stat") as f:
                stat = f.read()
        except OSError:
            continue
        if int(stat[stat.rindex(")") + 2:].split()[1]) == ppid:
            kids.append(int(name))
for p in sorted(kids):
    print(p)
' "$pid" 2>/dev/null || return 0
}

# ---------------------------------------------------------------------------
# cr_heartbeat_start <orderId> — [CFW-146] emit `kind: heartbeat` every
# $CFW_RENDER_HEARTBEAT_SECS while the Director works, so cfw-social can tell
# "slow" from "dead": the order card shows "Still working — last heard N min
# ago" once no event of ANY kind has arrived for 3 minutes, and the server
# extends the claim lease on every heartbeat. The pulse carries the renderer
# kind (mac|box|byo) so the card can keep saying where the work is happening.
#
# Echoes the background loop's PID; pair with cr_heartbeat_stop. A cadence of 0
# disables it (echoes nothing). Best-effort throughout: a failed pulse is
# logged by cr_event and never touches the render.
# ---------------------------------------------------------------------------
cr_heartbeat_start() {
  local order_id="$1"
  local secs="${CFW_RENDER_HEARTBEAT_SECS:-60}"
  [[ "$secs" =~ ^[0-9]+$ ]] || return 0
  (( secs > 0 )) || return 0
  # NOTE: the loop's stdout/stderr MUST be redirected away from the caller's
  # pipe. Callers take the PID via `$(cr_heartbeat_start …)`; a background child
  # that keeps the command substitution's pipe open means the substitution never
  # sees EOF and the caller hangs forever (same trap as test/run-tests.sh's
  # start_mock). cr_event already logs its own failures to the state dir.
  (
    while :; do
      sleep "$secs"
      cr_event "$order_id" heartbeat "${CFW_RENDER_RENDERER_KIND:-}" "Still working" ""
    done
  ) >/dev/null 2>&1 &
  echo $!
}

# ---------------------------------------------------------------------------
# cr_heartbeat_stop <pid> — stop the pulse. Always called before the outcome is
# reported, so no heartbeat can ever land after complete/block (the order is
# terminal then and the server rejects further events).
# ---------------------------------------------------------------------------
cr_heartbeat_stop() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  cr_kill_tree "$pid" TERM
  wait "$pid" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# cr_heartbeat_stop_if_pending — [CFW-315] stop a pulse (if one is running)
# BEFORE reporting a terminal outcome. Reads the pid dropped by spawn_director
# at $PWD/.heartbeat.pid (CWD is always the order's scratch dir, for both the
# Director's foreground run and any backgrounded straggler it forks — same
# assumption cfw-render-report.sh already makes for .outcome). Best-effort,
# idempotent, silent if no pidfile exists (heartbeat cadence 0, or already
# stopped).
# ---------------------------------------------------------------------------
cr_heartbeat_stop_if_pending() {
  [[ -f .heartbeat.pid ]] || return 0
  local pid; pid="$(cat .heartbeat.pid 2>/dev/null)"
  rm -f .heartbeat.pid
  cr_heartbeat_stop "$pid"
}

# ---------------------------------------------------------------------------
# claude_ollama_failover <label> <model> <outfile> -- <claude args...>
# BASH PORT of ~/ecosystem/ab-hustler/ab-lib.sh:76-105 (claude_ollama_failover).
# Same account order goofy_hugle -> recursing_pike, same rate-limit regex,
# same "non-quota failure does not burn the 2nd account" rule. Ported from
# zsh (`emulate -L zsh` / `typeset -ga`) to portable bash per plan §0.5 —
# a Linux computer has no guaranteed zsh.
# ---------------------------------------------------------------------------
claude_ollama_failover() {
  local label="$1" model="$2" out="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local keysfile="${CFW_RENDER_OLLAMA_KEYS_FILE:-$HOME/ecosystem/vault/ollama-keys.env}"
  # shellcheck source=/dev/null
  [[ -f "$keysfile" ]] && source "$keysfile"
  local accts=(
    "goofy_hugle:${OLLAMA_KEY_GOOFY_HUGLE_463_B:-}"
    "recursing_pike:${OLLAMA_KEY_RECURSING_PIKE_357:-}"
  )
  local rc=1 e nm key
  for e in "${accts[@]}"; do
    nm="${e%%:*}"; key="${e#*:}"
    [[ -z "$key" ]] && continue
    ANTHROPIC_BASE_URL="https://ollama.com" ANTHROPIC_AUTH_TOKEN="$key" \
      ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
      claude "$@" < /dev/null >> "$out" 2>&1
    rc=$?
    if (( rc == 0 )); then
      cr_log "  served by ollama:$nm ($model) — $label"
      return 0
    fi
    if grep -qiE 'rate.?limit|429|too many requests|quota|over capacity|exceeded|insufficient' "$out"; then
      cr_log "  ollama:$nm rate-limited on $label — failing over to next account"
      continue
    fi
    cr_log "  ollama:$nm failed on $label (exit $rc, not rate-limit) — caller's error path takes over"
    return $rc
  done
  cr_log "  all ollama accounts exhausted for $label (last exit $rc)"
  return $rc
}

# ---------------------------------------------------------------------------
# cr_is_native_claude_model <model> — true for a model the worker's own Claude
# login serves: the sonnet/haiku/opus aliases (optional "[1m]") or a full
# claude-* id. Everything else is treated as an Ollama Cloud model.
# ---------------------------------------------------------------------------
cr_is_native_claude_model() {
  [[ "$1" =~ ^(sonnet|haiku|opus)(\[1m\])?$ || "$1" == claude-* ]]
}

# ---------------------------------------------------------------------------
# claude_fanout_run <label> <model> <outfile> -- <claude args...>
# Fan-out routing by model name. A native Claude alias runs on the worker's
# own Claude login — the same subscription that serves the Director — so a
# box with no live Ollama Cloud account still has a fan-out path. Anything
# else goes through claude_ollama_failover unchanged. Ollama Cloud was found
# dead on 2026-09-29 (goofy_hugle at its monthly limit, recursing_pike
# Unauthorized): every fan-out call failed before a request left the Mac and
# every delegated order ended `block`.
# ---------------------------------------------------------------------------
claude_fanout_run() {
  local label="$1" model="$2" out="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  if cr_is_native_claude_model "$model"; then
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
    claude --model "$model" "$@" < /dev/null >> "$out" 2>&1
    local rc=$?
    if (( rc == 0 )); then
      cr_log "  served by native claude ($model) — $label"
      return 0
    fi
    cr_log "  native claude ($model) failed on $label (exit $rc) — caller's error path takes over"
    return $rc
  fi
  claude_ollama_failover "$label" "$model" "$out" -- "$@"
}

# ---------------------------------------------------------------------------
# claude_native_or_ollama_quota_fallback <label> <native_model> <outfile> \
#   <state_file> -- <claude args...>
# BASH PORT of ab-lib.sh:109-140. Runs native Claude first (Sonnet, Claude
# subscription OAuth); on a quota/rate-limit-shaped failure, retries via
# claude_ollama_failover with glm-5.2. Additionally (plan §3): writes which
# model actually served ("sonnet" or "glm-5.2") to <state_file> so the
# Director-model rollup in cfw-render-report.sh is truthful.
# ---------------------------------------------------------------------------
claude_native_or_ollama_quota_fallback() {
  local label="$1" native_model="$2" out="$3" state_file="$4"; shift 4
  [[ "${1:-}" == "--" ]] && shift
  local native_model_flag=()
  [[ -n "$native_model" ]] && native_model_flag=(--model "$native_model")

  # [CFW-286] verified on claude 2.1.261: removes run_in_background from the
  # Bash/Agent tool schema, so a one-shot Director cannot detach its own work.
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
  claude "${native_model_flag[@]}" "$@" < /dev/null >> "$out" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    printf '%s\n' "${native_model:-sonnet}" > "$state_file" 2>/dev/null
    return 0
  fi

  if grep -qiE 'rate.?limit|429|too many requests|quota|over capacity|exceeded|insufficient|weekly limit' "$out" 2>/dev/null; then
    cr_log "  native Claude quota/rate-limited on $label — retrying with GLM-5.2 via Ollama"
    local fallback_args=() skip_next=0 arg
    for arg in "$@"; do
      if (( skip_next )); then skip_next=0; continue; fi
      if [[ "$arg" == "--effort" ]]; then skip_next=1; continue; fi
      fallback_args+=("$arg")
    done
    claude_ollama_failover "$label" "glm-5.2" "$out" -- "${fallback_args[@]}"
    rc=$?
    (( rc == 0 )) && printf 'glm-5.2\n' > "$state_file" 2>/dev/null
    return $rc
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# cr_tick_lock_acquire / cr_tick_lock_release
# mkdir-based tick lock with stale-age self-heal (ab-hustler batch-lock
# semantics, no sqlite — plan §0.3: order-level mutex is already the server's
# claim CAS; this only prevents two overlapping drainer ticks on one host).
# Stale threshold: CFW_RENDER_TIMEOUT_VIDEO (default 3600) + 600s, OR the recorded pid is dead.
# ---------------------------------------------------------------------------
cr_tick_lock_acquire() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  local lock="$dir/tick.lock"
  mkdir -p "$dir" 2>/dev/null
  if mkdir "$lock" 2>/dev/null; then
    printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock/info" 2>/dev/null
    return 0
  fi
  # Lock exists — check staleness.
  local info="$lock/info" pid ts now stale_after
  pid="$(grep '^pid=' "$info" 2>/dev/null | cut -d= -f2)"
  ts="$(grep '^ts=' "$info" 2>/dev/null | cut -d= -f2)"
  now="$(date +%s)"
  stale_after=$(( ${CFW_RENDER_TIMEOUT_VIDEO:-3600} + 600 ))
  local is_stale=0
  if [[ -z "$pid" || -z "$ts" ]]; then
    is_stale=1
  elif ! kill -0 "$pid" 2>/dev/null; then
    is_stale=1
  elif (( now - ts > stale_after )); then
    is_stale=1
  fi
  if (( is_stale )); then
    cr_log "tick lock stale (pid=$pid ts=$ts) — self-healing, retaking"
    rm -rf "$lock" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then
      printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock/info" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

cr_tick_lock_release() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  rm -rf "$dir/tick.lock" 2>/dev/null
  return 0
}

# [M2-04] cr_tick_lock_touch — the kept-alive loop (D89) holds the lock for
# days; refresh ts so the staleness rule above (timeout + 10 min) never lets a
# second copy retake a lock whose owner is alive and merely idle.
cr_tick_lock_touch() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  [[ -d "$dir/tick.lock" ]] || return 0
  printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$dir/tick.lock/info" 2>/dev/null
  return 0
}

# ===========================================================================
# CAPACITY (M2-04, D52 / D78 / D51)
# ===========================================================================
# ONE table, in ONE place. `max` = how many requests this computer runs at
# once, 1..6, from physical memory, capped by performance cores ÷ 2:
#
#   memory         max        (then: min(max, perfCores ÷ 2), floor 1)
#   < 16 GB   →    1          (D78: still serves, one at a time; setup says so)
#   16 GB     →    2
#   24 GB     →    3
#   32 GB     →    4
#   48 GB     →    5
#   64 GB +   →    6
#
# Before each pickup (cr_capacity_now): free memory must be at least
# CR_CAPACITY_FREE_MB_FLOOR per request and the 1-min load average at most the
# logical CPU count — otherwise only an urgent request may be claimed (the
# worker then reports itself full: capacity.running = capacity.max).
#
# Test seams (never set in production): CFW_RENDER_CAPACITY_MEM_BYTES,
# CFW_RENDER_CAPACITY_PERF_CORES, CFW_RENDER_CAPACITY_FREE_MB,
# CFW_RENDER_CAPACITY_LOAD, CFW_RENDER_CAPACITY_NCPU replace the sysctl /
# vm_stat probes one-for-one so the table and the floor can be driven locally.
CR_CAPACITY_HARD_MAX=6
CR_CAPACITY_FREE_MB_FLOOR=3072
# D89: idle claim cadence and the claim-error back-off (base, cap). The unit is
# a test seam only (1 s in the suite) — production is 60 s → 10 min.
# Read by bin/cfw-render.sh's --loop (not in this file):
# shellcheck disable=SC2034
CR_CAPACITY_IDLE_CLAIM_SECS="${CFW_RENDER_CAPACITY_UNIT_SECS:-60}"
# shellcheck disable=SC2034
CR_CLAIM_BACKOFF_BASE_SECS="${CFW_RENDER_CAPACITY_UNIT_SECS:-60}"
# awk, not $(( )): the test seam may be fractional (0.05 s).
# shellcheck disable=SC2034
CR_CLAIM_BACKOFF_MAX_SECS="$(awk -v u="${CFW_RENDER_CAPACITY_UNIT_SECS:-60}" 'BEGIN { print u * 10 }')"
# Wake detection: the --loop sleeps in ticks of at most 2 s. When the wall
# clock moves more than one tick plus this gap between two ticks, the Mac was
# asleep (lid shut) and the loop claims at once instead of finishing a long
# back-off. Read by bin/cfw-render.sh's --loop.
# shellcheck disable=SC2034
CR_WAKE_GAP_SECS=30

# cr_now_epoch — wall-clock seconds. CFW_RENDER_DATE_CMD is a test seam (a fake
# date that can jump forward, as after sleep).
cr_now_epoch() { "${CFW_RENDER_DATE_CMD:-date}" +%s; }

# [M2-04, D78] cr_capacity_setup_note — the setup summary line when max is 1.
# Wording mirrored in cfw-social labels.ts by M2-12 (docs/capacity.md).
CR_CAPACITY_ONE_AT_A_TIME_MSG="This computer runs one request at a time. It still serves your brands; bigger jobs just take turns."
cr_capacity_setup_note() {
  local mx; mx="$(cr_capacity_max)"
  if [[ "$mx" == "1" ]]; then
    printf '%s\n' "$CR_CAPACITY_ONE_AT_A_TIME_MSG"
  else
    printf 'This computer runs up to %s requests at a time.\n' "$mx"
  fi
}

cr_capacity_sysctl() { # cr_capacity_sysctl <key> — "" when unavailable
  command -v sysctl >/dev/null 2>&1 || { printf ''; return 0; }
  sysctl -n "$1" 2>/dev/null | head -n1 | tr -d '[:space:]' || printf ''
}

# cr_capacity_table <mem_bytes> <perf_cores> — pure function of the table above.
cr_capacity_table() {
  local mem_bytes="${1:-0}" cores="${2:-0}" gb by_mem by_cores
  gb=$(( mem_bytes / 1073741824 ))
  if   (( gb >= 64 )); then by_mem=6
  elif (( gb >= 48 )); then by_mem=5
  elif (( gb >= 32 )); then by_mem=4
  elif (( gb >= 24 )); then by_mem=3
  elif (( gb >= 16 )); then by_mem=2
  else by_mem=1; fi
  by_cores=$(( cores / 2 ))
  (( by_cores < 1 )) && by_cores=1
  (( by_mem > by_cores )) && by_mem=$by_cores
  (( by_mem > CR_CAPACITY_HARD_MAX )) && by_mem=$CR_CAPACITY_HARD_MAX
  printf '%s' "$by_mem"
}

# cr_capacity_max — prints 1..6. CFW_RENDER_CONCURRENCY (owner) wins, capped.
cr_capacity_max() {
  local override="${CFW_RENDER_CONCURRENCY:-}" mem cores
  if [[ "$override" =~ ^[0-9]+$ ]] && (( override >= 1 )); then
    (( override > CR_CAPACITY_HARD_MAX )) && override=$CR_CAPACITY_HARD_MAX
    printf '%s' "$override"; return 0
  fi
  mem="${CFW_RENDER_CAPACITY_MEM_BYTES:-}"
  cores="${CFW_RENDER_CAPACITY_PERF_CORES:-}"
  if [[ -z "$mem" ]]; then
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
      mem="$(cr_capacity_sysctl hw.memsize)"
    elif [[ -r /proc/meminfo ]]; then
      mem="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) * 1024 ))"
    fi
  fi
  if [[ -z "$cores" ]]; then
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
      cores="$(cr_capacity_sysctl hw.perflevel0.physicalcpu)"
      [[ -n "$cores" ]] || cores="$(cr_capacity_sysctl hw.physicalcpu)"
    else
      cores="$(nproc 2>/dev/null || echo 1)"
    fi
  fi
  [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
  [[ "$cores" =~ ^[0-9]+$ ]] || cores=1
  cr_capacity_table "$mem" "$cores"
}

# cr_capacity_probe — prints "<free_mb>\x1f<load_1min>\x1f<ncpu>"; blanks when
# a probe is unavailable (treated as "no constraint" by cr_capacity_ok).
cr_capacity_probe() {
  local free_mb="${CFW_RENDER_CAPACITY_FREE_MB:-}" load="${CFW_RENDER_CAPACITY_LOAD:-}" ncpu="${CFW_RENDER_CAPACITY_NCPU:-}"
  # Test seam: a file whose content (MB) replaces the free-memory probe, so a
  # test can change the value while the loop runs. Empty file = no override.
  if [[ -z "$free_mb" && -n "${CFW_RENDER_CAPACITY_FREE_MB_FILE:-}" && -s "$CFW_RENDER_CAPACITY_FREE_MB_FILE" ]]; then
    free_mb="$(tr -d '[:space:]' < "$CFW_RENDER_CAPACITY_FREE_MB_FILE")"
  fi
  local os; os="$(uname -s 2>/dev/null)"
  if [[ -z "$free_mb" ]]; then
    if [[ "$os" == "Darwin" ]] && command -v vm_stat >/dev/null 2>&1; then
      # free + inactive pages: inactive is reclaimable, so counting only "free"
      # would call a healthy Mac full. Page size comes from vm_stat's header.
      free_mb="$(vm_stat 2>/dev/null | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
        /^Pages free:/ { gsub(/\./, "", $3); f = $3 }
        /^Pages inactive:/ { gsub(/\./, "", $3); ia = $3 }
        END { if (ps == "") ps = 4096; printf "%d", (f + ia) * ps / 1048576 }')"
    elif [[ -r /proc/meminfo ]]; then
      free_mb="$(awk '/^MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)"
    fi
  fi
  if [[ -z "$load" ]]; then
    if [[ "$os" == "Darwin" ]]; then
      load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')"
    elif [[ -r /proc/loadavg ]]; then
      load="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
    fi
  fi
  if [[ -z "$ncpu" ]]; then
    if [[ "$os" == "Darwin" ]]; then ncpu="$(cr_capacity_sysctl hw.ncpu)"; else ncpu="$(nproc 2>/dev/null)"; fi
  fi
  printf '%s\x1f%s\x1f%s' "$free_mb" "$load" "$ncpu"
}

# cr_capacity_ok <free_mb> <load> <ncpu> — 0 when a NORMAL request may be
# claimed; 1 when only urgent work should be (floor or load breached).
cr_capacity_ok() {
  local free_mb="$1" load="$2" ncpu="$3" load_int
  if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < CR_CAPACITY_FREE_MB_FLOOR )); then return 1; fi
  if [[ "$load" =~ ^[0-9]+(\.[0-9]+)?$ && "$ncpu" =~ ^[0-9]+$ ]]; then
    load_int="${load%%.*}"
    (( load_int > ncpu )) && return 1
  fi
  return 0
}

# cr_capacity_json <running> <max> <free_mb> <load> — the claim's `capacity`
# field (plans/m2/CONTRACTS.md §3): {running, max, freeMemoryMb?, cpuLoad?}.
cr_capacity_json() {
  python3 -c '
import json, sys
running, mx, free_mb, load = sys.argv[1:5]
c = {"running": int(running), "max": int(mx)}
if free_mb.isdigit(): c["freeMemoryMb"] = int(free_mb)
try:
    if load: c["cpuLoad"] = float(load)
except ValueError:
    pass
print(json.dumps(c))' "$1" "$2" "${3:-}" "${4:-}"
}

# ===========================================================================
# TOOLCHAIN PREFLIGHT (CFW-199)
# ===========================================================================
#
# WHY THIS EXISTS
# CFW-188 found a render computer with **no ImageMagick at all**, one schedule
# load away from claiming production orders on a computer that could
# not finish a single one — every claimed order would have burned its attempt,
# blocked, and shown the owner a failure. Nothing in the install path or the
# drainer's startup checked. `--dry` checks config, credentials and a live
# tools/list; it does NOT check that the recipes' toolchain is on the box.
#
# THE RULE: never claim an order this host cannot finish. A missing tool is a
# hard FAIL with a named install command and a NON-ZERO exit — the drainer
# refuses to start rather than claiming work it will burn.
#
# `cr_preflight` is called from three places: `install/install.sh` (before it
# reports success), `bin/cfw-render.sh` (before the claim loop AND inside
# `--dry`), and `bin/cfw-render-preflight.sh` (a human can run it alone).
# ---------------------------------------------------------------------------

# Binaries every recipe path needs, whatever it renders.
#   curl     — the MCP transport (claim/event/complete/block)
#   python3  — every JSON hop in this repo (no jq on the box)
#   node/npx — hyperframes CLI, the HTML compositor
#   ffmpeg   — every video recipe; ffprobe is how durations are read
#   magick   — ImageMagick 7 verb form. The recipes call `magick`, not
#              `convert`; an IM6 box with only `convert` fails at render time,
#              which is exactly what CFW-188 had to shim by hand.
_CR_REQUIRED_BINS=(curl python3 node npx ffmpeg ffprobe magick)

# ---------------------------------------------------------------------------
# cr_resolve_worker_path — CFW-291. Walks _CR_REQUIRED_BINS plus `claude` and
# `codex` (M1-10a: either engine is optional here; only one must exist),
# resolving each with `command -v` in the CALLER's current environment (at
# install time that's the installer's real, rich shell — the only place we
# can observe where things are actually installed). Takes the `dirname` of
# each hit and dedupes into an ordered list (first-seen wins). Appends
# today's static fallback dirs at the END, only if not already present, so a
# resolved real location always wins over a guess but a box that already
# worked via the old hardcoded dirs keeps working unchanged.
#
# A binary that doesn't resolve is silently skipped here — cr_preflight is
# still the one place that turns "missing" into a hard failure; this
# function's only job is turning "found, and here's where" into a PATH
# string. Prints the colon-joined result on stdout. Never fails.
# ---------------------------------------------------------------------------
# M3-07a: the private toolchain. When the desktop app has installed a bundle
# at ~/CFW Render/app/tools/<version>/ with tools/current -> <version>, its
# bin/ dir goes FIRST so a bundled ffmpeg/node/magick beats whatever Homebrew
# or the system has. When the dir is absent the output is byte-identical to
# the pre-M3-07 behaviour. CFW_RENDER_TOOLS_DIR overrides the tools root
# (tests); CFW_RENDER_HOME overrides the app home.
# ---------------------------------------------------------------------------
_cr_tools_bin() {
  printf '%s' "${CFW_RENDER_TOOLS_DIR:-${CFW_RENDER_HOME:-$HOME/CFW Render}/app/tools}/current/bin"
}

cr_resolve_worker_path() {
  local result="" b path dir fb tools_bin
  tools_bin="$(_cr_tools_bin)"
  if [[ -d "$tools_bin" ]]; then
    result="$tools_bin"
  fi
  for b in "${_CR_REQUIRED_BINS[@]}" claude codex; do
    path="$(command -v "$b" 2>/dev/null)" || continue
    dir="$(dirname "$path")"
    case ":$result:" in
      *":$dir:"*) ;;
      *) result="${result:+$result:}$dir" ;;
    esac
  done
  for fb in /usr/local/bin /usr/bin /bin /opt/homebrew/bin; do
    case ":$result:" in
      *":$fb:"*) ;;
      *) result="${result:+$result:}$fb" ;;
    esac
  done
  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# cr_probe_engine_headless <codex|claude> [worker_path] — CFW-291/M1-10a. The actual new safety
# net: doesn't just ask "does claude resolve" (cr_preflight already does
# that) — asks "does claude actually RUN in the narrowest environment a
# scheduled tick will ever get." Defaults worker_path to a fresh
# cr_resolve_worker_path call if not given.
#
# Mirrors cr_preflight's existing stub-Director skip (CFW_RENDER_DIRECTOR_CMD
# set → SKIP, not FAIL — a test/dev box that intentionally stubs out claude
# must not suddenly be required to install a real one). Otherwise runs the
# probe exactly the way launchd will run the real tick: `env -i` (a
# fully stripped environment) with only PATH=<worker_path>, HOME, and a
# short, explicit allow-list of vars a CLI can legitimately need to behave
# correctly (TMPDIR, LANG, LC_ALL, USER — passed through only if already set
# in the caller's env), then `claude --version`.
#
# Applies the same "exit 0 but empty output is still a failure" rule
# cr_preflight already applies to its own claude --version check.
#
# On success: prints the version string on stdout, returns 0.
# On failure (or SKIP): prints a message on stdout/stderr, returns 0 (SKIP)
# or 1 (genuine failure) — the captured probe output and the worker_path
# tried are always included in the failure message so a human (or
# install.sh) gets an actionable message instead of a bare non-zero.
# ---------------------------------------------------------------------------
cr_probe_engine_headless() {
  local engine="${1:-}" worker_path="${2:-}"
  case "$engine" in
    claude|codex) ;;
    *) printf 'cr_probe_engine_headless: engine must be codex|claude (got %s)\n' "${engine:-<empty>}" >&2; return 1 ;;
  esac
  [[ -n "$worker_path" ]] || worker_path="$(cr_resolve_worker_path)"

  if [[ -n "${CFW_RENDER_DIRECTOR_CMD:-}" ]]; then
    printf 'SKIP — CFW_RENDER_DIRECTOR_CMD is set (stub Director); not probing a real %s\n' "$engine"
    return 0
  fi

  local -a env_args=("PATH=$worker_path" "HOME=${HOME:-}")
  local v
  for v in TMPDIR LANG LC_ALL USER; do
    [[ -n "${!v:-}" ]] && env_args+=("$v=${!v}")
  done

  local out rc
  out="$(env -i "${env_args[@]}" "$engine" --version 2>&1 < /dev/null)"
  rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  {
    printf '%s --version failed under a headless probe (env -i, rc=%s)\n' "$engine" "$rc"
    printf 'worker_path tried: %s\n' "$worker_path"
    printf 'captured output: %s\n' "${out:-<empty>}"
  } >&2
  return 1
}

# cr_probe_claude_headless [worker_path] — thin wrapper kept for callers/tests.
cr_probe_claude_headless() {
  cr_probe_engine_headless claude "${1:-}"
}

# ---------------------------------------------------------------------------
# cr_install_select_engine [worker_path] — M1-10a. Probes codex then claude
# headless under the worker PATH and prints the engine name cr_engine_detect
# understands (`codex` | `claude-code`). Honours a preset CFW_RENDER_ENGINE
# when that engine passes its probe. Returns 1 with the abort message when
# neither runs. Never reads, copies, or inspects any vendor sign-in state —
# the probe is `<cli> --version` only; sign-in is the vendor tool's business.
# ---------------------------------------------------------------------------
cr_install_select_engine() {
  local worker_path="${1:-}"
  [[ -n "$worker_path" ]] || worker_path="$(cr_resolve_worker_path)"
  local -a order=(codex claude)
  case "${CFW_RENDER_ENGINE:-}" in
    codex) order=(codex claude) ;;
    claude|claude-code) order=(claude codex) ;;
  esac
  local e
  for e in "${order[@]}"; do
    if cr_probe_engine_headless "$e" "$worker_path" >/dev/null 2>&1; then
      case "$e" in
        claude) printf 'claude-code' ;;
        *) printf '%s' "$e" ;;
      esac
      return 0
    fi
  done
  {
    printf 'Neither Codex nor Claude Code runs under the worker PATH. '
    printf 'Sign in through the vendor\xe2\x80\x99s own tool (`codex login` or `claude login`) and re-run. '
    printf 'CFW never asks for or stores those credentials.\n'
    printf 'worker_path tried: %s\n' "$worker_path"
  } >&2
  return 1
}

# Install hint for one missing tool on this OS. Never a silent fallback — the
# operator gets the exact command. On macOS the CFW Render app ships these
# tools (a non-technical install does not use Homebrew). Linux keeps apt-get.
# The Debian package named whisper is a Graphite database, not speech-to-text.
cr_preflight_hint() { # cr_preflight_hint <tool>
  local tool="$1" os pv
  # One sentence for every Darwin toolchain tool, including the recipe rows
  # (ass filter, libx264, whisper). Do not put a Homebrew command in here.
  local darwin_hint="update the CFW Render app (it ships this tool), or re-run install/install.sh"
  os="$(uname -s 2>/dev/null || echo unknown)"
  case "$tool" in
    curl)            [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "apt-get install -y curl" ;;
    python3)         [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "apt-get install -y python3" ;;
    node|npx)        [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs" ;;
    ffmpeg|ffprobe|ffmpeg:ass|ffmpeg:libx264)
                     [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "apt-get install -y ffmpeg" ;;
    magick)          [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "apt-get install -y imagemagick   (IM6 ships only 'convert' — then add the IM7 verb shim: printf '#!/bin/sh\\nexec convert \"\$@\"\\n' >/usr/local/bin/magick && chmod +x /usr/local/bin/magick)" ;;
    whisper)         [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "pip install openai-whisper, or install cfw-transcribe and put it on PATH" ;;
    claude)          echo "npm i -g @anthropic-ai/claude-code   then sign in to Claude from the CFW Renderer app (Providers → Claude → Sign in; it saves a long-lived token in this Mac's Keychain, service com.cfw.render)   (verify: the app's Providers screen shows Claude connected)" ;;
    chromium)
      # The exact pinned version, never a bare `playwright` (that is the newest release,
      # which wants a Chromium revision this computer has not cached: B8).
      if pv="$(cr_playwright_pin_field playwright 2>/dev/null)"; then
        [[ "$os" == Darwin ]] && echo "npx playwright@$pv install chromium" || echo "npx playwright@$pv install --with-deps chromium"
      else
        echo "restore config/playwright-pin.json (re-run install.sh or update the CFW Render app), then re-run this check"
      fi ;;
    fonts)           [[ "$os" == Darwin ]] && echo "$darwin_hint" || echo "apt-get install -y fontconfig fonts-dejavu-core fonts-liberation2 fonts-noto-core" ;;
    *)               echo "install $tool and put it on PATH" ;;
  esac
}

# ---------------------------------------------------------------------------
# Playwright pin (B8, B10). ONE file pins the Playwright version and the Chromium
# revisions it needs: config/playwright-pin.json. The recipe step (through the
# CFW_PLAYWRIGHT_PIN variable cr_load_config exports), the preflight below and
# install/install.sh all read it, so they cannot disagree. A newer Playwright
# wants a Chromium revision this computer has not cached, and every slide render
# then dies at chromium.launch() (R-7LU5).
# ---------------------------------------------------------------------------
cr_playwright_pin_file() { printf '%s' "$_CR_REPO_ROOT/config/playwright-pin.json"; }

# cr_playwright_pin_field <playwright|chromiumRevision|chromiumHeadlessShellRevision>
# Prints one field, shape-checked (an exact x.y.z release, or digits). On any
# problem prints the reason on stderr and returns 1: no default, no fallback.
cr_playwright_pin_field() {
  python3 -c '
import json, re, sys
path, field = sys.argv[1], sys.argv[2]
shape = {"playwright": r"[0-9]+\.[0-9]+\.[0-9]+",
         "chromiumRevision": r"[0-9]+",
         "chromiumHeadlessShellRevision": r"[0-9]+"}
if field not in shape:
    sys.exit("unknown pin field %s" % field)
try:
    value = json.load(open(path))[field]
except FileNotFoundError:
    sys.exit("%s is missing" % path)
except Exception as e:
    sys.exit("%s has no usable \"%s\" (%s)" % (path, field, e))
if not isinstance(value, str) or not re.fullmatch(shape[field], value):
    sys.exit("%s: \"%s\" must match %s" % (path, field, shape[field]))
sys.stdout.write(value)' "$(cr_playwright_pin_file)" "$1"
}

# The folder Playwright itself looks in: PLAYWRIGHT_BROWSERS_PATH when set, else
# the per-OS default. One root, because a run that sets the variable never looks
# anywhere else; checking other roots here would pass a host the run cannot use.
cr_playwright_cache_root() {
  if [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
    printf '%s' "$PLAYWRIGHT_BROWSERS_PATH"
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    printf '%s' "$HOME/Library/Caches/ms-playwright"
  else
    printf '%s' "$HOME/.cache/ms-playwright"
  fi
}

# cr_preflight_chromium — rc 0 iff the EXACT pinned Playwright browser is cached:
# chromium-<chromiumRevision> and chromium_headless_shell-<chromiumHeadlessShellRevision>,
# each finished (Playwright writes INSTALLATION_COMPLETE only when an install ends).
# Any other cached revision does NOT count: carousel renders launch exactly this
# pair. A system Chrome does not count either. stdout: where it was found (rc 0),
# or the reason it was not (rc 1), so the caller can show the cause. Read-only.
cr_preflight_chromium() {
  local ver crev hrev root cdir hdir have d note=""
  ver="$(cr_playwright_pin_field playwright 2>&1)" || { printf '%s' "$ver"; return 1; }
  crev="$(cr_playwright_pin_field chromiumRevision 2>&1)" || { printf '%s' "$crev"; return 1; }
  hrev="$(cr_playwright_pin_field chromiumHeadlessShellRevision 2>&1)" || { printf '%s' "$hrev"; return 1; }
  root="$(cr_playwright_cache_root)"
  cdir="$root/chromium-$crev"
  hdir="$root/chromium_headless_shell-$hrev"
  if [[ -f "$cdir/INSTALLATION_COMPLETE" && -f "$hdir/INSTALLATION_COMPLETE" ]]; then
    printf 'Playwright %s: chromium-%s + chromium_headless_shell-%s in %s' "$ver" "$crev" "$hrev" "$root"
    return 0
  fi
  for d in "$cdir" "$hdir"; do
    [[ -d "$d" && ! -f "$d/INSTALLATION_COMPLETE" ]] && note="$note; ${d##*/} is incomplete"
  done
  have=""
  for d in "$root"/chromium-* "$root"/chromium_headless_shell-*; do
    [[ -d "$d" ]] && have="$have${have:+, }${d##*/}"
  done
  printf 'Playwright %s needs chromium-%s and chromium_headless_shell-%s in %s (found: %s%s)' \
    "$ver" "$crev" "$hrev" "$root" "${have:-no Playwright browsers}" "$note"
  return 1
}

# cr_install_pinned_chromium — install the pinned browser: `npx --yes playwright@<ver>
# install chromium` (that command fetches both the chromium and headless-shell
# revisions the version expects). The caller has already seen cr_preflight_chromium
# fail. rc 0 installed; rc 1 the install failed (npx's own output is shown, nothing
# is hidden); rc 2 there is no npx to run it with (the preflight that follows then
# names node and the exact command). It does not re-check: the preflight does.
cr_install_pinned_chromium() {
  local ver
  ver="$(cr_playwright_pin_field playwright 2>&1)" || { printf 'cfw-render: %s\n' "$ver" >&2; return 1; }
  command -v npx >/dev/null 2>&1 || return 2
  echo "cfw-render: installing the pinned Playwright browser: npx --yes playwright@$ver install chromium"
  npx --yes "playwright@$ver" install chromium
}

# Fonts. Deliberately checks the GENERIC families, not the brand families the
# recipes name (Inter/Oswald/JetBrains Mono/…): the HyperFrames compiler embeds
# those itself, and the Mac drainer — which has cooked real dishes — has none of
# them installed system-wide. Requiring them would be a false FAIL. What DOES
# break a render is a host with no usable font at all: headless Chromium and
# ImageMagick then draw blank or tofu text and the QA gate fails every time.
# Prints the resolved sans font on success.
cr_preflight_fonts() {
  local fam file
  if command -v fc-match >/dev/null 2>&1; then
    local sans=""
    for fam in sans-serif serif monospace; do
      file="$(fc-match -f '%{file}' "$fam" 2>/dev/null)"
      [[ -n "$file" && -r "$file" ]] || return 1
      [[ "$fam" == "sans-serif" ]] && sans="$file"
    done
    printf '%s' "$sans"
    return 0
  fi
  # No fontconfig: macOS still has Core Text system fonts, which Chromium uses.
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" && -d /System/Library/Fonts ]]; then
    file="$(find /System/Library/Fonts -maxdepth 1 -type f \( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \) 2>/dev/null | head -1)"
    [[ -n "$file" ]] && { printf '%s (no fontconfig; Core Text)' "$file"; return 0; }
  fi
  return 1
}

# _cr_ffmpeg_has_row <filters|encoders> <name>
# rc 0 when `ffmpeg -hide_banner -<filters|encoders>` has a row whose name
# column is exactly <name>. ffmpeg prints "FLAGS name ..."; the name is the
# second field. Matching that column ignores a description that only mentions
# the word (the ass filter's own text says "ASS" and "libass").
# set -e safe: install.sh sources this file with -e, so failures stay inside ifs.
# No here-string: bash stores one in a file under $TMPDIR, and this check must
# still run when that directory is read-only (the confined gate, a locked Mac).
_cr_ffmpeg_has_row() {
  local mode="$1" name="$2" line rest tok listing
  listing="$(ffmpeg -hide_banner "-$mode" 2>&1)" || listing=""
  while [[ -n "$listing" ]]; do
    line="${listing%%$'\n'*}"
    if [[ "$listing" == *$'\n'* ]]; then
      listing="${listing#*$'\n'}"
    else
      listing=""
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$line" ]]; then
      continue
    fi
    rest="${line#* }"
    if [[ "$rest" == "$line" ]]; then
      continue
    fi
    tok="${rest%% *}"
    if [[ "$tok" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# cr_preflight_manifest_rows — one "<check> <manifestName>" pair per line.
# manifestName is a toolchain tools[].name or a provides[] string, or "host"
# when that check is not a bundled tool (system curl, Claude Code from
# Anthropic, the machine's own fonts). cr_preflight reads this list.
# The manifest test reads the same list and fails when a preflight check has
# no manifest entry. Binary rows must match _CR_REQUIRED_BINS, same order.
# ---------------------------------------------------------------------------
cr_preflight_manifest_rows() {
  printf '%s\n' \
    "curl host" \
    "python3 python3" \
    "node node" \
    "npx npx" \
    "ffmpeg ffmpeg" \
    "ffprobe ffprobe" \
    "magick magick" \
    "claude host" \
    "chromium chromium" \
    "fonts host" \
    "ffmpeg:ass libass" \
    "ffmpeg:libx264 libx264" \
    "whisper whisper"
}

# rc 0 when every shared row is a check this function's caller performs.
# A new row whose label cr_preflight does not mention fails closed.
_cr_preflight_rows_agree() {
  local cname mname src rows line
  local -a row_bins=()
  src="$(declare -f cr_preflight)"
  # Same shell as the caller: a pipe would drop row_bins. No process
  # substitution either — that can need a temp file when TMPDIR is read-only.
  rows="$(cr_preflight_manifest_rows)" || return 1
  while [[ -n "$rows" ]]; do
    line="${rows%%$'\n'*}"
    if [[ "$rows" == *$'\n'* ]]; then
      rows="${rows#*$'\n'}"
    else
      rows=""
    fi
    cname="${line%% *}"
    if [[ "$line" == *" "* ]]; then
      mname="${line#* }"
    else
      mname=""
    fi
    [[ -n "${cname:-}" ]] || continue
    if [[ -z "${mname:-}" ]]; then
      printf 'cr_preflight: shared row "%s" has no manifest name\n' "$cname" >&2
      return 1
    fi
    case "$cname" in
      curl|python3|node|npx|ffmpeg|ffprobe|magick)
        row_bins+=("$cname")
        ;;
      *)
        case "$src" in
          *"$cname"*) ;;
          *)
            printf 'cr_preflight: shared row "%s" is not checked\n' "$cname" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done
  if [[ ${#row_bins[@]} -eq 0 ]]; then
    printf 'cr_preflight: shared manifest rows listed no binaries\n' >&2
    return 1
  fi
  if [[ "$(printf '%s ' "${row_bins[@]}")" != "$(printf '%s ' "${_CR_REQUIRED_BINS[@]}")" ]]; then
    printf 'cr_preflight: manifest rows do not match _CR_REQUIRED_BINS\n' >&2
    return 1
  fi
}

# rc 0 when <check> is a host row in cr_preflight_manifest_rows (not a file
# this bundle ships). curl, claude and fonts are host. A bundled name is not.
_cr_preflight_is_host() {
  local want="$1" cname mname rows line
  rows="$(cr_preflight_manifest_rows)" || return 1
  while [[ -n "$rows" ]]; do
    line="${rows%%$'\n'*}"
    if [[ "$rows" == *$'\n'* ]]; then
      rows="${rows#*$'\n'}"
    else
      rows=""
    fi
    cname="${line%% *}"
    if [[ "$line" == *" "* ]]; then
      mname="${line#* }"
    else
      mname=""
    fi
    [[ "$cname" == "$want" && "$mname" == "host" ]] && return 0
  done
  return 1
}

# Playwright browsers shipped in this tree. build.sh fills share/ms-playwright.
# browsers/ is accepted when that is the directory present instead.
# Prints the directory. rc 1 when neither exists (no HOME fallback here).
_cr_bundle_browsers_dir() {
  if [[ -d "$_CR_REPO_ROOT/share/ms-playwright" ]]; then
    printf '%s' "$_CR_REPO_ROOT/share/ms-playwright"
    return 0
  fi
  if [[ -d "$_CR_REPO_ROOT/browsers" ]]; then
    printf '%s' "$_CR_REPO_ROOT/browsers"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# cr_preflight — the gate. Prints one row per check; returns 0 iff every
# required check PASSes. Callers MUST treat a non-zero return as fatal.
#
# `--quiet` prints only failures (used on the drainer's hot path, so a healthy
# 15-minute tick stays silent).
#
# `--bundle` checks the unpacked tree this script lives in (the copy in
# bundle/bin, whose parent is the bundle). It checks bundled binaries and the
# pinned Chromium under that tree's browsers directory, read from that tree's
# config/playwright-pin.json. It skips host-only rows: the claude CLI, a stub
# Director (CFW_RENDER_DIRECTOR_CMD), system curl, system fonts, and the HOME
# Playwright cache. It may be combined with `--quiet` in either order.
# Without `--bundle` the full host check is unchanged.
# ---------------------------------------------------------------------------
cr_preflight() {
  local quiet=0 bundle=0 arg
  for arg in "$@"; do
    case "$arg" in
      --quiet) quiet=1 ;;
      --bundle) bundle=1 ;;
    esac
  done
  _cr_preflight_rows_agree || return 1

  local ok=1
  local -a missing=()
  _cr_pf_row() { # _cr_pf_row <ok:0|1> <label> <detail>
    if [[ "$1" == "0" ]]; then
      (( quiet )) || printf '  PASS  %-22s %s\n' "$2" "$3"
    else
      printf '  FAIL  %-22s %s\n' "$2" "$3" >&2
      ok=0
    fi
  }

  # Bundle mode points Chromium at this tree and never at the HOME cache.
  # Save and restore so a later full preflight in the same shell is unchanged.
  local pw_changed=0 pw_set=0 pw_old=""
  _cr_pf_restore_browsers() {
    if (( pw_changed )); then
      if (( pw_set )); then
        PLAYWRIGHT_BROWSERS_PATH="$pw_old"
        export PLAYWRIGHT_BROWSERS_PATH
      else
        unset PLAYWRIGHT_BROWSERS_PATH
      fi
    fi
  }
  if (( bundle )); then
    if [[ -n "${PLAYWRIGHT_BROWSERS_PATH+x}" ]]; then
      pw_set=1
      pw_old="$PLAYWRIGHT_BROWSERS_PATH"
    fi
    if ! PLAYWRIGHT_BROWSERS_PATH="$(_cr_bundle_browsers_dir)"; then
      PLAYWRIGHT_BROWSERS_PATH="$_CR_REPO_ROOT/share/ms-playwright"
    fi
    export PLAYWRIGHT_BROWSERS_PATH
    pw_changed=1
  fi

  (( quiet )) || { echo "cfw-render preflight — toolchain"; echo "-------------------------------------"; }

  local b path tools_bin
  tools_bin="$(_cr_tools_bin)"
  for b in "${_CR_REQUIRED_BINS[@]}"; do
    if (( bundle )) && _cr_preflight_is_host "$b"; then
      continue
    fi
    if path="$(command -v "$b" 2>/dev/null)"; then
      _cr_pf_row 0 "binary:$b" "$path"
    else
      if [[ -d "$tools_bin" ]]; then
        _cr_pf_row 1 "binary:$b" "not on PATH (not in $tools_bin either)"
      else
        _cr_pf_row 1 "binary:$b" "not on PATH"
      fi
      missing+=("$b")
    fi
  done

  # ImageMagick 7 verb form specifically — an IM6-only box has `convert` but the
  # recipes shell out to `magick` (CFW-188's exact hole).
  if command -v magick >/dev/null 2>&1; then
    local imv
    imv="$(magick -version 2>/dev/null | head -1)"
    _cr_pf_row 0 "imagemagick" "${imv:-present}"
  elif command -v convert >/dev/null 2>&1; then
    _cr_pf_row 1 "imagemagick" "only ImageMagick 6 'convert' found — the recipes call 'magick'"
  fi

  # The Director. Skipped when a stub Director is configured (tests / dev).
  # --bundle skips this host row: the bundle does not ship claude, and a
  # stub Director command is not part of the bundle either.
  if (( ! bundle )); then
    if [[ -n "${CFW_RENDER_DIRECTOR_CMD:-}" ]]; then
      (( quiet )) || printf '  SKIP  %-22s %s\n' "cli:claude" "CFW_RENDER_DIRECTOR_CMD is set — stub Director"
    elif command -v claude >/dev/null 2>&1; then
      local cv
      cv="$(claude --version 2>/dev/null | head -1)"
      if [[ -n "$cv" ]]; then
        _cr_pf_row 0 "cli:claude" "$cv"
      else
        _cr_pf_row 1 "cli:claude" "found at $(command -v claude) but 'claude --version' produced nothing"
        missing+=("claude")
      fi
    else
      _cr_pf_row 1 "cli:claude" "not on PATH — the render Director cannot run"
      missing+=("claude")
    fi
  fi

  if path="$(cr_preflight_chromium)"; then
    _cr_pf_row 0 "chromium" "$path"
  else
    _cr_pf_row 1 "chromium" "${path:-pinned Playwright browser not found} — carousel and HTML renders cannot launch"
    missing+=("chromium")
  fi

  # Fonts are the machine's own, not a bundled file. Full mode still checks them.
  if (( ! bundle )); then
    if path="$(cr_preflight_fonts)"; then
      _cr_pf_row 0 "fonts" "$path"
    else
      _cr_pf_row 1 "fonts" "no usable system font — text renders blank/tofu and every QA gate fails"
      missing+=("fonts")
    fi
  fi

  # Recipes call `ffmpeg -vf ass=` and `-c:v libx264`. A ffmpeg binary can
  # exist and still be built without libass or libx264, so the name check
  # above is not enough. Skip when ffmpeg itself is missing: that row already
  # names it, and there is no binary to ask.
  if command -v ffmpeg >/dev/null 2>&1; then
    if _cr_ffmpeg_has_row filters ass; then
      _cr_pf_row 0 "ffmpeg:ass" "ass filter (libass)"
    else
      _cr_pf_row 1 "ffmpeg:ass" "no ass filter (libass) — captions that use -vf ass= cannot render"
      missing+=("ffmpeg:ass")
    fi
    if _cr_ffmpeg_has_row encoders libx264; then
      _cr_pf_row 0 "ffmpeg:libx264" "libx264 encoder"
    else
      _cr_pf_row 1 "ffmpeg:libx264" "no libx264 encoder — recipes that use -c:v libx264 cannot encode"
      missing+=("ffmpeg:libx264")
    fi
  fi

  # p-reels-faceless and p-longform transcribe with any one of these.
  local wtool="" wpath=""
  for wtool in cfw-transcribe mlx_whisper whisper; do
    if wpath="$(command -v "$wtool" 2>/dev/null)"; then
      _cr_pf_row 0 "whisper" "$wtool ($wpath)"
      break
    fi
  done
  if [[ -z "$wpath" ]]; then
    _cr_pf_row 1 "whisper" "not on PATH — need cfw-transcribe, mlx_whisper or whisper"
    missing+=("whisper")
  fi

  if (( ok )); then
    (( quiet )) || { echo "-------------------------------------"; echo "PREFLIGHT: PASS"; }
    _cr_pf_restore_browsers
    return 0
  fi

  {
    echo ""
    echo "PREFLIGHT: FAIL — this host cannot finish a render. Refusing to continue."
    echo "cfw-render claims real orders; starting here would claim work and burn it."
    echo ""
    echo "Missing:"
    for b in "${missing[@]}"; do
      printf '  - %-10s %s\n' "$b" "$(cr_preflight_hint "$b")"
    done
    echo ""
    echo "Re-run 'bin/cfw-render-preflight.sh' until it prints PASS, then start the timer."
  } >&2
  _cr_pf_restore_browsers
  return 1
}

# ---------------------------------------------------------------------------
# [M3-01a] Worker version, status file, pause / battery state.
# ---------------------------------------------------------------------------
CR_LIB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# cr_worker_version — contents of $REPO/VERSION (0.0.0 when missing).
cr_worker_version() {
  local v
  v="$(head -n1 "$CR_LIB_REPO_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  printf '%s\n' "${v:-0.0.0}"
}

# cr_on_battery — rc 0 iff the Mac is on battery power (pmset). No pmset →
# not on battery. CFW_RENDER_PMSET_CMD overrides the command (tests).
cr_on_battery() {
  local cmd="${CFW_RENDER_PMSET_CMD:-pmset}"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" -g batt 2>/dev/null | grep -q 'Battery Power'
}

# cr_pause_state — echoes owner | battery | none.
cr_pause_state() {
  if [[ -e "$CFW_RENDER_STATE_DIR/paused" ]]; then
    echo owner
  elif [[ ! -e "$CFW_RENDER_STATE_DIR/allow-battery" ]] && cr_on_battery; then
    echo battery
  else
    echo none
  fi
}

# [M3-01c] cr_computer_name — the owner-facing computer name, cached per process.
CR_COMPUTER_NAME_CACHE=""
cr_computer_name() {
  if [[ -z "$CR_COMPUTER_NAME_CACHE" ]]; then
    CR_COMPUTER_NAME_CACHE="${CFW_RENDER_COMPUTER_NAME:-}"
    [[ -n "$CR_COMPUTER_NAME_CACHE" ]] || CR_COMPUTER_NAME_CACHE="$(scutil --get ComputerName 2>/dev/null || true)"
    [[ -n "$CR_COMPUTER_NAME_CACHE" ]] || CR_COMPUTER_NAME_CACHE="$(hostname -s 2>/dev/null || true)"
  fi
  printf '%s' "$CR_COMPUTER_NAME_CACHE"
}

# [M3-01c] cr_recent_append <order_json_file_or_empty> <outcome> [orderId] [identity_json] [owner_safe_reason] —
# one finished request into recent.ndjson (24 h, max 50 lines, atomic).
# Explicit identity is authoritative, even if empty/invalid: never read reused
# scratch in that case. Three-argument callers retain the legacy file fallback.
cr_recent_append() {
  local dir="$CFW_RENDER_STATE_DIR"
  mkdir -p "$dir" 2>/dev/null || return 0
  ( umask 077
    python3 -c '
import json, sys, os, datetime, re
f, outcome, oid, path, explicit, identity, reason = sys.argv[1:8]
def obj(value): return value if isinstance(value, dict) else {}
def text(value): return value if isinstance(value, str) else None
o = {}
if explicit:
    try: o = obj(json.loads(identity))
    except (ValueError, TypeError): pass
else:
    if f and os.path.isfile(f):
        try: o = obj(json.load(open(f)))
        except Exception: pass
    attempt = obj(o.get("attempt"))
    brand = obj(obj(o.get("taskOrder")).get("brand"))
    o = {"orderId": text(o.get("id")) or oid or None,
         "shortCode": o.get("shortCode"), "brand": o.get("brandName"),
         "attemptId": text(attempt.get("id")) or text(o.get("attemptId")),
         "brandSlug": text(brand.get("slug")) or text(o.get("brandSlug")), "recipe": o.get("recipe"), "kind": o.get("kind")}
# Re-allowlist at the serialization boundary; no nested data or raw reasons.
identity = {k: text(o.get(k)) for k in
            ("orderId", "attemptId", "shortCode", "brand", "brandSlug", "recipe", "kind", "startedAt", "directorLog")}
try:
    start = identity["startedAt"]
    if not start or not start.endswith("Z"): raise ValueError()
    datetime.datetime.fromisoformat(start.replace("Z", "+00:00"))
except (ValueError, TypeError): identity["startedAt"] = None
log = identity["directorLog"]
if log and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.out", log):
    identity["directorLog"] = None
# Reasons are supplied by the worker, not read from model output or scratch.
# Reapply the existing support redactor before storing the bounded summary.
import importlib.util
spec = importlib.util.spec_from_file_location("render_redact", sys.argv[8])
redactor = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(redactor)
reason = redactor.redact(" ".join(reason.split()))[:400]
m = {"complete": "done", "completed": "done", "stage-completed": "done"}
for k in ("released", "revoked", "engine_limit", "cancelled"): m[k] = "stopped"
nowdt = datetime.datetime.now(datetime.timezone.utc)
result = m.get(outcome, "failed")
row = dict(identity, result=result, reason=(reason or None) if result != "done" else None,
           finishedAt=nowdt.strftime("%Y-%m-%dT%H:%M:%SZ"))
rows = []
try:
    for line in open(path):
        try: rows.append(json.loads(line))
        except Exception: pass
except OSError: pass
rows.append(row)
cut = nowdt - datetime.timedelta(hours=24)
def fresh(r):
    try: return datetime.datetime.fromisoformat(r["finishedAt"].replace("Z", "+00:00")) >= cut
    except Exception: return False
rows = [r for r in rows if fresh(r)][-50:]
tmp = path + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
os.replace(tmp, path)
' "${1:-}" "${2:-}" "${3:-}" "$dir/recent.ndjson" "${4+x}" "${4:-}" "${5:-}" "$(dirname "${BASH_SOURCE[0]}")/cfw-render-redact.py"
  ) 2>/dev/null || true
}

# Refresh the read-only waiting list. Unsupported/invalid replies clear stale data.
cr_queue_refresh() {
  local out p="$CFW_RENDER_STATE_DIR/next.json"
  if ! out="$(cr_mcp_call_soft list_render_queue "$(python3 -c 'import json,sys; print(json.dumps({"workerId": sys.argv[1]}))' "${CFW_WORKER_ID:-}")" 2>/dev/null)"; then
    rm -f "$p"
    return 0
  fi
  ( umask 077
    python3 -c '
import json, sys, os
d = json.loads(sys.stdin.read())
orders = d.get("orders") if isinstance(d, dict) else None
if not isinstance(orders, list): raise ValueError("missing queue")
rows = []
for x in orders[:20]:
    if not isinstance(x, dict) or not isinstance(x.get("id"), str): continue
    def text(k):
        v = x.get(k)
        return v[:400] if isinstance(v, str) else None
    rows.append({"orderId": text("id"), "shortCode": text("shortCode"), "brand": text("brandName"),
                 "brandSlug": text("brandSlug"), "kind": text("kind"), "recipe": text("recipe"),
                 "status": text("status"), "needs": text("needs"), "createdAt": text("createdAt")})
p = sys.argv[1]; tmp = p + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f: json.dump(rows, f)
os.replace(tmp, p)' "$p" <<< "$out"
  ) 2>/dev/null || rm -f "$p"
}

# cr_status_write — atomically writes $CFW_RENDER_STATE_DIR/status.json in the
# frozen contract shape (CONTRACTS.md §1). [M3-01c] engines/activeEngine from
# cfw-render-engine.sh; `now` from <orderDir>/current-step.json; `brands` from
# brands.json; `recent` from recent.ndjson. Never holds keys or tokens.
cr_status_write() {
  local dir="$CFW_RENDER_STATE_DIR" tmp engines="[]" active="none"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/status.json.tmp.$$"
  if declare -F cr_engines_json >/dev/null; then
    engines="$(cr_engines_json)"; active="$(cr_engine_active)"
  fi
  ( umask 077
    python3 -c '
import json, sys, glob, os, datetime
a = sys.argv
def b(s): return s == "1"
def n(s, d=0):
    try: return int(s)
    except ValueError: return d
def load(p, d):
    try: return json.load(open(p))
    except Exception: return d
labels = {"codex": "ChatGPT", "claude-code": "Claude"}
engines = []
try: raw = json.loads(a[13] or "[]")
except Exception: raw = []
for e in raw:
    if not isinstance(e, dict): continue
    row = {"name": e.get("name"), "label": e.get("label") or labels.get(e.get("name"), e.get("name")), "auth": e.get("auth") or "signin",
                    "signedIn": bool(e.get("signedIn")), "limit": e.get("limit") or "unknown",
                    "resetsAt": e.get("resetsAt") or None}
    if e.get("reason"): row["reason"] = e["reason"]
    engines.append(row)
sd = a[15]
brands = []
for x in load(os.path.join(sd, "brands.json"), []) or []:
    if isinstance(x, dict) and x.get("id"):
        brands.append({"id": x.get("id"), "name": x.get("name"), "serving": True, "slug": x.get("slug")})
now = []
for p in sorted(glob.glob(os.path.join(a[16], "*", "*", "current-step.json"))):
    d = load(p, None)
    if not isinstance(d, dict): continue
    now.append({k: d.get(k) for k in ("shortCode", "brand", "recipe", "step", "steps", "stepLabel", "pct", "startedAt")})
recent = []
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
try: lines = open(os.path.join(sd, "recent.ndjson")).read().splitlines()
except OSError: lines = []
for line in reversed(lines):
    try:
        r = json.loads(line)
        if datetime.datetime.fromisoformat(r["finishedAt"].replace("Z", "+00:00")) < cut: continue
    except Exception: continue
    recent.append({k: r.get(k) for k in ("shortCode", "brand", "result", "finishedAt", "orderId", "attemptId", "brandSlug", "recipe", "kind", "reason", "startedAt", "directorLog")})
    if len(recent) >= 20: break
nxt = load(os.path.join(sd, "next.json"), [])
nxt = [x for x in nxt if isinstance(x, dict)][:20] if isinstance(nxt, list) else []
conn = load(os.path.join(sd, "connection.json"), None)
conn = {k: conn.get(k) for k in ("scope", "keyName", "keyHint", "connectedAt")} if isinstance(conn, dict) else None
doc = {
  "schema": 1, "workerVersion": a[2], "engines": engines,
  "activeEngine": (a[14] if a[14] not in ("", "none") else None),
  "computer": {"name": a[1] or None, "max": n(a[11], 1), "running": n(a[10]), "onBattery": b(a[5]),
               "paused": b(a[3]), "pauseReason": a[4] or None, "updateRequired": b(a[7])},
  "brands": brands, "now": now, "next": nxt, "recent": recent, "connection": conn,
  "lastCheckAt": a[9] or None, "lastError": a[8] or None,
  "cfwReach": (a[17] if a[17] in ("ok", "unreachable") else None),
  "cfwReachSince": a[18] or None,
}
json.dump(doc, open(a[12], "w"), indent=2)
' "$(cr_computer_name)" "$(cr_worker_version)" "${CR_STATUS_PAUSED:-0}" \
      "${CR_STATUS_PAUSE_REASON:-}" "${CR_STATUS_ON_BATTERY:-0}" "" \
      "${CR_STATUS_UPDATE_REQUIRED:-0}" "${CR_STATUS_LAST_ERROR:-}" "${CR_STATUS_LAST_CHECK_AT:-}" \
      "${CR_STATUS_RUNNING:-0}" "${CR_STATUS_MAX:-1}" "$tmp" "$engines" "$active" "$dir" \
      "${CFW_RENDER_SCRATCH:-/nonexistent}" "${CR_STATUS_CFW_REACH:-}" "${CR_STATUS_CFW_REACH_SINCE:-}"
  ) 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$dir/status.json"
}
