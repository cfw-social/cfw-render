#!/usr/bin/env bash
# test/engine-claude-token.test.sh — standalone check of how a claude-code step
# signs in, in bin/cfw-render-engine.sh (WI24).
#
#   bash test/engine-claude-token.test.sh      # exit 0 iff every check passes
#
# Claude Code 2.1.303 keeps its sign-in per config folder, so the empty
# per-step folder (WI2.109) is never signed in. A claude-code step instead
# authenticates with CLAUDE_CODE_OAUTH_TOKEN, a long-lived `claude setup-token`
# token that the desktop app's Sign in saves in the Keychain (service
# com.cfw.render, account claude-code). This test builds a temp HOME and a temp
# state dir, replaces the `security` command with a fake that answers from
# files under $ROOT/keychain/<account>, puts a fake `claude` and a fake `codex`
# first on PATH, and checks:
#   a. cr_engine_signed_in claude-code is 1 without the Keychain item (also
#      with only another account's item, or no CLI on PATH) and 0 with it, asks
#      by exit code only (no -w), never runs `claude auth status`, and creates
#      no shared Claude folder;
#   b. cr_engine_signed_in codex still probes a temp CODEX_HOME with the sign-in
#      link, and never asks the Keychain for claude-code;
#   c. cr_engine_run claude-code, with a stand-in step command AND with the real
#      `claude -p` command line, under sandbox-exec AND on the plain exec form:
#      the step sees the token from the item, a per-step empty
#      CLAUDE_CONFIG_DIR=<work>/.cfw-coder/claude (mode 700) and a per-step
#      CODEX_HOME, no process has the token in its argv while the step runs,
#      and the token is in no log, no write profile and no per-step folder;
#   d. without the Keychain item the step has no CLAUDE_CODE_OAUTH_TOKEN;
#   e. cr_engine_run codex never gets the token, and keeps its per-step
#      CODEX_HOME and sign-in link;
#   f. cr_engines_json shows claude-code signedIn only with the item.
#
# Safe to run alone: no network, no real claude or codex, no real Keychain (the
# security command is replaced), no server. It never reads ~/.claude or
# ~/.codex. Everything lives in one temp folder that is removed on exit.
# Never run test/run-tests.sh for this.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS_COUNT=0
FAILURES=0
SKIPS=0
pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }
skip() { printf '  SKIP  %s — %s\n' "$1" "$2"; SKIPS=$((SKIPS+1)); }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cfw-claude-token.XXXXXX")" || { echo "engine-claude-token: cannot make a temp folder" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)" || exit 2
cleanup() {
  if [[ -n "${ROOT:-}" && -d "$ROOT" ]]; then rm -rf -- "$ROOT"; fi
}
trap cleanup EXIT

STATE="$ROOT/state"                   # not created here: the engine must not need it
KEYCHAIN="$ROOT/keychain"             # one file per Keychain account; the file body is the secret
WORKER_LOG="$ROOT/worker.log"
export HOME="$ROOT/home"
export TMPDIR="$ROOT/tmp"
export CFW_RENDER_LOG_DIR="$ROOT/logs"
export CFW_RENDER_STATE_DIR="$STATE"
export CFW_RENDER_SECURITY_CMD="$ROOT/bin/security"
export FAKE_LOG="$ROOT/fake.log"
export FAKE_KEYCHAIN="$KEYCHAIN"
export FAKE_STEP="$ROOT/step.sh"
unset CFW_RENDER_ENGINE CFW_RENDER_ENGINE_CMD CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
mkdir -p "$HOME/.claude" "$HOME/.codex" "$TMPDIR" "$CFW_RENDER_LOG_DIR" "$KEYCHAIN" "$ROOT/bin" || exit 2
: > "$WORKER_LOG"
# A planted ~/.claude: it must never be read, copied or used.
printf '%s\n' '{"outputStyle":"WI24-PLANTED-STYLE"}' > "$HOME/.claude/settings.json"

