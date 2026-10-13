#!/usr/bin/env bash
# install/install.sh — installs cfw-render as a service pool on the current
# host. AUTHORING ONLY in this task (AB-RNDR-WORKER): this script is never
# executed against hst by the unattended dev lane. It is run later by a
# human/attended session per docs/deploy.md.
#
# Usage:
#   install.sh --user <u> --prefix <dir> [--env-file <path>] [--mode server|byoa] [--yes-really]
#   install.sh --uninstall [--delete-outputs] [--yes|--non-interactive] [--from-app]
#
# --prefix     where bin/ + lib/ + skills/ + scripts/ get copied
#              (default: server /opt/cfw-render; byoa "$HOME/CFW Render/app")
# --env-file   env file the installed unit will read
#              (default: server /etc/cfw-render.env; byoa ~/.cfw-render/cfw-render.env,
#              or the legacy ~/ecosystem/vault/cfw-render.env when only that exists)
# --mode       deploy mode written to the env file (server|byoa, default server) — doc §4
#
# byoa folder layout (the owner's own computer — see AGENTS.md "Where things are"):
#   "$HOME/CFW Render/"  app/ (prefix), outputs/<brand>/ (kept renders), logs/
#   ~/.cfw-render/       worker-id, cfw-render.env (chmod 600), scratch/
# --user       user the systemd unit runs as (Linux only; ignored on macOS)
# --yes-really required to run as root (refuses otherwise — guard rail)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

PREFIX=""
ENV_FILE=""
RUN_USER="${SUDO_USER:-$(id -un)}"
MODE="server"
YES_REALLY=0
NON_INTERACTIVE=0
FROM_APP=0
UNINSTALL=0
DELETE_OUTPUTS=0
ASSUME_YES=0

while (( $# )); do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --yes-really) YES_REALLY=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --from-app) FROM_APP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --delete-outputs) DELETE_OUTPUTS=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) echo "install.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# ── [M3-06a] --uninstall [--delete-outputs] [--yes]: remove CFW Render from
# this Mac (logic in install/uninstall.sh). Always exits 0 once confirmed.
if (( UNINSTALL )); then
  # shellcheck source=install/uninstall.sh
  source "$SELF_DIR/uninstall.sh"
  un_main
  exit $?
fi

case "$MODE" in
  server|byoa) : ;;
  *) echo "install.sh: --mode must be server|byoa (got '$MODE')" >&2; exit 2 ;;
esac

# ── [M3-04a] --from-app: the macOS app drives the whole set-up with no
# prompts. stdout carries ONLY one JSON object per line for the app; every
# human-readable line goes to stderr (fd 1 is re-pointed at fd 2, the app's
# channel is fd 3). The brand key arrives on stdin only — never argv/env/file.
if (( FROM_APP )); then
  if (( ! NON_INTERACTIVE )) || [[ "$MODE" != "byoa" ]]; then
    echo "install.sh: --from-app requires --non-interactive and --mode byoa" >&2
    exit 2
  fi
  exec 3>&1 1>&2
  # shellcheck source=install/from-app.sh
  source "$SELF_DIR/from-app.sh"
fi
# app_step <step> <state> <message> [action] — one JSON line on the app channel.
app_step() {
  (( FROM_APP )) || return 0
  python3 -c '
import json, sys
o = {"step": sys.argv[1], "state": sys.argv[2], "message": sys.argv[3]}
if len(sys.argv) > 4 and sys.argv[4]:
    o["action"] = sys.argv[4]
print(json.dumps(o), flush=True)' "$@" >&3
}
# app_fail <step> <exit> <message> [action]
app_fail() { app_step "$1" failed "$3" "${4:-}"; exit "$2"; }

# The service user's home. When the installer runs as that user, $HOME is it
# (and stays correct under a test harness that points HOME at a temp dir).
if [[ "$RUN_USER" == "$(id -un)" ]]; then
  RUN_HOME="$HOME"
