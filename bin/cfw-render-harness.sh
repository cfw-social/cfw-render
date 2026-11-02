#!/usr/bin/env bash
# cfw-render-harness.sh — [M1-08 slice c] the manifest step loop.
#
# `cr_harness_run <order-json-file> <order-dir> <recipe-dir>` walks the claimed
# order's `manifest.steps` (computer steps only, from `resumeFromStepId`), runs
# each one through cr_engine_run, verifies its saves, uploads them, and reports
# every transition to cfw-social via report_render_step.
#
# Layout (pinned, shared with the recipe step files):
#   $ORDER_DIR/steps/<stepId>/inputs/<inputId>/   files from the claim's `inputs`,
#                                                 and the owner's typed `answers`
#                                                 as <inputId>/<inputId>.md (B13)
#   $ORDER_DIR/steps/<stepId>/prior/<saveId>.<ext> earlier steps' saves (copied)
#   $ORDER_DIR/steps/<stepId>/saves/<saveId>.<ext> what the step must write
#   $ORDER_DIR/steps/<stepId>/brief.json           order brief (no secrets or provider keys)
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
# final_checks: when the agent refused (its own block/refuse verdict in this
# run's log), a missing-save line is replaced by the finding, first 500
# characters. A check script and a local validator keep their own detail.
# No refusal, and a redactor failure, keep the missing-save text.
#
# Return codes of cr_harness_run: 0 completed, 20 cancelled, 21 released
# (pause timeout, or an answered ask handed back so the next claim carries the
# answer, B13), 22 revoked, 23 superseded, 24 released for an engine usage
# limit [M3-01b], 25 nonfinal stage completed (no Composition),
# 30 step failed (attempt_failed reported), 31 local recovery blocked, 1 bad input.
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
CR_H_LOCAL=0
CR_H_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Durable, attempt-scoped reports. A lost acknowledgement must be replayed at
# its original sequence before any further engine work.
cr_h_checkpoint() {
  python3 "$CR_H_SELF_DIR/cfw-render-checkpoint.py" "$1" "$CR_H_ORDER_DIR" "$CFW_WORKER_ID" "${@:2}"
}

cr_h_local_replay() {
  local pending seq event extra reply
  pending="$(cr_h_checkpoint pending)" || return 31
  while IFS=$'\x1f' read -r seq event extra; do
    [[ -n "$seq" ]] || continue
    if ! reply="$(cr_report_step "$CR_H_ORDER_ID" "$CFW_WORKER_ID" "$CR_H_ATTEMPT_ID" "$seq" "$event" "$extra")"; then
      printf report_blocked > "$CR_H_ORDER_DIR/directive"; return 31
    fi
    cr_h_handle_reply "$reply" "$event"
    case "$(cr_h_directive)" in superseded) return 23 ;; stop_after_step) return 22 ;; cancel) return 20 ;; esac
    if ! python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("ok") is True else 1)' "$reply"; then
      printf report_blocked > "$CR_H_ORDER_DIR/directive"; return 31
    fi
    cr_h_checkpoint ack "$seq" >/dev/null || return 31
  done < <(python3 -c 'import json,sys
for r in json.loads(sys.argv[1]): print("\x1f".join([str(r["seq"]),r["event"],json.dumps(r["extra"])]))' "$pending")
}

cr_h_local_blocked() {
  cr_log "harness: local checkpoint unavailable or invalid; full restart required"
  cr_h_report attempt_failed '{"message":"Local checkpoint is missing, changed or incompatible. Restart the entire recipe to continue."}'
  return 31
}

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
print("\x1f".join([str(d.get("directive") or ""), "1" if d.get("ok") is True else "0", str(d.get("code") or ""), str(d.get("error") or "")]))
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
  if [[ "$event" == "attempt_completed" && "$ok" == "1" ]]; then
    : > "$CR_H_ORDER_DIR/attempt-completed-ack"
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
    tries=$((tries + 1))
    if (( tries > 1200 )); then
      if (( CR_H_LOCAL )); then return 31; fi
      rm -rf "$lock"; break
    fi
    sleep 0.05
  done
}
cr_h_report_unlock() { rmdir "$CR_H_ORDER_DIR/report.lock" 2>/dev/null || true; }

# cr_h_refuse_step <event> <extra-json> — Social refused report_render_step.
# End this step as failed and carry the refusal text on step_failed and
# attempt_failed. Do not report a failure report again (that loops). A
# heartbeat stays best-effort so a background pulse cannot fail the step.
cr_h_refuse_step() {
  local event="$1" extra="${2:-{\}}"
  case "$event" in
    heartbeat|step_failed|attempt_failed|attempt_cancelled|attempt_released) return 0 ;;
  esac
  local refusal="" step_id="" fail_msg=""
  [[ -f "$CR_H_ORDER_DIR/report-refusal.txt" ]] && refusal="$(cat "$CR_H_ORDER_DIR/report-refusal.txt")"
  step_id="$(python3 -c 'import json,sys
try:
    extra = json.loads(sys.argv[1])
except Exception:
    extra = {}
if not isinstance(extra, dict):
    extra = {}
print(extra.get("stepId") or "")' "$extra" 2>/dev/null)" || step_id=""
  fail_msg="$(python3 -c 'import json,sys
step, event, refusal = sys.argv[1], sys.argv[2], sys.argv[3]
text = refusal.replace("\n", " ").strip()
if len(text) > 400:
    text = text[:400]
msg = "report %s refused: %s" % (event, text)
body = {"message": msg}
if step:
    body["stepId"] = step
print(json.dumps(body))' "$step_id" "$event" "$refusal" 2>/dev/null)" || return 0
  if [[ -n "$step_id" ]]; then
    cr_h_report step_failed "$fail_msg" || true
  fi
  cr_h_report attempt_failed "$fail_msg" || true
  return 0
}

# cr_h_report <event> [extra-json] — legacy buffers; local fails on unacknowledged reports.
cr_h_report() {
  cr_h_report_lock || return $?
  local rc=0
  cr_h_report_locked "$@" || rc=$?
  cr_h_report_unlock
  # rc 30 is a refused report. Record the failure after the lock is released
  # so the failure reports can take the same lock. Callers return this rc
  # and must not treat the step as answered.
  if (( rc == 30 )); then
    cr_h_refuse_step "$1" "${2:-{\}}"
    return 30
  fi
  return "$rc"
}

cr_h_report_locked() {
  local event="$1" extra="${2:-{\}}" seq reply rc=0
  if (( CR_H_LOCAL )); then
    if ! cr_h_checkpoint enqueue "$event" "$extra" >/dev/null; then
      printf report_blocked > "$CR_H_ORDER_DIR/directive"; return 31
    fi
    cr_h_local_replay
    return $?
  fi
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
    # A tool error is a refusal, not an outage (rc 75 is the outage). Leaving
    # directive at `continue` from step_started makes the needs_input wait
    # treat the refusal as an answered ask and rerun the step. Stop instead.
    # Heartbeats stay best-effort and must not change the directive.
    if [[ "$event" == "heartbeat" ]]; then
      return 0
    fi
    printf '%s' "$reply" > "$CR_H_ORDER_DIR/report-refusal.txt"
    printf 'blocked' > "$CR_H_ORDER_DIR/directive"
    return 30
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
      report_blocked) return 31 ;;
      blocked) return 30 ;;
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
  local wait_file recipe kind
  [[ "$secs" =~ ^[1-9][0-9]{0,4}$ ]] && (( secs <= 86400 )) || return 1
  IFS=$'\t' read -r recipe kind <<< "$(python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); print(str(o.get("recipe") or "") + "\t" + str(o.get("kind") or "video"))' "$CR_H_ORDER_DIR/order.json")"
  secs="$(cr_recipe_budget "$secs" "$recipe" "$kind")"
  wait_file="$(mktemp "$CR_H_ORDER_DIR/provider-wait.XXXXXX")" || return 1
  local monitor=0
  [[ "$-" == *m* ]] && monitor=1
  set -m
  CFW_RENDER_WAIT_FILE="$wait_file" CFW_RENDER_SCRATCH_DIR="$CR_H_ORDER_DIR" "$@" & local pid=$!
  (( monitor )) || set +m
  cr_budget_watchdog "$pid" "$secs" "$wait_file" "$CR_H_ORDER_DIR" "$CR_H_ORDER_DIR/directive" "$CR_H_LOCAL" >/dev/null 2>&1 & local killer=$!
  local rc=0
  wait "$pid" || rc=$?
  # The recorded, testable engine process group owns any surviving children.
  # Do this before stopping the watchdog, whose delayed KILL may not run.
  kill -KILL -- "-$pid" 2>/dev/null || true
  cr_kill_tree "$killer" TERM || true
  wait "$killer" 2>/dev/null || true
  case "$(cr_h_directive)" in
    cancel) return 20 ;; superseded) return 23 ;;
    stop_after_step) if (( CR_H_LOCAL )); then return 22; fi ;;
    report_blocked) if (( CR_H_LOCAL )); then return 31; fi ;;
  esac
  if (( rc == 137 || rc == 143 )); then : > "$CR_H_ORDER_DIR/.retain-artifacts"; fi
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
ext = {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}
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
  # Standalone prompt inspections can source the harness without the worker lib.
  if declare -F cr_provider_wait_note >/dev/null; then cr_provider_wait_note >> "$prompt"; fi
  # Spotlight local evidence only. Loudness is sealed by cr_h_seal_prior_loudness
  # before this prompt is built; the agent is not asked to loudnorm.
  if (( CR_H_LOCAL )) && [[ "$step_id" == "assemble" || "$step_id" == "prepare_footage" || "$step_id" == "final_checks" ]] \
    && [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"]["recipe"])' "$order_file")" == p-reels-spotlight ]]; then
    python3 "$CR_H_SELF_DIR/cfw-render-checks.py" instructions "$CR_H_RECIPE_DIR" "$step_id" local >> "$prompt"
  fi
}