# The token is a test value made here; it never leaves $ROOT.
TOKEN="sk-ant-oat01-WI24TESTTOKEN-$$-$RANDOM$RANDOM"
write_key() { printf '%s\n' "$TOKEN" > "$KEYCHAIN/claude-code"; }   # the real item prints with a newline
drop_key() { rm -f "$KEYCHAIN/claude-code"; }

# Fake `security`: find-generic-password -s com.cfw.render -a <account> [-w].
# rc 0 iff $KEYCHAIN/<account> exists (the secret only with -w), else rc 44.
# Only the argv is logged, never the secret.
cat > "$ROOT/bin/security" <<'EOF'
#!/usr/bin/env bash
printf 'security|%s\n' "$*" >> "${FAKE_LOG:?}"
[[ "${1:-}" == find-generic-password ]] || exit 1
shift
svc=""; acct=""; want=0
while (($#)); do
  case "$1" in
    -s) svc="${2:-}"; shift 2 ;;
    -a) acct="${2:-}"; shift 2 ;;
    -w) want=1; shift ;;
    *) shift ;;
  esac
done
[[ "$svc" == com.cfw.render && -n "$acct" && -f "${FAKE_KEYCHAIN:?}/$acct" ]] || exit 44
if (( want )); then cat "$FAKE_KEYCHAIN/$acct"; fi
exit 0
EOF

# The step stand-in: writes what it sees to $STEP_REPORT (in the work folder).
# It never prints the token to stdout or stderr, so the step log can only hold
# it if the engine put it there. With STEP_WAIT=<path> it stops after writing
# <path>.ready until <path>.go exists (at most 20 s), so the test can list the
# process table from OUTSIDE the sandbox: ps itself cannot start under
# sandbox-exec (it is a restricted binary).
cat > "$ROOT/step.sh" <<'EOF'
#!/usr/bin/env bash
set -u
cat >/dev/null || true
report="${STEP_REPORT:?}"
{
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-}"
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
  printf 'SANDBOX=%s\n' "${CFW_RENDER_CODER_SANDBOX:-}"
  printf 'CLAUDE_ARGS=%s\n' "${FAKE_CLAUDE_ARGS-}"
} > "$report"
if [[ -n "${STEP_WAIT:-}" ]]; then
  : > "$STEP_WAIT.ready"
  i=0
  while [[ ! -e "$STEP_WAIT.go" && $i -lt 200 ]]; do sleep 0.1; i=$((i+1)); done
fi
exit 0
EOF

# Fake claude: `-p` (the real step command line) behaves like the step stand-in
# and reports its argv through the step report (the write sandbox refuses the
# log file); any other call is logged and fails. `auth status` must never come.
cat > "$ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -p ]]; then
  export FAKE_CLAUDE_ARGS="$*"
  exec bash "${FAKE_STEP:?}"
fi
printf 'claude|%s|CLAUDE_CONFIG_DIR=%s\n' "$*" "${CLAUDE_CONFIG_DIR:-unset}" >> "${FAKE_LOG:?}"
exit 1
EOF
# Fake codex: signed in iff the temp CODEX_HOME holds the sign-in link/file.
cat > "$ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex|%s|CODEX_HOME=%s\n' "$*" "${CODEX_HOME:-unset}" >> "${FAKE_LOG:?}"
if [[ "${1:-}" == login && "${2:-}" == status ]]; then
  [[ -n "${CODEX_HOME:-}" && -e "$CODEX_HOME/auth.json" ]]
  exit
fi
if [[ "${1:-}" == exec ]]; then exec bash "${FAKE_STEP:?}"; fi
exit 0
EOF
chmod 755 "$ROOT/bin/security" "$ROOT/bin/claude" "$ROOT/bin/codex" "$ROOT/step.sh" || exit 2
export PATH="$ROOT/bin:$PATH"

