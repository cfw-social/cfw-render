# install/from-app.sh — [M3-04a] the connecting / test_render / ready steps of
# `install.sh --mode byoa --non-interactive --from-app`. Sourced by install.sh
# (functions only; install.sh calls fa_connect_and_probe). Never prints a key.
# shellcheck shell=bash

# fa_api_base — CFW_RENDER_API_BASE (tests) > env file CFW_API_BASE > prod.
fa_api_base() {
  local b="${CFW_RENDER_API_BASE:-}"
  [[ -n "$b" ]] || b="$(env_value CFW_API_BASE)"
  printf '%s' "${b:-https://app.cfw.social}"
}

# fa_env_set <key> <file> — upsert key=<stdin line> into file (0600). The value
# travels on stdin so it never lands on any argv.
fa_env_set() {
  python3 -c '
import os, re, sys
key, path = sys.argv[1], sys.argv[2]
val = sys.stdin.readline().rstrip("\n")
lines = open(path).read().splitlines() if os.path.exists(path) else []
out, done = [], False
for ln in lines:
    if re.match(r"\s*" + re.escape(key) + "=", ln):
        if not done:
            out.append(f"{key}={val}"); done = True
        continue
    out.append(ln)
if not done:
    out.append(f"{key}={val}")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(path, 0o600)' "$1" "$2"
}

# fa_tools_list_ok <base> <render-key> — claim-free key check (same tools/list
# the --dry path runs). Header goes over stdin (-H @-), not argv.
fa_tools_list_ok() {
  local resp
  resp="$(printf 'cfw-render-key: %s\n' "$2" | curl -sS --max-time 15 -X POST "${1%/}/api/v1/mcp" \
    -H @- -H "content-type: application/json" -H "accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)" || return 1
  python3 -c '
import json, sys
try:
    names = {t.get("name") for t in json.loads(sys.stdin.read()).get("result", {}).get("tools", [])}
except Exception:
    sys.exit(1)
sys.exit(0 if {"claim_render_order", "complete_render_order"} <= names else 1)' <<< "$resp"
}

# fa_json_get <field> — read a field of the JSON object on stdin ("" if absent).
fa_json_get() {
  python3 -c '
import json, sys
try:
    v = json.loads(sys.stdin.read()).get(sys.argv[1], "")
except Exception:
    v = ""
print("true" if v is True else "false" if v is False else v)' "$1"
}

# fa_setup_report <step> [extra-json] — report_byoa_setup_step with origin app.
fa_setup_report() {
  local args
  args="$(python3 -c '
import json, sys
a = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
a.update({"workerId": sys.argv[1], "step": sys.argv[2], "origin": "app"})
print(json.dumps(a))' "$FA_WORKER_ID" "$@")"
  cr_mcp_call_soft report_byoa_setup_step "$args"
}

fa_connect_and_probe() {
  app_step installing "done" "CFW Render is installed"
  app_step connecting started "Connecting to CFW"
  local base code resp render_key
  base="$(fa_api_base)"
  FA_WORKER_ID="$(tr -d '[:space:]' < "$WORKER_ID_FILE")"
  local device
  device="$(cr_computer_name 2>/dev/null || hostname)"; device="${device:0:100}"; device="${device:-This Mac}"
  # Exchange: the brand key goes in a header read from stdin (-H @-).
  resp="$(printf 'x-api-key: %s\n' "$BRAND_KEY" | curl -sS --max-time 30 -w '\n%{http_code}' -X POST \
    "${base%/}/api/v1/render-worker-keys/exchange" -H @- -H "content-type: application/json" \
    --data "$(python3 -c 'import json,sys;print(json.dumps({"deviceName": sys.argv[1]}))' "$device")" 2>/dev/null)" || resp=""
  BRAND_KEY=""; unset BRAND_KEY
  code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  case "$code" in
    201|200) ;;
    401|403) app_fail connecting 5 "CFW did not accept that key" "Copy a fresh key from CFW Settings" ;;
    400) app_fail connecting 5 "CFW could not use that key" "Copy a fresh key from CFW Settings" ;;
    *) app_fail connecting 6 "Could not reach CFW" "Check your internet connection and try again" ;;
  esac
  render_key="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read())["key"]["plain"])
