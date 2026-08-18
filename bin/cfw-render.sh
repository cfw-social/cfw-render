#!/usr/bin/env bash
# cfw-render.sh — the drainer. One tick per invocation (launchd/systemd timer
# calls this every ~15 min; see install/). Claims queued RenderOrders via the
# narrow cfw-render worker credential, spawns a headless Claude Creative
# Director per order, watches it, and reconciles the outcome.
#
# Usage: cfw-render.sh [--once] [--dry]
#   --once   accepted for AC compat; this script always does exactly one tick.
#   --dry    validation only — checks binaries/dirs/keys + a live tools/list
#            call. Claims NOTHING. Exit 0 = all PASS, 1 = any FAIL.
#
# Design source: backlog/attachments/AB-RNDR-WORKER/implementation-plan.md §4.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry) DRY=1 ;;
    --once) : ;; # default behavior; accepted for AC compat
    *) printf 'cfw-render.sh: unknown flag %s\n' "$arg" >&2; exit 2 ;;
  esac
done

cr_load_config || exit 1

# ---------------------------------------------------------------------------
# --dry: validate config + credential presence + live tools/list. Claims
# nothing (AC requirement).
# ---------------------------------------------------------------------------
if (( DRY )); then
  pass=1
  row() { # row <label> <ok:0/1> <detail>
    if [[ "$2" == "0" ]]; then
      printf '  PASS  %-28s %s\n' "$1" "$3"
    else
      printf '  FAIL  %-28s %s\n' "$1" "$3"
      pass=0
    fi
  }
  warn_row() { printf '  WARN  %-28s %s\n' "$1" "$2"; }

  echo "cfw-render --dry — validation report"
  echo "-------------------------------------"

  for b in curl python3 claude; do
    if command -v "$b" >/dev/null 2>&1; then row "binary:$b" 0 "found"; else row "binary:$b" 1 "not on PATH"; fi
  done
  for b in ffmpeg shellcheck; do
    if command -v "$b" >/dev/null 2>&1; then warn_row "binary:$b" "found"; else warn_row "binary:$b" "not on PATH (optional)"; fi
  done

  if [[ -w "$CFW_RENDER_SCRATCH" || ( ! -e "$CFW_RENDER_SCRATCH" && -w "$(dirname "$CFW_RENDER_SCRATCH")" ) ]]; then
    row "dir:scratch" 0 "$CFW_RENDER_SCRATCH"
  else
    row "dir:scratch" 1 "$CFW_RENDER_SCRATCH not writable"
  fi
  if [[ -d "$CFW_RENDER_SKILLS_DIR" ]]; then
    row "dir:skills" 0 "$CFW_RENDER_SKILLS_DIR"
  else
    warn_row "dir:skills" "$CFW_RENDER_SKILLS_DIR not found (ok for local dev override)"
  fi

  # Which pinned skills release is live (doc §5 last para) — informational.
  row "skills:pinned" 0 "$(cr_skills_pin_summary)"

  # Deploy mode + skills source (doc §4). mode=byoa && source=bundle is a
  # visible-but-non-fatal misconfiguration (doc risk #4): a BYOA box would use
  # the full pinned bundle instead of a curated fetch — wasted disk, not a
  # security issue (the server-side brand filter is the real boundary).
  if [[ "$CFW_RENDER_MODE" == "byoa" && "$CFW_RENDER_SKILLS_SOURCE" == "bundle" ]]; then
    warn_row "mode:skills-source" "mode=byoa with skills-source=bundle — BYOA usually wants curated 'fetch' (CFW-V2-067). Using the full pinned bundle; wasted disk, not a security issue."
  else
    row "mode:skills-source" 0 "mode=$CFW_RENDER_MODE source=$CFW_RENDER_SKILLS_SOURCE"
  fi

  if [[ -w "$CFW_RENDER_STATE_DIR" || ( ! -e "$CFW_RENDER_STATE_DIR" && -w "$(dirname "$CFW_RENDER_STATE_DIR")" ) ]]; then
    row "dir:state" 0 "$CFW_RENDER_STATE_DIR"
  else
    row "dir:state" 1 "$CFW_RENDER_STATE_DIR not writable"
  fi

  row "key:shape" 0 "CFW_RENDER_WORKER_KEY matches ^cfw_render_"  # cr_load_config already enforced this

  if [[ -f "$CFW_RENDER_OLLAMA_KEYS_FILE" ]]; then
    row "keys:ollama" 0 "$CFW_RENDER_OLLAMA_KEYS_FILE"
  else
    warn_row "keys:ollama" "$CFW_RENDER_OLLAMA_KEYS_FILE not found — fan-out/quota-failover unavailable"
  fi

  # Live check WITHOUT claiming: tools/list must show the 4 worker tools.
  tools_resp="$(curl -sS --max-time 15 -X POST "${CFW_API_BASE%/}/api/v1/mcp" \
    -H "cfw-render-key: $CFW_RENDER_WORKER_KEY" \
    -H "content-type: application/json" \
    -H "accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)"
  if [[ -z "$tools_resp" ]]; then
    row "live:tools/list" 1 "no response from $CFW_API_BASE (unreachable?)"
  else
    ok="$(python3 -c '
