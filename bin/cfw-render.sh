#!/usr/bin/env bash
# cfw-render.sh — the drainer. One tick per invocation (launchd/systemd timer
# calls this every ~15 min; see install/). Claims queued RenderOrders via the
# narrow cfw-render worker credential, spawns a headless Claude Creative
# Director per order, watches it, and reconciles the outcome.
#
# Usage: cfw-render.sh [--once] [--loop] [--dry]
#   --once   one tick: claim up to capacity, run, wait, exit (default; the
#            Linux timer and the test suite use this).
#   --loop   [M2-04, D89] stay running: the LaunchAgent keeps this alive. Idle
#            → one claim every CR_CAPACITY_IDLE_CLAIM_SECS; busy → heartbeats
#            per order as today + a claim check whenever a request finishes or
#            every 60 s while there is spare capacity. Tick lock held and
#            touched for the whole life of the process. Claim errors back off
#            60 s → 10 min, one log line per back-off step.
#   --dry    validation only — checks binaries/dirs/keys + a live tools/list
#            call. Claims NOTHING. Exit 0 = all PASS, 1 = any FAIL.
#
# Design source: backlog/attachments/AB-RNDR-WORKER/implementation-plan.md §4.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-engine.sh"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-harness.sh"

DRY=0
LOOP=0
for arg in "$@"; do
  case "$arg" in
    --dry) DRY=1 ;;
    --once) LOOP=0 ;;
    --loop) LOOP=1 ;;
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
  if [[ -w "$CFW_RENDER_LOG_DIR" ]]; then
    row "dir:logs" 0 "$CFW_RENDER_LOG_DIR"
  else
    row "dir:logs" 1 "$CFW_RENDER_LOG_DIR not writable"
  fi
  if [[ "$CFW_RENDER_KEEP_OUTPUTS" == "1" ]]; then
    row "dir:outputs" 0 "$CFW_RENDER_OUTPUTS (finished renders are kept here)"
  else
    warn_row "dir:outputs" "off — finished renders are not kept on this computer"
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
# Per-render transcripts are logs: "$HOME/CFW Render/logs/runs" on an owner's
# computer, the state dir on the fleet (CFW_RENDER_LOG_DIR default).
RUNS_DIR="$CFW_RENDER_LOG_DIR/runs"
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

  # [CFW-313] Brand-scoped provider credential gate. A HeyGen recipe must
  # carry taskOrder.credentials.heygen — a brand-scoped OAuth credential
  # cfw-social embeds into the order at claim time from THAT brand's own
  # connected HeyGen account. This worker NEVER falls back to any
  # worker-local/vault HeyGen key — absent or malformed means this brand
  # simply hasn't connected HeyGen yet (or the companion cfw-social piece of
  # CFW-313 hasn't shipped), and the honest answer is to block, not to
  # borrow another brand's credential.
  local heygen_mode="" heygen_token="" heygen_expires="" heygen_pool="" heygen_expired=""
  if cr_recipe_needs_heygen "$recipe"; then
    IFS=$'\x1f' read -r heygen_mode heygen_token heygen_expires heygen_pool heygen_expired <<< "$(python3 -c '
import datetime, json, sys
o = json.load(sys.stdin)
cred = ((o.get("taskOrder") or {}).get("credentials") or {}).get("heygen") or {}
mode = cred.get("mode") or ""
token = cred.get("accessToken") or ""
expires = cred.get("expiresAt") or ""
pool = cred.get("creditPool") or ""
expired = "0"
if expires:
    try:
        exp_dt = datetime.datetime.fromisoformat(expires.replace("Z", "+00:00"))
        expired = "1" if exp_dt <= datetime.datetime.now(datetime.timezone.utc) else "0"
    except Exception:
        expired = "1"  # unparsable expiresAt — fail closed, treat as expired
