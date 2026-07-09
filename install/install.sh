#!/usr/bin/env bash
# install/install.sh — installs cfw-render as a service pool on the current
# host. AUTHORING ONLY in this task (AB-RNDR-WORKER): this script is never
# executed against hst by the unattended dev lane. It is run later by a
# human/attended session per docs/deploy.md.
#
# Usage:
#   install.sh --user <u> --prefix <dir> [--env-file <path>] [--yes-really]
#
# --prefix     where bin/ + lib/ get copied (default /opt/cfw-render)
# --env-file   env file the installed unit will read (default /etc/cfw-render.env)
# --user       user the systemd unit runs as (Linux only; ignored on macOS)
# --yes-really required to run as root (refuses otherwise — guard rail)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

PREFIX="/opt/cfw-render"
ENV_FILE="/etc/cfw-render.env"
RUN_USER="${SUDO_USER:-$(id -un)}"
YES_REALLY=0

while (( $# )); do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --yes-really) YES_REALLY=1; shift ;;
    *) echo "install.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" -eq 0 && "$YES_REALLY" -ne 1 ]]; then
  echo "install.sh: refusing to run as root without --yes-really (guard rail)" >&2
  exit 1
fi

OS="$(uname -s)"
echo "install.sh: OS=$OS prefix=$PREFIX env-file=$ENV_FILE user=$RUN_USER"

mkdir -p "$PREFIX/bin" "$PREFIX/lib"
cp -a "$REPO_DIR"/bin/*.sh "$PREFIX/bin/"
cp -a "$REPO_DIR"/lib/*.md "$PREFIX/lib/"
chmod +x "$PREFIX"/bin/*.sh

if [[ ! -f "$ENV_FILE" ]]; then
  echo "install.sh: NOTE — $ENV_FILE does not exist yet. Per AB-RNDR-AUTH §5.2, this" >&2
  echo "  is created at deploy time by a human (CFW_RENDER_WORKER_KEY, CFW_API_BASE)." >&2
  echo "  See config/cfw-render.env.example. Continuing install; --dry will FAIL until it exists." >&2
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