else
  RUN_HOME="$(eval echo "~$RUN_USER" 2>/dev/null || echo "$HOME")"
fi

# env_value <KEY> — the last KEY=value in the env file (if any), with a
# leading $HOME / ${HOME} / ~ expanded to the service user's home.
env_value() {
  local v=""
  [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] || return 0
  v="$(grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  case "$v" in
    '$HOME'*) v="$RUN_HOME${v#\$HOME}" ;;
    '${HOME}'*) v="$RUN_HOME${v#\$\{HOME\}}" ;;
    '~'*) v="$RUN_HOME${v#\~}" ;;
  esac
  printf '%s' "$v"
}

# Mode-dependent defaults for --env-file / --prefix (explicit flags win).
if [[ -z "$ENV_FILE" ]]; then
  if [[ "$MODE" == "byoa" ]]; then
    ENV_FILE="$RUN_HOME/.cfw-render/cfw-render.env"
    if [[ ! -e "$ENV_FILE" && -r "$RUN_HOME/ecosystem/vault/cfw-render.env" ]]; then
      ENV_FILE="$RUN_HOME/ecosystem/vault/cfw-render.env"
      echo "install.sh: NOTE — using the existing settings file at its older location $ENV_FILE." >&2
      echo "  New installs keep it at ~/.cfw-render/cfw-render.env; move it there whenever convenient." >&2
    fi
  else
    ENV_FILE="/etc/cfw-render.env"
  fi
fi
CFW_HOME="${CFW_RENDER_HOME:-$(env_value CFW_RENDER_HOME)}"
CFW_HOME="${CFW_HOME:-$RUN_HOME/CFW Render}"
if [[ -z "$PREFIX" ]]; then
  if [[ "$MODE" == "byoa" ]]; then
    PREFIX="$CFW_HOME/app"
  else
    PREFIX="/opt/cfw-render"
  fi
fi

BRAND_KEY=""
if (( FROM_APP )); then
  # One line from stdin; empty (or no stdin) means "adopt an existing set-up".
  IFS= read -r BRAND_KEY || true
  BRAND_KEY="${BRAND_KEY%$'\r'}"
  APP_PLIST="$HOME/Library/LaunchAgents/com.cfw.render.plist"
  if [[ -z "$BRAND_KEY" ]]; then
    # ── Adopt (M3-04 item 4): already set up → verify the key with a
    # claim-free tools/list (the --dry check) and report ready.
    if [[ -n "$(env_value CFW_RENDER_WORKER_KEY)" && -f "$APP_PLIST" ]]; then
      app_step checking started "Checking this computer"
      if fa_tools_list_ok "$(fa_api_base)" "$(env_value CFW_RENDER_WORKER_KEY)"; then
        app_step ready "done" "Already set up"
        exit 0
      fi
      app_fail checking 5 "The saved connection did not work" "Paste a fresh key from CFW Settings"
    fi
    app_fail connecting 5 "No key was given" "Paste the key from CFW Settings"
  fi
  if ! [[ "$BRAND_KEY" =~ ^cfw_[A-Za-z0-9_]+$ ]]; then
    BRAND_KEY=""
    app_fail connecting 5 "That key does not look right" "Copy the key again from CFW Settings"
  fi
  app_step checking started "Checking this computer"
fi

if [[ "$(id -u)" -eq 0 && "$YES_REALLY" -ne 1 ]]; then
  echo "install.sh: refusing to run as root without --yes-really (guard rail)" >&2
  exit 1
fi

# CFW_RENDER_TEST_OS — a narrow test-only seam (same spirit as
# CFW_RENDER_DIRECTOR_CMD) so test/run-tests.sh can exercise the Linux
# template-rendering branch from a macOS dev box without an actual Linux
# host. Only ever set by the test harness; never set in a real install.
OS="${CFW_RENDER_TEST_OS:-$(uname -s)}"
echo "install.sh: OS=$OS prefix=$PREFIX env-file=$ENV_FILE user=$RUN_USER mode=$MODE"

