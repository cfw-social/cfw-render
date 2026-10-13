# install/uninstall.sh — [M3-06a] `install.sh --uninstall [--delete-outputs]
# [--yes|--non-interactive] [--from-app]`. Sourced by install.sh (functions
# only; install.sh calls un_main). Never prints or passes a key on argv.
# With --from-app, stdout carries only JSON lines
# {"step":"uninstall","state":...,"message":...}; human text goes to stderr.
# shellcheck shell=bash

un_say() {
  if (( FROM_APP )); then
    python3 -c 'import json,sys;print(json.dumps({"step":"uninstall","state":sys.argv[1],"message":sys.argv[2]}),flush=True)' "$1" "$2" >&3
  else
    printf '%s\n' "$2"
  fi
}

# un_env_value <KEY> <file> — last KEY=value in the file ("" if absent).
un_env_value() {
  [[ -f "$2" ]] || return 0
  grep -E "^[[:space:]]*$1=" "$2" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true
}

# un_revoke <env-file> — revoke_this_computer with the render key. The key
# travels in a header read from stdin (-H @-), never argv. 0 = revoked.
un_revoke() {
  local key base resp
  key="$(un_env_value CFW_RENDER_WORKER_KEY "$1")"
  [[ -n "$key" ]] || return 1
  base="${CFW_RENDER_API_BASE:-$(un_env_value CFW_API_BASE "$1")}"
  base="${base:-https://app.cfw.social}"
  resp="$(printf 'cfw-render-key: %s\n' "$key" | curl -sS --max-time 15 -X POST "${base%/}/api/v1/mcp" \
    -H @- -H "content-type: application/json" -H "accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"revoke_this_computer","arguments":{}}}' 2>/dev/null)" || return 1
  key=""
  python3 -c '
import json, sys
try:
    r = json.loads(sys.stdin.read())
    t = r["result"]["content"][0]["text"]
    sys.exit(0 if json.loads(t).get("ok") else 1)
except Exception:
    sys.exit(1)' <<< "$resp"
}

un_main() {
  local home="${RUN_HOME:-$HOME}"
  local state="$home/.cfw-render"
  local cfw_home="${CFW_RENDER_HOME:-$home/CFW Render}"
  local plist="$home/Library/LaunchAgents/com.cfw.render.plist"
  local env_file="${ENV_FILE:-$state/cfw-render.env}"
  [[ -f "$env_file" ]] || env_file="$state/cfw-render.env"
  local security="${CFW_RENDER_SECURITY_CMD:-/usr/bin/security}"

  (( FROM_APP )) && exec 3>&1 1>&2

  if (( ! ASSUME_YES && ! NON_INTERACTIVE )); then
    echo "This removes CFW Render from this Mac: the background worker, its settings,"
    echo "its saved sign-ins, and its logs."
    if (( DELETE_OUTPUTS )); then
      echo "Your rendered files in $cfw_home/outputs will ALSO be deleted."
    else
      echo "Your rendered files in $cfw_home/outputs are kept."
    fi
    local ans=""
    read -r -p "Remove CFW Render? [y/N] " ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) echo "Nothing was removed."; return 0 ;; esac
  fi

  un_say started "Stopping CFW Render"
  if [[ "${CFW_RENDER_SKIP_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  fi

  local revoked=0 summary=()
  un_say progress "Disconnecting this computer from CFW"
  if un_revoke "$env_file"; then
    revoked=1; summary+=("Disconnected this computer from CFW")
  else
    un_say progress "This computer will show as offline in CFW until you remove it there."
    summary+=("This computer will show as offline in CFW until you remove it there.")
  fi

  un_say progress "Removing files"
  rm -f "$plist"
  rm -rf "$state" "$cfw_home/app" "$cfw_home/logs"
  if (( DELETE_OUTPUTS )); then
    rm -rf "$cfw_home/outputs"
    summary+=("Deleted your rendered files")
  elif [[ -d "$cfw_home/outputs" ]]; then
    summary+=("Kept your rendered files in $cfw_home/outputs")
  fi
  rmdir "$cfw_home" 2>/dev/null || true

  un_say progress "Removing saved sign-ins"
  local n=0
  while (( n < 100 )) && "$security" delete-generic-password -s com.cfw.render >/dev/null 2>&1; do
    n=$((n + 1))
  done
  summary+=("Removed $n saved sign-in(s)")
  summary+=("Removed the background worker, settings and logs")

  if (( ! FROM_APP )); then
    echo ""
    echo "CFW Render was removed:"
    local l; for l in "${summary[@]}"; do echo "  - $l"; done
  fi
  un_say "done" "CFW Render was removed$( (( revoked )) || printf ' (offline — remove this computer in CFW)')"
  return 0
}
