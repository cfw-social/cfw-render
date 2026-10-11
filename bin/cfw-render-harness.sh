#!/usr/bin/env bash
# cfw-render-harness.sh — [M1-08 slice c] the manifest step loop.
#
# `cr_harness_run <order-json-file> <order-dir> <recipe-dir>` walks the claimed
# order's `manifest.steps` (computer steps only, from `resumeFromStepId`), runs
# each one through cr_engine_run, verifies its saves, uploads them, and reports
# every transition to cfw-social via report_render_step.
#
# Layout (pinned, shared with the recipe step files):
#   $ORDER_DIR/steps/<stepId>/inputs/<inputId>/   files from the claim's `inputs`
#   $ORDER_DIR/steps/<stepId>/prior/<saveId>.<ext> earlier steps' saves (copied)
#   $ORDER_DIR/steps/<stepId>/saves/<saveId>.<ext> what the step must write
#   $ORDER_DIR/steps/<stepId>/needs_input.json     {inputId, reason, count?}
#   $ORDER_DIR/steps/<stepId>/prompt.md            _shared.md + instructions + ## Order
#   $ORDER_DIR/logs/<stepId>.log                   engine stdout+stderr
#   $ORDER_DIR/seq                                 last report seq (int)
#   $ORDER_DIR/directive                           directive from the last reply
#   $ORDER_DIR/pending-reports.ndjson              reports buffered while unreachable
#
# Save extension by kind: video→mp4, image→png, json→json, text→md.
#
# Engine env: the step's expected saves are exported as
#   CFW_STEP_SAVES="<id>:<ext> <id>:<ext> ..."  and  CFW_STEP_ID=<stepId>
# (the fake engine in tests relies on this; real engines read prompt.md).
#
# Checks: for each `checks[].id` the harness runs `<recipe-dir>/checks/<id>.sh
# <workdir>` when that script exists. FALLBACK: when it doesn't, the check
# passes iff every declared save for the step exists and is non-empty.
#
# Return codes of cr_harness_run: 0 completed, 20 cancelled, 21 released
# (pause timeout), 30 step failed (attempt_failed reported), 1 bad input.
# On rc 0 the final outputs JSON ([{id,url,path}]) is printed to stdout.
#
# Depends on cfw-render-lib.sh (cr_log, cr_report_step) and
# cfw-render-engine.sh (cr_engine_detect, cr_engine_run) being sourced first.

: "${CFW_RENDER_HEARTBEAT_SEC:=30}"
: "${CFW_RENDER_STEP_TIMEOUT_SEC:=3600}"
: "${CFW_RENDER_PAUSE_MAX_SEC:=900}"

# Populated by cr_harness_run; read by the helpers below.
CR_H_ORDER_ID=""; CR_H_ATTEMPT_ID=""; CR_H_ORDER_DIR=""; CR_H_RECIPE_DIR=""
CR_H_HEARTBEAT_PID=""
CR_H_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cr_h_next_seq — increments $ORDER_DIR/seq under a mkdir lock (heartbeat
# subshell + step loop share the counter).
cr_h_next_seq() {
  local lock="$CR_H_ORDER_DIR/seq.lock" n=0 tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1)); (( tries > 200 )) && { rm -rf "$lock"; break; }
    sleep 0.05
  done
  [[ -f "$CR_H_ORDER_DIR/seq" ]] && n="$(tr -d '[:space:]' < "$CR_H_ORDER_DIR/seq")"
  n=$(( ${n:-0} + 1 ))
  printf '%s' "$n" > "$CR_H_ORDER_DIR/seq"
  rmdir "$lock" 2>/dev/null || true
  echo "$n"
}

# cr_h_handle_reply <reply-json> <event> — writes the directive file; maps
# fatal codes to `cancel`, not_implemented on needs_input to `not_implemented`.
cr_h_handle_reply() {
  local reply="$1" event="$2" parsed directive ok code err
  parsed="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
print("\x1f".join([str(d.get("directive") or ""), "1" if d.get("ok") else "0", str(d.get("code") or ""), str(d.get("error") or "")]))
' "$reply" 2>/dev/null)" || parsed=""
  IFS=$'\x1f' read -r directive ok code err <<< "$parsed"
  if [[ "$ok" == "0" ]]; then
    case "$code" in
      attempt_superseded|order_not_held)
        cr_log "harness: order $CR_H_ORDER_ID — $code ($err) → cancel"
        directive="cancel" ;;
      not_implemented)
        if [[ "$event" == "needs_input" ]]; then
          cr_log "harness: order $CR_H_ORDER_ID — needs_input rejected: not_implemented ($err)"
          directive="not_implemented"
        fi ;;
      *) cr_log "harness: order $CR_H_ORDER_ID — report $event rejected: $code $err" ;;
    esac
  fi
  [[ -n "$directive" ]] && printf '%s' "$directive" > "$CR_H_ORDER_DIR/directive"
  return 0
}