# shellcheck disable=SC1091
source "$REPO_DIR/bin/cfw-render-lib.sh" || { echo "engine-claude-token: cannot source the lib" >&2; exit 2; }
# shellcheck disable=SC1091
source "$REPO_DIR/bin/cfw-render-engine.sh" || { echo "engine-claude-token: cannot source the engine" >&2; exit 2; }
# The worker log of this test: every cr_log line lands in one file we can search.
cr_log() { printf '%s\n' "$*" >> "$WORKER_LOG"; }

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
field() { sed -n "s/^$1=//p" "$2" | tail -n 1; }
probe_dirs() { find "$TMPDIR" -maxdepth 1 -name 'cfw-engine-probe.*' 2>/dev/null | wc -l | tr -d ' '; }
log_lines() { grep -c "$1" "$FAKE_LOG" 2>/dev/null || true; }

echo "=== a. claude-code is signed in iff the CLI and the Keychain item exist ==="
drop_key
: > "$FAKE_LOG"
rc=0; ( umask 022; cr_engine_signed_in claude-code ) || rc=$?
[[ "$rc" == 1 ]] && pass "no Keychain item: not signed in (rc 1)" || fail "no item" "rc=$rc"
printf '%s\n' 'other-secret' > "$KEYCHAIN/gemini"
rc=0; cr_engine_signed_in claude-code || rc=$?
[[ "$rc" == 1 ]] && pass "an item for another account does not count (rc 1)" || fail "other account" "rc=$rc"
rm -f "$KEYCHAIN/gemini"
write_key
: > "$FAKE_LOG"
rc=0; cr_engine_signed_in claude-code || rc=$?
[[ "$rc" == 0 ]] && pass "Keychain item present: signed in (rc 0)" || fail "item present" "rc=$rc"
[[ "$(grep -c '^security|' "$FAKE_LOG")" == 1 && "$(grep '^security|' "$FAKE_LOG")" == "security|find-generic-password -s com.cfw.render -a claude-code" ]] \
  && pass "asked the Keychain once, by exit code (no -w)" || fail "keychain ask" "$(grep '^security|' "$FAKE_LOG" | tr '\n' ' ')"
[[ -z "$(grep '^claude|' "$FAKE_LOG")" ]] \
  && pass "claude auth status was never run" || fail "claude called" "$(grep '^claude|' "$FAKE_LOG" | tr '\n' ' ')"
[[ ! -e "$STATE/claude" && ! -e "$STATE" ]] \
  && pass "no shared Claude folder (and no state dir) was created" || fail "shared folder" "$STATE exists"
[[ "$(probe_dirs)" == 0 ]] && pass "no temp probe folder for claude-code" || fail "temp probe folder" "$(probe_dirs) left under TMPDIR"
nocli_path="$ROOT/nobin:/usr/bin:/bin"
if ( PATH="$nocli_path"; command -v claude >/dev/null 2>&1 ); then
  skip "signed in needs the CLI" "a claude is already on $nocli_path"
else
  rc=0; ( PATH="$nocli_path"; cr_engine_signed_in claude-code ) || rc=$?
  [[ "$rc" == 1 ]] && pass "item present but no claude on PATH: not signed in (rc 1)" || fail "no CLI" "rc=$rc"
fi
[[ ! -e "$HOME/.claude/.credentials.json" && "$(cat "$HOME/.claude/settings.json")" == '{"outputStyle":"WI24-PLANTED-STYLE"}' ]] \
  && pass "the planted \$HOME/.claude was not used or changed" || fail "planted \$HOME/.claude" "touched"
rc=0; ( export CFW_RENDER_ENGINE_CMD=true; cr_engine_signed_in claude-code ) || rc=$?
[[ "$rc" == 0 ]] && pass "CFW_RENDER_ENGINE_CMD still short-circuits to signed in" || fail "engine cmd short-circuit" "rc=$rc"

echo "=== b. codex probe is unchanged: temp CODEX_HOME, never the Claude item ==="
: > "$FAKE_LOG"
rc=0; cr_engine_signed_in codex || rc=$?
[[ "$rc" == 1 ]] && pass "codex without a sign-in file: rc 1" || fail "codex no sign-in" "rc=$rc"
codex_line="$(grep '^codex|' "$FAKE_LOG" | head -n 1)"
[[ "$codex_line" == "codex|login status|CODEX_HOME=$TMPDIR/cfw-engine-probe."*"/codex" ]] \
  && pass "codex login status ran in a temp CODEX_HOME" || fail "codex probe dir" "$codex_line"
