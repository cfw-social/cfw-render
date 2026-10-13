#!/usr/bin/env bash
# cfw-render-engine.sh — [M1-08] engine adapters for the step harness.
#
# The harness runs each manifest step through whichever subscription-backed
# coding CLI the owner's computer already has signed in: OpenAI Codex
# (`codex`) or Claude Code (`claude`). This file is the ONE place that knows
# how to (a) tell which engine is usable and (b) run a prompt file through it
# non-interactively. Everything else talks to `cr_engine_detect` /
# `cr_engine_run` only.
#
# Credential rule ("no credential leaves the computer"): this file NEVER
# reads, copies or prints ~/.codex/auth.json, ~/.claude/*, the keychain, or
# any env var that looks like a key. Detection relies solely on each CLI's own
# status command EXIT CODE; its stdout (which carries the account e-mail) is
# discarded, never logged.
#
# Pinned non-interactive forms — CONFIRMED from `codex exec --help`
# (codex-cli 0.142.5) and `claude --help` / `claude auth status --help`
# (Claude Code 2.1.288) on 2026-10-11:
#
#   codex  : codex login status                     → rc 0 iff signed in
#            codex exec --skip-git-repo-check -C <workdir> \
#                  --dangerously-bypass-approvals-and-sandbox - < prompt.md
#              `-` = read the prompt from stdin (no argv size limit).
#              The bypass flag is the codex equivalent of the Director path's
#              `--dangerously-skip-permissions`: steps shell out to ffmpeg and
#              fetch inputs over the network, which the workspace-write
#              sandbox blocks.
#   claude : claude auth status                     → rc 0 iff signed in
#            claude -p --dangerously-skip-permissions --output-format text < prompt.md
#              `-p` with no positional prompt reads it from stdin.
#
# Overrides:
#   CFW_RENDER_ENGINE       codex | claude-code | none — skip detection.
#                           `none` = never send capabilities (legacy worker).
#   CFW_RENDER_ENGINE_CMD   command run INSTEAD of the real CLI (tests). It is
#                           invoked with cwd = the step workdir, the prompt on
#                           stdin and CFW_RENDER_ENGINE_PROMPT_FILE in env.
#                           Word-split on purpose, like CFW_RENDER_DIRECTOR_CMD.
#
# Sourced by cfw-render.sh (claim capabilities) and cfw-render-harness.sh.
# Depends on cfw-render-lib.sh being sourced first (cr_log).

# ---------------------------------------------------------------------------
# [M3-01b] Engine list, order, usage limits and failover (contract §1/§3,
# D107/D109). Known engines, default order. State files live under
# CFW_RENDER_STATE_DIR: engines.json {"order":[...]} (owner-set order) and
# engine-limits.json {"<engine>": {"until": "<ISO>"}} (limits we observed).
# ---------------------------------------------------------------------------
CR_ENGINES_KNOWN=(codex claude-code gemini zai moonshot minimax xai openrouter)
# [M3-08b] API-key engines: run through `codex exec` against an
# OpenAI-compatible endpoint from config/api-providers.json, key from the
# Keychain (service com.cfw.render, account = engine name).
cr_engine_is_api() { case "$1" in zai|moonshot|minimax|xai|openrouter) return 0 ;; esac; return 1; }
cr_engine_label() {
  case "$1" in
    codex) echo ChatGPT ;; claude-code) echo Claude ;; gemini) echo Gemini ;; zai) echo Z.AI ;;
    moonshot) echo Moonshot ;; minimax) echo MiniMax ;; xai) echo xAI ;; openrouter) echo OpenRouter ;;
    *) echo "$1" ;;
  esac
}
cr_engine_security() { printf '%s' "${CFW_RENDER_SECURITY_CMD:-/usr/bin/security}"; }
# cr_engine_has_key <engine> — rc 0 iff a Keychain item exists. Exit code
# only: no -w, so the password is never printed.
cr_engine_has_key() {
  "$(cr_engine_security)" find-generic-password -s com.cfw.render -a "$1" >/dev/null 2>&1 < /dev/null
}
cr_engine_providers_file() {
  printf '%s' "${CFW_RENDER_API_PROVIDERS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/api-providers.json}"
}
# cr_engine_provider_field <engine> <field>
cr_engine_provider_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' \
    "$(cr_engine_providers_file)" "$1" "$2"
}

