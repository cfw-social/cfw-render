#!/usr/bin/env bash
# install/install.sh — installs the cfw-render worker on the owner's own
# computer (macOS LaunchAgent). CFW-run server rendering was removed (D118);
# this is the only install path.
#
# Usage:
#   install.sh [--prefix <dir>] [--env-file <path>] [--mode byoa] [--yes-really]
#   install.sh --uninstall [--delete-outputs] [--yes|--non-interactive] [--from-app]
#
# --prefix     where bin/ + lib/ + skills/ + scripts/ get copied
#              (default "$HOME/CFW Render/app")
# --env-file   env file the installed schedule will read
#              (default ~/.cfw-render/cfw-render.env, or the legacy
#              ~/ecosystem/vault/cfw-render.env when only that exists)
# --mode       accepted for compatibility; byoa is the only mode
#
# Folder layout (see AGENTS.md "Where things are"):
#   "$HOME/CFW Render/"  app/ (prefix), outputs/<brand>/ (kept renders), logs/
#   ~/.cfw-render/       worker-id, cfw-render.env (chmod 600), scratch/
# --user       accepted for compatibility (the LaunchAgent runs as the logged-in user)
# --yes-really required to run as root (refuses otherwise — guard rail)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

PREFIX=""
ENV_FILE=""
RUN_USER="${SUDO_USER:-$(id -un)}"
MODE="byoa"
YES_REALLY=0
NON_INTERACTIVE=0
FROM_APP=0
UPDATE=0
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
    --update) UPDATE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --delete-outputs) DELETE_OUTPUTS=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) echo "install.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# [WI27] Install and uninstall work only on the production install
# (~/.cfw-render, "~/CFW Render", com.cfw.render). A dev-profile worker is set
# up by cfw-social's `pnpm seed:dev` instead, so refuse rather than touch it.
if [[ -n "${CFW_RENDER_PROFILE:-}" && "${CFW_RENDER_PROFILE}" != prod ]]; then
  echo "install.sh: CFW_RENDER_PROFILE=${CFW_RENDER_PROFILE} — install and uninstall only manage the production install. Set up a dev worker with 'pnpm seed:dev' in cfw-social." >&2
  exit 2
fi

# ── [M3-06a] --uninstall [--delete-outputs] [--yes]: remove CFW Render from
# this Mac (logic in install/uninstall.sh). Always exits 0 once confirmed.
if (( UNINSTALL )); then
  : "$DELETE_OUTPUTS" "$ASSUME_YES" # read by un_main
  # shellcheck source=install/uninstall.sh
  source "$SELF_DIR/uninstall.sh"
  un_main
  exit $?
fi

case "$MODE" in
  byoa) : ;;
  server) echo "install.sh: --mode server was removed (D118) — CFW no longer runs render servers. Install on your own computer with --mode byoa." >&2; exit 2 ;;
  *) echo "install.sh: --mode must be byoa (got '$MODE')" >&2; exit 2 ;;
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

# drop_env <key> <file> — remove every "<key>=" line from the settings file, with
# leading blanks and an optional `export ` allowed: the worker SOURCES this file
# (cr_load_config), so a hand-written `export KEY=value` is a pin too. Other keys
# that merely start with <key> (CFW_RENDER_ENGINE_CMD, ...) and comments are kept.
# Return codes: 0 a line was removed; 1 nothing to do (no file, or no such line);
# 2 it failed (file not readable or not writable, no temp file, a write error), with
# the reason in DROP_ENV_ERR. A failure leaves the file as it was except for a write
# that breaks half way. Same portable write-back as upsert_env: sed to a temp file,
# then `cat tmp > file`, so the file keeps its mode (0600) and owner; the temp file
# never outlives the call.
DROP_ENV_ERR=""
drop_env() { # drop_env <key> <file>
  local key="$1" file="$2" tmp g=0 pat
  DROP_ENV_ERR=""
  pat="^[[:space:]]*(export[[:space:]]+)?${key}="
  [[ -f "$file" ]] || return 1
  grep -qE "$pat" "$file" 2>/dev/null || g=$?
  case "$g" in
    0) ;;
    1) return 1 ;;
    *) DROP_ENV_ERR="the file cannot be read"; return 2 ;;
  esac
  [[ -w "$file" ]] || { DROP_ENV_ERR="the file is read-only"; return 2; }
  tmp="$(mktemp 2>/dev/null)" || { DROP_ENV_ERR="no temp file could be made"; return 2; }
  if ! sed -E "/${pat}/d" "$file" > "$tmp" 2>/dev/null; then
    DROP_ENV_ERR="the file could not be rewritten"; rm -f "$tmp"; return 2
  fi
  if ! cat "$tmp" > "$file" 2>/dev/null; then
    DROP_ENV_ERR="the file could not be written"; rm -f "$tmp"; return 2
  fi
  rm -f "$tmp"
  return 0
}