[[ -z "$(grep '^claude|\|^security|' "$FAKE_LOG")" ]] \
  && pass "the codex probe did not call claude or the Keychain" || fail "codex vs claude" "$(tr '\n' ' ' < "$FAKE_LOG")"
[[ "$(probe_dirs)" == 0 ]] && pass "codex temp probe folder was removed" || fail "codex temp folder" "$(probe_dirs) left"
printf '%s\n' 'fake-codex-signin-marker' > "$HOME/.codex/auth.json"
rc=0; cr_engine_signed_in codex || rc=$?
[[ "$rc" == 0 ]] && pass "codex with the linked sign-in file: rc 0" || fail "codex sign-in link" "rc=$rc"
rm -f "$HOME/.codex/auth.json"

# argv_hits — how many running processes hold the token in their command line.
# Looked at from the test, outside the sandbox. "ps-failed" if ps cannot list.
argv_hits() {
  local c=0 line
  /bin/ps -Ao args= > "$ROOT/ps.out" 2>/dev/null || { echo ps-failed; return 0; }
  while IFS= read -r line; do
    case "$line" in *"$TOKEN"*) c=$((c+1)) ;; esac
  done < "$ROOT/ps.out"
  rm -f "$ROOT/ps.out"
  echo "$c"
}

# run_case <name> <engine> <cmd|cli> <natural|enclosing> [watch]
#   cmd = CFW_RENDER_ENGINE_CMD stand-in; cli = the engine's own command line
#   run against the fake claude/codex on PATH.
#   natural = the sandbox mode this computer reports (sandbox-exec when it can);
#   enclosing = the plain exec form (no sandbox-exec), forced.
#   watch = hold the step open and count the processes with the token in argv.
# Sets RUN_RC, WORK, REPORT, STEPLOG, ARGV_HITS; $ROOT/leak-<name> exists iff the
# caller's shell was left with a CLAUDE_CODE_OAUTH_TOKEN variable.
run_case() {
  local name="$1" engine="$2" via="$3" mode="$4" watch="${5:-}" hold="" pid="" i=0
  WORK="$ROOT/work-$name"; REPORT="$WORK/report.txt"; STEPLOG="$ROOT/logs/$name.log"
  mkdir -p "$WORK" "$ROOT/logs" || exit 2
  printf 'render the fixture\n' > "$WORK/prompt.md"
  RUN_RC=0; ARGV_HITS=unwatched
  [[ -n "$watch" ]] && hold="$WORK/hold"
  unset CR_ENGINE_SANDBOX_MODE
  [[ "$mode" == enclosing ]] && CR_ENGINE_SANDBOX_MODE=enclosing
  # A subshell, so the test can look at the process table while the step runs.
  # It also checks, as the caller of cr_engine_run, that no token variable is
  # left in the worker's own shell afterwards.
  (
    rc=0
    if [[ "$via" == cmd ]]; then
      CFW_RENDER_ENGINE_CMD="bash $FAKE_STEP" STEP_REPORT="$REPORT" STEP_WAIT="$hold" \
        cr_engine_run "$engine" "$WORK/prompt.md" "$WORK" "$STEPLOG" > "$ROOT/$name.out" 2>&1 || rc=$?
    else
      STEP_REPORT="$REPORT" STEP_WAIT="$hold" \
        cr_engine_run "$engine" "$WORK/prompt.md" "$WORK" "$STEPLOG" > "$ROOT/$name.out" 2>&1 || rc=$?
    fi
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ]]; then : > "$ROOT/leak-$name"; fi
    exit "$rc"
  ) &
  pid=$!
  if [[ -n "$hold" ]]; then
    while [[ ! -e "$hold.ready" && $i -lt 200 ]] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    if [[ -e "$hold.ready" ]]; then ARGV_HITS="$(argv_hits)"; else ARGV_HITS=never-ready; fi
    : > "$hold.go"
  fi
  wait "$pid" || RUN_RC=$?
  unset CR_ENGINE_SANDBOX_MODE
}