# cr_h_write_brief <workdir> <order-file> — step workdir/brief.json.
# Fields the recipe steps read: recipe, intent, targets, brand (slug, name,
# palette/typography when present, brief text, optional imageStyle, and
# heygen/elevenlabs ids when the brand has them) and options. Credentials
# and provider keys are left in order.json; they are not copied here.
cr_h_write_brief() {
  python3 - "$2" "$1/brief.json" <<'PY'
import json, sys

def as_dict(value):
    return value if isinstance(value, dict) else {}

def text(value):
    return value if isinstance(value, str) and value else None

def secret_key(key):
    folded = str(key).lower().replace("-", "").replace("_", "")
    return any(part in folded for part in (
        "token", "secret", "password", "credential", "apikey", "privatekey",
        "authorization", "providerkey", "workerkey"))

def scrub(value):
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items() if not secret_key(key)}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    return value

def id_value(block, *names):
    block = as_dict(block)
    for name in names:
        found = text(block.get(name))
        if found:
            return found
    return None

order = json.load(open(sys.argv[1]))
task = as_dict(order.get("taskOrder"))
manifest = as_dict(order.get("manifest"))
brand_src = as_dict(task.get("brand")) or as_dict(order.get("brand"))
recipe = text(task.get("recipe")) or text(order.get("recipe")) or text(manifest.get("recipe")) or ""
intent = text(task.get("intent"))
if intent is None:
    intent = text(order.get("intent")) or ""
raw_targets = task.get("targets")
if not isinstance(raw_targets, list):
    raw_targets = order.get("targets") if isinstance(order.get("targets"), list) else []
fonts = brand_src.get("fonts") if isinstance(brand_src.get("fonts"), dict) else None
typography = brand_src.get("typography") if isinstance(brand_src.get("typography"), dict) else fonts
brand = {}
slug = text(brand_src.get("slug")) or text(order.get("brandSlug"))
name = text(brand_src.get("name")) or text(order.get("brandName"))
brief_text = text(brand_src.get("brief"))
image_style = text(brand_src.get("imageStyle"))
if slug:
    brand["slug"] = slug
if name:
    brand["name"] = name
if brief_text:
    brand["brief"] = brief_text
if isinstance(brand_src.get("palette"), dict):
    brand["palette"] = scrub(brand_src["palette"])
if isinstance(typography, dict):
    brand["typography"] = scrub(typography)
if isinstance(fonts, dict):
    brand["fonts"] = scrub(fonts)
if image_style:
    brand["imageStyle"] = image_style
heygen = {}
avatar = id_value(brand_src.get("heygen"), "avatarId", "avatar_id")
voice = id_value(brand_src.get("heygen"), "voiceId", "voice_id")
if avatar:
    heygen["avatarId"] = avatar
if voice:
    heygen["voiceId"] = voice
if heygen:
    brand["heygen"] = heygen
eleven_voice = id_value(brand_src.get("elevenlabs"), "voiceId", "voice_id")
if eleven_voice:
    brand["elevenlabs"] = {"voiceId": eleven_voice}
options = task.get("options")
if not isinstance(options, dict):
    options = order.get("options") if isinstance(order.get("options"), dict) else {}
brief = {
    "recipe": recipe,
    "intent": intent,
    "targets": [item for item in raw_targets if isinstance(item, str)],
    "brand": brand,
    "options": scrub(options),
}
with open(sys.argv[2], "w") as handle:
    json.dump(brief, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
}

# Shared claim parser for staging and conditions. Social sends inputs as
# [{inputId, items:[{kind,url}]}] and answers as [{inputId, text}]. Keep legacy
# dict values unchanged (including their condition truthiness). Missing/null
# collections are empty; malformed collections must not become a false condition.
CR_H_CLAIM_PY='
def claim_values(order, field):
    raw = order.get(field)
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, list):
        raise ValueError("invalid claim collection")
    values = {}
    for entry in raw:
        if not isinstance(entry, dict):
            raise ValueError("invalid claim entry")
        key = entry.get("inputId")
        if not isinstance(key, str) or not key:
            raise ValueError("invalid claim inputId")
        if field == "inputs":
            items = entry.get("items")
            if not isinstance(items, list):
                raise ValueError("invalid claim items")
            values.setdefault(key, []).extend(items)
        else:
            text = entry.get("text")
            if not isinstance(text, str):
                raise ValueError("invalid claim answer text")
            values[key] = text
    return values
'

# cr_h_condition <order-file> <kind> <arg> — print 0/1, or fail to evaluate.
cr_h_condition() {
  python3 -c "$CR_H_CLAIM_PY"'
import json, sys
try:
    with open(sys.argv[1]) as source:
        order = json.load(source)
    if not isinstance(order, dict):
        raise ValueError("invalid claim")
    kind, arg = sys.argv[2:4]
    if kind == "always":
        matched = True
    elif kind == "inputPresent":
        matched = bool(claim_values(order, "inputs").get(arg))
    elif kind == "alternative":
        matched = claim_values(order, "answers").get("alternative") == arg
    else:
        raise ValueError("invalid condition kind")
    print("1" if matched else "0")
except (OSError, ValueError, TypeError):
    print("harness: invalid condition data", file=sys.stderr)
    sys.exit(1)
' "$1" "$2" "$3"
}

