#!/usr/bin/env bash
# install/install.sh — installs the cfw-render worker on the owner's own
# computer (macOS LaunchAgent). CFW-run server rendering was removed (D118);
# this is the only install path.
#
# Usage:
#   install.sh [--prefix <dir>] [--env-file <path>] [--mode byoa] [--yes-really]
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

while (( $# )); do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --yes-really) YES_REALLY=1; shift ;;
    *) echo "install.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  byoa) : ;;
  server) echo "install.sh: --mode server was removed (D118) — CFW no longer runs render servers. Install on your own computer with --mode byoa." >&2; exit 2 ;;
  *) echo "install.sh: --mode must be byoa (got '$MODE')" >&2; exit 2 ;;
esac

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
if ! cr_preflight; then
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
# preset CFW_RENDER_ENGINE when it passes) and record the one that runs.
if ! ENGINE="$(cr_install_select_engine "$WORKER_PATH")"; then
  echo "install.sh: ABORTING — no engine runs under the worker PATH (see above). Nothing was installed." >&2
  exit 1
fi
echo "install.sh: engine=$ENGINE"
echo ""

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/config" "$PREFIX/scripts"
cp -a "$REPO_DIR"/bin/*.sh "$PREFIX/bin/"
cp -a "$REPO_DIR"/lib/*.md "$PREFIX/lib/"
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
  if upsert_env CFW_RENDER_ENGINE "$ENGINE" "$ENV_FILE"; then
    echo "install.sh: set CFW_RENDER_ENGINE=$ENGINE in $ENV_FILE"
  fi
else
  echo "install.sh: NOTE — add 'CFW_RENDER_MODE=$MODE' to $ENV_FILE when you create it." >&2
  echo "install.sh: NOTE — also add 'CFW_RENDER_ENGINE=$ENGINE' to $ENV_FILE." >&2
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
    if command -v launchctl >/dev/null 2>&1 && [[ "${CFW_RENDER_INSTALL_NO_LAUNCHCTL:-0}" != "1" ]]; then
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

echo ""
echo "install.sh: running validation (--dry) —"
CFW_RENDER_ENV="$ENV_FILE" "$PREFIX/bin/cfw-render.sh" --dry || {
  echo "install.sh: --dry reported FAIL — fix before enabling the timer." >&2
  exit 1
}