# ── [CFW-199] Toolchain preflight, BEFORE anything is copied or a unit written.
# CFW-188 found hst with no ImageMagick at all — installed, unit-ready, and one
# `systemctl enable` away from claiming production orders it could not finish.
# Fail here, loudly, with the install commands, rather than leaving a box that
# looks installed and burns real work.
# shellcheck source=/dev/null
source "$REPO_DIR/bin/cfw-render-lib.sh"
if (( FROM_APP )); then
  if ! pf_err="$(cr_preflight 2>&1 >/dev/null)"; then
    printf '%s\n' "$pf_err" >&2
    pf_tool="$(printf '%s\n' "$pf_err" | sed -nE 's/^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)"
    app_fail checking 4 "A needed tool is missing: ${pf_tool:-unknown}" "Install ${pf_tool:-the missing tool} and try again"
  fi
elif ! cr_preflight; then
  echo "install.sh: ABORTING — the toolchain preflight failed (see above)." >&2
  echo "  Nothing was installed. Fix the missing tools and re-run install.sh." >&2
  exit 1
fi
echo ""

# ── [CFW-291] Resolve the real worker PATH from where binaries actually live
# (not a guessed static list), then prove `claude` runs under EXACTLY that
# PATH in a stripped env — the narrow environment launchd/systemd hand a
# scheduled unit, not this installer's rich shell. A `claude` that resolves
# via cr_preflight's `command -v` (because a shell function/alias/nvm-asdf
# init hook shadows or wraps the real binary) can still fail the moment it
# runs headless — this is the gap CFW-279 left open.
WORKER_PATH="$(cr_resolve_worker_path)"
echo "install.sh: resolved worker PATH: $WORKER_PATH"
# M1-10a: either engine is acceptable — probe codex then claude (honouring a
# preset CFW_RENDER_ENGINE when it passes) and record the one that runs.
if [[ "$OS" != "Darwin" ]]; then
  echo "install.sh: Linux installs are unchanged but not advertised in M1"
fi
# CFW_RENDER_TEST_NO_ENGINE — test-only seam (like CFW_RENDER_TEST_OS): a dev
# box always has a real engine somewhere on the resolved PATH.
if [[ "${CFW_RENDER_TEST_NO_ENGINE:-0}" == "1" ]] || ! ENGINE="$(cr_install_select_engine "$WORKER_PATH")"; then
  (( FROM_APP )) && app_fail checking 3 "No AI engine is signed in on this computer" "Sign in to ChatGPT or Claude in AI Providers"
  echo "install.sh: ABORTING — no engine runs under the worker PATH (see above). Nothing was installed." >&2
  exit 1