# Limit detection table — ONE place. Row = engine|regex (python `re`, IGNORECASE).
CR_ENGINE_LIMIT_TABLE=(
  "codex|usage limit|rate limit reached|You've hit your usage limit|Try again (at|in)|limit resets"
  "claude-code|usage limit|rate limit|You've reached your (usage|message) limit|limit will reset|resets at"
  "gemini|RESOURCE_EXHAUSTED|[Qq]uota exceeded|[Rr]ate limit (reached|exceeded)|status 429|HTTP 429|\b429 Too Many"
  "apikey|[Rr]ate limit (reached|exceeded)|status 429|HTTP 429|\b429 Too Many|Too Many Requests"
)
# [M3-08b] Rows whose limit lasts a fixed window instead of a parsed reset time.
CR_ENGINE_LIMIT_WINDOW_MIN=15
# Out-of-credit table: these never expire by time (reason "credit"); cleared by
# the app deleting the entry or `cfw-render-ctl.sh clear-limit <engine>`.
# Only phrasing a vendor's error reply uses: the bare words "credit", "402" or
# "billing" also appear in ordinary render output ("add a credit line"), and a
# match here marks the provider out of credit until the owner clears it.
CR_ENGINE_CREDIT_TABLE=(
  "gemini|[Ii]nsufficient (balance|credits?|funds)|insufficient_quota|[Oo]ut of credits?|credit balance is too low|[Pp]ayment [Rr]equired|status 402|HTTP 402|\b402 Payment|billing (hard )?limit|exceeded your current quota"
  "apikey|[Ii]nsufficient (balance|credits?|funds)|insufficient_quota|[Oo]ut of credits?|credit balance is too low|[Pp]ayment [Rr]equired|status 402|HTTP 402|\b402 Payment|billing (hard )?limit|exceeded your current quota"
)

cr_engine_state_dir() { printf '%s' "${CFW_RENDER_STATE_DIR:-${HOME}/.cfw-render}"; }

# cr_engine_signed_in <engine> → rc 0 iff the CLI is present and signed in.
# Status output is discarded on purpose — it names the account.
cr_engine_signed_in() {
  local engine="$1"
  if cr_engine_is_api "$engine"; then cr_engine_has_key "$engine"; return; fi
  if [[ "$engine" == gemini ]]; then
    # The gemini CLI has no non-interactive auth-status command, so "signed in"
    # means: CLI present AND a Keychain key for it.
    { [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]] || command -v gemini >/dev/null 2>&1; } && cr_engine_has_key gemini
    return
  fi
  case "$engine" in codex|claude-code) ;; *) return 1 ;; esac
  [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]] && return 0
  case "$engine" in
    codex) command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1 < /dev/null ;;
    claude-code) command -v claude >/dev/null 2>&1 && claude auth status >/dev/null 2>&1 < /dev/null ;;
  esac
}

# cr_engine_order — known engines one per line, in the owner's order.
cr_engine_order() {
  local forced="${CFW_RENDER_ENGINE:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      codex|claude-code|gemini|zai|moonshot|minimax|xai|openrouter) echo "$forced" ;;
      none) ;;
      *) cr_log "cr_engine_order: CFW_RENDER_ENGINE='$forced' is not a known engine or none — treating as none" ;;
    esac
    return 0
  fi
  python3 -c '
import json, sys
known = sys.argv[2:]
order = []
try:
    o = json.load(open(sys.argv[1])).get("order")
    if isinstance(o, list):
        order = [x for x in o if isinstance(x, str) and x in known]
except Exception:
    pass
for k in known:
    if k not in order: order.append(k)
print("\n".join(order))
' "$(cr_engine_state_dir)/engines.json" "${CR_ENGINES_KNOWN[@]}"
}

# cr_engine_limit_until <engine> — ISO reset time or empty; expired entries
# are dropped from the file.
cr_engine_limit_until() {
  local engine="$1" f until
  f="$(cr_engine_state_dir)/engine-limits.json"
  [[ -f "$f" ]] || return 0
  until="$(python3 -c '
import json, sys, datetime
try:
    ent = json.load(open(sys.argv[1])).get(sys.argv[2]) or {}
    u = ent.get("until")
except Exception:
    ent, u = {}, None
if isinstance(ent, dict) and ent.get("reason") == "credit": print("credit"); sys.exit(0)
if not isinstance(u, str) or not u: sys.exit(0)
try:
    t = datetime.datetime.fromisoformat(u.replace("Z", "+00:00"))
    if t.tzinfo is None: t = t.replace(tzinfo=datetime.timezone.utc)
except Exception:
    print("expired"); sys.exit(0)
print("expired" if t <= datetime.datetime.now(datetime.timezone.utc) else u)
' "$f" "$engine" 2>/dev/null || true)"
  if [[ "$until" == "expired" ]]; then cr_engine_limit_clear "$engine"; return 0; fi
  printf '%s' "$until"
}