# secret_free <name> — the token is in no log, no profile and no per-step folder.
secret_free() {
  local name="$1" hits
  grep -qF -- "$TOKEN" "$STEPLOG" 2>/dev/null && fail "$name: step log" "holds the token" || pass "$name: the step log does not hold the token"
  grep -qF -- "$TOKEN" "$WORKER_LOG" "$ROOT/$name.out" 2>/dev/null && fail "$name: worker log" "holds the token" || pass "$name: the worker log does not hold the token"
  grep -qF -- "$TOKEN" "$WORK/.cfw-coder/profile.sb" 2>/dev/null && fail "$name: write profile" "holds the token" || pass "$name: the write profile does not hold the token"
  hits="$(grep -rlF -- "$TOKEN" "$WORK/.cfw-coder" "$CFW_RENDER_LOG_DIR" "$HOME" "$TMPDIR" 2>/dev/null | tr '\n' ' ')"
  [[ -z "$hits" ]] && pass "$name: no per-step folder, home or log folder holds the token" || fail "$name: token on disk" "$hits"
}

# check_isolation <name> — the per-step folders are exactly WI2.109's.
check_isolation() {
  local name="$1"
  [[ "$(field CLAUDE_CONFIG_DIR "$REPORT")" == "$WORK/.cfw-coder/claude" ]] \
    && pass "$name: CLAUDE_CONFIG_DIR is the per-step folder" || fail "$name: claude dir" "$(field CLAUDE_CONFIG_DIR "$REPORT")"
  [[ -d "$WORK/.cfw-coder/claude" && "$(mode_of "$WORK/.cfw-coder/claude")" == 700 ]] \
    && pass "$name: the per-step Claude folder exists, mode 700" || fail "$name: claude dir mode" "$(mode_of "$WORK/.cfw-coder/claude" 2>/dev/null)"
  [[ -z "$(ls -A "$WORK/.cfw-coder/claude" 2>/dev/null)" ]] \
    && pass "$name: the per-step Claude folder is empty (nothing copied, no sign-in)" || fail "$name: claude dir content" "$(ls -A "$WORK/.cfw-coder/claude" | tr '\n' ' ')"
  [[ "$(field CODEX_HOME "$REPORT")" == "$WORK/.cfw-coder/codex" ]] \
    && pass "$name: CODEX_HOME is the per-step folder" || fail "$name: codex dir" "$(field CODEX_HOME "$REPORT")"
  [[ ! -e "$STATE/claude" ]] && pass "$name: no shared Claude folder under the state dir" || fail "$name: shared folder" "$STATE/claude"
}