fi
echo "install.sh: engine=$ENGINE"
echo ""
app_step checking "done" "This computer is ready to install"
app_step installing started "Installing CFW Render"

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/config" "$PREFIX/scripts"
cp -a "$REPO_DIR"/bin/*.sh "$PREFIX/bin/"
cp -a "$REPO_DIR"/lib/*.md "$PREFIX/lib/"
# scripts/ (verify-skills-bundle.sh, gen-skills-manifest.sh) — the worker's
# cr_verify_skills_bundle shells out to verify-skills-bundle.sh at $PREFIX/scripts.
cp -a "$REPO_DIR"/scripts/*.sh "$PREFIX/scripts/" 2>/dev/null || true
chmod +x "$PREFIX"/bin/*.sh "$PREFIX"/scripts/*.sh 2>/dev/null || true

# Bundled skills (CFW-HST-BUNDLE, VPS-simplification epic Phase 2): the
# pinned recipe closure ships as part of this repo checkout, so installing
# the worker also installs its skills — no separate hourly pull needed once
# a box is fully on the bundle. See config/skills-version.json for the exact
# commit this checkout carries.
if [[ -d "$REPO_DIR/skills" ]]; then
  echo "install.sh: copying bundled skills/ ($(find "$REPO_DIR/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') recipes) to $PREFIX/skills"
  rm -rf "$PREFIX/skills"
  cp -a "$REPO_DIR/skills" "$PREFIX/skills"
else
  echo "install.sh: ERROR — $REPO_DIR/skills not found. cfw-render carries its skills bundle" >&2
  echo "  in-repo; a checkout without skills/ is broken. Re-clone/pull the repo (or run" >&2
  echo "  CFW_SKILLS_SRC=<source> scripts/sync-skills.sh) before installing." >&2
  exit 1
fi
[[ -f "$REPO_DIR/config/skills-version.json" ]] && cp -a "$REPO_DIR/config/skills-version.json" "$PREFIX/config/skills-version.json"
# Open-box guide: AGENTS.md (+ the CLAUDE.md pointer) ship with the install so
# any coding assistant on this computer can find and use the recipes in
# $PREFIX/skills for local renders outside CFW.
for guide in AGENTS.md CLAUDE.md; do
  if [[ -f "$REPO_DIR/$guide" ]]; then
    cp -a "$REPO_DIR/$guide" "$PREFIX/$guide"
  fi
done

if (( FROM_APP )) && [[ ! -f "$ENV_FILE" ]]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  ( umask 077; : > "$ENV_FILE" )
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "install.sh: NOTE — $ENV_FILE does not exist yet. Per AB-RNDR-AUTH §5.2, this" >&2
  echo "  is created at deploy time by a human (CFW_RENDER_WORKER_KEY, CFW_API_BASE)." >&2
  echo "  See config/cfw-render.env.example. Continuing install; --dry will FAIL until it exists." >&2
fi

# ── Deploy mode (doc §4) — upsert CFW_RENDER_MODE into the env file when it
# exists; otherwise print the exact line the human must add. Mode is
# operational (server|byoa), not a secret, and not the security boundary.
upsert_env() { # upsert_env <key> <value> <file>
  local key="$1" val="$2" file="$3"
  [[ -f "$file" ]] || return 1
  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    # portable in-place edit (GNU + BSD sed differ on -i) via temp file
    local tmp; tmp="$(mktemp)"
    sed -E "s#^[[:space:]]*${key}=.*#${key}=${val}#" "$file" > "$tmp" && cat "$tmp" > "$file" && rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}
if [[ -f "$ENV_FILE" ]]; then
  if upsert_env CFW_RENDER_MODE "$MODE" "$ENV_FILE"; then
    echo "install.sh: set CFW_RENDER_MODE=$MODE in $ENV_FILE"
  fi
  if upsert_env CFW_RENDER_ENGINE "$ENGINE" "$ENV_FILE"; then
    echo "install.sh: set CFW_RENDER_ENGINE=$ENGINE in $ENV_FILE"
  fi
else
  echo "install.sh: NOTE — add 'CFW_RENDER_MODE=$MODE' to $ENV_FILE when you create it (default 'server' applies if omitted)." >&2
  echo "install.sh: NOTE — also add 'CFW_RENDER_ENGINE=$ENGINE' to $ENV_FILE." >&2
fi
if [[ "$MODE" == "byoa" ]]; then
  echo "install.sh: mode=byoa — skills come from this repo's in-repo bundle (skills/), same as" >&2
  echo "  server mode. To update a BYOA box: 'git pull' this repo and restart the skills cron/" >&2
  echo "  service (it re-copies skills/ on run). See install/byoa-installer-notes.md." >&2
fi

# ── Stable worker identity (doc §6.3) — seed ONCE, never regenerate on re-run.
# A systemd oneshot fires a fresh PID every tick; a per-process workerId would
# defeat CFW-V2-068's per-workerId circuit breaker. Resolve the state dir from
# the env file if it declares one, else the run-user's default ~/.cfw-render.
# shellcheck source=/dev/null
STATE_DIR="$(env_value CFW_RENDER_STATE_DIR)"
STATE_DIR="${STATE_DIR:-$RUN_HOME/.cfw-render}"
WORKER_ID_FILE="$STATE_DIR/worker-id"
SCRATCH_DIR="$(env_value CFW_RENDER_SCRATCH)"
SCRATCH_DIR="${SCRATCH_DIR:-$RUN_HOME/.cfw-render/scratch}"

# ── Folder layout. byoa: one visible "CFW Render" folder for the app, kept
# renders and logs; the settings file stays private (600) in ~/.cfw-render.
# server (fleet): logs stay where they always were; nothing is kept locally.
if [[ "$MODE" == "byoa" ]]; then
  LOG_DIR="$(env_value CFW_RENDER_LOG_DIR)"
  LOG_DIR="${LOG_DIR:-$CFW_HOME/logs}"
  OUTPUTS_DIR="$(env_value CFW_RENDER_OUTPUTS)"
  OUTPUTS_DIR="${OUTPUTS_DIR:-$CFW_HOME/outputs}"
  mkdir -p "$LOG_DIR" "$OUTPUTS_DIR" "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  if [[ -f "$ENV_FILE" ]]; then
    chmod 600 "$ENV_FILE"
    echo "install.sh: settings file $ENV_FILE is private to you (mode 600)"
  fi
  MAC_LOG_DIR="$LOG_DIR"
else
  LOG_DIR="$STATE_DIR"
  OUTPUTS_DIR=""
  MAC_LOG_DIR="$HOME/Library/Logs"
fi

# sed_escape <s> — make <s> safe as a sed s### replacement (\, &, #).
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
# shellcheck source=/dev/null
source "$REPO_DIR/bin/cfw-render-lib.sh"
if [[ -s "$WORKER_ID_FILE" ]]; then
  echo "install.sh: worker-id already present at $WORKER_ID_FILE — keeping it (stable across reinstalls)"
else
  cr_seed_worker_id "$WORKER_ID_FILE"
  echo "install.sh: seeded stable worker-id at $WORKER_ID_FILE"
fi

case "$OS" in
  Darwin)
    PLIST_SRC="$SELF_DIR/com.cfw.render.plist"
    PLIST_DST="$HOME/Library/LaunchAgents/com.cfw.render.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$MAC_LOG_DIR"
    # NOTE: {{HOME}} here also seeds the plist's EnvironmentVariables PATH
    # (~/.local/bin, ~/bin) — must resolve to the *service user's* home, not
    # the installer's, for parity with the worker-id RUN_USER resolution
    # above. Unlike the Linux {{USER}} systemd path, a macOS LaunchAgent is
    # always per-logged-in-user, so plain $HOME is already correct here.
    sed -e "s#{{PREFIX}}#$(sed_escape "$PREFIX")#g" -e "s#{{ENV_FILE}}#$(sed_escape "$ENV_FILE")#g" \
        -e "s#{{HOME}}#$(sed_escape "$HOME")#g" -e "s#{{LOG_DIR}}#$(sed_escape "$MAC_LOG_DIR")#g" \
        -e "s#{{WORKER_PATH}}#$(sed_escape "$WORKER_PATH")#g" \
      "$PLIST_SRC" > "$PLIST_DST"
    echo "install.sh: wrote $PLIST_DST"
    # [M2-04, D89] The job is kept alive now (--loop). A computer already on
    # the old 15-minute schedule must be unloaded and reloaded, or launchd
    # keeps running the plist it has in memory: bootout (ignore "not loaded"),
    # then bootstrap. Idempotent on a fresh install and on every re-run.
    if (( FROM_APP )); then
      : # loaded in the connecting step, once the render key is in place
    elif command -v launchctl >/dev/null 2>&1 && [[ "${CFW_RENDER_INSTALL_NO_LAUNCHCTL:-0}" != "1" ]]; then
      launchctl bootout "gui/$(id -u)/com.cfw.render" >/dev/null 2>&1 || true
      if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1; then
        echo "install.sh: loaded com.cfw.render (kept-alive loop) via launchctl bootstrap"
      else
        echo "install.sh: could not load com.cfw.render — run: launchctl bootstrap \"gui/\$(id -u)\" \"$PLIST_DST\"" >&2
      fi
    else
      echo "install.sh: to load: launchctl bootout \"gui/\$(id -u)/com.cfw.render\"; launchctl bootstrap \"gui/\$(id -u)\" \"$PLIST_DST\""
    fi
    ;;
  Linux)
    UNIT_DST=/etc/systemd/system
    # Every writable path, absolute and double-quoted (a "CFW Render" path has
    # a space; systemd unquotes each word). A leading '-' = skip if missing.
    # Absolute paths, not %h: in a system unit %h is root's home even with
    # User= set, so it never pointed at the service user's folders.
    rw_paths=("$PREFIX" "-$STATE_DIR" "-$SCRATCH_DIR" "-$LOG_DIR")
    [[ -n "$OUTPUTS_DIR" ]] && rw_paths+=("-$OUTPUTS_DIR")
    RW_PATHS=""
    for p in "${rw_paths[@]}"; do RW_PATHS+="${RW_PATHS:+ }\"$p\""; done
    sed -e "s#{{PREFIX}}#$(sed_escape "$PREFIX")#g" -e "s#{{ENV_FILE}}#$(sed_escape "$ENV_FILE")#g" \
        -e "s#{{USER}}#$(sed_escape "$RUN_USER")#g" -e "s#{{RW_PATHS}}#$(sed_escape "$RW_PATHS")#g" \
        -e "s#{{WORKER_PATH}}#$(sed_escape "$WORKER_PATH")#g" \
      "$SELF_DIR/cfw-render.service" > "/tmp/cfw-render.service.$$"
    sed -e "s#{{PREFIX}}#$PREFIX#g" \
      "$SELF_DIR/cfw-render.timer" > "/tmp/cfw-render.timer.$$"
    echo "install.sh: rendered units at /tmp/cfw-render.{service,timer}.$$"
    echo "install.sh: to install (as root): "
    echo "  cp /tmp/cfw-render.service.$$ $UNIT_DST/cfw-render.service"
    echo "  cp /tmp/cfw-render.timer.$$ $UNIT_DST/cfw-render.timer"
    echo "  systemctl daemon-reload && systemctl enable --now cfw-render.timer"
    ;;
  *)
    echo "install.sh: unsupported OS '$OS'" >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "byoa" ]]; then
  # Earlier versions installed to other places. The schedule written above now
  # runs from $PREFIX, so an older copy is unused — say so, never delete it.
  for old in "$RUN_HOME/.cfw-render/app" "$RUN_HOME/cfw-render" "/opt/cfw-render"; do
    if [[ "$old" != "$PREFIX" && "$old" != "$REPO_DIR" && -f "$old/bin/cfw-render.sh" ]]; then
      echo "install.sh: NOTE — an earlier copy is still at $old. The schedule now runs" >&2
      echo "  from $PREFIX, so that copy is unused; the owner may delete it." >&2
    fi
  done
  echo ""
  echo "install.sh: where things are on this computer —"
  echo "  finished renders: $OUTPUTS_DIR/<brand>/"
  echo "  the app:          $PREFIX  (recipes in skills/, guide in AGENTS.md)"
  echo "  logs:             $LOG_DIR"
  echo "  private settings: $ENV_FILE  (and $STATE_DIR)"
fi

# [M2-04, D78] How many requests this computer runs at once (bin/cfw-render-lib.sh table).
echo ""
echo "install.sh: $(cr_capacity_setup_note)"

if (( FROM_APP )); then
  fa_connect_and_probe
  exit 0
fi

echo ""
echo "install.sh: running validation (--dry) —"
CFW_RENDER_ENV="$ENV_FILE" "$PREFIX/bin/cfw-render.sh" --dry || {
  echo "install.sh: --dry reported FAIL — fix before enabling the timer." >&2
  exit 1
}