import json, sys
try:
    env = json.loads(sys.stdin.read())
    names = {t.get("name") for t in env.get("result", {}).get("tools", [])}
    need = {"claim_render_order", "append_render_event", "complete_render_order", "block_render_order"}
    print("1" if need.issubset(names) else "0")
except Exception:
    print("0")
' <<< "$tools_resp" 2>/dev/null)"
    if [[ "$ok" == "1" ]]; then
      row "live:tools/list" 0 "all 4 worker tools present, claimed nothing"
    else
      row "live:tools/list" 1 "worker tools missing/unexpected response — check key/route"
    fi
  fi

  echo "-------------------------------------"
  if (( pass )); then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
fi

# ---------------------------------------------------------------------------
# Real tick.
# ---------------------------------------------------------------------------
cr_tick_lock_acquire || { cr_log "tick lock held by another run — quiet no-op"; exit 0; }
trap 'cr_tick_lock_release' EXIT

# 48h scratch janitor — leftover forensics from failed runs get wiped.
if [[ -d "$CFW_RENDER_SCRATCH" ]]; then
  find "$CFW_RENDER_SCRATCH" -mindepth 2 -maxdepth 2 -type d -mtime +2 -print0 2>/dev/null \
    | while IFS= read -r -d '' d; do
        cr_log "janitor: removing stale scratch dir older than 48h: $d"
        rm -rf "$d"
      done
fi

JOURNAL="$CFW_RENDER_STATE_DIR/journal.tsv"
RUNS_DIR="$CFW_RENDER_STATE_DIR/runs"
mkdir -p "$RUNS_DIR"

