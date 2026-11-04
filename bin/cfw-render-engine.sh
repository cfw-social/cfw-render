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
# reads, copies or prints ~/.codex/auth.json, ~/.claude/*, or any env var that
# looks like a key. Detection of codex relies solely on the CLI's own status
# command EXIT CODE; its stdout (which carries the account e-mail) is
# discarded, never logged. Detection of Claude and of the API-key engines is
# the EXIT CODE of a Keychain lookup (no -w), never the secret. The sign-in
# steps it takes: a codex run and the codex status probe get a SYMLINK to the
# codex sign-in file (a path; the file is never opened here), and a claude-code
# run gets its Keychain token in that one child's environment. See WI2.109
# below.
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
#   claude : signed in = `claude` is on PATH AND the Keychain item
#            com.cfw.render / claude-code exists (WI24). Claude Code 2.1.303
#            keeps its sign-in per config folder, so the empty per-step folder
#            is never signed in (`claude auth status` exits 1 there). A step
#            authenticates with CLAUDE_CODE_OAUTH_TOKEN from that item (saved
#            by the desktop app's Sign in, a `claude setup-token` token),
#            passed to that child's environment only.
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
  if [[ "$engine" == claude-code ]]; then
    # Claude Code 2.1.303 keeps its sign-in per config folder, so a fresh empty
    # folder is never signed in and a `claude auth status` probe there always
    # says no. A claude-code step authenticates with CLAUDE_CODE_OAUTH_TOKEN
    # (see WI2.109), so "signed in" means: CLI present AND the Keychain item
    # the desktop app's Sign in saves. Exit code only; the token is not read.
    command -v claude >/dev/null 2>&1 && cr_engine_has_key claude-code && return 0
    return 1
  fi
  # Probe the way cr_engine_run runs: an empty config dir plus the sign-in
  # link. A sign-in a run cannot see must not count as signed in.
  local probe rc=1
  probe="$(mktemp -d "${TMPDIR:-/tmp}/cfw-engine-probe.XXXXXX")" || return 1
  case "$engine" in
    codex)
      if command -v codex >/dev/null 2>&1 && mkdir -p "$probe/codex"; then
        cr_engine_link_codex_signin "$probe/codex" || true
        CODEX_HOME="$probe/codex" codex login status >/dev/null 2>&1 < /dev/null && rc=0
      fi
      ;;
  esac
  rm -rf "$probe"
  return "$rc"
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
# Checkpoints remain unadvertised until the Social protocol/schema counterpart
# is integrated. Explicit opted-in synthetic local claims exercise the worker;
# neither a combined stage/checkpoint protocol nor deployed recovery is claimed.
print(json.dumps({"engine": sys.argv[1], "os": sys.argv[2], "manifests": json.loads(sys.argv[3]), "engines": json.loads(sys.argv[4]), "features": ["stage-range-v1"]}))
' "$engine" "$(cr_engine_os)" "$manifests" "$(cr_engines_json)"
}