# cr_engine_limit_set <engine> <ISO|credit> / cr_engine_limit_clear <engine>
# cr_engine_limit_until prints `credit` for an out-of-credit entry (no reset).
cr_engine_limit_write() {
  local engine="$1" until="$2" dir f
  dir="$(cr_engine_state_dir)"; f="$dir/engine-limits.json"
  ( umask 077; mkdir -p "$dir"; python3 -c '
import json, os, sys
f, eng, until = sys.argv[1:4]
try:
    d = json.load(open(f))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
if until == "credit": d[eng] = {"until": None, "reason": "credit"}
elif until: d[eng] = {"until": until}
else: d.pop(eng, None)
tmp = f + ".tmp"
with open(tmp, "w") as fh: json.dump(d, fh)
os.replace(tmp, f)
' "$f" "$engine" "$until" )
}
cr_engine_limit_set() { cr_engine_limit_write "$1" "$2"; }
cr_engine_limit_clear() { cr_engine_limit_write "$1" ""; }

# cr_engine_limit_raw_count — number of entries in engine-limits.json as
# written (expired ones included); lets the claim loop notice an expiry.
cr_engine_limit_raw_count() {
  python3 -c '
import json, sys
try: print(sum(1 for v in json.load(open(sys.argv[1])).values() if not (isinstance(v, dict) and v.get("reason") == "credit")))
except Exception: print(0)' "$(cr_engine_state_dir)/engine-limits.json" 2>/dev/null || echo 0
}

# cr_engine_limit_earliest — earliest unexpired reset ISO across engines, or empty.
cr_engine_limit_earliest() {
  local e u best=""
  for e in "${CR_ENGINES_KNOWN[@]}"; do
    u="$(cr_engine_limit_until "$e")"
    [[ -n "$u" && "$u" != credit ]] || continue
    if [[ -z "$best" || "$u" < "$best" ]]; then best="$u"; fi
  done
  printf '%s' "$best"
}

# cr_engines_json — [{"name","label","auth","signedIn","limit":"ok"|"limited","resetsAt"?,"reason"?}] in order.
# gemini reports auth "api_key": its CLI login can't be checked non-interactively.
cr_engines_json() {
  local e signed until auth rows=""
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    signed=false; cr_engine_signed_in "$e" && signed=true
    until="$(cr_engine_limit_until "$e")"
    auth=signin
    if cr_engine_is_api "$e" || [[ "$e" == gemini ]]; then auth=api_key; fi
    rows+="${e}"$'\x1f'"${signed}"$'\x1f'"${until}"$'\x1f'"$(cr_engine_label "$e")"$'\x1f'"${auth}"$'\n'
  done < <(cr_engine_order)
  python3 -c '
import json, sys
out = []
for line in sys.argv[1].splitlines():
    if not line: continue
    name, signed, until, label, auth = line.split("\x1f")
    row = {"name": name, "label": label, "auth": auth, "signedIn": signed == "true", "limit": "limited" if until else "ok"}
    if until == "credit": row["resetsAt"] = None; row["reason"] = "credit"
    elif until: row["resetsAt"] = until
    out.append(row)
print(json.dumps(out))
' "$rows"
}

# cr_engine_active — first engine in order that is signed in and not limited, else none.
cr_engine_active() {
  local e
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    cr_engine_signed_in "$e" || continue
    [[ -z "$(cr_engine_limit_until "$e")" ]] || continue
    echo "$e"; return 0
  done < <(cr_engine_order)
  echo none
}

# cr_engine_detect — kept for callers; same as cr_engine_active.
cr_engine_detect() { cr_engine_active; }

# cr_engine_limit_detect <engine> <log-file> <rc> [<from-byte>] — rc 0 + reset ISO (UTC) on
# stdout when the last ~200 log lines show a usage limit; else rc 1. The regex
# match alone is sufficient (some CLIs exit 0 on a limit message).
cr_engine_limit_detect() {
  local engine="$1" log="$2" rc="${3:-0}" from="${4:-0}" row regex="" credit="" key="$1" window=""
  [[ -f "$log" ]] || return 1
  cr_engine_is_api "$engine" && key=apikey
  [[ "$key" == apikey || "$key" == gemini ]] && window="$CR_ENGINE_LIMIT_WINDOW_MIN"
  for row in "${CR_ENGINE_LIMIT_TABLE[@]}"; do
    [[ "${row%%|*}" == "$key" ]] && { regex="${row#*|}"; break; }
  done
  for row in "${CR_ENGINE_CREDIT_TABLE[@]}"; do
    [[ "${row%%|*}" == "$key" ]] && { credit="${row#*|}"; break; }
  done
  [[ -n "$regex" ]] || return 1
  # Only THIS run's output: the step log is appended across runs, so a limit
  # message from the previous engine must not be read as the next one's.
  # <from> is the log's byte size before the run (0 = whole file).
  tail -c "+$((from + 1))" "$log" | tail -n 200 | python3 -c '
import re, sys, datetime
regex, credit, window = sys.argv[1], sys.argv[2], sys.argv[3]
text = sys.stdin.read().splitlines()
if credit and any(re.search(credit, l, re.I) for l in text): print("credit"); sys.exit(0)
lines = [l for l in text if re.search(regex, l, re.I)]
if not lines: sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc)
if window:
    print((now + datetime.timedelta(minutes=int(window))).strftime("%Y-%m-%dT%H:%M:%SZ")); sys.exit(0)
reset = None
for l in lines:
    m = re.search(r"in (\d+) ?(h|hours?|m|min|minutes?)\b", l, re.I)
    if m:
        n = int(m.group(1)); unit = m.group(2).lower()
        reset = now + (datetime.timedelta(hours=n) if unit.startswith("h") else datetime.timedelta(minutes=n))
        break
    m = re.search(r"(\d{1,2}):(\d{2})\s*(am|pm)?", l, re.I)
    if m:
        h, mi, ap = int(m.group(1)), int(m.group(2)), (m.group(3) or "").lower()
        if ap == "pm" and h < 12: h += 12
        if ap == "am" and h == 12: h = 0
        if h > 23 or mi > 59: continue
        t = now.replace(hour=h, minute=mi, second=0, microsecond=0)
        if t <= now: t += datetime.timedelta(days=1)
        reset = t
        break
if reset is None: reset = now + datetime.timedelta(hours=5)
print(reset.strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$regex" "$credit" "$window"
}

# ---------------------------------------------------------------------------
# cr_engine_os — `macos` | `linux` | lower-cased uname, for capabilities.os.
# ---------------------------------------------------------------------------
cr_engine_os() {
  local u
  u="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$u" in
    darwin) echo macos ;;
    linux)  echo linux ;;
    *)      echo "${u:-unknown}" ;;
  esac
}