print("\x1f".join([mode, token, expires, pool, expired]))
' <<< "$order_json" 2>/dev/null)"

    if [[ "$heygen_mode" != "oauth" || -z "$heygen_token" || "$heygen_expired" == "1" ]]; then
      cr_log "spawn_director: order $order_id (recipe=$recipe) has no usable brand-scoped HeyGen OAuth credential on taskOrder.credentials.heygen (mode=$heygen_mode expired=$heygen_expired) — blocking (never falling back to a worker-local key)"
      cr_mcp_call block_render_order "$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":"this brand'"'"'s HeyGen account isn'"'"'t connected — connect it in brand settings","needs":"decision"}))' "$order_id" "$CFW_WORKER_ID")" >/dev/null 2>&1 \
        || cr_log "order $order_id — block_render_order (no-heygen-credential) call failed; lease expiry is the backstop"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "$brand_slug" "$kind" "blocked" "" "" >> "$JOURNAL"
      return 1
    fi
  fi

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

  # [M1-08] Manifest-driven order → the step harness runs it instead of a
  # Director. Completion goes through cfw-render-report.sh complete with the
  # LAST completed step's saves, exactly like the Director path does.
  if [[ "$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("manifest") else "0")' <<< "$order_json" 2>/dev/null)" == "1" ]]; then
    local h_rc=0 h_out="" h_outcome="harness-failed"
    # The harness result goes through a file, not $(...): the harness forks a
    # heartbeat loop and the engine CLI, and any inherited stdout would hold a
    # command substitution open after the step loop has already returned.
    (
      cd "$order_dir" || exit 1
      export CFW_ORDER_ID="$order_id" CFW_WORKER_ID CFW_API_BASE CFW_RENDER_WORKER_KEY
      export CFW_RENDER_SCRATCH_DIR="$order_dir" CFW_RENDER_STATE_DIR CFW_RENDER_LOG_DIR
      CFW_RENDER_KEEP_DIR="$(cr_keep_output_dir "$brand_slug" "$order_id")"; export CFW_RENDER_KEEP_DIR
      export PATH="$SELF_DIR:$PATH"
      cr_harness_run "$order_dir/order.json" "$order_dir" "$CFW_RENDER_SKILLS_DIR/$recipe" > "$order_dir/harness-result.json"
    ) </dev/null || h_rc=$?
    h_out="$(cat "$order_dir/harness-result.json" 2>/dev/null || true)"
    if (( h_rc == 0 )); then
      # [M2-06] Only media saves are deliverables. A `json`/`md` save is a
      # side file: the report script would otherwise type `captions.json` as
      # an image after the video and the server rejects it ("image after a
      # video must be role poster"). A save with id `captions` is the
      # recipe's captions file and goes to the report as CFW_CAPTIONS_FILE.
      local -a h_files=() h_captions=""
      while IFS=$'\t' read -r f role; do
        [[ -n "$f" ]] || continue
        if [[ "$role" == "captions" ]]; then h_captions="$f"; else h_files+=("$f"); fi
      done < <(python3 -c '
import json, sys, os
MEDIA = {"mp4", "mov", "webm", "m4v", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp3", "wav", "m4a"}
a = json.loads(sys.argv[1] or "[]")
for x in a:
    p = x["path"]; ext = os.path.splitext(p)[1].lstrip(".").lower()
    if x.get("id") == "captions" and ext == "json": print(p + "\tcaptions")
    elif ext in MEDIA: print(p + "\tmedia")' "$h_out" 2>/dev/null)
      if (( ${#h_files[@]} > 0 )) && ( cd "$order_dir" && CFW_ORDER_ID="$order_id" CFW_CAPTIONS_FILE="${h_captions:-final/captions.json}" CFW_RENDER_KEEP_DIR="$(cr_keep_output_dir "$brand_slug" "$order_id")" PATH="$SELF_DIR:$PATH" cfw-render-report.sh complete "${h_files[@]}" ); then
        h_outcome="completed"
      else
        cr_log "order $order_id — harness finished but complete_render_order failed"
      fi
    else
      case "$h_rc" in 20) h_outcome="cancelled" ;; 21) h_outcome="released" ;; 22) h_outcome="revoked" ;; 23) h_outcome="superseded" ;; 24) h_outcome="engine_limit" ;; 30) h_outcome="failed" ;; esac
      cr_log "order $order_id — harness exited $h_rc ($h_outcome)"
      # [M2-04, D76] stop_after_step (22) and attempt_superseded (23): this
      # brand is no longer ours to serve from this computer — delete the
      # order folder (order.json carries the brand's credentials/providerKeys,
      # steps/ carries its files) and any key material held for it. No further
      # reports: the attempt is already released (22) or belongs to another
      # computer (23). [M3-01b] 24 = released for an engine usage limit:
      # the attempt is released; the server re-queues it.
      if (( h_rc == 22 || h_rc == 23 || h_rc == 24 )); then
        rm -rf "$order_dir"
        rm -rf "$(cr_keep_output_dir "$brand_slug" "$order_id")" 2>/dev/null
        cr_log "order $order_id — brand files and keys deleted after $h_outcome"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "$brand_slug" "$kind" "$h_outcome" "$h_rc" "harness" >> "$JOURNAL"
        return 0
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$order_id" "$brand_slug" "$kind" "$h_outcome" "$h_rc" "harness" >> "$JOURNAL"
    return 0
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
    export CFW_RENDER_LOG_DIR
    # Where cfw-render-report.sh keeps a local copy of the finished files once
    # CFW has accepted them (empty = keep none, e.g. the fleet).
    CFW_RENDER_KEEP_DIR="$(cr_keep_output_dir "$brand_slug" "$order_id")"
    export CFW_RENDER_KEEP_DIR
    export CFW_RENDER_OLLAMA_KEYS_FILE
    export CFW_RENDER_FANOUT_MODELS
    # [CFW-313] Brand-scoped HeyGen credential, if the gate above resolved
    # one — exported under its own name (never HEYGEN_API_KEY, which implies
    # api-key auth to anyone reading the env later) so the recipe can assert
    # it got an OAuth token billing the brand's own plan credits, not a
    # shared worker-vault key. Absent entirely when this order doesn't need
    # HeyGen (the gate above never ran) or (impossible here — the gate
    # already blocked and returned) when it's missing.
    if [[ -n "$heygen_token" ]]; then
      export HEYGEN_OAUTH_TOKEN="$heygen_token"
      export HEYGEN_CREDIT_POOL="$heygen_pool"
      export HEYGEN_TOKEN_EXPIRES_AT="$heygen_expires"
    fi
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