# cr_h_replay_pending — resend buffered reports in order; stops on rc 75.
cr_h_replay_pending() {
  local pend="$CR_H_ORDER_DIR/pending-reports.ndjson" line seq event extra reply rc tmp
  [[ -s "$pend" ]] || return 0
  tmp="$pend.tmp"; : > "$tmp"
  local stopped=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if (( stopped )); then printf '%s\n' "$line" >> "$tmp"; continue; fi
    IFS=$'\x1f' read -r seq event extra <<< "$(python3 -c '
import json, sys
d = json.loads(sys.argv[1]); print("\x1f".join([str(d["seq"]), d["event"], json.dumps(d["extra"])]))' "$line")"
    rc=0
    reply="$(cr_report_step "$CR_H_ORDER_ID" "$CFW_WORKER_ID" "$CR_H_ATTEMPT_ID" "$seq" "$event" "$extra")" || rc=$?
    if (( rc == 75 )); then
      stopped=1; printf '%s\n' "$line" >> "$tmp"
    elif (( rc == 0 )); then
      cr_h_handle_reply "$reply" "$event"
    fi
  done < "$pend"
  mv "$tmp" "$pend"
  [[ -s "$pend" ]] || rm -f "$pend"
  return 0
}

# cr_h_report <event> [extra-json] — the report() wrapper. Never fails.
cr_h_report() {
  local event="$1" extra="${2:-{\}}" seq reply rc=0
  # Replay the backlog FIRST so the server sees seqs in order.
  cr_h_replay_pending
  seq="$(cr_h_next_seq)"
  if [[ -s "$CR_H_ORDER_DIR/pending-reports.ndjson" ]]; then
    rc=75   # still unreachable — don't even try, keep order
  else
    reply="$(cr_report_step "$CR_H_ORDER_ID" "$CFW_WORKER_ID" "$CR_H_ATTEMPT_ID" "$seq" "$event" "$extra")" || rc=$?
  fi
  if (( rc == 75 )); then
    python3 -c 'import json, sys; print(json.dumps({"seq": int(sys.argv[1]), "event": sys.argv[2], "extra": json.loads(sys.argv[3])}))' \
      "$seq" "$event" "$extra" >> "$CR_H_ORDER_DIR/pending-reports.ndjson"
    cr_log "harness: order $CR_H_ORDER_ID — server unreachable; buffered seq $seq $event"
    return 0
  fi
  if (( rc == 0 )); then
    cr_h_handle_reply "$reply" "$event"
  else
    cr_log "harness: order $CR_H_ORDER_ID — report $event seq $seq tool error: $reply"
  fi
  return 0
}

cr_h_directive() {
  if [[ -f "$CR_H_ORDER_DIR/directive" ]]; then tr -d '[:space:]' < "$CR_H_ORDER_DIR/directive"; else echo continue; fi
}

cr_harness_heartbeat_start() {
  # Detach stdin/stdout: the caller may run cr_harness_run inside a command
  # substitution, and an inherited stdout would keep that $(...) open until the
  # loop dies.
  (
    exec </dev/null >/dev/null
    while true; do
      sleep "$CFW_RENDER_HEARTBEAT_SEC"
      cr_h_report heartbeat '{}' >/dev/null 2>&1 || true
    done
  ) &
  CR_H_HEARTBEAT_PID=$!
}

cr_harness_heartbeat_stop() {
  if [[ -n "$CR_H_HEARTBEAT_PID" ]]; then
    kill "$CR_H_HEARTBEAT_PID" 2>/dev/null || true
    wait "$CR_H_HEARTBEAT_PID" 2>/dev/null || true
  fi
  CR_H_HEARTBEAT_PID=""
}

