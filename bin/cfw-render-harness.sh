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
# (pause timeout), 22 revoked, 23 superseded, 24 released for an engine usage
# limit [M3-01b], 30 step failed (attempt_failed reported), 1 bad input.
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
      attempt_superseded)
        # [M2-04] Another computer now runs this request (CONTRACTS §4): stop
        # at once, no further uploads or reports. The server's directive is
        # `cancel`; locally it is sharper than cancel, so it gets its own word.
        cr_log "harness: order $CR_H_ORDER_ID — attempt_superseded ($err) → stop immediately"
        directive="superseded" ;;
      order_not_held)
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
  if [[ -n "$directive" ]]; then
    local cur; cur="$(cr_h_directive)"
    # superseded / stop_after_step are sticky: a heartbeat's `continue` racing
    # in afterwards must not un-stop the attempt.
    if [[ "$cur" == "superseded" || ( "$cur" == "stop_after_step" && "$directive" != "superseded" ) ]]; then
      return 0
    fi
    printf '%s' "$directive" > "$CR_H_ORDER_DIR/directive"
  fi
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

# cr_h_report_lock / cr_h_report_unlock — one report at a time per order.
# The heartbeat subshell and the step loop both call cr_h_report; without this,
# one can be replaying (and rewriting) pending-reports.ndjson while the other
# appends to it, and a seq lands out of order after an outage (19f).
cr_h_report_lock() {
  local lock="$CR_H_ORDER_DIR/report.lock" tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1)); (( tries > 1200 )) && { rm -rf "$lock"; break; }   # 60 s: a dead holder
    sleep 0.05
  done
}
cr_h_report_unlock() { rmdir "$CR_H_ORDER_DIR/report.lock" 2>/dev/null || true; }

# cr_h_report <event> [extra-json] — the report() wrapper. Never fails.
cr_h_report() {
  cr_h_report_lock
  cr_h_report_locked "$@"
  local rc=$?
  cr_h_report_unlock
  return "$rc"
}

cr_h_report_locked() {
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

# cr_h_upload_with_retry <file> — the presign/PUT/complete trio has per-call
# retries, but a short CFW outage (the same one the report buffer absorbs) can
# span all of them; retry the whole upload with backoff before failing the step.
cr_h_upload_with_retry() {
  local f="$1" url="" attempt
  local max="${CFW_RENDER_UPLOAD_ATTEMPTS:-4}"
  for (( attempt = 1; attempt <= max; attempt++ )); do
    if url="$(CFW_ORDER_ID="$CR_H_ORDER_ID" "$CR_H_SELF_DIR/cfw-render-upload.sh" "$f")" && [[ -n "$url" ]]; then
      printf '%s' "$url"; return 0
    fi
    (( attempt < max )) && sleep $(( attempt * 2 ))
  done
  return 1
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
# changes. Returns 0 to continue, 20 cancel, 21 pause timeout, 22 stop_after_step
# (release before the next step), 23 superseded.
cr_h_wait_pause() {
  local waited=0 d
  while :; do
    d="$(cr_h_directive)"
    case "$d" in
      cancel) return 20 ;;
      stop_after_step) return 22 ;;
      superseded) return 23 ;;
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
ans = o.get("answers") or {}
if isinstance(ans, list):  # CONTRACTS §7 array → {inputId: text}
    ans = {x.get("inputId"): x.get("text") for x in ans if isinstance(x, dict) and x.get("inputId")}
print("Answers:\n```json\n" + json.dumps(ans) + "\n```\n")
fb = o.get("feedback")
if fb: print("Feedback:\n" + str(fb) + "\n")
print("Prior saves:\n" + listing(os.path.join(wd, "prior")) + "\n")
print("## You must produce\n")
for sv in s.get("saves") or []:
    print(f"- saves/{sv['id']}.{ext.get(sv.get('kind'), 'bin')} ({sv.get('kind')})")
PY
}

# CR_H_CLAIM_PY — python prelude: `inputs_of(o)` / `answers_of(o)` read the
# claim's owner files and answers as dicts. CFW sends the CONTRACTS §7 arrays
# (`inputs: [{inputId, items:[{kind,url}]}]`, `answers: [{inputId, text}]`);
# fixtures and older servers send dicts — both work.
CR_H_CLAIM_PY='
def inputs_of(o):
    v = o.get("inputs") or {}
    if isinstance(v, list):
        out = {}
        for x in v:
            if isinstance(x, dict) and x.get("inputId"):
                out.setdefault(x["inputId"], []).extend(x.get("items") or [])
        return out
    return v if isinstance(v, dict) else {}