# Brand API keys live only in the engine subshell. Never inherit recipe keys
# from the worker, derive env names from claim data, or treat HeyGen OAuth in
# taskOrder.credentials as an API key. The NUL stream ends with a success marker:
# a failed/truncated parser cannot silently start an engine with partial keys.
cr_h_export_step_keys() {
  { set +x; } 2>/dev/null
  local order_file="$1" step_id="$2" name value ready=0
  unset HEYGEN_API_KEY ELEVENLABS_API_KEY KIE_AI_API_KEY GEMINI_API_KEY FAL_KEY REPLICATE_API_TOKEN || return 1
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    case "$name" in
      HEYGEN_API_KEY|ELEVENLABS_API_KEY|KIE_AI_API_KEY|GEMINI_API_KEY|FAL_KEY|REPLICATE_API_TOKEN)
        (( ready == 0 )) && [[ -n "$value" ]] || return 1
        export "$name=$value" || return 1 ;;
      __CFW_KEYS_OK__)
        (( ready == 0 )) && [[ -z "$value" ]] || return 1
        ready=1 ;;
      *) return 1 ;;
    esac
  done < <(python3 - "$order_file" "$step_id" <<'PY'
import datetime, json, sys

ENV = {"heygen": "HEYGEN_API_KEY", "elevenlabs": "ELEVENLABS_API_KEY",
       "kie": "KIE_AI_API_KEY", "gemini": "GEMINI_API_KEY", "fal": "FAL_KEY",
       "replicate": "REPLICATE_API_TOKEN"}
try:
    with open(sys.argv[1]) as source:
        order = json.load(source)
    if not isinstance(order, dict) or not isinstance(order.get("manifest"), dict):
        raise ValueError("invalid claim")
    steps = order["manifest"].get("steps")
    if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
        raise ValueError("invalid steps")
    matches = [s for s in steps if s.get("id") == sys.argv[2]]
    if len(matches) != 1:
        raise ValueError("invalid step")
    step = matches[0]
    allowed = set(ENV)
    if "uses" in step:
        uses = step["uses"]
        if not isinstance(uses, dict):
            raise ValueError("invalid uses")
        groups, optional = uses.get("providers", []), uses.get("optionalProviders", [])
        if (not isinstance(groups, list) or not isinstance(optional, list)
                or any(not isinstance(g, list) or not g for g in groups)):
            raise ValueError("invalid provider groups")
        providers = [p for group in groups for p in group] + optional
        if any(not isinstance(p, str) or not p for p in providers):
            raise ValueError("invalid provider name")
        allowed = set(providers)
    keys = order.get("providerKeys", [])
    if not isinstance(keys, list):
        raise ValueError("invalid provider keys")
    delivered = {}
    now = datetime.datetime.now(datetime.timezone.utc)
    for key in keys:
        if not isinstance(key, dict):
            raise ValueError("invalid provider key")
        provider, value = key.get("provider"), key.get("value")
        if (not isinstance(provider, str) or provider not in ENV or provider in delivered
                or not isinstance(value, str) or not value.strip() or "\x00" in value):
            raise ValueError("invalid provider key")
        if "expiresAt" in key:
            expires = key["expiresAt"]
            if not isinstance(expires, str):
                raise ValueError("invalid key expiry")
            expiry = datetime.datetime.fromisoformat(expires.replace("Z", "+00:00"))
            if expiry.tzinfo is None or expiry <= now:
                raise ValueError("expired provider key")
        delivered[provider] = value
    # Validate the entire claim before emitting any secret bytes.
    output = bytearray()
    for provider in sorted(delivered):
        if provider in allowed:
            output.extend(ENV[provider].encode() + b"\x00" + delivered[provider].encode() + b"\x00")
    output.extend(b"__CFW_KEYS_OK__\x00\x00")
except (OSError, ValueError, TypeError):
    print("harness: invalid provider key claim", file=sys.stderr)
    sys.exit(1)
sys.stdout.buffer.write(output)
PY
)
  [[ "$ready" == 1 ]]
}

# cr_h_stage_inputs <workdir> <order-file> — copy/download claim inputs.
# A plain-text value (not an http(s) URL and not an existing path) is written
# as UTF-8 to inputs/<name>/<name>.md. A JSON number or boolean is written
# the same way, as text (3, true, false), including 0 and false. URL and path
# values stay on the copy/download path below. The text is taken from JSON;
# it is never eval'd. An input name containing / or .. is refused so a staged
# file cannot land outside inputs/.
# Social sends inputs as a list: [{inputId, items:[{kind, url}]}]. inputId is
# the input name. Each item is staged the same way as a dict value. The older
# dict form {name: value} still works. An empty list stages nothing.
# B13: Social sends a typed (text) answer only in the claim's `answers`
# ([{inputId, text}], claim-inputs.ts), never in `inputs`. Each answer is
# written to inputs/<inputId>/<inputId>.md, the same file a typed `inputs`
# value gets, so a step that reads inputs/<name>/ finds it and does not ask
# again. An input that `inputs` already supplied is left alone, an empty or
# blank answer is skipped, and `alternative` stays a condition value (it is
# not a step input). An answer name containing / or .. is refused like an
# input name.
cr_h_stage_inputs() {
  local workdir="$1" order_file="$2" iid src dest list err py_rc=0
  cr_h_write_brief "$workdir" "$order_file" || return 1
  list="$(mktemp)"
  err="$(mktemp)"
  python3 -c "$CR_H_CLAIM_PY"'
import json, os, sys
workdir, order_path = sys.argv[1], sys.argv[2]
order = json.load(open(order_path))
refused = False

def name_refused(name):
    text = str(name)
    return "/" in text or ".." in text

def write_text(key, text):
    folder = os.path.join(workdir, "inputs", str(key))
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, str(key) + ".md"), "w", encoding="utf-8", newline="") as handle:
        handle.write(text)

supplied = set()
for key, value in claim_values(order, "inputs").items():
    if name_refused(key):
        print(key, file=sys.stderr)
        refused = True
        continue
    vals = value if isinstance(value, list) else [value]
    for item in vals:
        raw = (item.get("url") or item.get("path")) if isinstance(item, dict) else item
        if raw is None or raw == "":
            continue
        supplied.add(key)
        if isinstance(raw, str):
            if raw.startswith("http://") or raw.startswith("https://") or os.path.exists(raw):
                print(f"{key}\x1f{raw}")
                continue
            write_text(key, raw)
            continue
        if isinstance(raw, bool) or isinstance(raw, (int, float)):
            write_text(key, json.dumps(raw))
            continue
        print(f"{key}\x1f{raw}")

# B13: typed answers ride in answers, not inputs. The id alternative is the
# condition value cr_h_condition reads; it is not a step input.
for key, text in claim_values(order, "answers").items():
    if key == "alternative" or key in supplied or not isinstance(text, str) or not text.strip():
        continue
    if name_refused(key):
        print(key, file=sys.stderr)
        refused = True
        continue
    write_text(key, text)
if refused:
    raise SystemExit(2)
' "$workdir" "$order_file" >"$list" 2>"$err" || py_rc=$?
  if (( py_rc == 2 )); then
    cr_log "harness: input name refused ($(tr '\n' ' ' < "$err"))"
    rm -f "$list" "$err"
    return 1
  fi
  if (( py_rc != 0 )); then
    cr_log "harness: input staging failed"
    rm -f "$list" "$err"
    return 1
  fi
  while IFS=$'\x1f' read -r iid src; do
    [[ -n "$iid" && -n "$src" ]] || continue
    if [[ "$iid" == *"/"* || "$iid" == *".."* ]]; then
      cr_log "harness: input name refused ($iid)"
      rm -f "$list" "$err"
      return 1
    fi
    dest="$workdir/inputs/$iid"; mkdir -p "$dest"
    if [[ "$src" == http://* || "$src" == https://* ]]; then
      curl -sS -L --max-time 600 -o "$dest/$(basename "${src%%\?*}")" "$src" 2>/dev/null \
        || cr_log "harness: input $iid download failed ($src)"
    elif [[ -e "$src" ]]; then
      cp -R "$src" "$dest/" 2>/dev/null || true
    fi
  done < "$list"
  rm -f "$list" "$err"
  return 0
}

# cr_h_saves_for <stepId> → "id.ext ..." of the step's declared saves.
cr_h_saves_for() {
  python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); sid = sys.argv[2]
ext = {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}
s = next((s for s in (o.get("manifest") or {}).get("steps", []) if s.get("id") == sid), {})
print(" ".join("%s.%s" % (v["id"], ext.get(v.get("kind"), "bin")) for v in s.get("saves") or []))' "$CR_H_ORDER_DIR/order.json" "$1"
}