except Exception:
    pass' <<< "$resp")"
  resp=""
  [[ "$render_key" =~ ^cfw_render_[A-Za-z0-9_]+$ ]] || app_fail connecting 6 "CFW sent an unexpected reply" "Try again in a minute"
  printf '%s\n' "$render_key" | fa_env_set CFW_RENDER_WORKER_KEY "$ENV_FILE"
  printf '%s\n' "$base" | fa_env_set CFW_API_BASE "$ENV_FILE"
  export CFW_API_BASE="$base" CFW_RENDER_WORKER_KEY="$render_key"
  render_key=""

  local step out
  # provider_keys_needed is not reported here: telling which recipe needs a
  # missing provider key is not cheap from the installer (follow-up).
  for step in deps credential recipe_fetch; do
    out="$(fa_setup_report "$step")" || app_fail connecting 6 "CFW did not accept the set-up report" "Try again in a minute"
    [[ "$(fa_json_get ok <<< "$out")" == "true" ]] || app_fail connecting 6 "CFW said: $(fa_json_get error <<< "$out")" "Try again in a minute"
  done

  if [[ "${CFW_RENDER_SKIP_LAUNCHCTL:-0}" != "1" && "${CFW_RENDER_INSTALL_NO_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.cfw.render" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 \
      || app_fail connecting 6 "Could not start CFW Render in the background" "Restart your Mac and try again"
  fi
  app_step connecting "done" "Connected to CFW"

  app_step test_render started "Making a test render"
  out="$(cr_mcp_call_soft create_probe_render_order "$(python3 -c 'import json,sys;print(json.dumps({"workerId": sys.argv[1]}))' "$FA_WORKER_ID")")" \
    || app_fail test_render 6 "Could not start the test render" "Try again in a minute"
  [[ "$(fa_json_get ok <<< "$out")" == "true" ]] || app_fail test_render 7 "Could not start the test render: $(fa_json_get error <<< "$out")" "Try again in a minute"
  local timeout="${CFW_RENDER_PROBE_TIMEOUT_SEC:-900}" poll="${CFW_RENDER_PROBE_POLL_SEC:-5}" start err
  start="$(date +%s)"
  while :; do
    if out="$(fa_setup_report probe_render)" && [[ "$(fa_json_get ok <<< "$out")" == "true" ]]; then
      break
    fi
    err="$(fa_json_get error <<< "${out:-}")"
    case "$err" in
      probe_order_not_done|probe_order_not_recorded|"") ;;
      *) app_fail test_render 7 "The test render failed: $err" "Check AI Providers, then try again" ;;
    esac
    if (( $(date +%s) - start >= timeout )); then
      app_fail test_render 7 "The test render did not finish in time" "Make sure this Mac stays awake, then try again"
    fi
    sleep "$poll"
  done
  app_step test_render "done" "The test render worked"
  app_step ready "done" "This computer is ready"
}

# fa_update — [M3-05a] `--from-app --update`: copy the bundled worker files
# over $PREFIX (settings, keys and state are untouched) and reload the
# LaunchAgent if it is installed. Prints one "ready/done/Updated" line.
fa_update() {
  local d f
  mkdir -p "$PREFIX" || app_fail ready 6 "Could not update CFW Render" "Reinstall CFW Render"
  # config/ may hold local files: merge over it instead of replacing it.
  if [[ -d "$REPO_DIR/config" ]]; then
    mkdir -p "$PREFIX/config" && cp -a "$REPO_DIR/config/." "$PREFIX/config/" \
      || app_fail ready 6 "Could not update CFW Render" "Reinstall CFW Render"
  fi
  for d in bin lib scripts skills; do
    [[ -d "$REPO_DIR/$d" ]] || continue
    rm -rf "${PREFIX:?}/$d.new"
    cp -a "$REPO_DIR/$d" "$PREFIX/$d.new" && rm -rf "${PREFIX:?}/$d" && mv "$PREFIX/$d.new" "$PREFIX/$d" \
      || app_fail ready 6 "Could not update CFW Render" "Reinstall CFW Render"
  done
  for f in AGENTS.md CLAUDE.md VERSION; do
    [[ -f "$REPO_DIR/$f" ]] && cp -a "$REPO_DIR/$f" "$PREFIX/$f"
  done
  chmod +x "$PREFIX"/bin/*.sh "$PREFIX"/scripts/*.sh 2>/dev/null || true
  local plist="$HOME/Library/LaunchAgents/com.cfw.render.plist"
  if [[ -f "$plist" && "${CFW_RENDER_SKIP_LAUNCHCTL:-0}" != "1" && "${CFW_RENDER_INSTALL_NO_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.cfw.render" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  fi
  app_step ready "done" "Updated"
}