# ---------------------------------------------------------------------------
# [M2-04] Claims with capacity (CONTRACTS.md §3, D52/D51/D78).
# ---------------------------------------------------------------------------
spawn_pids=()
claim_caps=""   # recomputed per claim round (engines/limits change) — see claim_round
claim_label="$(hostname -s 2>/dev/null || hostname)"
CLAIM_MAX="$(cr_capacity_max)"
cr_log "capacity: max=$CLAIM_MAX request(s) at once${CFW_RENDER_CONCURRENCY:+ (CFW_RENDER_CONCURRENCY=$CFW_RENDER_CONCURRENCY)}"

# prune_running — drop finished order processes; sets RUNNING (live count).
# Never call these helpers inside $(...): they mutate spawn_pids and start
# background jobs, and a command substitution would both lose the array and
# hang on the children's inherited stdout.
RUNNING=0
prune_running() {
  local -a live=() ; local p
  for p in "${spawn_pids[@]:-}"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && live+=("$p")
  done
  spawn_pids=()
  for p in "${live[@]:-}"; do [[ -n "$p" ]] && spawn_pids+=("$p"); done
  RUNNING=${#spawn_pids[@]}
}

# claim_once <running> <max> <free_mb> <load> — one claim_render_order call.
# Prints the orders handed back, one JSON per line (`orders[]` from an M2
# server, or the single `order` from an older one). rc 1 = call failed.
claim_once() {
  local capacity resp
  capacity="$(cr_capacity_json "$1" "$2" "$3" "$4")"
  # [CFW-146] renderer identity → "Working on your Mac"; [M1-08] capabilities
  # → manifest orders; [M2-04] capacity → the server hands out at most
  # max - running, or one urgent request when running == max.
  resp="$(cr_mcp_call claim_render_order "$(python3 -c '
import json, sys
a = {"workerId": sys.argv[1], "renderer": {"kind": sys.argv[2], "label": sys.argv[3]}}
if sys.argv[4]:
    a["capabilities"] = json.loads(sys.argv[4])
    a["capabilities"]["workerVersion"] = sys.argv[6]
a["capacity"] = json.loads(sys.argv[5])
print(json.dumps(a))' "$CFW_WORKER_ID" "$CFW_RENDER_RENDERER_KIND" "$claim_label" "$claim_caps" "$capacity" "$CLAIM_WORKER_VERSION")")" || return 1
  # [M3-01a] updateRequired: the server wants a newer worker — no orders
  # until the owner updates. Cleared by the next reply without the flag.
  if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read()).get("updateRequired") is True else 1)' <<< "$resp" 2>/dev/null; then
    if (( ! CR_STATUS_UPDATE_REQUIRED )); then
      cr_log "update required: the server needs a newer cfw-render (this is $CLAIM_WORKER_VERSION) — not taking requests until this computer is updated"
    fi
    CR_STATUS_UPDATE_REQUIRED=1; CR_STATUS_LAST_ERROR="Update this computer"
    return 0
  fi
  CR_STATUS_UPDATE_REQUIRED=0; CR_STATUS_LAST_ERROR=""
  # SERVER_KNOWS_CAPACITY flips once a reply carries `orders[]`: only an M2
  # server does, and only such a server honours the "full" ask (see
  # claim_round). An older server ignores capacity and would hand a NORMAL
  # order to a full computer.
  if python3 -c 'import json,sys; sys.exit(0 if isinstance(json.loads(sys.stdin.read()).get("orders"), list) else 1)' <<< "$resp" 2>/dev/null; then
    SERVER_KNOWS_CAPACITY=1
  fi
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
orders = d.get("orders")
if not isinstance(orders, list):
    orders = [d.get("order")] if d.get("order") else []
for o in orders:
    if isinstance(o, dict) and o.get("id"): print(json.dumps(o))
' <<< "$resp" 2>/dev/null
}
SERVER_KNOWS_CAPACITY=0
CLAIM_WORKER_VERSION="$(cr_worker_version)"
# CR_STATUS_* are read by cr_status_write (lib); exported so shellcheck and
# any helper subshell see them as used.
export CR_STATUS_UPDATE_REQUIRED=0 CR_STATUS_LAST_ERROR="" CR_STATUS_LAST_CHECK_AT=""
export CR_STATUS_PAUSED=0 CR_STATUS_PAUSE_REASON="" CR_STATUS_ON_BATTERY=0 CR_STATUS_ALLOW_BATTERY=0
export CR_STATUS_RUNNING=0 CR_STATUS_MAX=1