# ---------------------------------------------------------------------------
# WI2.109 — coder config and write sandbox.
#
# Every claude-code, codex, and CFW_RENDER_ENGINE_CMD run gets an empty
# config directory inside the step work area. CLAUDE_CONFIG_DIR and
# CODEX_HOME point there. Nothing is copied from ~/.claude or ~/.codex:
# no settings, config.toml, skills, plugins, hooks, CLAUDE.md or AGENTS.md.
#
# Sign-in (hotfix for the 7b08037 401s): a codex run gets one entry in its
# isolated CODEX_HOME, auth.json as a SYMLINK to the owner's
# ${CODEX_HOME:-~/.codex}/auth.json. A link, not a copy: the work area then
# holds a path, never a token, and codex rewrites auth.json in place when
# it refreshes (open + truncate, not rename). OpenAI refresh tokens are
# single-use, so a refreshed copy would leave the owner's file holding a
# spent token. The write profile allows that one file.
# Claude Code 2.1.303 keeps its sign-in per config folder, so the empty
# per-step CLAUDE_CONFIG_DIR is never signed in. A claude-code step
# authenticates with CLAUDE_CODE_OAUTH_TOKEN from the worker's Keychain item
# (service com.cfw.render, account claude-code; saved by the desktop app's
# Sign in, a `claude setup-token` token). cr_engine_run reads it outside the
# sandbox and passes it to that one child's environment only (`env VAR=...`
# in front of the exec). It never reaches the step log, the worker log, the
# write profile or the argv of anything but `env`, and nothing is written into
# the step folder. No shared Claude folder exists: every step keeps its own
# empty one (WI24).
# cr_engine_signed_in advertises codex only when its isolated probe (empty
# CODEX_HOME plus the sign-in link) passes, and Claude only when that Keychain
# item exists, so the worker advertises only an engine its runs can use.
#
# Writes go through sandbox-exec. The profile allows writes only under the
# work folder, the isolated config dirs and a private tmp dir (plus device
# nodes libc already opens, and Chrome's own singleton-socket folders under the
# user temp dir; HyperFrames' font cache is redirected into the private tmp).
# Reads stay open. If sandbox-exec is missing, or it fails for any reason other
# than "already inside a sandbox", the coder is not started. macOS refuses a
# nested sandbox_apply, so a coder that is already sandboxed keeps this
# isolated config and the enclosing write sandbox; that limit is logged, not
# hidden.
# ---------------------------------------------------------------------------
cr_engine_sb_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

cr_engine_allow_write_subpath() {
  local logical="$1" physical quoted
  [[ -n "$logical" ]] || return 1
  quoted="$(cr_engine_sb_quote "$logical")"
  printf '(allow file-write* (subpath %s))\n' "$quoted"
  physical="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$logical" 2>/dev/null)" || return 1
  [[ -n "$physical" ]] || return 1
  if [[ "$physical" != "$logical" ]]; then
    quoted="$(cr_engine_sb_quote "$physical")"
    printf '(allow file-write* (subpath %s))\n' "$quoted"
  fi
}

# cr_engine_allow_browser_socket_dirs — a browser the coder starts (HyperFrames
# render, Playwright) opens its profile lock socket in a folder under the macOS
# user temp dir (`getconf DARWIN_USER_TEMP_DIR`, /var/folders/xx/yyyy/T). Chrome
# takes that dir from the system, not from TMPDIR, so the private tmp does not
# help. Without this rule the launch aborts with "Failed to create a
# ProcessSingleton" and puppeteer reports "The browser is already running".
# Allow only Chrome's own socket folders there: <bundle id>.<random>, such as
# com.google.Chrome.AbC123 or org.chromium.Chromium.AbC123 (optional leading
# dot), and what is inside them. Never the whole temp dir, and never another
# com.google.* folder. The temp dir is resolved to its real path (/var is a link
# to /private/var) because the sandbox checks the target. Fails closed (rc 1)
# when the temp dir cannot be resolved.
#
# The rule cannot tell the Chrome the coder is about to start from a Chrome that
# already runs on this Mac (the owner's desktop Chrome keeps its SingletonSocket
# folder here, and the updater leaves many more). So every Chrome-named entry
# that already exists directly under the temp dir when the profile is built gets
# an explicit write deny after the allow (the later rule wins). Only a folder
# Chrome creates afresh inside the sandboxed run stays writable. A temp dir we
# cannot list is not read as "nothing there": it fails closed (rc 1).
cr_engine_allow_browser_socket_dirs() {
  local ut phys re entry name
  ut="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || return 1
  [[ -n "$ut" ]] || return 1
  phys="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]).rstrip("/"))' "$ut" 2>/dev/null)" || return 1
  [[ -n "$phys" && -d "$phys" && -r "$phys" && -x "$phys" ]] || return 1
  re="$(python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "$phys" 2>/dev/null)" || return 1
  [[ -n "$re" ]] || return 1
  printf '(allow file-write* (regex #"^%s/\\.?(com\\.google\\.[Cc]hrome|org\\.chromium\\.Chromium)(\\.[^/]+)?(/.*)?$"))\n' "$re"
  # Deny what already exists. A superset of the names the regex allows is fine:
  # denying more is the safe direction.
  (
    shopt -s nullglob dotglob
    for entry in "$phys"/*; do
      name="${entry##*/}"
      case "$name" in
        com.google.[Cc]hrome|com.google.[Cc]hrome.*|org.chromium.Chromium|org.chromium.Chromium.*| \
        .com.google.[Cc]hrome|.com.google.[Cc]hrome.*|.org.chromium.Chromium|.org.chromium.Chromium.*)
          printf '(deny file-write* (subpath %s))\n' "$(cr_engine_sb_quote "$entry")"
          ;;
      esac
    done
  )
  return 0
}