# cr_h_wait_pause — directive says pause: poll (heartbeat each loop) until it
# changes. Returns 0 to continue, 20 cancel, 21 pause timeout.
cr_h_wait_pause() {
  local waited=0 d
  while :; do
    d="$(cr_h_directive)"
    case "$d" in
      cancel) return 20 ;;
      pause|not_implemented) ;;
      *) return 0 ;;
    esac
    (( waited >= CFW_RENDER_PAUSE_MAX_SEC )) && return 21
    sleep 5; waited=$((waited + 5))
    cr_h_report heartbeat '{}'
  done
}

# cr_h_run_with_timeout <secs> <cmd...> — background+wait with a killer.
cr_h_run_with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local killer=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

# cr_h_build_prompt <stepId> <workdir> <order-file> — writes workdir/prompt.md.
cr_h_build_prompt() {
  local step_id="$1" workdir="$2" order_file="$3" instr prompt
  prompt="$workdir/prompt.md"
  : > "$prompt"
  [[ -f "$CR_H_RECIPE_DIR/steps/_shared.md" ]] && cat "$CR_H_RECIPE_DIR/steps/_shared.md" >> "$prompt"
  instr="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))
s = next((s for s in (o.get("manifest") or {}).get("steps", []) if s.get("id") == sys.argv[2]), {})
print(s.get("instructions") or "")' "$order_file" "$step_id")"
  if [[ -n "$instr" && -f "$CR_H_RECIPE_DIR/$instr" ]]; then
    printf '\n' >> "$prompt"; cat "$CR_H_RECIPE_DIR/$instr" >> "$prompt"
  fi
  python3 - "$order_file" "$step_id" "$workdir" >> "$prompt" <<'PY'
import json, os, sys
o = json.load(open(sys.argv[1])); sid = sys.argv[2]; wd = sys.argv[3]
s = next((s for s in (o.get("manifest") or {}).get("steps", []) if s.get("id") == sid), {})
ext = {"video": "mp4", "image": "png", "json": "json", "text": "md"}
def listing(d):
    out = []
    for root, _, files in os.walk(d):
        for f in sorted(files):
            p = os.path.join(root, f); out.append(f"- {os.path.relpath(p, wd)} ({os.path.getsize(p)} bytes)")
    return "\n".join(out) or "- (none)"
print("\n## Order\n")
print("Brief:\n```json\n" + json.dumps(o.get("taskOrder") or {}, indent=1) + "\n```\n")
print("Inputs:\n" + listing(os.path.join(wd, "inputs")) + "\n")
print("Answers:\n```json\n" + json.dumps(o.get("answers") or {}) + "\n```\n")
fb = o.get("feedback")
if fb: print("Feedback:\n" + str(fb) + "\n")
print("Prior saves:\n" + listing(os.path.join(wd, "prior")) + "\n")
print("## You must produce\n")
for sv in s.get("saves") or []:
    print(f"- saves/{sv['id']}.{ext.get(sv.get('kind'), 'bin')} ({sv.get('kind')})")
PY
}

# cr_h_stage_inputs <workdir> <order-file> — copy/download claim inputs.
cr_h_stage_inputs() {
  local workdir="$1" order_file="$2" iid src dest
  while IFS=$'\x1f' read -r iid src; do
    [[ -n "$iid" && -n "$src" ]] || continue
    dest="$workdir/inputs/$iid"; mkdir -p "$dest"
    if [[ "$src" == http://* || "$src" == https://* ]]; then
      curl -sS -L --max-time 600 -o "$dest/$(basename "${src%%\?*}")" "$src" 2>/dev/null \
        || cr_log "harness: input $iid download failed ($src)"
    elif [[ -e "$src" ]]; then
      cp -R "$src" "$dest/" 2>/dev/null || true
    fi
  done < <(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))
for k, v in (o.get("inputs") or {}).items():
    vals = v if isinstance(v, list) else [v]
    for x in vals:
        u = (x.get("url") or x.get("path")) if isinstance(x, dict) else x
        if u: print(f"{k}\x1f{u}")' "$order_file")
  return 0
}

# cr_h_saves_for <stepId> → "id.ext ..." of the step's declared saves.
cr_h_saves_for() {
  python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); sid = sys.argv[2]
ext = {"video": "mp4", "image": "png", "json": "json", "text": "md"}
s = next((s for s in (o.get("manifest") or {}).get("steps", []) if s.get("id") == sid), {})
print(" ".join("%s.%s" % (v["id"], ext.get(v.get("kind"), "bin")) for v in s.get("saves") or []))' "$CR_H_ORDER_DIR/order.json" "$1"
}