# cr_h_seal_prior_loudness <stepId> <workdir>
# Reel final_checks input is prior/assembled_video.mp4 (the step doc's OUT_RAW).
# Seal it to the recipe target before the agent starts, on local and non-local
# runs, so the step-doc cover concat already lands near -14 LUFS. The pinned
# step docs still score immediately after that concat; this does not ask the
# agent to loudnorm. A file already inside +/- 1.5 LU is left unchanged.
# A missing file or a placeholder (no decodable audio) is skipped. A real
# audio file whose seal fails is logged and returned to the caller.
cr_h_seal_prior_loudness() {
  local step_id="$1" workdir="$2" recipe media detail audio errfile
  [[ "$step_id" == "final_checks" ]] || return 0
  media="$workdir/prior/assembled_video.mp4"
  [[ -f "$media" && ! -L "$media" ]] || return 0
  recipe="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("manifest") or {}).get("recipe") or "")' "$CR_H_ORDER_DIR/order.json")" || {
    cr_log "harness: final loudness recipe lookup failed"
    return 1
  }
  case "$recipe" in
    p-reels-spotlight|p-reels-pip) ;;
    *) return 0 ;;
  esac
  # Placeholder saves in harness tests are not decodable media. Leave them.
  # A real audio file that fails to seal is not skipped.
  audio="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$media" 2>/dev/null || true)"
  audio="${audio//$'\r'/}"
  [[ "$audio" == "audio" ]] || return 0
  errfile="$workdir/.cfw-loudnorm-prior.err"
  if ! python3 "$CR_H_SELF_DIR/cfw-render-checks.py" loudnorm "$media" "$CR_H_RECIPE_DIR" >"$errfile" 2>&1; then
    detail="$(tr '\n' ' ' < "$errfile" 2>/dev/null || true)"
    rm -f "$errfile"
    if (( ${#detail} > 400 )); then
      detail="${detail:$((${#detail}-400))}"
    fi
    cr_log "harness: final loudness normalisation failed (${detail})"
    return 1
  fi
  rm -f "$errfile"
}

# cr_h_seal_final_loudness <stepId> <workdir>
# Safety net for non-local harness checks: seal saves/final_video.mp4 before
# any check script reads it. The prior input was already sealed before the
# agent started. Local spotlight seals again inside evidence mode, before
# qa/review.json is hashed; local PIP seals inside run. This returns without
# a second pass on local runs (checks.py owns that path). A file already in
# range is not encoded again. Video is copied; only audio is re-encoded.
# A placeholder save (not decodable audio) is skipped. A real media file
# whose seal fails is logged and returned to the caller, which fails qa_gate.
cr_h_seal_final_loudness() {
  local step_id="$1" workdir="$2" recipe media detail audio errfile
  [[ "$step_id" == "final_checks" ]] || return 0
  if (( CR_H_LOCAL )); then
    return 0
  fi
  media="$workdir/saves/final_video.mp4"
  [[ -f "$media" && ! -L "$media" ]] || return 0
  recipe="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("manifest") or {}).get("recipe") or "")' "$CR_H_ORDER_DIR/order.json")" || {
    cr_log "harness: final loudness recipe lookup failed"
    return 1
  }
  case "$recipe" in
    p-reels-spotlight|p-reels-pip) ;;
    *) return 0 ;;
  esac
  # Placeholder saves in harness tests are not decodable media. Leave them
  # for the step checks. A real audio file that fails to seal is not skipped.
  audio="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$media" 2>/dev/null || true)"
  audio="${audio//$'\r'/}"
  [[ "$audio" == "audio" ]] || return 0
  # Keep the tool's own error. A failing command substitution assigned to a
  # local variable can discard that text, which hides the real failure.
  errfile="$workdir/.cfw-loudnorm.err"
  if ! python3 "$CR_H_SELF_DIR/cfw-render-checks.py" loudnorm "$media" "$CR_H_RECIPE_DIR" >"$errfile" 2>&1; then
    detail="$(tr '\n' ' ' < "$errfile" 2>/dev/null || true)"
    rm -f "$errfile"
    if (( ${#detail} > 400 )); then
      detail="${detail:$((${#detail}-400))}"
    fi
    cr_log "harness: final loudness normalisation failed (${detail})"
    return 1
  fi
  rm -f "$errfile"
}

# cr_h_agent_refusal <log> <from-byte> <prompt-file>
# The final_checks agent's own block/refuse finding for THIS run, as one
# line, first 500 characters. Prints nothing when this run did not refuse.
# Codex copies the step prompt into the log, and that prompt already says
# "DELIVERY BLOCKED", so the prompt is not the verdict. The final answer is
# the text after the last "tokens used" / count pair (the count may contain
# a comma, as in 21,140). Secrets are redacted before the cut.
cr_h_agent_refusal() {
  local log="$1" from="$2" prompt="$3"
  [[ -f "$log" ]] || return 0
  python3 - "$CR_H_SELF_DIR/cfw-render-redact.py" "$log" "${from:-0}" "$prompt" <<'PY'
import re, subprocess, sys
sys.dont_write_bytecode = True
redact_py, log_path, from_s, prompt_path = sys.argv[1:]
try:
    start = int(from_s)
except ValueError:
    sys.stderr.write("harness: agent refusal log offset is not an integer\n")
    sys.exit(1)
if start < 0:
    start = 0
try:
    with open(log_path, "rb") as fh:
        fh.seek(start)
        raw = fh.read().decode("utf-8", "replace")
except OSError:
    sys.exit(0)
prompt = ""
if prompt_path:
    try:
        with open(prompt_path, "r", encoding="utf-8", errors="replace") as fh:
            prompt = fh.read()
    except OSError:
        prompt = ""
if prompt:
    raw = raw.replace(prompt, "\n")
# Last pair wins: an earlier pair in the same run is not the final answer.
matches = list(re.finditer(r"(?m)^tokens used\r?\n[0-9][0-9,]*[ \t]*\r?\n", raw))
body = raw[matches[-1].end():] if matches else raw
text = " ".join(body.split())
if not text:
    sys.exit(0)
# Negated forms are not a refusal. Each lookbehind is fixed-width.
# "not blocked", "isn't blocked", "isnt blocked", "nothing blocking",
# and "no blockers" / "no blocking" do not count. "block:" is the verdict.
refusal = re.compile(
    r"(?i)(?<![Nn]ot )(?<!nothing )(?<!no )(?<!isn't )(?<!isn’t )(?<!isnt )"
    r"(?:\bblock\s*:|\bblocked\b|\bblocking\b|\brefus(?:e|es|ed|al)\b|\bdo not deliver\b|\bnot delivered\b)"
)
found = list(refusal.finditer(text))
if not found:
    sys.exit(0)
# No tokens-used marker: do not take a preamble from the engine banner.
# Start at the last refusal sentence and keep the rest of the answer.
if not matches and found[-1].start() > 0:
    start_at = text.rfind(". ", 0, found[-1].start())
    text = text[start_at + 2:] if start_at >= 0 else text[found[-1].start():]
    text = " ".join(text.split())
try:
    proc = subprocess.run(
        [sys.executable, redact_py],
        input=text,
        text=True,
        capture_output=True,
        timeout=15,
    )
except Exception as exc:
    sys.stderr.write("harness: agent refusal redaction failed: %s\n" % exc)
    sys.exit(1)
if proc.returncode != 0:
    sys.stderr.write("harness: agent refusal redaction failed\n")
    sys.exit(1)
clean = " ".join(proc.stdout.split())
if not clean or not refusal.search(clean):
    sys.exit(0)
sys.stdout.write(clean[:500])
PY
}

# cr_h_run_checks <stepId> <workdir> <check-ids...> → prints checks JSON; rc 1 if any failed.
# CR_H_AGENT_REFUSAL, when set, is the finding from cr_h_agent_refusal for
# this run. A missing save then carries that finding instead of the
# missing-save line. An empty value keeps today's missing-save text.
cr_h_run_checks() {
  local step_id="$1" workdir="$2"; shift 2
  if (( CR_H_LOCAL )); then
    local result rc=0
    result="$(python3 "$CR_H_SELF_DIR/cfw-render-checks.py" run \
      "$CR_H_ORDER_DIR/order.json" "$CR_H_RECIPE_DIR" "$workdir" "$step_id" 2>/dev/null)" || rc=$?
    if [[ -z "$result" ]]; then
      printf '%s' '[{"id":"validation","passed":false,"detail":"Local validators are unavailable. Update the renderer before retrying."}]'
      return 1
    fi
    printf '%s' "$result"
    return "$rc"
  fi
  if ! cr_h_seal_final_loudness "$step_id" "$workdir"; then
    printf '%s' '[{"id":"qa_gate","passed":false,"detail":"Final loudness normalisation failed."}]'
    return 1
  fi
  local id script detail ok f failed=0 json="["
  for id in "$@"; do
    script="$CR_H_RECIPE_DIR/checks/$id.sh"
    detail=""; ok=1
    if [[ -f "$script" ]]; then
      detail="$(bash "$script" "$workdir" 2>&1)" || ok=0
      # Last 400 characters. A negative offset is not portable on bash 3.2
      # and can discard the message the retry log has to keep.
      if (( ${#detail} > 400 )); then
        detail="${detail:$((${#detail}-400))}"
      fi
    else
      for f in $(cr_h_saves_for "$step_id"); do
        [[ -s "$workdir/saves/$f" ]] || { ok=0; detail="missing or empty save $f"; }
      done
      # The agent refused. The missing file is not the reason Social should see.
      if (( ! ok )) && [[ -n "${CR_H_AGENT_REFUSAL:-}" ]]; then
        detail="$CR_H_AGENT_REFUSAL"
      fi
    fi
    (( ok )) || failed=1
    json+="$(python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1], "passed": sys.argv[2]=="1", **({"detail": sys.argv[3]} if sys.argv[3] else {})}))' "$id" "$ok" "$detail"),"
  done
  json="${json%,}]"
  printf '%s' "$json"
  (( failed )) && return 1
  return 0
}

# cr_h_failed_check_note <checks-json> — one short line of failed checks.
# Shape: "<id>: <message>; <id>: <message>". Passed checks are omitted.
# Messages are the check's own detail, collapsed to one line, redacted and
# cut off. This does not read save files or copy their contents.
cr_h_failed_check_note() {
  python3 - "$CR_H_SELF_DIR/cfw-render-redact.py" "$1" <<'PY'
import json, subprocess, sys
sys.dont_write_bytecode = True
try:
    rows = json.loads(sys.argv[2]) if str(sys.argv[2]).strip() else []
except Exception:
    rows = []
if not isinstance(rows, list):
    rows = []

def clean(text):
    # Run the support redactor as a program. Importing it from this process
    # shares stdin with the harness script and can blank the message.
    text = " ".join(text.split())
    if not text:
        return ""
    try:
        proc = subprocess.run(
            [sys.executable, sys.argv[1]],
            input=text,
            text=True,
            capture_output=True,
            timeout=15,
        )
    except Exception:
        return ""
    if proc.returncode != 0:
        return ""
    return " ".join(proc.stdout.split())

parts = []
for row in rows:
    if not isinstance(row, dict) or row.get("passed") is True:
        continue
    cid = row.get("id")
    if not isinstance(cid, str) or not cid.strip():
        cid = "check"
    cid = " ".join(cid.split())[:80]
    raw = row.get("detail")
    if not isinstance(raw, str):
        raw = row.get("message") if isinstance(row.get("message"), str) else ""
    msg = clean(" ".join(raw.split()))
    if len(msg) > 160:
        msg = msg[:157] + "..."
    if not msg:
        msg = "failed"
    parts.append("%s: %s" % (cid, msg))
note = "; ".join(parts)
if len(note) > 900:
    note = note[:897] + "..."
sys.stdout.write(note)
PY
}

# cr_h_json_detail <json-object> <detail> [message]
# Adds detail when it is non-empty. With "message", also sets an owner-safe
# message (at most 240 characters) when that field is absent.
cr_h_json_detail() {
  python3 -c '
import json, sys
base = json.loads(sys.argv[1])
if not isinstance(base, dict):
    raise SystemExit(1)
detail = sys.argv[2]
if detail:
    base["detail"] = detail
    if len(sys.argv) > 3 and sys.argv[3] == "message" and not base.get("message"):
        base["message"] = detail if len(detail) <= 240 else detail[:237] + "..."
print(json.dumps(base, separators=(",", ":")))
' "$1" "$2" "${3:-}"
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
  local order_file="$1" order_dir="$2" restored rc=0
  : > "$order_dir/resume-restored.txt"; : > "$order_dir/resume-missing.txt"
  printf '[]' > "$order_dir/restored-outputs.json"
  restored="$(python3 "$CR_H_SELF_DIR/cfw-render-stage.py" restore "$order_file" "$order_dir" \
    "${CFW_RENDER_MEDIA_BASE_URL:-}" "${CFW_RENDER_TEST_MEDIA_BASE_URL:-}")" || rc=$?
  if (( rc != 0 )); then
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("missing", "invalid_output"))' \
      "${restored:-{\}}" > "$order_dir/resume-missing.txt" || printf 'invalid_output' > "$order_dir/resume-missing.txt"
    return 1
  fi
  printf '%s' "$restored" > "$order_dir/restored-outputs.json"
  python3 -c 'import json,sys; print("\n".join(x["path"] for x in json.loads(sys.argv[1])))' \
    "$restored" > "$order_dir/resume-restored.txt"
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
  local meta engine resume_from range_plan nonfinal endpoint
  # Local claims are experimental and explicitly opted in. Unknown modes never
  # fall through to legacy uploads; range + local is not a supported protocol.
  CR_H_LOCAL="$(python3 - "$order_file" "${CFW_RENDER_LOCAL_CHECKPOINTS:-0}" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
if "checkpoint" not in o:
    print(0)
else:
    c = o["checkpoint"]
    if (sys.argv[2] != "1" or not isinstance(c, dict) or c.get("mode") != "local-v1"
            or any(k in o for k in ("stageRange", "stopAfterStepId", "stageRangeCompleted"))
            or "stageRange" in (o.get("taskOrder") or {})):
        sys.exit(31)
    print(1)
PY
)" || { cr_log "harness: unsupported checkpoint claim; no engine started"; return 31; }
  range_plan="$(python3 "$CR_H_SELF_DIR/cfw-render-stage.py" plan "$order_file" "$order_dir")" || return 1
  printf '%s' "$range_plan" > "$order_dir/range-plan.json"
  IFS=$'\x1f' read -r nonfinal endpoint <<< "$(python3 -c 'import json,sys; p=json.loads(sys.argv[1]); print("\x1f".join(["1" if p["nonfinal"] else "0", p["endpoint"]]))' "$range_plan")"
  meta="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))
print("\x1f".join([o.get("id") or "", (o.get("attempt") or {}).get("id") or "", o.get("resumeFromStepId") or ""]))' "$order_file")"
  IFS=$'\x1f' read -r CR_H_ORDER_ID CR_H_ATTEMPT_ID resume_from <<< "$meta"
  [[ -n "$CR_H_ORDER_ID" && -n "$CR_H_ATTEMPT_ID" ]] || { cr_log "harness: order/attempt id missing"; return 1; }
  engine="$(cr_engine_detect)"
  rm -f "$order_dir/directive" "$order_dir/attempt-completed-ack"
  if (( CR_H_LOCAL )); then
    [[ ! -e "$order_dir/.delivery-started" ]] || return 31
    if [[ ! -r "$CR_H_SELF_DIR/cfw-render-checks.py" ]] || ! cr_h_checkpoint init >/dev/null; then
      cr_log "harness: local checkpoint unavailable; no engine started"
      return 31
    fi
    cr_h_local_replay || return $?
  else
    rm -f "$order_dir/pending-reports.ndjson"
    [[ -f "$order_dir/seq" ]] || printf '0' > "$order_dir/seq"
  fi

  # Step table: id, runsOn, maxCheckRetries, when-kind, when-arg, saves, checks
  local steps
  steps="$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1])); selected = json.loads(sys.argv[2])["stepIds"]
if sys.argv[3] == "1": selected = [s["id"] for s in o["manifest"]["steps"] if s.get("runsOn", "computer") == "computer"]
ext = {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}
for s in (o.get("manifest") or {}).get("steps", []):
    if s["id"] not in selected: continue
    w = s.get("when", "always")
    wk, wa = "always", ""
    if isinstance(w, dict):
        if "inputPresent" in w: wk, wa = "inputPresent", w["inputPresent"]
        elif "alternative" in w: wk, wa = "alternative", w["alternative"]
    saves = " ".join("%s:%s" % (v["id"], ext.get(v.get("kind"), "bin")) for v in s.get("saves") or [])
    checks = " ".join(c["id"] for c in s.get("checks") or [])
    print("\x1f".join([s["id"], s.get("runsOn", "computer"), str(s.get("maxCheckRetries", 0)), wk, wa, saves, checks]))' "$order_file" "$range_plan" "$CR_H_LOCAL")" || return 1

  # [M2-04] Resume (D30): pull every savedOutput into the path the step would
  # have written it to, verify it, and remember what is missing so the first
  # step we run can fail with a reason the server can act on.
  local -a completed_saves=()
  local resume_missing=""
  if (( CR_H_LOCAL )); then
    local restored
    restored="$(cr_h_checkpoint restore)" || { cr_h_local_blocked; return 31; }
    while IFS= read -r p; do [[ -n "$p" ]] && completed_saves+=("$p"); done < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$restored")
  else
    cr_h_restore_saved_outputs "$order_file" "$order_dir" || true
    while IFS= read -r p; do [[ -n "$p" ]] && completed_saves+=("$p"); done < "$order_dir/resume-restored.txt"
    resume_missing="$(cat "$order_dir/resume-missing.txt" 2>/dev/null || true)"
  fi
  if [[ -n "$resume_from" ]]; then
    cr_log "harness: order $CR_H_ORDER_ID resumes at $resume_from (${#completed_saves[@]} saved output(s) restored${resume_missing:+; missing: $resume_missing})"
  fi

  cr_harness_heartbeat_start
  # shellcheck disable=SC2064
  trap "cr_harness_heartbeat_stop; rm -f '$order_dir/current-step.json'" RETURN

  local step_id runs_on max_retries when_kind when_arg saves checks rc cond p
  local final_outputs
  final_outputs="[]"
  if (( ! CR_H_LOCAL )); then final_outputs="$(cat "$order_dir/restored-outputs.json")"; fi
  # An already completed range has no loop iterations. Missing restored files
  # must still fail, rather than falsely acknowledging completion.
  if [[ -n "$resume_missing" && -z "$steps" ]]; then
    cr_h_report attempt_failed "{\"stepId\":\"$endpoint\",\"message\":\"Saved results are missing\"}"
    return 30
  fi
  while IFS=$'\x1f' read -r step_id runs_on max_retries when_kind when_arg saves checks; do
    [[ -n "$step_id" ]] || continue
    [[ "$runs_on" == "computer" ]] || continue
    rc=0; cr_h_wait_pause || rc=$?
    if (( rc == 20 )); then cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20; fi
    (( rc == 21 )) && { cr_log "harness: pause timeout — releasing order $CR_H_ORDER_ID"; return 21; }
    (( rc == 22 )) && { cr_h_release_revoked "$step_id"; return 22; }
    (( rc == 23 )) && return 23
    (( rc == 30 )) && return 30
    (( rc == 31 )) && return 31

    if (( CR_H_LOCAL )); then
      local cached cached_event cached_extra
      cached="$(cr_h_checkpoint cached "$step_id")" || { cr_h_local_blocked; return 31; }
      if [[ "$cached" != null ]]; then
        IFS=$'\x1f' read -r cached_event cached_extra <<< "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["event"]+"\x1f"+json.dumps(d["extra"]))' "$cached")"
        cr_h_report "$cached_event" "$cached_extra" || return $?
        continue
      fi
    fi

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

    rc=0
    cond="$(cr_h_condition "$order_file" "$when_kind" "$when_arg")" || rc=$?
    if (( rc != 0 )) || [[ "$cond" != "0" && "$cond" != "1" ]]; then
      cr_log "harness: step $step_id condition evaluation failed"
      cr_h_report step_failed "{\"stepId\":\"$step_id\",\"message\":\"Condition evaluation failed: invalid claim data\"}" || return $?
      cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"Condition evaluation failed: invalid claim data\"}" || return $?
      return 30
    fi
    if [[ "$cond" != "1" ]]; then
      if (( CR_H_LOCAL )); then cr_h_checkpoint skip "$step_id" >/dev/null || return 31; fi
      cr_h_report step_skipped "{\"stepId\":\"$step_id\",\"message\":\"condition not met\"}" || return $?
      continue
    fi

    local workdir="$order_dir/steps/$step_id" log="$order_dir/logs/$step_id.log"
    mkdir -p "$workdir/inputs" "$workdir/prior" "$workdir/saves"
    cr_h_stage_inputs "$workdir" "$order_file" || return 1
    for p in ${completed_saves[@]+"${completed_saves[@]}"}; do cp "$p" "$workdir/prior/" 2>/dev/null || true; done

    local run=0 checks_json="[]" passed=0 ask d waited
    local CR_H_AGENT_REFUSAL=""
    # [M3-01b] Engine failover (D107/D109): each engine is tried at most once
    # per step; a usage-limit message moves the step to the next engine.
    local tried=" " limit_until next_engine log_from
    while :; do
      run=$((run + 1))
      if (( CR_H_LOCAL )); then
        cr_h_checkpoint prepare "$step_id" >/dev/null || return 31
        for p in "${completed_saves[@]}"; do cp "$p" "$workdir/prior/" || return 31; done
      fi
      # Seal the reel prior after any local recopy and before the agent.
      # A quiet assemble save is encoded once; a file already in range is not.
      if ! cr_h_seal_prior_loudness "$step_id" "$workdir"; then
        cr_h_report step_failed "{\"stepId\":\"$step_id\",\"message\":\"Final loudness normalisation failed.\",\"checks\":[{\"id\":\"qa_gate\",\"passed\":false,\"detail\":\"Final loudness normalisation failed.\"}]}" || return $?
        cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"Final loudness normalisation failed.\"}" || return $?
        return 30
      fi
      tried+="$engine "
      # A check failure on the previous run is carried on this step_started.
      # The workdir is removed after success, so the event has to keep the reason.
      local start_extra="{\"stepId\":\"$step_id\",\"engine\":\"$engine\"}"
      local fail_note_file="$order_dir/.cfw-check-fail-$step_id"
      if [[ -s "$fail_note_file" ]]; then
        local carried_note
        carried_note="$(cat "$fail_note_file")"
        start_extra="$(cr_h_json_detail "$start_extra" "$carried_note")" || return 1
      fi
      cr_h_report step_started "$start_extra" || return $?
      if (( CR_H_LOCAL )); then cr_h_wait_pause || return $?; fi
      cr_h_write_current_step "$order_dir" "$step_id" "$engine"
      rm -f "$workdir/needs_input.json"
      cr_h_build_prompt "$step_id" "$workdir" "$order_file"
      rc=0; log_from=0
      [[ -f "$log" ]] && log_from="$(wc -c < "$log" | tr -d ' ')"
      (
        cr_h_export_step_keys "$order_file" "$step_id" || exit 32
        CFW_STEP_SAVES="$saves" CFW_STEP_ID="$step_id" \
          cr_h_run_with_timeout "$CFW_RENDER_STEP_TIMEOUT_SEC" cr_engine_run "$engine" "$workdir/prompt.md" "$workdir" "$log"
      ) || { rc=$?; cr_log "harness: step $step_id engine exited nonzero (run $run)"; }

      if (( rc == 32 )); then
        cr_h_report step_failed "{\"stepId\":\"$step_id\",\"message\":\"Invalid or expired provider key claim\"}" || return $?
        cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"Invalid or expired provider key claim\"}" || return $?
        return 30
      fi

      # Cancellation/supersession always wins over timeout/check retry policy.
      case "$rc" in
        20) cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20 ;;
        23) return 23 ;;
        22) cr_h_release_revoked "$step_id"; return 22 ;;
        31) return 31 ;;
        137|143)
          cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"step exceeded its bounded budget; artifacts retained\"}"
          return 30 ;;
      esac
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
        # Social accepts ask.count only as {min,max}. A bare integer n >= 0,
        # or a numeric string of one, is sent as {min:n,max:n}. An object is
        # kept only when min and max are integers, min >= 0, and min <= max
        # (max may be null). No count stays absent. A count that breaks those
        # rules is dropped, with one log line.
        ask="$(python3 - "$workdir/needs_input.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    ask = json.load(open(path))