# ---------------------------------------------------------------------------
# cr_engine_manifests_json <skillsDir> — JSON array of {recipe, recipeVersion}
# for every <skillsDir>/*/manifest.json that parses. Unparsable files are
# skipped (they'd fail the lint gate anyway) so one bad file can't stop the
# claim from advertising the others.
# ---------------------------------------------------------------------------
cr_engine_manifests_json() {
  local skills_dir="$1"
  python3 -c '
import glob, json, os, sys
root = sys.argv[1]
out = []
for p in sorted(glob.glob(os.path.join(root, "*", "manifest.json"))):
    try:
        m = json.load(open(p))
    except Exception:
        continue
    r, v = m.get("recipe"), m.get("recipeVersion")
    if isinstance(r, str) and isinstance(v, str) and r and v:
        out.append({"recipe": r, "recipeVersion": v})
print(json.dumps(out))
' "$skills_dir" 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# cr_engine_capabilities_json <engine> <skillsDir> — the §7 `capabilities`
# object, or an empty string when <engine> is `none` (caller omits the field).
# ---------------------------------------------------------------------------
cr_engine_capabilities_json() {
  local engine="$1" skills_dir="$2"
  [[ "$engine" == "none" ]] && { echo ""; return 0; }
  local manifests
  manifests="$(cr_engine_manifests_json "$skills_dir")"
  python3 -c '
import json, sys
print(json.dumps({"engine": sys.argv[1], "os": sys.argv[2], "manifests": json.loads(sys.argv[3]), "engines": json.loads(sys.argv[4])}))
' "$engine" "$(cr_engine_os)" "$manifests" "$(cr_engines_json)"
}

# ---------------------------------------------------------------------------
# cr_engine_run <engine> <prompt-file> <workdir> <log> — run one step prompt.
# stdout+stderr of the engine are APPENDED to <log>; returns the engine's rc.
# ---------------------------------------------------------------------------
cr_engine_run() {
  local engine="$1" prompt_file="$2" workdir="$3" log="$4"
  [[ -f "$prompt_file" ]] || { cr_log "cr_engine_run: prompt file missing: $prompt_file"; return 2; }
  mkdir -p "$workdir" "$(dirname "$log")"
  printf '=== %s engine=%s prompt=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$engine" "$(basename "$prompt_file")" >> "$log"
  local rc=0
  case "$engine" in
    gemini) cr_engine_run_gemini "$prompt_file" "$workdir" "$log"; return ;;
    zai|moonshot|minimax|xai|openrouter) cr_engine_run_api "$engine" "$prompt_file" "$workdir" "$log"; return ;;
  esac
  if [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]]; then
    (
      cd "$workdir" || exit 1
      export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file" CFW_ENGINE_NAME="$engine"
      # shellcheck disable=SC2086
      $CFW_RENDER_ENGINE_CMD < "$prompt_file" >> "$log" 2>&1
    ) || rc=$?
    return "$rc"
  fi
  case "$engine" in
    codex)
      ( cd "$workdir" && codex exec --skip-git-repo-check -C "$workdir" \
          --dangerously-bypass-approvals-and-sandbox - < "$prompt_file" >> "$log" 2>&1 ) || rc=$?
      ;;
    claude-code)
      ( cd "$workdir" && claude -p --dangerously-skip-permissions --output-format text \
          < "$prompt_file" >> "$log" 2>&1 ) || rc=$?
      ;;
    *)
      cr_log "cr_engine_run: no usable engine ('$engine')"
      return 2
      ;;
  esac
  return "$rc"
}