echo "=== c. cr_engine_run claude-code hands the Keychain token to the step only ==="
cr_engine_sandbox_probe
natural_mode="$CR_ENGINE_SANDBOX_MODE"
unset CR_ENGINE_SANDBOX_MODE
for combo in "cmd natural" "cli natural" "cmd enclosing" "cli enclosing"; do
  set -- $combo; via="$1"; mode="$2"
  name="c-$via-$mode"
  if [[ "$mode" == natural && "$natural_mode" != apply ]]; then
    skip "$name" "sandbox-exec mode here is '$natural_mode', not apply; the plain exec form runs as c-$via-enclosing"
    continue
  fi
  write_key
  : > "$FAKE_LOG"
  run_case "$name" claude-code "$via" "$mode" watch
  [[ "$RUN_RC" == 0 && -f "$REPORT" ]] && pass "$name: the step ran (rc 0, report written)" \
    || fail "$name: step run" "rc=$RUN_RC log=$(tail -c 240 "$STEPLOG" 2>/dev/null | tr '\n' ' ')"
  [[ -f "$REPORT" ]] || continue
  [[ "$(field CLAUDE_CODE_OAUTH_TOKEN "$REPORT")" == "$TOKEN" ]] \
    && pass "$name: the step sees CLAUDE_CODE_OAUTH_TOKEN from the Keychain item" || fail "$name: token in step" "wrong or missing"
  if [[ "$mode" == natural ]]; then
    [[ "$(field SANDBOX "$REPORT")" == apply ]] && pass "$name: ran under sandbox-exec" || fail "$name: sandbox" "$(field SANDBOX "$REPORT")"
  else
    [[ "$(field SANDBOX "$REPORT")" == enclosing ]] && pass "$name: ran on the plain exec form" || fail "$name: sandbox" "$(field SANDBOX "$REPORT")"
  fi
  if [[ "$ARGV_HITS" == ps-failed ]]; then skip "$name: argv" "ps could not list processes here"
  else [[ "$ARGV_HITS" == 0 ]] && pass "$name: no process had the token in its argv while the step ran" || fail "$name: token in argv" "$ARGV_HITS"; fi
  [[ "$(grep -c '^security|.* -w' "$FAKE_LOG")" == 1 && -n "$(grep '^security|find-generic-password -s com.cfw.render -a claude-code -w$' "$FAKE_LOG")" ]] \
    && pass "$name: the secret was read once, for claude-code only" || fail "$name: keychain reads" "$(grep '^security|' "$FAKE_LOG" | tr '\n' ' ')"
  [[ ! -e "$ROOT/leak-$name" ]] && pass "$name: the worker's own environment never got the token" || fail "$name: worker env" "CLAUDE_CODE_OAUTH_TOKEN left set"
  check_isolation "$name"
  secret_free "$name"
  if [[ "$via" == cli ]]; then
    [[ "$(field CLAUDE_ARGS "$REPORT")" == "-p --dangerously-skip-permissions --output-format text" ]] \
      && pass "$name: the real command line ran (claude -p, the pinned flags)" || fail "$name: claude call" "$(field CLAUDE_ARGS "$REPORT")"
    [[ -z "$(grep '^claude|' "$FAKE_LOG")" ]] \
      && pass "$name: no other claude call (no auth status)" || fail "$name: other claude call" "$(grep '^claude|' "$FAKE_LOG" | tr '\n' ' ')"
  fi
done
# Everything the token touched on disk, over the whole temp tree: the Keychain
# stand-in and the step reports, nothing else.
holders="$(grep -rlF -- "$TOKEN" "$ROOT" 2>/dev/null | sed "s#^$ROOT/##" | grep -v '^work-c-.*/report.txt$' | grep -v '^keychain/claude-code$' | tr '\n' ' ')"
[[ -z "$holders" ]] && pass "c: the token is on disk only in the Keychain stand-in and the step reports" || fail "c: token files" "$holders"
[[ ! -e "$HOME/.claude/.credentials.json" && "$(cat "$HOME/.claude/settings.json")" == '{"outputStyle":"WI24-PLANTED-STYLE"}' ]] \
  && pass "c: the planted \$HOME/.claude was not used or changed" || fail "c: planted \$HOME/.claude" "touched"

echo "=== d. without the Keychain item the step gets no token ==="
for combo in "cmd natural" "cli natural"; do
  set -- $combo; via="$1"; mode="$2"
  name="d-$via"
  if [[ "$natural_mode" == missing ]]; then skip "$name" "sandbox-exec is missing on this computer"; continue; fi
  drop_key
  : > "$FAKE_LOG"
  run_case "$name" claude-code "$via" "$mode"
  [[ "$RUN_RC" == 0 && -f "$REPORT" ]] && pass "$name: the step ran (rc 0, report written)" \
    || fail "$name: step run" "rc=$RUN_RC log=$(tail -c 240 "$STEPLOG" 2>/dev/null | tr '\n' ' ')"
  [[ -f "$REPORT" ]] || continue
  [[ "$(field CLAUDE_CODE_OAUTH_TOKEN "$REPORT")" == unset ]] \
    && pass "$name: CLAUDE_CODE_OAUTH_TOKEN is not set in the step" || fail "$name: token in step" "$(field CLAUDE_CODE_OAUTH_TOKEN "$REPORT")"
  [[ -z "$(grep ' -w' "$FAKE_LOG" | grep '^security|')" && -n "$(grep '^security|find-generic-password -s com.cfw.render -a claude-code$' "$FAKE_LOG")" ]] \
    && pass "$name: the Keychain was asked by exit code only, no secret read" || fail "$name: keychain asks" "$(grep '^security|' "$FAKE_LOG" | tr '\n' ' ')"
  check_isolation "$name"