# cr_h_run_checks <stepId> <workdir> <check-ids...> → prints checks JSON; rc 1 if any failed.
cr_h_run_checks() {
  local step_id="$1" workdir="$2"; shift 2
  local id script detail ok f failed=0 json="["
  for id in "$@"; do
    script="$CR_H_RECIPE_DIR/checks/$id.sh"
    detail=""; ok=1
    if [[ -f "$script" ]]; then
      detail="$(bash "$script" "$workdir" 2>&1 | tail -c 400)" || true
      bash "$script" "$workdir" >/dev/null 2>&1 || ok=0
    else
      for f in $(cr_h_saves_for "$step_id"); do
        [[ -s "$workdir/saves/$f" ]] || { ok=0; detail="missing or empty save $f"; }
      done
    fi
    (( ok )) || failed=1
    json+="$(python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1], "passed": sys.argv[2]=="1", **({"detail": sys.argv[3]} if sys.argv[3] else {})}))' "$id" "$ok" "$detail"),"
  done
  json="${json%,}]"
  printf '%s' "$json"
  (( failed )) && return 1
  return 0
}

# ---------------------------------------------------------------------------
cr_harness_run() {
  local order_file="$1" order_dir="$2" recipe_dir="$3"
  [[ -f "$order_file" ]] || { cr_log "harness: order file missing: $order_file"; return 1; }
  CR_H_ORDER_DIR="$order_dir"; CR_H_RECIPE_DIR="$recipe_dir"
  mkdir -p "$order_dir/steps" "$order_dir/logs"
  [[ "$order_file" -ef "$order_dir/order.json" ]] || cp "$order_file" "$order_dir/order.json"
  local meta engine resume_from
  meta="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))
print("\x1f".join([o.get("id") or "", (o.get("attempt") or {}).get("id") or "", o.get("resumeFromStepId") or ""]))' "$order_file")"
  IFS=$'\x1f' read -r CR_H_ORDER_ID CR_H_ATTEMPT_ID resume_from <<< "$meta"
  [[ -n "$CR_H_ORDER_ID" && -n "$CR_H_ATTEMPT_ID" ]] || { cr_log "harness: order/attempt id missing"; return 1; }
  engine="$(cr_engine_detect)"
  rm -f "$order_dir/directive" "$order_dir/pending-reports.ndjson"
  [[ -f "$order_dir/seq" ]] || printf '0' > "$order_dir/seq"

  # Step table: id, runsOn, maxCheckRetries, when-kind, when-arg, saves, checks
  local steps
  steps="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); resume = sys.argv[2]
ext = {"video": "mp4", "image": "png", "json": "json", "text": "md"}
started = not resume
for s in (o.get("manifest") or {}).get("steps", []):
    if s.get("id") == resume: started = True
    if not started: continue
    w = s.get("when", "always")
    wk, wa = "always", ""
    if isinstance(w, dict):
        if "inputPresent" in w: wk, wa = "inputPresent", w["inputPresent"]
        elif "alternative" in w: wk, wa = "alternative", w["alternative"]
    saves = " ".join("%s:%s" % (v["id"], ext.get(v.get("kind"), "bin")) for v in s.get("saves") or [])
    checks = " ".join(c["id"] for c in s.get("checks") or [])
    print("\x1f".join([s["id"], s.get("runsOn", "computer"), str(s.get("maxCheckRetries", 0)), wk, wa, saves, checks]))' "$order_file" "$resume_from")"

  cr_harness_heartbeat_start
  trap 'cr_harness_heartbeat_stop' RETURN

  local step_id runs_on max_retries when_kind when_arg saves checks rc cond p
  local -a completed_saves=()
  local final_outputs="[]"
  while IFS=$'\x1f' read -r step_id runs_on max_retries when_kind when_arg saves checks; do
    [[ -n "$step_id" ]] || continue
    [[ "$runs_on" == "computer" ]] || continue
    rc=0; cr_h_wait_pause || rc=$?
    if (( rc == 20 )); then cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20; fi
    (( rc == 21 )) && { cr_log "harness: pause timeout — releasing order $CR_H_ORDER_ID"; return 21; }

    cond=1
    case "$when_kind" in
      inputPresent) cond="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); v = (o.get("inputs") or {}).get(sys.argv[2])