except Exception:
    print("keep")
    print("{}")
    raise SystemExit(0)

def whole(value):
    return isinstance(value, int) and not isinstance(value, bool)

def parse_number(count):
    if isinstance(count, bool):
        return None
    if isinstance(count, int):
        return count
    if isinstance(count, str):
        text = count.strip()
        if text.startswith("+"):
            text = text[1:]
        if text.startswith("-"):
            if len(text) > 1 and text[1:].isdigit():
                return int(text)
            return None
        if text.isdigit():
            return int(text)
    return None

def range_ok(min_v, max_v):
    if not whole(min_v) or min_v < 0:
        return False
    if max_v is None:
        return True
    if not whole(max_v) or max_v < 0:
        return False
    return min_v <= max_v

dropped = False
if isinstance(ask, dict) and "count" in ask:
    count = ask["count"]
    number = parse_number(count)
    if number is not None and number >= 0:
        ask["count"] = {"min": number, "max": number}
    elif isinstance(count, dict) and "min" in count and "max" in count and range_ok(count.get("min"), count.get("max")):
        pass
    else:
        del ask["count"]
        dropped = True
print("drop" if dropped else "keep")
print(json.dumps(ask))
PY
)" || ask=$'keep\n{}'
        if [[ "${ask%%$'\n'*}" == "drop" ]]; then
          cr_log "harness: step $step_id needs_input count dropped (need integer min>=0 and min<=max)"
        fi
        ask="${ask#*$'\n'}"
        [[ -n "$ask" ]] || ask='{}'
        # A refused needs_input report already failed the step (rc 30) and
        # carried the refusal text. Do not wait, and do not rerun the step.
        cr_h_report needs_input "{\"stepId\":\"$step_id\",\"ask\":$ask}" || return $?
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
          [[ "$d" == "report_blocked" ]] && return 31
          [[ "$d" == "blocked" ]] && return 30
          [[ "$d" == "stop_after_step" ]] && { cr_h_release_revoked "$step_id"; return 22; }
          [[ "$d" == "continue" ]] && break
          (( waited >= CFW_RENDER_PAUSE_MAX_SEC )) && return 21
          sleep 10; waited=$((waited + 10))
          cr_h_report heartbeat '{}'
        done
        # B13: the owner's answer reaches this computer only inside a claim
        # (claim_render_order: `answers`, `inputs`, `providerKeys`). The claim
        # this run holds was taken before the ask, so rerunning the step here
        # would show it the same empty answers and it would ask again. Hand the
        # attempt back instead: Social queues the request, and the next claim
        # carries the answer (cr_h_stage_inputs writes it where the step reads
        # it). This is the path a hold-window release already takes. A local
        # checkpoint claim keeps the rerun.
        if (( ! CR_H_LOCAL )); then
          rm -f "$order_dir/current-step.json"
          cr_h_report attempt_released "{\"stepId\":\"$step_id\",\"reason\":\"ask_answered\"}" || return $?
          cr_log "harness: order $CR_H_ORDER_ID — ask at step $step_id answered; released so the next claim carries the answer"
          return 21
        fi
        run=$((run - 1))   # an answered ask reruns the step; not a check retry
        continue
      fi

      # final_checks only: a QA refusal is read from this run's log. Other
      # steps keep the check text they already had. A redactor failure or
      # timeout logs one line, keeps an empty refusal (the missing-save text
      # stays) and continues. It must not return before the failure report.
      CR_H_AGENT_REFUSAL=""
      if [[ "$step_id" == "final_checks" ]]; then
        local refusal_err="" refusal_line="" refusal_rc=0
        refusal_err="$(mktemp 2>/dev/null)" || refusal_err=""
        if [[ -n "$refusal_err" ]]; then
          CR_H_AGENT_REFUSAL="$(cr_h_agent_refusal "$log" "$log_from" "$workdir/prompt.md" 2>"$refusal_err")" || refusal_rc=$?
        else
          CR_H_AGENT_REFUSAL="$(cr_h_agent_refusal "$log" "$log_from" "$workdir/prompt.md")" || refusal_rc=$?
        fi
        if (( refusal_rc != 0 )); then
          CR_H_AGENT_REFUSAL=""
          if [[ -n "$refusal_err" ]]; then
            IFS= read -r refusal_line < "$refusal_err" || true
          fi
          if [[ -z "$refusal_line" ]]; then
            refusal_line="harness: agent refusal redaction failed"
          fi
          printf '%s\n' "$refusal_line" >&2
        fi
        if [[ -n "$refusal_err" ]]; then
          rm -f "$refusal_err"
        fi
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
      # Keep the failed check names for the next step event and the log line.
      # Retry count is unchanged: one failure still consumes one run.
      local this_note=""
      this_note="$(cr_h_failed_check_note "$checks_json")" || this_note=""
      # The joined note cuts each message to 160 characters. The full refusal
      # is the step reason only when every failed check is a missing save
      # (that fallback already stored the finding). A check script or a local
      # validator keeps its own detail, even when the agent log refused.
      if [[ -n "$CR_H_AGENT_REFUSAL" ]] && python3 -c '
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
refusal = sys.argv[2]
if not isinstance(rows, list) or not refusal:
    raise SystemExit(1)