# spawn_orders <file> — start one order process per JSON line; sets SPAWNED.
SPAWNED=0
spawn_orders() {
  local line
  SPAWNED=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    spawn_director "$line" </dev/null &
    spawn_pids+=($!); SPAWNED=$(( SPAWNED + 1 ))
    # [M3-01a, D90] keep the Mac awake while this request runs; caffeinate
    # exits with the order's process.
    if command -v "${CFW_RENDER_CAFFEINATE_CMD:-caffeinate}" >/dev/null 2>&1; then
      "${CFW_RENDER_CAFFEINATE_CMD:-caffeinate}" -i -w "${spawn_pids[${#spawn_pids[@]}-1]}" >/dev/null 2>&1 &
    fi
  done < "$1"
}

# claim_round — claim up to max - running, then once more for urgent work
# when full (or when the host is under the memory/load floor). The server
# decides what, if anything, comes back for that last ask; the worker takes
# whatever it gets. Sets STARTED (orders started). rc 2 = a claim call
# failed (the loop backs off), 0 otherwise.
STARTED=0
claim_round() {
  local running free_mb load ncpu started=0 n=0 normal_ok=1 rc=0 drained=0 tmp
  # [M3-01b] Engines and their limits move between rounds: recompute the
  # capabilities each round. When every signed-in engine is limited, skip the
  # claim until the earliest limit passes (the limit file clears itself).
  local active_engine limit_earliest limit_raw
  limit_raw="$(cr_engine_limit_raw_count)"
  active_engine="$(cr_engine_active)"
  limit_earliest="$(cr_engine_limit_earliest)"
  if (( limit_raw > 0 )) && [[ -z "$limit_earliest" ]]; then
    # Every recorded limit has passed (the read above dropped them): tell the server.
    cr_log "engine: usage limit(s) passed — resuming"
    cr_mcp_call_soft set_computer_limit '{"until":null}' >/dev/null 2>&1 || cr_log "set_computer_limit clear failed (ignored)"
  fi
  if [[ "$active_engine" == "none" ]]; then
    if [[ -n "$limit_earliest" ]] && [[ "$(cr_engines_json)" == *'"signedIn": true'* ]]; then
      CR_STATUS_LAST_ERROR="AI limit reached; resumes $limit_earliest"
      cr_log "engine: every signed-in engine is at its usage limit — not claiming until $limit_earliest"
      prune_running; STARTED=0
      return 0
    fi
  fi
  [[ "$CR_STATUS_LAST_ERROR" == "AI limit reached;"* ]] && CR_STATUS_LAST_ERROR=""
  claim_caps="$(cr_engine_capabilities_json "$active_engine" "$CFW_RENDER_SKILLS_DIR")"
  tmp="$(mktemp)"
  prune_running; running=$RUNNING
  IFS=$'\x1f' read -r free_mb load ncpu <<< "$(cr_capacity_probe)"
  cr_capacity_ok "$free_mb" "$load" "$ncpu" || normal_ok=0
  if (( ! normal_ok )); then
    cr_log "capacity: free=${free_mb:-?}MB load=${load:-?} (floor ${CR_CAPACITY_FREE_MB_FLOOR}MB / ncpu ${ncpu:-?}) — normal claims skipped, urgent only"
  fi
  while (( normal_ok && running < CLAIM_MAX )); do
    if ! claim_once "$running" "$CLAIM_MAX" "$free_mb" "$load" > "$tmp"; then rc=2; break; fi
    spawn_orders "$tmp"; n=$SPAWNED
    if (( n == 0 )); then drained=1; break; fi
    running=$(( running + n )); started=$(( started + n ))
  done
  # Full (or floor breached): one more ask, reporting running >= max, so an
  # urgent request can start alongside (D51). Not when the queue just ran dry.
  # Only against a server that honours capacity (it answered with `orders[]`
  # before): an older server would hand a normal order to a full computer.
  if (( rc == 0 && ! drained && SERVER_KNOWS_CAPACITY )) && { (( ! normal_ok )) || (( running >= CLAIM_MAX )); }; then
    local ask_running=$running
    (( ask_running < CLAIM_MAX )) && ask_running=$CLAIM_MAX
    if claim_once "$ask_running" "$CLAIM_MAX" "$free_mb" "$load" > "$tmp"; then
      spawn_orders "$tmp"; n=$SPAWNED
      (( n > 0 )) && cr_log "capacity: urgent ask with running=$ask_running max=$CLAIM_MAX returned $n order(s) — starting alongside"
      started=$(( started + n ))
    else
      rc=2
    fi
  fi
  rm -f "$tmp"
  STARTED=$started
  return $rc
}