# cr_engine_codex_signin_file — the owner's codex sign-in file (path only).
cr_engine_codex_signin_file() { printf '%s/auth.json' "${CODEX_HOME:-${HOME}/.codex}"; }

# cr_engine_link_codex_signin <isolated-codex-home> — symlink the owner's
# sign-in file into it. rc 0 linked; 1 no sign-in file, or a regular file
# is already there (left alone, never overwritten).
cr_engine_link_codex_signin() {
  local src dest="$1/auth.json"
  src="$(cr_engine_codex_signin_file)"
  [[ -f "$src" ]] || return 1
  [[ -L "$dest" || ! -e "$dest" ]] || return 1
  ln -sfn "$src" "$dest"
}

# cr_engine_sandbox_probe — set CR_ENGINE_SANDBOX_MODE to apply, enclosing,
# missing or broken. Cached for this shell. Does not run the coder.
cr_engine_sandbox_probe() {
  local err rc
  [[ -n "${CR_ENGINE_SANDBOX_MODE:-}" ]] && return 0
  if [[ ! -x /usr/bin/sandbox-exec ]]; then
    CR_ENGINE_SANDBOX_MODE=missing
    return 0
  fi
  rc=0
  err="$(/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    CR_ENGINE_SANDBOX_MODE=apply
    return 0
  fi
  case "$err" in
    *"sandbox_apply: Operation not permitted"*) CR_ENGINE_SANDBOX_MODE=enclosing ;;
    *)
      CR_ENGINE_SANDBOX_MODE=broken
      CR_ENGINE_SANDBOX_ERROR="${err//$'\n'/ }"
      ;;
  esac
}

cr_engine_prepare_isolate() {
  local workdir="$1"
  CR_CODER_ROOT="$workdir/.cfw-coder"
  CR_CODER_CLAUDE_DIR="$CR_CODER_ROOT/claude"
  CR_CODER_CODEX_DIR="$CR_CODER_ROOT/codex"
  CR_CODER_TMP="$CR_CODER_ROOT/tmp"
  # Empty dirs. Do not copy settings, output styles, CLAUDE.md, plugins or hooks.
  ( umask 077
    mkdir -p "$CR_CODER_CLAUDE_DIR" "$CR_CODER_CODEX_DIR" "$CR_CODER_TMP" ) || return 1
  chmod 700 "$CR_CODER_ROOT" "$CR_CODER_CLAUDE_DIR" "$CR_CODER_CODEX_DIR" "$CR_CODER_TMP" || return 1
}