# cr_engine_bin <real> — the CLI to run: CFW_RENDER_ENGINE_CMD (tests) or <real>.
# Sets CR_ENGINE_BIN (array).
cr_engine_bin() {
  if [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    CR_ENGINE_BIN=($CFW_RENDER_ENGINE_CMD)
  else
    CR_ENGINE_BIN=("$1")
  fi
}

# [M3-08b] gemini: `gemini -p` with the prompt on stdin. A Keychain key, if
# any, goes into THAT process's env only (never argv, never this shell).
cr_engine_run_gemini() {
  local prompt_file="$1" workdir="$2" log="$3" rc=0 k=""
  cr_engine_bin gemini
  if cr_engine_has_key gemini; then
    k="$("$(cr_engine_security)" find-generic-password -s com.cfw.render -a gemini -w 2>/dev/null < /dev/null || true)"
  fi
  (
    cd "$workdir" || exit 1
    export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file" CFW_ENGINE_NAME=gemini
    if [[ -n "$k" ]]; then
      env GEMINI_API_KEY="$k" "${CR_ENGINE_BIN[@]}" -p < "$prompt_file" >> "$log" 2>&1
    else
      "${CR_ENGINE_BIN[@]}" -p < "$prompt_file" >> "$log" 2>&1
    fi
  ) || rc=$?
  k=""; unset k
  return "$rc"
}

# [M3-08b] API-key engines: `codex exec` with a throwaway CODEX_HOME under the
# request folder holding ONE provider table; ~/.codex is never read or written.
# The key reaches only the codex process, under the provider's envKey.
cr_engine_run_api() {
  local engine="$1" prompt_file="$2" workdir="$3" log="$4" rc=0 k="" ch base envkey wire model
  base="$(cr_engine_provider_field "$engine" baseUrl)" || { cr_log "cr_engine_run: no provider entry for $engine"; return 2; }
  envkey="$(cr_engine_provider_field "$engine" envKey)" || return 2
  wire="$(cr_engine_provider_field "$engine" wireApi)" || return 2
  model="$(cr_engine_provider_field "$engine" defaultModel)" || return 2
  ch="$workdir/.codex-home-$engine"
  rm -rf "$ch"
  ( umask 077; mkdir -p "$ch" ) || return 2
  chmod 700 "$ch"
  cat > "$ch/config.toml" <<TOML
model = "$model"
model_provider = "$engine"

[model_providers.$engine]
name = "$(cr_engine_label "$engine")"
base_url = "$base"
env_key = "$envkey"
wire_api = "$wire"
TOML
  k="$("$(cr_engine_security)" find-generic-password -s com.cfw.render -a "$engine" -w 2>/dev/null < /dev/null || true)"
  cr_engine_bin codex
  (
    cd "$workdir" || exit 1
    export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file" CFW_ENGINE_NAME="$engine"
    env CODEX_HOME="$ch" "$envkey=$k" "${CR_ENGINE_BIN[@]}" exec --skip-git-repo-check -C "$workdir" \
      -c "model_provider=$engine" --dangerously-bypass-approvals-and-sandbox - < "$prompt_file" >> "$log" 2>&1
  ) || rc=$?
  k=""; unset k
  rm -rf "$ch"
  return "$rc"
}