failed = [row for row in rows if isinstance(row, dict) and row.get("passed") is not True]
if not failed or any(row.get("detail") != refusal for row in failed):
    raise SystemExit(1)
' "$checks_json" "$CR_H_AGENT_REFUSAL"; then
        this_note="$CR_H_AGENT_REFUSAL"
      fi
      if [[ -n "$this_note" ]]; then
        printf '%s' "$this_note" > "$order_dir/.cfw-check-fail-$step_id"
      fi
      (( run > max_retries )) && break
      if [[ -n "$this_note" ]]; then
        cr_log "harness: step $step_id checks failed (run $run/$((max_retries + 1))): $this_note — retrying"
      else
        cr_log "harness: step $step_id checks failed (run $run/$((max_retries + 1))) — retrying"
      fi
    done

    # [M2-04] attempt_superseded (set by any report/heartbeat reply) → stop
    # now, before a single upload. Nothing else is sent.
    [[ "$(cr_h_directive)" == "superseded" ]] && return 23

    if (( ! passed )); then
      local fail_extra="{\"stepId\":\"$step_id\",\"checks\":$checks_json}"
      local attempt_extra="{\"stepId\":\"$step_id\",\"message\":\"step $step_id failed its checks\"}"
      if [[ -s "$order_dir/.cfw-check-fail-$step_id" ]]; then
        local failed_note
        failed_note="$(cat "$order_dir/.cfw-check-fail-$step_id")"
        fail_extra="$(cr_h_json_detail "$fail_extra" "$failed_note" message)" || return 1
        attempt_extra="$(cr_h_json_detail "{\"stepId\":\"$step_id\"}" "$failed_note" message)" || return 1
      fi
      rm -f "$order_dir/.cfw-check-fail-$step_id"
      cr_h_report step_failed "$fail_extra"
      cr_h_report attempt_failed "$attempt_extra"
      return 30
    fi

    local outputs="[" sv sid ext url f
    if (( CR_H_LOCAL )); then
      local completion
      completion="$(cr_h_checkpoint save "$step_id" "$checks_json")" || return 31
      for sv in $saves; do completed_saves+=("$workdir/saves/${sv%%:*}.${sv##*:}"); done
      rm -f "$order_dir/current-step.json"
      if [[ -s "$order_dir/.cfw-check-fail-$step_id" ]]; then
        local failed_note
        failed_note="$(cat "$order_dir/.cfw-check-fail-$step_id")"
        completion="$(cr_h_json_detail "$completion" "$failed_note")" || return 1
        rm -f "$order_dir/.cfw-check-fail-$step_id"
      fi
      cr_h_report step_completed "$completion" || return $?
    else
    for sv in $saves; do
      sid="${sv%%:*}"; ext="${sv##*:}"; f="$workdir/saves/$sid.$ext"
      if [[ ! -s "$f" || -L "$f" ]]; then
        cr_h_report step_failed "{\"stepId\":\"$step_id\",\"message\":\"Declared save is missing or empty\"}"
        cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"Declared save is missing or empty\"}"
        return 30
      fi
      if ! url="$(cr_h_upload_with_retry "$f")"; then
        cr_log "harness: upload failed for $f"
        cr_h_report step_failed "{\"stepId\":\"$step_id\",\"checks\":[{\"id\":\"upload\",\"passed\":false,\"detail\":\"upload failed\"}]}"
        cr_h_report attempt_failed "{\"stepId\":\"$step_id\",\"message\":\"upload failed\"}"
        return 30
      fi
      outputs+="$(python3 -c 'import hashlib,json,sys; h=hashlib.sha256(); f=open(sys.argv[3], "rb");