# unpin_engine — clear a CFW_RENDER_ENGINE line from the settings file. An older
# installer wrote one: the worker takes it to mean "use only this engine", which
# hides the owner's AI Providers order (engines.json) and any engine that is
# signed in. Used by the full install, --update and the --from-app adopt path, so
# a computer that already has the pin loses it however the app runs the installer.
# The worker reads its settings once, when it starts (bin/cfw-render.sh calls
# cr_load_config before its loop and never again), and this does not restart it: a
# running worker keeps the pin until its next start. Prints one line when it
# removes one (naming the value, if it is a plain engine name — never any other
# line of the file) and one line to stderr when it cannot; it never fails the
# install or update. In --from-app mode both lines go to stderr like every other
# human-readable line (fd 1 is fd 2 there); the app's JSON channel is fd 3.
# Always returns 0, and every command in it is guarded, so `set -e` cannot abort.
unpin_engine() {
  local rc=0 val=""
  if [[ -f "$ENV_FILE" ]]; then
    val="$(grep -E "^[[:space:]]*(export[[:space:]]+)?CFW_RENDER_ENGINE=" "$ENV_FILE" 2>/dev/null \
      | tail -n 1 | cut -d= -f2- | tr -d "\"'" | awk '{ print $1 }')" || val=""
  fi
  case "$val" in *[!A-Za-z0-9._-]*) val="" ;; esac
  (( ${#val} <= 32 )) || val=""
  drop_env CFW_RENDER_ENGINE "$ENV_FILE" || rc=$?
  case "$rc" in
    0) echo "install.sh: removed CFW_RENDER_ENGINE${val:+=$val} from $ENV_FILE; the app's AI Providers order picks the engine now" ;;
    1) : ;;
    *) echo "install.sh: could not remove CFW_RENDER_ENGINE from $ENV_FILE (${DROP_ENV_ERR:-unknown error}); remove that line by hand so the app's provider order is used" >&2 ;;
  esac
  return 0
}

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
  ENV_FILE="$RUN_HOME/.cfw-render/cfw-render.env"
  if [[ ! -e "$ENV_FILE" && -r "$RUN_HOME/ecosystem/vault/cfw-render.env" ]]; then
    ENV_FILE="$RUN_HOME/ecosystem/vault/cfw-render.env"
    echo "install.sh: NOTE — using the existing settings file at its older location $ENV_FILE." >&2
    echo "  New installs keep it at ~/.cfw-render/cfw-render.env; move it there whenever convenient." >&2
  fi
fi
CFW_HOME="${CFW_RENDER_HOME:-$(env_value CFW_RENDER_HOME)}"
CFW_HOME="${CFW_HOME:-$RUN_HOME/CFW Render}"
if [[ -z "$PREFIX" ]]; then
  PREFIX="$CFW_HOME/app"
fi

# ── [B8/B10] ensure_pinned_browser — the pinned Playwright browser, installed ONLY when
# its cache folders are missing. The preflight requires the exact Chromium revisions
# config/playwright-pin.json names, and a bare `npx playwright install chromium` would
# fetch whatever is newest, so the carousel render would die at chromium.launch()
# (R-7LU5). This ONE function serves the fresh install and `--from-app --update`.
# Needs cfw-render-lib.sh sourced. Pin cached: rc 0, nothing runs. Installed: rc 0.
# No npx: rc 2, nothing installed (the caller decides). A failed install stops here
# with npx's own output (app: step checking, exit 4). In app mode fd 1 is already
# fd 2, so npx output never reaches the JSON step lines on fd 3.
ensure_pinned_browser() {
  local pw_rc=0
  if cr_preflight_chromium >/dev/null; then
    return 0
  fi
  app_step checking started "Installing the browser CFW Render needs (one time)"
  cr_install_pinned_chromium || pw_rc=$?
  if (( pw_rc == 1 )); then
    (( FROM_APP )) && app_fail checking 4 "Could not install the browser CFW Render needs" "Check your internet connection and try again"
    echo "install.sh: ABORTING — the pinned Playwright browser could not be installed (see above)." >&2
    echo "  Nothing was installed. Fix the error above and re-run install.sh." >&2
    exit 1
  fi
  return "$pw_rc"
}

