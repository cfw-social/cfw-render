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

  # Deploy mode (doc §4) — operational only. Skills always come from the in-repo
  # bundle; server and BYOA use the same source (BYOA git-pulls to update).
  row "mode" 0 "mode=$CFW_RENDER_MODE (skills: in-repo bundle)"

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

  # [CFW-199] Toolchain preflight is part of --dry too, so a box is validated
  # before anyone enables the timer. The old --dry checked config, credentials
  # and a live tools/list but NOT whether this host owns the tools the recipes
  # shell out to — which is how CFW-188 found hst with no ImageMagick at all,
  # one `systemctl enable` from claiming orders it could not finish.
  echo ""
  cr_preflight || pass=0

  echo "-------------------------------------"
  if (( pass )); then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
fi

# ---------------------------------------------------------------------------
# Real tick.
# ---------------------------------------------------------------------------

# [CFW-199] THE GATE. Before the tick lock, before the claim loop, before a
# single tools/call: prove this host can finish a render. `claim_render_order`
# claims fleet-wide, oldest-first, across every brand — a half-provisioned box
# that starts here does not fail quietly, it takes the owner's real orders and
# burns them into failures. A missing tool is fatal, never a warning.
if ! cr_preflight --quiet; then
  cr_log "preflight FAILED — refusing to claim any order on this host"
  exit 1
fi

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
    "{{fanoutModels}}": sys.argv[8],
}
for k, v in subs.items():
    tpl = tpl.replace(k, v)
