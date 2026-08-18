#!/usr/bin/env bash
# install/install.sh — installs cfw-render as a service pool on the current
# host. AUTHORING ONLY in this task (AB-RNDR-WORKER): this script is never
# executed against hst by the unattended dev lane. It is run later by a
# human/attended session per docs/deploy.md.
#
# Usage:
#   install.sh --user <u> --prefix <dir> [--env-file <path>] [--mode server|byoa] [--yes-really]
#
# --prefix     where bin/ + lib/ + skills/ + scripts/ get copied (default /opt/cfw-render)
# --env-file   env file the installed unit will read (default /etc/cfw-render.env)
# --mode       deploy mode written to the env file (server|byoa, default server) — doc §4
# --user       user the systemd unit runs as (Linux only; ignored on macOS)
# --yes-really required to run as root (refuses otherwise — guard rail)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

PREFIX="/opt/cfw-render"
ENV_FILE="/etc/cfw-render.env"
RUN_USER="${SUDO_USER:-$(id -un)}"
MODE="server"
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
  server|byoa) : ;;
  *) echo "install.sh: --mode must be server|byoa (got '$MODE')" >&2; exit 2 ;;
esac

if [[ "$(id -u)" -eq 0 && "$YES_REALLY" -ne 1 ]]; then
  echo "install.sh: refusing to run as root without --yes-really (guard rail)" >&2
  exit 1
fi

OS="$(uname -s)"
echo "install.sh: OS=$OS prefix=$PREFIX env-file=$ENV_FILE user=$RUN_USER mode=$MODE"

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
  echo "install.sh: WARNING — $REPO_DIR/skills not found (this checkout predates the CFW-HST-BUNDLE" >&2
  echo "  merge, or the subtree wasn't pulled). The worker will fall back to the legacy shared" >&2
  echo "  path /data/shared/cfw-skills/cfw unless CFW_RENDER_SKILLS_DIR overrides it." >&2
fi
[[ -f "$REPO_DIR/config/skills-version.json" ]] && cp -a "$REPO_DIR/config/skills-version.json" "$PREFIX/config/skills-version.json"

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
else
  echo "install.sh: NOTE — add 'CFW_RENDER_MODE=$MODE' to $ENV_FILE when you create it (default 'server' applies if omitted)." >&2
fi
if [[ "$MODE" == "byoa" ]]; then
  echo "install.sh: mode=byoa — BYOA skills 'fetch' path (CFW_RENDER_SKILLS_SOURCE=fetch) is NOT built yet" >&2
  echo "  (waits on CFW-V2-067 byoa-fetch-plan). Leave CFW_RENDER_SKILLS_SOURCE=bundle for now; the" >&2
  echo "  bundled skills/ is used (wasted disk vs a curated fetch, not a security issue). See" >&2
  echo "  install/byoa-installer-notes.md." >&2
fi

# ── Stable worker identity (doc §6.3) — seed ONCE, never regenerate on re-run.
# A systemd oneshot fires a fresh PID every tick; a per-process workerId would
# defeat CFW-V2-068's per-workerId circuit breaker. Resolve the state dir from
# the env file if it declares one, else the run-user's default ~/.cfw-render.
# shellcheck source=/dev/null
STATE_DIR=""
if [[ -f "$ENV_FILE" ]]; then
  STATE_DIR="$(grep -E '^[[:space:]]*CFW_RENDER_STATE_DIR=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi
if [[ -z "$STATE_DIR" ]]; then
  RUN_HOME="$(eval echo "~$RUN_USER" 2>/dev/null || echo "$HOME")"
  STATE_DIR="$RUN_HOME/.cfw-render"
fi
WORKER_ID_FILE="$STATE_DIR/worker-id"
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
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    sed -e "s#{{PREFIX}}#$PREFIX#g" -e "s#{{ENV_FILE}}#$ENV_FILE#g" -e "s#{{HOME}}#$HOME#g" \
      "$PLIST_SRC" > "$PLIST_DST"
    echo "install.sh: wrote $PLIST_DST"
    echo "install.sh: to load: launchctl bootstrap gui/\$(id -u) $PLIST_DST"
    ;;
  Linux)
    UNIT_DST=/etc/systemd/system
    sed -e "s#{{PREFIX}}#$PREFIX#g" -e "s#{{ENV_FILE}}#$ENV_FILE#g" -e "s#{{USER}}#$RUN_USER#g" \
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

echo ""
echo "install.sh: running validation (--dry) —"
CFW_RENDER_ENV="$ENV_FILE" "$PREFIX/bin/cfw-render.sh" --dry || {
  echo "install.sh: --dry reported FAIL — fix before enabling the timer." >&2
  exit 1
}