cr_engine_write_profile() {
  local dest="$1" work="$2" claude="$3" codex="$4" tmp="$5" signin="${6:-}" dev physical
  {
    printf '%s\n' '(version 1)' '(allow default)' '(deny file-write*)'
    # Device nodes libc and the test doubles open for write. Not work-folder paths.
    for dev in /dev/null /dev/zero /dev/dtracehelper /dev/random /dev/urandom /dev/tty /dev/stdin /dev/stdout /dev/stderr; do
      printf '(allow file-write* (literal %s))\n' "$(cr_engine_sb_quote "$dev")"
    done
    cr_engine_allow_write_subpath "$work" || return 1
    cr_engine_allow_write_subpath "$claude" || return 1
    cr_engine_allow_write_subpath "$codex" || return 1
    cr_engine_allow_write_subpath "$tmp" || return 1
    cr_engine_allow_browser_socket_dirs || return 1
    if [[ -n "$signin" ]]; then
      # The sandbox checks the link's target, so allow that one real file.
      physical="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$signin" 2>/dev/null)" || return 1
      [[ -n "$physical" ]] || return 1
      printf '(allow file-write* (literal %s))\n' "$(cr_engine_sb_quote "$physical")"
    fi
  } > "$dest" || return 1
  chmod 600 "$dest" || return 1
}

cr_engine_refuse_unsandboxed() {
  local log="$1" why="$2"
  cr_log "cr_engine_run: $why"
  printf '%s\n' "cr_engine_run: $why" >> "$log"
  return 127
}

# cr_engine_drop_worker_auth — WI2.152 / B14. Run INSIDE the subshell that execs
# a model process, never in the worker. The worker's own auth stays in the
# worker: report/upload/heartbeat calls are made by the worker, and no recipe
# step needs it (a step reports through the harness, not with the worker key).
# Provider keys are NOT dropped here; a step still receives the ones its
# manifest `uses` names (cr_h_export_step_keys).
cr_engine_drop_worker_auth() {
  unset CFW_RENDER_WORKER_KEY
}