# [M3-01a] pause gate. gated_claim_round — runs claim_round unless the owner
# paused this computer or it is on battery (without allow-battery); tells the
# server once per state change; writes status.json after every round/skip.
LAST_PAUSE_STATE="__unset__"
gated_claim_round() {
  local state rc=0 args
  state="$(cr_pause_state)"
  if [[ "$state" != "$LAST_PAUSE_STATE" ]]; then
    if [[ "$state" != "none" ]]; then
      cr_log "paused ($state): not taking new requests; running requests continue"
      args="$(python3 -c 'import json,sys; print(json.dumps({"paused": True, "reason": sys.argv[1]}))' "$state")"
    else
      args='{"paused":false}'
    fi
    if [[ "$state" != "none" || "$LAST_PAUSE_STATE" != "__unset__" ]]; then
      [[ "$state" == "none" ]] && cr_log "resumed: taking requests again"
      cr_mcp_call_soft set_computer_paused "$args" >/dev/null 2>&1 \
        || cr_log "set_computer_paused call failed (server may not have the tool yet) — carrying on"
    fi
    LAST_PAUSE_STATE="$state"
  fi
  if [[ "$state" == "none" ]]; then
    CR_STATUS_LAST_CHECK_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    claim_round && rc=0 || rc=$?
  else
    prune_running; STARTED=0
  fi
  [[ "$state" == "none" ]] && CR_STATUS_PAUSED=0 || CR_STATUS_PAUSED=1
  CR_STATUS_PAUSE_REASON=""; [[ "$state" != "none" ]] && CR_STATUS_PAUSE_REASON="$state"
  cr_on_battery && CR_STATUS_ON_BATTERY=1 || CR_STATUS_ON_BATTERY=0
  [[ -e "$CFW_RENDER_STATE_DIR/allow-battery" ]] && CR_STATUS_ALLOW_BATTERY=1 || CR_STATUS_ALLOW_BATTERY=0
  prune_running; CR_STATUS_RUNNING=$RUNNING; CR_STATUS_MAX=$CLAIM_MAX
  cr_status_write || cr_log "could not write status.json"
  return $rc
}