print("1" if v else "0")' "$order_file" "$when_arg")" ;;
      alternative) cond="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); print("1" if (o.get("answers") or {}).get("alternative") == sys.argv[2] else "0")' "$order_file" "$when_arg")" ;;
    esac
    if [[ "$cond" != "1" ]]; then
      cr_h_report step_skipped "{\"stepId\":\"$step_id\",\"message\":\"condition not met\"}"
      continue
    fi

    local workdir="$order_dir/steps/$step_id" log="$order_dir/logs/$step_id.log"
    mkdir -p "$workdir/inputs" "$workdir/prior" "$workdir/saves"
    cr_h_stage_inputs "$workdir" "$order_file"
    for p in "${completed_saves[@]}"; do cp "$p" "$workdir/prior/" 2>/dev/null || true; done

    local run=0 checks_json="[]" passed=0 ask d waited
    while :; do
      run=$((run + 1))
      cr_h_report step_started "{\"stepId\":\"$step_id\"}"
      rm -f "$workdir/needs_input.json"
      cr_h_build_prompt "$step_id" "$workdir" "$order_file"
      CFW_STEP_SAVES="$saves" CFW_STEP_ID="$step_id" \
        cr_h_run_with_timeout "$CFW_RENDER_STEP_TIMEOUT_SEC" cr_engine_run "$engine" "$workdir/prompt.md" "$workdir" "$log" \
        || cr_log "harness: step $step_id engine exited nonzero (run $run)"

      if [[ -f "$workdir/needs_input.json" ]]; then
        ask="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$workdir/needs_input.json" 2>/dev/null || echo '{}')"
        cr_h_report needs_input "{\"stepId\":\"$step_id\",\"ask\":$ask}"
        if [[ "$(cr_h_directive)" == "not_implemented" ]]; then
          cr_log "harness: step $step_id asked for input but the server does not implement asks — failing attempt"
          cr_h_report step_failed "{\"stepId\":\"$step_id\",\"checks\":[{\"id\":\"needs_input\",\"passed\":false,\"detail\":\"asks not implemented\"}]}"
          cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"needs_input not implemented by server\"}"
          return 30
        fi
        waited=0
        while :; do
          d="$(cr_h_directive)"
          [[ "$d" == "cancel" ]] && { cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20; }
          [[ "$d" == "continue" ]] && break
          (( waited >= CFW_RENDER_PAUSE_MAX_SEC )) && return 21
          sleep 10; waited=$((waited + 10))
          cr_h_report heartbeat '{}'
        done
        run=$((run - 1))   # an answered ask reruns the step; not a check retry
        continue
      fi

      # shellcheck disable=SC2086
      if checks_json="$(cr_h_run_checks "$step_id" "$workdir" $checks)"; then passed=1; break; fi
      (( run > max_retries )) && break
      cr_log "harness: step $step_id checks failed (run $run/$((max_retries + 1))) — retrying"
    done

    if (( ! passed )); then
      cr_h_report step_failed "{\"stepId\":\"$step_id\",\"checks\":$checks_json}"
      cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"step $step_id failed its checks\"}"
      return 30
    fi

    local outputs="[" sv sid ext url f
    for sv in $saves; do
      sid="${sv%%:*}"; ext="${sv##*:}"; f="$workdir/saves/$sid.$ext"
      [[ -f "$f" ]] || continue
      if ! url="$(CFW_ORDER_ID="$CR_H_ORDER_ID" "$CR_H_SELF_DIR/cfw-render-upload.sh" "$f")"; then
        cr_log "harness: upload failed for $f"
        cr_h_report step_failed "{\"stepId\":\"$step_id\",\"checks\":[{\"id\":\"upload\",\"passed\":false,\"detail\":\"upload failed\"}]}"
        cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"upload failed\"}"
        return 30
      fi
      outputs+="$(python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1], "url": sys.argv[2]}))' "$sid" "$url"),"
      completed_saves+=("$f")
      final_outputs="$(python3 -c 'import json,sys; a=[x for x in json.loads(sys.argv[1]) if x["id"]!=sys.argv[2]]; a.append({"id":sys.argv[2],"url":sys.argv[3],"path":sys.argv[4]}); print(json.dumps(a))' "$final_outputs" "$sid" "$url" "$f")"
    done
    outputs="${outputs%,}]"
    cr_h_report step_completed "{\"stepId\":\"$step_id\",\"outputs\":$outputs,\"checks\":$checks_json}"
    [[ "$(cr_h_directive)" == "cancel" ]] && { cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20; }
  done <<< "$steps"

  cr_h_report attempt_completed '{}'
  printf '%s\n' "$final_outputs"
  return 0
}