# ── [M3-05a] --from-app --update: after an app update, refresh the app files
# in $PREFIX from the bundle and reload the LaunchAgent. No key, no stdin.
if (( UPDATE )); then
  (( FROM_APP )) || { echo "install.sh: --update requires --from-app" >&2; exit 2; }
  # [B8/B10] An app update can ship a new config/playwright-pin.json, and the worker's
  # per-tick preflight then refuses every claim until that browser is cached. Install it
  # here, BEFORE any file is replaced: if it cannot be installed the old worker (and the
  # browser it already has) keeps running and the app retries on its next launch. With
  # the pin already cached nothing runs. The pin read is the bundle's, the file fa_update
  # copies to $PREFIX/config below.
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  # The app starts this installer with the GUI's minimal PATH (no node, no npx). Look
  # where the worker itself looks: the private toolchain first, then Homebrew.
  PATH="$(cr_resolve_worker_path):$PATH" ensure_pinned_browser || {
    echo "install.sh: ABORTING the update — the pinned Playwright browser is not cached and npx is not available to install it." >&2
    echo "  Nothing was changed. Run: $(cr_preflight_hint npx)   then: $(cr_preflight_hint chromium)" >&2
    app_fail checking 4 "CFW Render needs Node.js to install its browser" "Install Node.js, then reopen CFW Render"
  }
  # An older installer pinned CFW_RENDER_ENGINE in the settings file. Clear it before
  # fa_update reloads the worker, so the reloaded worker follows the AI Providers order.
  unpin_engine || true
  fa_update
  exit 0
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
    # Keychain-only installs (WI17.2.2) have no CFW_RENDER_WORKER_KEY in the
    # env file; fa_keychain_worker_key covers that path.
    ADOPT_KEY="$(env_value CFW_RENDER_WORKER_KEY)"
    [[ -z "$ADOPT_KEY" ]] && ADOPT_KEY="$(fa_keychain_worker_key)"
    if [[ -n "$ADOPT_KEY" && -f "$APP_PLIST" ]]; then
      app_step checking started "Checking this computer"
      if fa_tools_list_ok "$(fa_api_base)" "$ADOPT_KEY"; then
        ADOPT_KEY=""
        # The app's hidden set-up window runs adopt at every launch on a computer
        # with a worker key and a LaunchAgent (SetupScreen -> setup_adopt), so this
        # clears an old engine pin even on a build that gets no --update. The
        # worker is not restarted from here; it re-reads its settings at its next
        # start.
        unpin_engine || true
        app_step ready "done" "Already set up"
        exit 0
      fi
      ADOPT_KEY=""
      app_fail checking 5 "The saved connection did not work" "Paste a fresh key from CFW Settings"
    fi
    ADOPT_KEY=""
    app_fail connecting 5 "No key was given" "Paste the key from CFW Settings"
  fi
  # CFW keys are base64url: `-` is a normal key character.
  if ! [[ "$BRAND_KEY" =~ ^cfw_[A-Za-z0-9_-]+$ ]]; then
    BRAND_KEY=""
    app_fail connecting 5 "That key does not look right" "Copy the key again from CFW Settings"
  fi
  app_step checking started "Checking this computer"
fi

if [[ "$(id -u)" -eq 0 && "$YES_REALLY" -ne 1 ]]; then
  echo "install.sh: refusing to run as root without --yes-really (guard rail)" >&2
  exit 1
fi

OS="$(uname -s)"
echo "install.sh: OS=$OS prefix=$PREFIX env-file=$ENV_FILE user=$RUN_USER mode=$MODE"

# ── [CFW-199] Toolchain preflight, BEFORE anything is copied or a unit written.
# CFW-188 found a render computer with no ImageMagick at all — installed and one
# schedule load away from claiming production orders it could not finish.
# Fail here, loudly, with the install commands, rather than leaving a computer that
# looks installed and burns real work.
# shellcheck source=/dev/null
source "$REPO_DIR/bin/cfw-render-lib.sh"