for chunk in iter(lambda: f.read(1048576), b""): h.update(chunk)
print(json.dumps({"saveId": sys.argv[1], "url": sys.argv[2], "checksum": "sha256:" + h.hexdigest()}))' "$sid" "$url" "$f"),"
      completed_saves+=("$f")
      final_outputs="$(python3 -c 'import json,sys; a=[x for x in json.loads(sys.argv[1]) if x["id"]!=sys.argv[2]]; a.append({"id":sys.argv[2],"url":sys.argv[3],"path":sys.argv[4]}); print(json.dumps(a))' "$final_outputs" "$sid" "$url" "$f")"
    done
    outputs="${outputs%,}]"
    rm -f "$order_dir/current-step.json"
    local done_extra="{\"stepId\":\"$step_id\",\"outputs\":$outputs,\"checks\":$checks_json}"
    if [[ -s "$order_dir/.cfw-check-fail-$step_id" ]]; then
      local failed_note
      failed_note="$(cat "$order_dir/.cfw-check-fail-$step_id")"
      done_extra="$(cr_h_json_detail "$done_extra" "$failed_note")" || return 1
      rm -f "$order_dir/.cfw-check-fail-$step_id"
    fi
    cr_h_report step_completed "$done_extra" || return $?
    fi
    case "$(cr_h_directive)" in
      cancel) cr_h_report attempt_cancelled "{\"stepId\":\"$step_id\"}"; return 20 ;;
      # [M2-04] D76: the step finished and its saves are up; end the attempt
      # here as revoked. The caller deletes the folder and held keys.
      stop_after_step) cr_h_release_revoked "$step_id"; return 22 ;;
      superseded) return 23 ;;
    esac
  done <<< "$steps"

  # Stop heartbeat before terminal completion; a nonfinal completion releases
  # the lease and no later heartbeat should race that transition.
  cr_harness_heartbeat_stop
  if (( CR_H_LOCAL )); then final_outputs="$(cr_h_checkpoint final)" || return 31; fi
  # Delivery order is this list. Do this before attempt_completed. Every
  # recipe delivers only its deliverables (F22): manifest finalOutputs, or for
  # a reel final_video, cover and captions. A finished run (not a partial
  # stage) missing a deliverable reports attempt_failed and names the missing
  # file. It does not report success. Step saves (voice_bed, body_video,
  # voice_track, assembled, scenes) stay out of the list.
  # The filtered list drops all media when one deliverable is missing, so name
  # the gap from the step outputs, before that filter runs.
  local reel_raw="$final_outputs" reel_missing="" reel_fail=""
  final_outputs="$(cr_h_reel_delivery_outputs "$order_file" "$final_outputs" "$CR_H_RECIPE_DIR")" || return 1
  if [[ "$nonfinal" != "1" ]]; then
    reel_missing="$(cr_h_reel_missing_delivery "$order_file" "$reel_raw" "$CR_H_RECIPE_DIR")" || return 1
    if [[ -n "$reel_missing" ]]; then
      reel_fail="$(python3 -c 'import json,sys