print(tpl)
' "$SELF_DIR/../lib/director-prompt.md" "$order_id" "$CFW_RENDER_SKILLS_DIR" "$recipe" "$gate" "$CFW_RENDER_GATE_FAIL_CAP" "$timeout_min" "$CFW_RENDER_FANOUT_MODELS" 2>/dev/null)"

  cr_event "$order_id" stage fetch-assets "Gathering ingredients" 5

  # [CFW-146] Pulse every 60 s for as long as this Director runs. Started
  # BEFORE the subprocess and stopped in every exit path below (normal,
  # watchdog kill, crash) so no heartbeat can land after the order is terminal.
  local heartbeat_pid
  heartbeat_pid="$(cr_heartbeat_start "$order_id")"
  # [CFW-315] Let the Director's own process (cfw-render-report.sh, running
  # inside it) stop the pulse itself, synchronously, right before it reports a
  # terminal outcome — stopping it here, after wait, is too late: the Director
  # already called complete/block from inside its own tree before it exits.
  [[ -n "$heartbeat_pid" ]] && echo "$heartbeat_pid" > "$order_dir/.heartbeat.pid"

  local ts out_file model_state_file
  ts="$(date +%s)"
  out_file="$RUNS_DIR/${order_id}-${ts}.out"
  model_state_file="$order_dir/work/.director-model"
  : > "$out_file"

  # [CFW-286] Enable job control HERE — in the frame that backgrounds the
  # subshell below — not inside it. Job control gives a `(...) &` job its own
  # new process group (pgid == the job's own pid) only when monitor mode is
  # already on in the shell doing the backgrounding; turning it on inside the
  # subshell itself is too late; the subshell's own pgid is already fixed at
  # fork time. Once set, the plain (non-`&`) foreground exec of claude/
  # $CFW_RENDER_DIRECTOR_CMD inside the subshell stays in that same group, and
  # since spawn_director itself always runs as its own forked job (called via
  # `spawn_director "$order_json" &`), this is scoped to one order — it does
  # not affect the main script or sibling concurrent orders.
  set -m
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

  # [CFW-286] Capture the Director's process group right after backgrounding
  # it — before anything can exit — so both the watchdog and the post-wait
  # reap below can signal the whole group, not just the subshell itself. If
  # the lookup races a very short-lived process (e.g. a config error that
  # exits in milliseconds) and comes back empty, fall back to the bare PID —
  # today's behavior, never a hard failure of the drainer.
  local director_pgid director_kill_target
  director_pgid="$(ps -o pgid= -p "$director_pid" 2>/dev/null | tr -d ' ')"
  if [[ -n "$director_pgid" ]]; then
    director_kill_target="-$director_pgid"
  else
    director_kill_target="$director_pid"
  fi

  # Watchdog kills the whole tree (CFW-292). Redirected so the orphaned `sleep`
  # it leaves behind cannot hold the caller's stdout open — that was the
  # test-gate hang and the stray `sleep 3600`s found on the Mac (CFW-286).
  ( sleep "$timeout_secs"; cr_kill_tree "$director_pid" TERM; sleep 30; cr_kill_tree "$director_pid" KILL ) >/dev/null 2>&1 &
  local watchdog_pid=$!

  wait "$director_pid"
  local director_exit=$?
  cr_kill_tree "$watchdog_pid" TERM; wait "$watchdog_pid" 2>/dev/null
  # Stop the pulse before ANY outcome is reported — a heartbeat after
  # complete/block would be rejected ("order not claimed by this worker").
  cr_heartbeat_stop "$heartbeat_pid"

  local outcome_file="$order_dir/.outcome" outcome model_served=""
  [[ -f "$model_state_file" ]] && model_served="$(cat "$model_state_file" 2>/dev/null)"

  # [CFW-286] The Director's turn ended (not a watchdog kill) but .outcome
  # hasn't landed yet — exactly the race a backgrounded step produces:
  # `claude` exits clean while a background write is still in flight. Poll
  # for a short, fixed window before declaring the render orphaned; a
  # genuinely near-finished write lands within it and is treated as a normal
  # completion below. Bounded (seconds, not minutes) — indefinitely awaiting
  # an unsupervised background process would defeat the whole point of the
  # per-kind timeout budget.
  if [[ ! -f "$outcome_file" ]] && (( director_exit != 143 && director_exit != 137 )); then
    local grace_secs="${CFW_RENDER_ORPHAN_GRACE_SECS:-5}"
    local grace_ticks=$(( grace_secs * 2 )) grace_i=0
    while (( grace_i < grace_ticks )) && [[ ! -f "$outcome_file" ]]; do
      sleep 0.5
      grace_i=$(( grace_i + 1 ))
    done
  fi

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
    cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"render exceeded the time budget","needs":"capacity"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
      || cr_log "order $order_id — block_render_order (timeout) call failed; lease expiry is the backstop"
  else
    # [CFW-286] Grace window expired with no terminal action ever landing.
    # Reap anything still alive in the Director's process group first — a
    # best-effort cleanup (a detached/setsid child escapes this, which is
    # why the prompt-level fix in lib/director-prompt.md is the primary
    # defense) — so no straggler can keep mutating the scratch dir or race
    # the drainer's own decision with a stale completion.
    kill -TERM "$director_kill_target" 2>/dev/null
    sleep 1
    kill -KILL "$director_kill_target" 2>/dev/null
    if (( director_exit == 0 )); then
      # Clean exit, no complete/block ever called — the Director backgrounded
      # a step and ended its turn without waiting on it. This is the CFW-286
      # bug itself, made visible instead of hidden inside "crashed".
      outcome="orphaned"
      cr_log "order $order_id — Director exited cleanly (rc=0) with no complete/block after a ${grace_secs}s grace window; a background step was likely still running when its turn ended (CFW-286)"
      cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"render ended without finishing — a background step was still running when the Director'"'"'s turn ended"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
        || cr_log "order $order_id — block_render_order (orphaned) call failed; lease expiry is the backstop"
    else
      # Nonzero exit (bad exit code, uncaught exception, OOM, etc.) — a
      # genuine crash, distinct from the clean-exit orphaned case above.
      outcome="crashed"
      cr_log "order $order_id — Director exited nonzero (exit=$director_exit) with no complete/block"
      cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"render failed unexpectedly"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
        || cr_log "order $order_id — block_render_order (crash) call failed; lease expiry is the backstop"
    fi
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
  # [CFW-146] the claim carries the renderer identity so the owner's order card
  # can say "Working on your Mac" / "on the box" instead of a bare "Cooking".
  claim_resp="$(cr_mcp_call claim_render_order "$(python3 -c 'import json,sys; print(json.dumps({"workerId":sys.argv[1],"renderer":{"kind":sys.argv[2],"label":sys.argv[3]}}))' "$CFW_WORKER_ID" "$CFW_RENDER_RENDERER_KIND" "$(hostname -s 2>/dev/null || hostname)")")" || {
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