sanitize_slug() {
  # [a-z0-9-] only, lowercase, collapse repeats, trim leading/trailing '-'.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

spawn_director() {
  local order_json="$1"
  local order_id brand_id kind recipe brand_slug
  order_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$order_json" 2>/dev/null)"
  brand_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("brandId",""))' <<< "$order_json" 2>/dev/null)"
  kind="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))' <<< "$order_json" 2>/dev/null)"
  recipe="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("recipe",""))' <<< "$order_json" 2>/dev/null)"
  local raw_slug
  raw_slug="$(python3 -c '
import json, sys
o = json.load(sys.stdin)
brand = (o.get("taskOrder") or {}).get("brand") or {}
print(brand.get("slug") or "")
' <<< "$order_json" 2>/dev/null)"

  if [[ -z "$order_id" ]]; then
    cr_log "spawn_director: order JSON missing id — skipping"
    return 1
  fi

  brand_slug="$(sanitize_slug "${raw_slug:-$brand_id}")"
  if [[ -z "$brand_slug" ]]; then
    cr_log "spawn_director: order $order_id has malformed/missing taskOrder.brand — blocking"
    cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"order was underspecified — missing brand context"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "" "$kind" "blocked" "" "" >> "$JOURNAL"
    return 1
  fi

  local order_dir="$CFW_RENDER_SCRATCH/$brand_slug/$order_id"
  mkdir -p "$order_dir/ingredients" "$order_dir/clips" "$order_dir/work" "$order_dir/final"
  printf '%s' "$order_json" > "$order_dir/order.json"

  # Integrity gate (doc §5): verify ONLY this order's recipe against the
  # bundle's index.json before spending a Director on it. A genuine checksum
  # mismatch (a pinned file changed under us — e.g. a pull landed mid-tick)
  # blocks the order with an owner-safe reason instead of rendering from a
  # corrupted recipe. Missing/absent manifest = unverifiable = proceed (logged
  # in the lib) — never a false block.
  if ! cr_verify_skills_bundle "$recipe"; then
    cr_log "spawn_director: order $order_id — skills bundle checksum MISMATCH for recipe '$recipe'; blocking instead of rendering from corrupted recipe files"
    cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"this render'"'"'s recipe files are out of sync — a redeploy is needed"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
      || cr_log "order $order_id — block_render_order (skills-mismatch) call failed; lease expiry is the backstop"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "$brand_slug" "$kind" "blocked" "" "" >> "$JOURNAL"
    return 1
  fi

  local gate
  gate="$(python3 -c '
import json, sys
o = json.load(sys.stdin)
to = o.get("taskOrder") or {}
gate = (to.get("acceptance") or {}).get("gate")
if not gate:
    gate = "c-shorts-qa-gate" if o.get("kind") == "video" else "c-vision-qa"
print(gate)
' <<< "$order_json" 2>/dev/null)"

  local timeout_secs
  if [[ "$kind" == "image" ]]; then timeout_secs="$CFW_RENDER_TIMEOUT_IMAGE"; else timeout_secs="$CFW_RENDER_TIMEOUT_VIDEO"; fi
  local timeout_min=$(( (timeout_secs + 59) / 60 ))

  local prompt
  prompt="$(python3 -c '
import sys
tpl = open(sys.argv[1]).read()
subs = {
    "{{orderId}}": sys.argv[2],
    "{{skillsDir}}": sys.argv[3],
    "{{recipe}}": sys.argv[4],
    "{{gate}}": sys.argv[5],
    "{{failCap}}": sys.argv[6],
    "{{timeoutMin}}": sys.argv[7],
}
for k, v in subs.items():
    tpl = tpl.replace(k, v)
print(tpl)
' "$SELF_DIR/../lib/director-prompt.md" "$order_id" "$CFW_RENDER_SKILLS_DIR" "$recipe" "$gate" "$CFW_RENDER_GATE_FAIL_CAP" "$timeout_min" 2>/dev/null)"

  cr_event "$order_id" stage fetch-assets "Gathering ingredients" 5

  local ts out_file model_state_file
  ts="$(date +%s)"
  out_file="$RUNS_DIR/${order_id}-${ts}.out"
  model_state_file="$order_dir/work/.director-model"
  : > "$out_file"

  (
    cd "$order_dir" || exit 1
    export CFW_ORDER_ID="$order_id"
    export CFW_WORKER_ID
    export CFW_API_BASE
    export CFW_RENDER_WORKER_KEY
    export CFW_RENDER_SCRATCH_DIR="$order_dir"
    export CFW_RENDER_STATE_DIR
    export CFW_RENDER_OLLAMA_KEYS_FILE
    export CFW_RENDER_FANOUT_MODELS
    export PATH="$SELF_DIR:$PATH"
    if [[ -n "$CFW_RENDER_DIRECTOR_CMD" ]]; then
      # shellcheck disable=SC2086
      $CFW_RENDER_DIRECTOR_CMD < /dev/null >> "$out_file" 2>&1
      exit $?
    else
      # shellcheck disable=SC1091
      source "$SELF_DIR/cfw-render-lib.sh"
      claude_native_or_ollama_quota_fallback "$order_id" "$CFW_RENDER_DIRECTOR_MODEL" "$out_file" "$model_state_file" -- \
        -p "$prompt" \
        --dangerously-skip-permissions \
        --output-format text
      exit $?
    fi
  ) &
  local director_pid=$!

  ( sleep "$timeout_secs"; kill -TERM "$director_pid" 2>/dev/null; sleep 30; kill -KILL "$director_pid" 2>/dev/null ) &
  local watchdog_pid=$!

  wait "$director_pid"
  local director_exit=$?
  kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null

  local outcome_file="$order_dir/.outcome" outcome model_served=""
  [[ -f "$model_state_file" ]] && model_served="$(cat "$model_state_file" 2>/dev/null)"

  if [[ -f "$outcome_file" ]]; then
    outcome="$(cat "$outcome_file" 2>/dev/null)"
    if [[ "$outcome" == "complete" ]]; then
      rm -rf "$order_dir"
      cr_log "order $order_id complete — scratch wiped"
    else
      cr_log "order $order_id ended with outcome=$outcome — scratch kept for 48h janitor"
    fi
  elif (( director_exit == 143 || director_exit == 137 )); then
    outcome="timeout"
    cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"render exceeded the time budget"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
      || cr_log "order $order_id — block_render_order (timeout) call failed; lease expiry is the backstop"
  else
    outcome="crashed"
    cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"render failed unexpectedly"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
      || cr_log "order $order_id — block_render_order (crash) call failed; lease expiry is the backstop"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "$brand_slug" "$kind" "$outcome" "$director_exit" "$model_served" >> "$JOURNAL"
}

# Claim loop (sequential — each claim is a fast DB CAS), then spawn one
# Director subprocess per claimed order IN BACKGROUND, then wait for all
# (plan §4 pseudocode) so CFW_RENDER_CONCURRENCY>1 renders in parallel.
spawn_pids=()
slot=0
while (( slot < CFW_RENDER_CONCURRENCY )); do
  slot=$(( slot + 1 ))
  claim_resp="$(cr_mcp_call claim_render_order "$(python3 -c 'import json,sys; print(json.dumps({"workerId":sys.argv[1]}))' "$CFW_WORKER_ID")")" || {
    cr_log "claim_render_order call failed — stopping this tick's claim loop"
    break
  }
  order_json="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
o = d.get("order")
print(json.dumps(o) if o else "")
' <<< "$claim_resp" 2>/dev/null)"
  if [[ -z "$order_json" ]]; then
    cr_log "queue empty or lost claim race — tick done ($((slot-1)) order(s) claimed)"
    break
  fi
  spawn_director "$order_json" &
  spawn_pids+=($!)
done

for pid in "${spawn_pids[@]:-}"; do
  [[ -n "$pid" ]] && wait "$pid"
done

cr_log "tick complete"
exit 0