# ── [B8/B10] The pinned Playwright browser, BEFORE the preflight (which now requires
# it; a fresh computer has none cached). No npx (rc 2) falls through on purpose: the
# preflight below fails and names node and the exact command.
ensure_pinned_browser || true

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
# PATH in a stripped env — the narrow environment launchd hands a
# scheduled unit, not this installer's rich shell. A `claude` that resolves
# via cr_preflight's `command -v` (because a shell function/alias/nvm-asdf
# init hook shadows or wraps the real binary) can still fail the moment it
# runs headless — this is the gap CFW-279 left open.
WORKER_PATH="$(cr_resolve_worker_path)"
echo "install.sh: resolved worker PATH: $WORKER_PATH"
# M1-10a: either engine is acceptable — probe codex then claude (honouring a
# preset CFW_RENDER_ENGINE from this shell when it passes). This is a check
# only: it proves the box can run a step, and the install aborts when neither
# engine runs. The result is NOT written to the settings file. A
# CFW_RENDER_ENGINE line there means "use only this engine" to the worker
# (cr_engine_order), so recording the probe winner would override the owner's
# provider order (engines.json, set in the app's AI Providers screen).
# CFW_RENDER_TEST_NO_ENGINE — test-only seam: a dev
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
cp -a "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/*.py "$PREFIX/bin/"
cp -a "$REPO_DIR"/lib/*.md "$REPO_DIR"/lib/*.py "$PREFIX/lib/"
cp -a "$REPO_DIR/config/agent-guides.json" "$PREFIX/config/"
# The Playwright pin: the installed worker's preflight and recipe steps read it.
cp -a "$REPO_DIR/config/playwright-pin.json" "$PREFIX/config/"
# scripts/ (verify-skills-bundle.sh, gen-skills-manifest.sh) — the worker's
# cr_verify_skills_bundle shells out to verify-skills-bundle.sh at $PREFIX/scripts.
cp -a "$REPO_DIR"/scripts/*.sh "$PREFIX/scripts/" 2>/dev/null || true
chmod +x "$PREFIX"/bin/*.sh "$PREFIX"/scripts/*.sh 2>/dev/null || true

# Bundled skills: the pinned recipe closure ships as part of this repo
# checkout, so installing the worker also installs its skills. See config/skills-version.json for the exact
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

# Claims must report the bundled worker version, including on a fresh install.
if [[ -f "$REPO_DIR/VERSION" ]]; then
  cp -a "$REPO_DIR/VERSION" "$PREFIX/VERSION"
else
  echo "install.sh: WARNING — missing VERSION; CFW may refuse work until updated" >&2
fi

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
# operational (byoa only), not a secret, and not the security boundary.
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
  unpin_engine || true
else
  echo "install.sh: NOTE — add 'CFW_RENDER_MODE=$MODE' to $ENV_FILE when you create it." >&2
fi
echo "install.sh: skills come from this repo's in-repo bundle (skills/). To update:" >&2
echo "  'git pull' this repo and re-run install.sh (it re-copies skills/). See install/byoa-installer-notes.md." >&2

# ── Stable worker identity (doc §6.3) — seed ONCE, never regenerate on re-run.
# A scheduled tick gets a fresh PID every time; a per-process workerId would
# defeat CFW-V2-068's per-workerId circuit breaker. Resolve the state dir from
# the env file if it declares one, else the run-user's default ~/.cfw-render.
# shellcheck source=/dev/null
STATE_DIR="$(env_value CFW_RENDER_STATE_DIR)"
STATE_DIR="${STATE_DIR:-$RUN_HOME/.cfw-render}"
WORKER_ID_FILE="$STATE_DIR/worker-id"
SCRATCH_DIR="$(env_value CFW_RENDER_SCRATCH)"
SCRATCH_DIR="${SCRATCH_DIR:-$RUN_HOME/.cfw-render/scratch}"

# ── Folder layout: one visible "CFW Render" folder for the app, kept renders
# and logs; the settings file stays private (600) in ~/.cfw-render.
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
    # the installer's. A macOS LaunchAgent is always per-logged-in-user, so
    # plain $HOME is already correct here.
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
  *)
    echo "install.sh: unsupported OS '$OS' — the worker installs on macOS only" >&2
    exit 1
    ;;
esac

{
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
}

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
