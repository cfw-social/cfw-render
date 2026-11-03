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

# fa_reload_agent <plist> — bootout + bootstrap com.cfw.render. Right after a
# bootout of a RUNNING job, launchd can still be tearing it down and refuses
# the bootstrap ("Bootstrap failed: 5: Input/output error"); retry for a few
# seconds. Returns non-zero if the job never loaded, so the caller reports it
# instead of claiming success with no worker running.
fa_reload_agent() {
  local plist="$1" tries="${CFW_RENDER_BOOTSTRAP_TRIES:-10}" i
  launchctl bootout "gui/$(id -u)/com.cfw.render" >/dev/null 2>&1 || true
  for (( i = 1; i <= tries; i++ )); do
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 && return 0
    (( i < tries )) && sleep "${CFW_RENDER_BOOTSTRAP_WAIT_SEC:-1}"
  done
  return 1
}

# fa_pending_keys <add|list|remove> — private revocation outbox beside worker-id.
# Keys travel on stdin/stdout (callers capture stdout), never process arguments.
# Refuse unsafe/corrupt state rather than silently forgetting a live credential.
fa_pending_keys() {
  python3 -c '
import json, os, re, secrets, stat, sys


def valid_key(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"cfw_render_[A-Za-z0-9_-]{1,4096}", value) is not None


def unique_object(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def run() -> None:
    action, worker = sys.argv[1:]
    # Resolve ancestor aliases (macOS /var, /tmp), then walk by descriptor.
    # The state directory itself and its files must not be symlinks.
    parent = os.path.dirname(os.path.abspath(worker))
    parent = os.path.join(os.path.realpath(os.path.dirname(parent)), os.path.basename(parent))
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parent.split("/"):
            if not part:
                continue
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("state directory must be private")
        name = "pending-key-revocations.json"
        keys = []
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            pass
        else:
            with os.fdopen(fd, "r") as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                    raise ValueError("unsafe pending file")
                raw = source.read(1048577)
                if len(raw) > 1048576:
                    raise ValueError("pending file too large")
                data = json.loads(raw, object_pairs_hook=unique_object)
                if (not isinstance(data, dict) or set(data) != {"version", "keys"}
                        or type(data["version"]) is not int or data["version"] != 1):
                    raise ValueError("invalid pending schema")
                keys = data["keys"]
                if (not isinstance(keys, list) or len(keys) > 256
                        or not all(valid_key(key) for key in keys) or len(set(keys)) != len(keys)):
                    raise ValueError("invalid pending keys")
        if action == "list":
            for key in keys:
                print(key)
            return
        incoming = sys.stdin.read(1048577).splitlines()
        if not all(valid_key(key) for key in incoming):
            raise ValueError("invalid key")
        if action == "add":
            keys = sorted(set(keys + incoming))
        elif action == "remove":
            keys = sorted(set(keys) - set(incoming))
        else:
            raise ValueError("invalid action")
        payload = json.dumps({"version": 1, "keys": keys}) + "\n"
        if len(keys) > 256 or len(payload) > 1048576:
            raise ValueError("pending state full")
        tmp = ".pending-key-revocations-" + secrets.token_hex(16)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, "w") as target:
                os.fchmod(target.fileno(), 0o600)
                target.write(payload)
                target.flush()
                os.fsync(target.fileno())
            os.replace(tmp, name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(tmp, dir_fd=directory)
            except FileNotFoundError:
                pass
    finally:
        os.close(directory)


try:
    run()
except (OSError, ValueError, TypeError, UnicodeError):
    # Never echo parser input, paths, keys, or exception text.
    print("install.sh: pending key revocation state is unavailable or invalid", file=sys.stderr)
    sys.exit(1)
' "$1" "$WORKER_ID_FILE"
}

fa_pending_fail() {
  app_fail connecting 6 "Could not preserve pending key revocations" "Keep the private state folder and retry; contact support if this continues"
}

fa_connect_and_probe() {
  app_step installing "done" "CFW Render is installed"
  app_step connecting started "Connecting to CFW"
  local base code resp render_key
  base="$(fa_api_base)"
  FA_WORKER_ID="$(tr -d '[:space:]' < "$WORKER_ID_FILE")"
  local device old_key
  device="$(cr_computer_name 2>/dev/null || hostname)"; device="${device:0:100}"; device="${device:-This Mac}"
  # Journal BEFORE exchange/env replacement. A failed probe must not lose the
  # previous parent-scoped key, even across multiple attempts or app restarts.
  old_key="$(env_value CFW_RENDER_WORKER_KEY)"
  if [[ -n "$old_key" ]]; then
    printf '%s\n' "$old_key" | fa_pending_keys add || fa_pending_fail
  else
    fa_pending_keys add < /dev/null || fa_pending_fail
  fi
  old_key=""
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
  [[ "$render_key" =~ ^cfw_render_[A-Za-z0-9_-]+$ ]] || app_fail connecting 6 "CFW sent an unexpected reply" "Try again in a minute"
  # Which key this is, for the app ("Connected for all your brands"): scope, name and a short
  # prefix only — never the key. Kept in the private state dir beside worker-id.
  ( umask 077
    python3 -c '
import json, sys, os, datetime
try:
    k = json.loads(sys.stdin.read()).get("key") or {}
except Exception:
    k = {}
pre = (k.get("prefix") or "")[:17]
c = {"scope": k.get("scope") if k.get("scope") in ("brand", "user", "subset") else None,
     "keyName": (k.get("name") or k.get("deviceName") or None),
     "keyHint": (pre + "…") if pre.startswith("cfw_render_") else None,
     "connectedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
p = sys.argv[1]; tmp = p + ".tmp"
json.dump(c, open(tmp, "w")); os.replace(tmp, p)' "$(dirname "$WORKER_ID_FILE")/connection.json" <<< "$resp"
  ) 2>/dev/null || true
  resp=""
  # Also journal the issued key before writing env: an interrupted/failed env
  # write must not orphan it. The current key is never revoked when draining.
  printf '%s\n' "$render_key" | fa_pending_keys add || fa_pending_fail
  printf '%s\n' "$render_key" | fa_env_set CFW_RENDER_WORKER_KEY "$ENV_FILE"
  printf '%s\n' "$base" | fa_env_set CFW_API_BASE "$ENV_FILE"
  export CFW_API_BASE="$base" CFW_RENDER_WORKER_KEY="$render_key"
  render_key=""

  local step out probe_brand=""
  # Open (or resume) this computer's setup session first: CFW keeps progress per
  # computer and refuses step reports without one. A key covering several brands
  # names no brand here; CFW picks one to test, and the test unlocks them all.
  out="$(cr_mcp_call_soft get_byoa_setup_instructions "$(python3 -c 'import json,sys;print(json.dumps({"workerId": sys.argv[1]}))' "$FA_WORKER_ID")")" \
    || app_fail connecting 6 "CFW did not accept the set-up report" "Try again in a minute"
  [[ "$(fa_json_get ok <<< "$out")" == "true" ]] || app_fail connecting 6 "CFW said: $(fa_json_get error <<< "$out")" "Try again in a minute"
  # provider_keys_needed is not reported here: telling which recipe needs a
  # missing provider key is not cheap from the installer (follow-up).
  for step in deps credential recipe_fetch; do
    out="$(fa_setup_report "$step")" || app_fail connecting 6 "CFW did not accept the set-up report" "Try again in a minute"
    [[ "$(fa_json_get ok <<< "$out")" == "true" ]] || app_fail connecting 6 "CFW said: $(fa_json_get error <<< "$out")" "Try again in a minute"
  done

  if [[ "${CFW_RENDER_SKIP_LAUNCHCTL:-0}" != "1" && "${CFW_RENDER_INSTALL_NO_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
    fa_reload_agent "$PLIST_DST" \
      || app_fail connecting 6 "Could not start CFW Render in the background" "Restart your Mac and try again"
  fi
  app_step connecting "done" "Connected to CFW"

  app_step test_render started "Making a test render"
  out="$(cr_mcp_call_soft create_probe_render_order "$(python3 -c 'import json,sys;print(json.dumps({"workerId": sys.argv[1]}))' "$FA_WORKER_ID")")" \
    || app_fail test_render 6 "Could not start the test render" "Try again in a minute"
  [[ "$(fa_json_get ok <<< "$out")" == "true" ]] || app_fail test_render 7 "Could not start the test render: $(fa_json_get error <<< "$out")" "Try again in a minute"
  # Report the test against the brand CFW tested (multi-brand keys); older servers send none.
  probe_brand="$(fa_json_get brandId <<< "$out")"
  [[ "$probe_brand" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || probe_brand=""
  local timeout="${CFW_RENDER_PROBE_TIMEOUT_SEC:-900}" poll="${CFW_RENDER_PROBE_POLL_SEC:-5}" start err
  start="$(date +%s)"
  while :; do
    if out="$(fa_setup_report probe_render "$(python3 -c 'import json,sys;print(json.dumps({"brandId": sys.argv[1]} if sys.argv[1] else {}))' "$probe_brand")")" \
       && [[ "$(fa_json_get ok <<< "$out")" == "true" ]]; then
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
  local pending
  pending="$(fa_pending_keys list)" || fa_pending_fail
  while IFS= read -r old_key; do
    [[ -n "$old_key" ]] || continue
    if [[ "$old_key" != "$CFW_RENDER_WORKER_KEY" && "$old_key" != "$(env_value CFW_RENDER_WORKER_KEY)" ]]; then
      # Each old key authorizes only its own revocation, across parent scopes.
      # Failure (including an ambiguous response) stays in the durable outbox.
      if ! out="$(CFW_RENDER_WORKER_KEY="$old_key" cr_mcp_call_soft revoke_this_computer '{}' 2>/dev/null)" || [[ "$(fa_json_get ok <<< "$out")" != "true" ]]; then
        echo "install.sh: WARNING — a previous key could not be turned off; retained for retry after the next successful setup" >&2
        continue
      fi
    fi
    printf '%s\n' "$old_key" | fa_pending_keys remove || fa_pending_fail
  done <<< "$pending"
  old_key=""; pending=""
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
    fa_reload_agent "$plist" \
      || app_fail ready 6 "Updated, but CFW Render could not restart in the background" "Restart your Mac"
  fi
  app_step ready "done" "Updated"
}