# ---------------------------------------------------------------------------
# cr_engine_run <engine> <prompt-file> <workdir> <log> — run one step prompt.
# stdout+stderr of the engine are APPENDED to <log>; returns the engine's rc.
# ---------------------------------------------------------------------------
cr_engine_run() {
  local engine="$1" prompt_file="$2" workdir="$3" log="$4" k=""
  [[ -f "$prompt_file" ]] || { cr_log "cr_engine_run: prompt file missing: $prompt_file"; return 2; }
  mkdir -p "$workdir" "$(dirname "$log")"
  printf '=== %s engine=%s prompt=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$engine" "$(basename "$prompt_file")" >> "$log"
  local rc=0
  case "$engine" in
    gemini) cr_engine_run_gemini "$prompt_file" "$workdir" "$log"; return ;;
    zai|moonshot|minimax|xai|openrouter) cr_engine_run_api "$engine" "$prompt_file" "$workdir" "$log"; return ;;
  esac
  cr_engine_sandbox_probe
  case "$CR_ENGINE_SANDBOX_MODE" in
    missing)
      cr_engine_refuse_unsandboxed "$log" "sandbox-exec is missing; refusing to run the coder without a write sandbox"
      return $?
      ;;
    broken)
      cr_engine_refuse_unsandboxed "$log" "sandbox-exec cannot apply a write profile (${CR_ENGINE_SANDBOX_ERROR:0:180}); refusing to run the coder unsandboxed"
      return $?
      ;;
  esac
  if ! cr_engine_prepare_isolate "$workdir"; then
    cr_log "cr_engine_run: could not create the isolated coder config dir"
    return 2
  fi
  local signin=""
  if [[ "$engine" == codex ]] && cr_engine_link_codex_signin "$CR_CODER_CODEX_DIR"; then
    signin="$(cr_engine_codex_signin_file)"
  fi
  if ! cr_engine_write_profile "$CR_CODER_ROOT/profile.sb" "$workdir" "$CR_CODER_CLAUDE_DIR" "$CR_CODER_CODEX_DIR" "$CR_CODER_TMP" "$signin"; then
    cr_log "cr_engine_run: could not write the coder write profile"
    return 2
  fi
  if [[ "$CR_ENGINE_SANDBOX_MODE" == "enclosing" ]]; then
    cr_log "cr_engine_run: sandbox-exec cannot nest inside the current sandbox; coder keeps the isolated config dir and the enclosing write sandbox"
    printf '%s\n' "cr_engine_run: sandbox-exec cannot nest inside the current sandbox; coder keeps the isolated config dir and the enclosing write sandbox" >> "$log"
  fi
  local -a cmd
  if [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    cmd=($CFW_RENDER_ENGINE_CMD)
  elif [[ "$engine" == "codex" ]]; then
    cmd=(codex exec --skip-git-repo-check -C "$workdir" --dangerously-bypass-approvals-and-sandbox -)
  elif [[ "$engine" == "claude-code" ]]; then
    cmd=(claude -p --dangerously-skip-permissions --output-format text)
  else
    cr_log "cr_engine_run: no usable engine ('$engine')"
    return 2
  fi
  # claude-code: the long-lived token from the Keychain (WI24). Read here, after
  # every refusal above, so a refused run never touches it. Same read as gemini.
  # It is a shell variable, not exported: only the `env` below hands it on.
  if [[ "$engine" == claude-code ]] && cr_engine_has_key claude-code; then
    k="$("$(cr_engine_security)" find-generic-password -s com.cfw.render -a claude-code -w 2>/dev/null < /dev/null || true)"
  fi
  (
    cd "$workdir" || exit 1
    cr_engine_drop_worker_auth
    export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file" CFW_ENGINE_NAME="$engine"
    export CLAUDE_CONFIG_DIR="$CR_CODER_CLAUDE_DIR" CODEX_HOME="$CR_CODER_CODEX_DIR"
    export TMPDIR="$CR_CODER_TMP" TMP="$CR_CODER_TMP" TEMP="$CR_CODER_TMP"
    # HyperFrames caches downloaded fonts under ~/.cache; the write profile refuses
    # that, so a font it has not cached before (Barlow Condensed) fails with EPERM.
    # Keep that cache inside the private tmp.
    export HYPERFRAMES_FONT_CACHE_DIR="$CR_CODER_TMP/hyperframes-fonts"
    export CFW_RENDER_CODER_SANDBOX="$CR_ENGINE_SANDBOX_MODE"
    if [[ "$CR_ENGINE_SANDBOX_MODE" == "apply" ]]; then
      if [[ -n "$k" ]]; then
        exec env CLAUDE_CODE_OAUTH_TOKEN="$k" /usr/bin/sandbox-exec -f "$CR_CODER_ROOT/profile.sb" "${cmd[@]}" < "$prompt_file" || exit $?
      fi
      exec /usr/bin/sandbox-exec -f "$CR_CODER_ROOT/profile.sb" "${cmd[@]}" < "$prompt_file" || exit $?
    fi
    if [[ -n "$k" ]]; then
      exec env CLAUDE_CODE_OAUTH_TOKEN="$k" "${cmd[@]}" < "$prompt_file" || exit $?
    fi
    exec "${cmd[@]}" < "$prompt_file" || exit $?
  ) >> "$log" 2>&1 || rc=$?
  k=""; unset k
  if [[ -n "$signin" && -e "$CR_CODER_CODEX_DIR/auth.json" && ! -L "$CR_CODER_CODEX_DIR/auth.json" ]]; then
    cr_log "cr_engine_run: codex replaced the sign-in link with a file; $signin may hold a spent token (check: codex login status)"
  fi
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
    cr_engine_drop_worker_auth
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
    cr_engine_drop_worker_auth
    export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file" CFW_ENGINE_NAME="$engine"
    env CODEX_HOME="$ch" "$envkey=$k" "${CR_ENGINE_BIN[@]}" exec --skip-git-repo-check -C "$workdir" \
      -c "model_provider=$engine" --dangerously-bypass-approvals-and-sandbox - < "$prompt_file" >> "$log" 2>&1
  ) || rc=$?
  k=""; unset k
  rm -rf "$ch"
  return "$rc"
}