done

echo "=== e. cr_engine_run codex never gets the Claude token ==="
write_key
printf '%s\n' 'fake-codex-signin-marker' > "$HOME/.codex/auth.json"
for via in cmd cli; do
  name="e-$via"
  if [[ "$natural_mode" == missing ]]; then skip "$name" "sandbox-exec is missing on this computer"; continue; fi
  : > "$FAKE_LOG"
  run_case "$name" codex "$via" natural
  [[ "$RUN_RC" == 0 && -f "$REPORT" ]] && pass "$name: the codex step ran (rc 0, report written)" \
    || fail "$name: step run" "rc=$RUN_RC log=$(tail -c 240 "$STEPLOG" 2>/dev/null | tr '\n' ' ')"
  [[ -f "$REPORT" ]] || continue
  [[ "$(field CLAUDE_CODE_OAUTH_TOKEN "$REPORT")" == unset ]] \
    && pass "$name: no CLAUDE_CODE_OAUTH_TOKEN in a codex step" || fail "$name: token in codex step" "$(field CLAUDE_CODE_OAUTH_TOKEN "$REPORT")"
  [[ -z "$(grep '^security|' "$FAKE_LOG")" ]] \
    && pass "$name: the Keychain was not asked for a codex step" || fail "$name: keychain asks" "$(grep '^security|' "$FAKE_LOG" | tr '\n' ' ')"
  [[ ! -e "$ROOT/leak-$name" ]] && pass "$name: the worker's own environment never got the token" || fail "$name: worker env" "CLAUDE_CODE_OAUTH_TOKEN left set"
  [[ "$(field CODEX_HOME "$REPORT")" == "$WORK/.cfw-coder/codex" ]] \
    && pass "$name: CODEX_HOME is the per-step folder" || fail "$name: codex dir" "$(field CODEX_HOME "$REPORT")"
  [[ -L "$WORK/.cfw-coder/codex/auth.json" ]] \
    && pass "$name: the codex sign-in link is still in the per-step folder" || fail "$name: sign-in link" "missing"
  [[ -d "$WORK/.cfw-coder/claude" && -z "$(ls -A "$WORK/.cfw-coder/claude")" ]] \
    && pass "$name: the per-step Claude folder is empty" || fail "$name: claude dir" "not empty"
  secret_free "$name"
done
rm -f "$HOME/.codex/auth.json"

echo "=== f. cr_engines_json reports claude-code signedIn only with the item ==="
signed_in_json() {
  python3 -c 'import json, sys
rows = json.loads(sys.argv[1])
print([r["signedIn"] for r in rows if r["name"] == "claude-code"][0])' "$(cr_engines_json)"
}
drop_key
[[ "$(signed_in_json)" == "False" ]] && pass "claude-code signedIn false without the item" || fail "json without item" "$(signed_in_json)"
write_key
[[ "$(signed_in_json)" == "True" ]] && pass "claude-code signedIn true with the item" || fail "json with item" "$(signed_in_json)"
[[ "$(cr_engine_active)" == "claude-code" || "$(cr_engine_active)" == "codex" ]] \
  && pass "cr_engine_active can pick claude-code once signed in" || fail "cr_engine_active" "$(cr_engine_active)"

echo "=== g. the shared-folder design is gone from the engine ==="
if grep -q 'cr_engine_claude_dir\|cr_engine_scrub_claude_dir\|claude auth status >' "$REPO_DIR/bin/cfw-render-engine.sh"; then
  fail "engine source" "still mentions the shared Claude folder or a claude auth status probe"
else
  pass "no shared-folder helper and no claude auth status probe in cfw-render-engine.sh"
fi

echo "-------------------------------------"
echo "PASS: $PASS_COUNT   FAIL: $FAILURES   SKIP: $SKIPS"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
