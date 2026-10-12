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
CR_ENGINES_KNOWN=(codex claude-code)

# Limit detection table — ONE place. Row = engine|regex (python `re`, IGNORECASE).
CR_ENGINE_LIMIT_TABLE=(
  "codex|usage limit|rate limit reached|You've hit your usage limit|Try again (at|in)|limit resets"
  "claude-code|usage limit|rate limit|You've reached your (usage|message) limit|limit will reset|resets at"
)

cr_engine_state_dir() { printf '%s' "${CFW_RENDER_STATE_DIR:-${HOME}/.cfw-render}"; }

# cr_engine_signed_in <engine> → rc 0 iff the CLI is present and signed in.
# Status output is discarded on purpose — it names the account.
cr_engine_signed_in() {
  local engine="$1"
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
      codex|claude-code) echo "$forced" ;;
      none) ;;
      *) cr_log "cr_engine_order: CFW_RENDER_ENGINE='$forced' is not codex|claude-code|none — treating as none" ;;
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
    u = (json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get("until")
except Exception:
    u = None
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

# cr_engine_limit_set <engine> <ISO> / cr_engine_limit_clear <engine>
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
if until: d[eng] = {"until": until}
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
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)' "$(cr_engine_state_dir)/engine-limits.json" 2>/dev/null || echo 0
}

# cr_engine_limit_earliest — earliest unexpired reset ISO across engines, or empty.
cr_engine_limit_earliest() {
  local e u best=""
  for e in "${CR_ENGINES_KNOWN[@]}"; do
    u="$(cr_engine_limit_until "$e")"
    [[ -n "$u" ]] || continue
    if [[ -z "$best" || "$u" < "$best" ]]; then best="$u"; fi
  done
  printf '%s' "$best"
}

# cr_engines_json — [{"name","signedIn","limit":"ok"|"limited","resetsAt"?}] in order.
cr_engines_json() {
  local e signed until rows=""
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    signed=false; cr_engine_signed_in "$e" && signed=true
    until="$(cr_engine_limit_until "$e")"
    rows+="${e}"$'\x1f'"${signed}"$'\x1f'"${until}"$'\n'
  done < <(cr_engine_order)
  python3 -c '
import json, sys
out = []
for line in sys.argv[1].splitlines():
    if not line: continue
    name, signed, until = line.split("\x1f")
    row = {"name": name, "signedIn": signed == "true", "limit": "limited" if until else "ok"}
    if until: row["resetsAt"] = until
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
  local engine="$1" log="$2" rc="${3:-0}" from="${4:-0}" row regex=""
  [[ -f "$log" ]] || return 1
  for row in "${CR_ENGINE_LIMIT_TABLE[@]}"; do
    [[ "${row%%|*}" == "$engine" ]] && { regex="${row#*|}"; break; }
  done
  [[ -n "$regex" ]] || return 1
  # Only THIS run's output: the step log is appended across runs, so a limit
  # message from the previous engine must not be read as the next one's.
  # <from> is the log's byte size before the run (0 = whole file).
  tail -c "+$((from + 1))" "$log" | tail -n 200 | python3 -c '
import re, sys, datetime
regex = sys.argv[1]
lines = [l for l in sys.stdin.read().splitlines() if re.search(regex, l, re.I)]
if not lines: sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc)
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
' "$regex"
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