names = sys.argv[1].split()
step = sys.argv[2]
if len(names) == 1:
    msg = names[0] + " is missing"
else:
    msg = " and ".join(names) + " are missing"
body = {"message": msg}
if step:
    body["stepId"] = step
print(json.dumps(body))' "$reel_missing" "$endpoint")" || return 1
      cr_h_report attempt_failed "$reel_fail" || return $?
      return 30
    fi
  fi
  cr_h_report attempt_completed '{}' || return $?
  if [[ "$nonfinal" == "1" ]]; then
    [[ -f "$order_dir/attempt-completed-ack" ]] || return 1
    return 25
  fi
  printf '%s\n' "$final_outputs"
  return 0
}

# ---------------------------------------------------------------------------
# Delivery filter (F22, finishes WI2.51). Only a recipe's deliverables go to
# Social. Every other step save (voice_bed, body_video, assembled_video,
# voice_track, rendered_scenes, narration, ...) stays in the order's scratch
# folder; none of them is a Reviews file.
#
# The rule is read from the order's manifest, not from a recipe name:
#   1. manifest.finalOutputs[] when it is set: exactly those saves, in that
#      order. A ref is {stepId, saveId, role}; role is deliverable, poster or
#      captions. The harness list is matched by save id.
#   2. Otherwise a reel or video recipe, meaning its manifest declares a video
#      save with id final_video: final_video, then cover, then captions when
#      the recipe saves them. (A bare manifest that names only p-reels-spotlight
#      or p-reels-pip, with no steps, gets the same rule, as before.)
#   3. Otherwise the list is returned unchanged. p-carousel keeps its ordered
#      slide_N rule, and the image recipes keep the WI2.51 preview drop, both
#      in cr_select_deliverables (cfw-render-lib.sh).
# A media deliverable that is absent contributes no media at all, so an
# intermediate can never become outputUrl. cr_h_reel_missing_delivery names the
# absent ids and cr_harness_run then reports attempt_failed, not success.
# Exit 2 from the filter means finalOutputs is malformed; the caller stops.
# ---------------------------------------------------------------------------
cr_h_delivery_py() {
  cat <<'PY'
import json, os, sys

mode, order_path, raw, recipe_dir = sys.argv[1:5]
ROLES = ("deliverable", "poster", "captions")
BARE_REELS = ("p-reels-spotlight", "p-reels-pip")

try:
    order = json.load(open(order_path))
except (OSError, ValueError):
    order = {}
if not isinstance(order, dict):
    order = {}
manifest = order.get("manifest") if isinstance(order.get("manifest"), dict) else {}
if isinstance(manifest.get("recipe"), str):
    recipe = manifest["recipe"]
elif isinstance(order.get("recipe"), str):
    recipe = order["recipe"]
else:
    recipe = ""
if not recipe and recipe_dir:
    recipe = os.path.basename(recipe_dir.rstrip("/"))


def declares_reel():
    for step in manifest.get("steps") or []:
        if not isinstance(step, dict):
            continue
        for save in step.get("saves") or []:
            if isinstance(save, dict) and save.get("id") == "final_video" and save.get("kind") == "video":
                return True
    return recipe in BARE_REELS


def bad_refs():
    sys.stderr.write("finalOutputs needs a saveId and a role (deliverable, poster or captions) on every entry\n")
    raise SystemExit(2)


# Each target is (save id, file extension or "", role).
refs = manifest.get("finalOutputs")
explicit = refs not in (None, [])
targets = None
if explicit:
    if not isinstance(refs, list):
        bad_refs()
    targets = []
    for ref in refs:
        if (not isinstance(ref, dict) or not isinstance(ref.get("saveId"), str)
                or not ref["saveId"] or ref.get("role") not in ROLES):
            bad_refs()
        targets.append((ref["saveId"], "", ref["role"]))
elif declares_reel():
    targets = [("final_video", "mp4", "deliverable"), ("cover", "png", "poster"), ("captions", "json", "captions")]

if targets is None:
    if mode == "select":
        sys.stdout.write(raw)
    raise SystemExit(0)

try:
    items = json.loads(raw or "[]")
except json.JSONDecodeError:
    items = []
if not isinstance(items, list):
    items = []


def ident(item):
    sid = item.get("id") if isinstance(item.get("id"), str) else ""
    if not sid and isinstance(item.get("saveId"), str):
        sid = item["saveId"]
    path = item.get("path") if isinstance(item.get("path"), str) else ""
    return sid, os.path.basename(path)


def matches(item, name, ext):
    sid, base = ident(item)
    if sid == name:
        return True
    if ext:
        return base == name + "." + ext
    return not sid and os.path.splitext(base)[0] == name


def pick(name, ext, role):
    hits = [i for i in items if isinstance(i, dict) and matches(i, name, ext)]
    # A later save with the same id wins. Captions keep every match.
    return hits if role == "captions" else hits[-1:]


picked = [(t, pick(*t)) for t in targets]
missing = [t[0] for t, hits in picked if t[2] != "captions" and not hits]
if mode == "missing":
    sys.stdout.write(" ".join(missing))
    raise SystemExit(0)

media, captions = [], []
for (name, ext, role), hits in picked:
    for item in hits:
        if role == "captions":
            if explicit and not isinstance(item.get("role"), str):
                item = dict(item, role="captions")
            captions.append(item)
        else:
            media.append(item)
out = ([] if missing else media) + captions
sys.stdout.write(json.dumps(out, separators=(",", ":")))
PY
}

# cr_h_delivery_run <select|missing> <order-file> <outputs-json> <recipe-dir>
cr_h_delivery_run() {
  local out rc=0
  out="$(python3 -c "$(cr_h_delivery_py)" "$@")" || rc=$?
  if (( rc != 0 )); then
    if declare -F cr_log >/dev/null; then
      if (( rc == 2 )); then
        cr_log "harness: manifest finalOutputs is invalid (each entry needs a saveId and a role); nothing was delivered"
      else
        cr_log "harness: delivery filter failed (exit $rc)"
      fi
    fi
    return 1
  fi
  printf '%s' "$out"
}

# cr_h_reel_missing_delivery <order-file> <step-outputs-json> <recipe-dir>
# Print the missing media deliverable ids, separated by a space: final_video
# then cover for a reel, or the finalOutputs saveIds that are absent. Read the
# step outputs from before cr_h_reel_delivery_outputs: that filter drops all
# media when one deliverable is missing, so it cannot say which was absent.
# Print nothing for a recipe with no delivery rule, and nothing when every
# deliverable is present. Both functions share cr_h_delivery_py.
cr_h_reel_missing_delivery() {
  cr_h_delivery_run missing "$1" "$2" "$3"
}

# cr_h_reel_delivery_outputs <order-file> <outputs-json> <recipe-dir>
# The list of finished files to hand to Social, in delivery order (rules above).
# Captions stay in the list so the worker can send them beside the media.
# A recipe with no delivery rule is returned unchanged, in the order the steps
# saved. The name says reel for history; it now covers every recipe.
cr_h_reel_delivery_outputs() {
  cr_h_delivery_run select "$1" "$2" "$3"
}