if (( ! LOOP )); then
  # One tick (--once): one claim round, then wait for every order it started.
  gated_claim_round || cr_log "claim_render_order call failed — stopping this tick's claim loop"
  cr_log "claim round done — $STARTED order(s) started"
  for pid in "${spawn_pids[@]:-}"; do
    [[ -n "$pid" ]] && wait "$pid"
  done
  cr_log "tick complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# [M2-04, D89] --loop: stay running. Sleeps are in units of
# CR_CAPACITY_IDLE_CLAIM_SECS (60 s; CFW_RENDER_CAPACITY_UNIT_SECS scales them
# for tests). A finished request wakes the loop early so the freed slot is
# re-filled at once.
# ---------------------------------------------------------------------------
loop_sleep() { # loop_sleep <secs> — returns early when a running order ends,
  # on run-now (ctl), or when the pause state changes (M3-01a).
  local secs="$1" step tick ticks before after i
  step="$(awk -v s="$secs" 'BEGIN { s = s / 10; if (s < 0.05) s = 0.05; printf "%.3f", s }')"
  tick="$(awk -v s="$step" 'BEGIN { printf "%.3f", (s < 2) ? s : 2 }')"
  ticks="$(awk -v s="$secs" -v t="$tick" 'BEGIN { n = int(s / t + 0.999); if (n < 1) n = 1; print n }')"
  prune_running; before=$RUNNING
  for (( i = 0; i < ticks; i++ )); do
    sleep "$tick"
    if [[ -e "$CFW_RENDER_STATE_DIR/run-now" ]]; then
      rm -f "$CFW_RENDER_STATE_DIR/run-now"; cr_log "run-now: claiming now"; return 0
    fi
    [[ "$(cr_pause_state)" != "$LAST_PAUSE_STATE" ]] && return 0
    prune_running; after=$RUNNING
    (( after < before )) && return 0
  done
  return 0
}

backoff=0
cr_log "loop: started (pid $$) — idle claim every ${CR_CAPACITY_IDLE_CLAIM_SECS}s, back-off ${CR_CLAIM_BACKOFF_BASE_SECS}s..${CR_CLAIM_BACKOFF_MAX_SECS}s"
while true; do
  cr_tick_lock_touch
  gated_claim_round && round_rc=0 || round_rc=$?
  started=$STARTED
  if (( round_rc == 2 )); then
    # One line per back-off STEP: the value only changes 60→120→240→480→600,
    # so a 5-minute outage logs five lines, not fifty.
    next="$(awk -v b="$backoff" -v base="$CR_CLAIM_BACKOFF_BASE_SECS" -v mx="$CR_CLAIM_BACKOFF_MAX_SECS" \
      'BEGIN { n = (b == 0) ? base : b * 2; if (n > mx) n = mx; print n }')"
    if [[ "$next" != "$backoff" ]]; then
      backoff="$next"
      cr_log "claim back-off: claim_render_order keeps failing — retrying every ${backoff}s (cap ${CR_CLAIM_BACKOFF_MAX_SECS}s)"
    fi
    loop_sleep "$backoff"
    continue
  fi
  if [[ "$backoff" != "0" ]]; then
    cr_log "claim back-off: cleared — claims are succeeding again"
    backoff=0
  fi
  if (( started > 0 )); then prune_running; cr_log "loop: $started order(s) started ($RUNNING running)"; fi
  loop_sleep "$CR_CAPACITY_IDLE_CLAIM_SECS"
done