def answers_of(o):
    v = o.get("answers") or {}
    if isinstance(v, list):
        return {x["inputId"]: x.get("text") for x in v if isinstance(x, dict) and x.get("inputId")}
    return v if isinstance(v, dict) else {}
'

# cr_h_input_present <order-file> <inputId> → 1 when the claim carries files for it.
cr_h_input_present() {
  python3 -c "$CR_H_CLAIM_PY"'
import json, sys
o = json.load(open(sys.argv[1])); print("1" if inputs_of(o).get(sys.argv[2]) else "0")' "$1" "$2"
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
  done < <(python3 -c "$CR_H_CLAIM_PY"'
import json, sys
o = json.load(open(sys.argv[1]))
for k, v in inputs_of(o).items():
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

# [M2-04] cr_h_release_revoked <stepId> — stop_after_step landed: report the
# attempt as released (reason revoked, CONTRACTS §4) and let the caller wipe.
cr_h_release_revoked() {
  local step_id="$1"
  cr_log "harness: order $CR_H_ORDER_ID — stop_after_step: releasing after step $step_id (revoked)"
  cr_h_report attempt_released "{\"stepId\":\"$step_id\",\"reason\":\"revoked\"}"
  return 0
}

# [M2-04] cr_h_restore_saved_outputs <order-file> <order-dir> — resume (D30).
# Downloads each claim-reply savedOutputs[{stepId, saveId, url, checksum?}]
# into <order-dir>/steps/<stepId>/saves/<saveId>.<ext> (ext from the manifest
# step's save kind, as the step itself would have written). Verifies non-empty
# and the checksum when given ("sha256:<hex>", "md5:<hex>", or a bare hex
# digest sized for either). Writes:
#   <order-dir>/resume-restored.txt   one restored path per line
#   <order-dir>/resume-missing.txt    "stepId/saveId" tokens, space-separated
cr_h_restore_saved_outputs() {
  local order_file="$1" order_dir="$2" line step_id save_id url checksum ext dest rc missing=""
  : > "$order_dir/resume-restored.txt"; : > "$order_dir/resume-missing.txt"
  while IFS=$'\x1f' read -r step_id save_id url checksum ext; do
    [[ -n "$step_id" && -n "$save_id" ]] || continue
    dest="$order_dir/steps/$step_id/saves/$save_id.$ext"
    mkdir -p "$(dirname "$dest")"
    rc=0
    if [[ -z "$url" ]]; then
      rc=1
    else
      curl -fsSL --retry 2 --retry-delay 1 --max-time 600 -o "$dest" "$url" 2>/dev/null || rc=$?
    fi
    if (( rc == 0 )) && [[ -s "$dest" ]] && cr_h_checksum_ok "$dest" "$checksum"; then
      printf '%s\n' "$dest" >> "$order_dir/resume-restored.txt"
    else
      cr_log "harness: order $CR_H_ORDER_ID — saved output $step_id/$save_id unusable (download rc=$rc, empty or checksum mismatch): $url"
      rm -f "$dest"
      missing+="${missing:+ }$step_id/$save_id"
    fi
  done < <(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))
ext = {"video": "mp4", "image": "png", "json": "json", "text": "md"}
kinds = {}
for s in (o.get("manifest") or {}).get("steps", []):
    for v in s.get("saves") or []:
        kinds[(s["id"], v["id"])] = ext.get(v.get("kind"), "bin")
for so in o.get("savedOutputs") or []:
    if not isinstance(so, dict): continue
    sid, vid = so.get("stepId") or "", so.get("saveId") or ""
    print("\x1f".join([sid, vid, so.get("url") or "", so.get("checksum") or "", kinds.get((sid, vid), "bin")]))' "$order_file")
  printf '%s' "$missing" > "$order_dir/resume-missing.txt"
  [[ -z "$missing" ]]
}

# cr_h_checksum_ok <file> <checksum> — empty checksum = nothing to verify.
cr_h_checksum_ok() {
  local f="$1" want="${2:-}" algo hex got
  [[ -n "$want" ]] || return 0
  want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  case "$want" in
    sha256:*) algo=sha256; hex="${want#sha256:}" ;;
    md5:*) algo=md5; hex="${want#md5:}" ;;
    *) hex="$want"; if (( ${#hex} == 64 )); then algo=sha256; elif (( ${#hex} == 32 )); then algo=md5; else return 1; fi ;;
  esac
  got="$(python3 -c 'import hashlib, sys; print(getattr(hashlib, sys.argv[1])(open(sys.argv[2], "rb").read()).hexdigest())' "$algo" "$f" 2>/dev/null)" || return 1
  [[ "$got" == "$hex" ]]
}

# [M3-01c] cr_h_write_current_step <orderDir> <stepId> <engine> — the status
# file's `now` entry; removed when the step ends. startedAt = CR_H_STARTED_AT.
cr_h_write_current_step() {
  python3 -c '
import json, sys
d, sid, eng, started = sys.argv[1:5]
o = json.load(open(d + "/order.json")); m = o.get("manifest") or {}
cs = [s for s in m.get("steps", []) if s.get("runsOn", "computer") == "computer"]
idx = next((i for i, s in enumerate(cs) if s.get("id") == sid), 0)
def w(s):
    try: return float(s.get("weight") or 0)
    except Exception: return 0.0
tot = sum(w(s) for s in cs)
pct = int(sum(w(s) for s in cs[:idx]) / tot * 100) if tot > 0 else 0
json.dump({"orderId": o.get("id"), "shortCode": o.get("shortCode"), "brand": o.get("brandName"),
           "recipe": m.get("label"), "step": idx + 1, "steps": len(cs),
           "stepLabel": (cs[idx].get("label") if cs else None), "pct": pct,
           "startedAt": started or None, "engine": eng},
          open(d + "/current-step.json", "w"))
' "$@" "${CR_H_STARTED_AT:-}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
cr_harness_run() {
  local order_file="$1" order_dir="$2" recipe_dir="$3"
  [[ -f "$order_file" ]] || { cr_log "harness: order file missing: $order_file"; return 1; }
  CR_H_ORDER_DIR="$order_dir"; CR_H_RECIPE_DIR="$recipe_dir"
  CR_H_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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

  # [M2-04] Resume (D30): pull every savedOutput into the path the step would
  # have written it to, verify it, and remember what is missing so the first
  # step we run can fail with a reason the server can act on.
  local -a completed_saves=()
  local resume_missing=""
  if [[ -n "$resume_from" ]]; then
    cr_h_restore_saved_outputs "$order_file" "$order_dir" || true
    while IFS= read -r p; do [[ -n "$p" ]] && completed_saves+=("$p"); done < "$order_dir/resume-restored.txt"
    resume_missing="$(cat "$order_dir/resume-missing.txt" 2>/dev/null || true)"
    cr_log "harness: order $CR_H_ORDER_ID resumes at $resume_from (${#completed_saves[@]} saved output(s) restored${resume_missing:+; missing: $resume_missing})"
  fi

  cr_harness_heartbeat_start
  # shellcheck disable=SC2064
  trap "cr_harness_heartbeat_stop; rm -f '$order_dir/current-step.json'" RETURN

  local step_id runs_on max_retries when_kind when_arg saves checks rc cond p
  local final_outputs="[]"
  while IFS=$'\x1f' read -r step_id runs_on max_retries when_kind when_arg saves checks; do
    [[ -n "$step_id" ]] || continue
    [[ "$runs_on" == "computer" ]] || continue
    rc=0; cr_h_wait_pause || rc=$?
    if (( rc == 20 )); then cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20; fi
    (( rc == 21 )) && { cr_log "harness: pause timeout — releasing order $CR_H_ORDER_ID"; return 21; }
    (( rc == 22 )) && { cr_h_release_revoked "$step_id"; return 22; }
    (( rc == 23 )) && return 23

    if [[ -n "$resume_missing" ]]; then
      # The first step that runs is the first that needs the earlier saves.
      local miss_checks="[" miss_step
      for miss_step in $resume_missing; do
        miss_checks+="$(python3 -c 'import json,sys; print(json.dumps({"id": "saved_output:" + sys.argv[1], "passed": False, "detail": "Saved result from step %s is missing" % sys.argv[1].split("/")[0]}))' "$miss_step"),"
      done
      miss_checks="${miss_checks%,}]"
      local first_missing="${resume_missing%% *}"; first_missing="${first_missing%%/*}"
      cr_h_report step_failed "{\"stepId\":\"$step_id\",\"message\":\"Saved result from step $first_missing is missing\",\"checks\":$miss_checks}"
      cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"Saved result from step $first_missing is missing\"}"
      return 30
    fi

    cond=1
    case "$when_kind" in
      inputPresent) cond="$(cr_h_input_present "$order_file" "$when_arg")" ;;
      alternative) cond="$(python3 -c "$CR_H_CLAIM_PY"'
import json, sys
o = json.load(open(sys.argv[1])); print("1" if answers_of(o).get("alternative") == sys.argv[2] else "0")' "$order_file" "$when_arg")" ;;
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
    # [M3-01b] Engine failover (D107/D109): each engine is tried at most once
    # per step; a usage-limit message moves the step to the next engine.
    local tried=" " limit_until next_engine log_from
    while :; do
      run=$((run + 1))
      tried+="$engine "
      cr_h_report step_started "{\"stepId\":\"$step_id\",\"engine\":\"$engine\"}"
      cr_h_write_current_step "$order_dir" "$step_id" "$engine"
      rm -f "$workdir/needs_input.json"
      cr_h_build_prompt "$step_id" "$workdir" "$order_file"
      rc=0; log_from=0
      [[ -f "$log" ]] && log_from="$(wc -c < "$log" | tr -d ' ')"
      CFW_STEP_SAVES="$saves" CFW_STEP_ID="$step_id" \
        cr_h_run_with_timeout "$CFW_RENDER_STEP_TIMEOUT_SEC" cr_engine_run "$engine" "$workdir/prompt.md" "$workdir" "$log" \
        || { rc=$?; cr_log "harness: step $step_id engine exited nonzero (run $run)"; }

      if limit_until="$(cr_engine_limit_detect "$engine" "$log" "$rc" "$log_from")"; then
        cr_engine_limit_set "$engine" "$limit_until"
        cr_log "harness: $engine hit its limit (resets $limit_until) — trying next engine"
        next_engine="$(cr_engine_active)"
        if [[ "$next_engine" == "none" || "$tried" == *" $next_engine "* ]]; then
          rm -f "$order_dir/current-step.json"
          cr_h_report attempt_released "{\"stepId\":\"$step_id\",\"reason\":\"engine_limit\"}"
          local earliest; earliest="$(cr_engine_limit_earliest)"
          # [M3-08b] An out-of-credit engine has no reset: send no `until`.
          local lim_args="{\"engine\":\"$engine\",\"until\":\"${earliest:-$limit_until}\"}"
          [[ -z "$earliest" && "$limit_until" == credit ]] && lim_args="{\"engine\":\"$engine\"}"
          cr_mcp_call_soft set_computer_limit "$lim_args" >/dev/null 2>&1 \
            || cr_log "harness: set_computer_limit failed (ignored)"
          return 24
        fi
        engine="$next_engine"
        run=$((run - 1))   # an engine switch is not a check retry
        continue
      fi

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
          [[ "$d" == "superseded" ]] && return 23
          [[ "$d" == "stop_after_step" ]] && { cr_h_release_revoked "$step_id"; return 22; }
          [[ "$d" == "continue" ]] && break
          (( waited >= CFW_RENDER_PAUSE_MAX_SEC )) && return 21
          sleep 10; waited=$((waited + 10))
          cr_h_report heartbeat '{}'
        done
        run=$((run - 1))   # an answered ask reruns the step; not a check retry
        continue
      fi

      # shellcheck disable=SC2086
      if checks_json="$(cr_h_run_checks "$step_id" "$workdir" $checks)"; then
        passed=1
        # [M3-01b] A step that passed on this engine proves its limit is over.
        if [[ -n "$(cr_engine_limit_until "$engine")" ]]; then
          cr_engine_limit_clear "$engine"
          [[ -z "$(cr_engine_limit_earliest)" ]] && { cr_mcp_call_soft set_computer_limit '{"until":null}' >/dev/null 2>&1 || cr_log "harness: set_computer_limit clear failed (ignored)"; }
        fi
        break
      fi
      (( run > max_retries )) && break
      cr_log "harness: step $step_id checks failed (run $run/$((max_retries + 1))) — retrying"
    done

    # [M2-04] attempt_superseded (set by any report/heartbeat reply) → stop
    # now, before a single upload. Nothing else is sent.
    [[ "$(cr_h_directive)" == "superseded" ]] && return 23

    if (( ! passed )); then
      cr_h_report step_failed "{\"stepId\":\"$step_id\",\"checks\":$checks_json}"
      cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"step $step_id failed its checks\"}"
      return 30
    fi

    local outputs="[" sv sid ext url f
    for sv in $saves; do
      sid="${sv%%:*}"; ext="${sv##*:}"; f="$workdir/saves/$sid.$ext"
      [[ -f "$f" ]] || continue
      if ! url="$(cr_h_upload_with_retry "$f")"; then
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
    rm -f "$order_dir/current-step.json"
    cr_h_report step_completed "{\"stepId\":\"$step_id\",\"outputs\":$outputs,\"checks\":$checks_json}"
    case "$(cr_h_directive)" in
      cancel) cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20 ;;
      # [M2-04] D76: the step finished and its saves are up; end the attempt
      # here as revoked. The caller deletes the folder and held keys.
      stop_after_step) cr_h_release_revoked "$step_id"; return 22 ;;
      superseded) return 23 ;;
    esac
  done <<< "$steps"

  cr_h_report attempt_completed '{}'
  printf '%s\n' "$final_outputs"
  return 0
}
