#!/usr/bin/env bash
# test/install-engine-pin.test.sh — standalone check that install/install.sh no
# longer pins one AI engine in the worker settings file (WI24).
#
#   bash test/install-engine-pin.test.sh      # exit 0 iff every check passes
#
# The problem: install.sh probed codex then claude and wrote
# CFW_RENDER_ENGINE=<the first that ran> into ~/.cfw-render/cfw-render.env.
# bin/cfw-render-engine.sh (cr_engine_order) reads a set CFW_RENDER_ENGINE as
# "use ONLY this engine", so the worker listed and ran one engine, ignored the
# owner's provider order (engines.json, written by the app's AI Providers
# screen), and a good Claude sign-in never showed as Connected.
#
# What this test checks, with a throwaway HOME for every installer run, run with
# /bin/bash (the shell the desktop app starts install.sh with, updates.rs):
#   a. --from-app --update (what the desktop app runs after an app update) takes
#      a CFW_RENDER_ENGINE line out of the settings file and nothing else: the
#      other lines, their order and mode 600 stay, one "removed CFW_RENDER_ENGINE=
#      <value>" line goes to stderr, stdout stays one
#      {"step":"ready",...,"message":"Updated"} line, stdin is not read and no
#      temp file is left behind;
#   b. a settings file with no pin stays byte for byte the same (no pin is
#      added, no "removed" message); no settings file at all stays absent;
#   c. an indented pin line is removed too, and so is a hand-written
#      `export CFW_RENDER_ENGINE=...` line (the worker sources the file); a
#      comment, CFW_RENDER_ENGINE_CMD and CFW_RENDER_ENGINE_PROMPT_FILE are kept;
#      an odd value is never echoed; a file that holds only the pin is left
#      empty, still mode 600;
#   d. the full install (no --from-app) neither writes a pin nor keeps one: the
#      one "removed" line is on stdout, the engine check still runs
#      (install.sh: engine=...), the rest of the file is the same; with no engine
#      running (CFW_RENDER_TEST_NO_ENGINE=1) it still aborts and writes no pin;
#   e. the full install with --from-app (what the app runs on first set-up) keeps
#      stdout to JSON lines only and sends the "removed" line to stderr; with no
#      engine running it still fails the checking step;
#   f. the adopt path (--from-app, empty stdin, already set up) removes the pin
#      before its "Already set up" step, with stdout still JSON only and no
#      launchctl call;
#   g. when the pin cannot be removed (a read-only settings file, no temp file)
#      one "could not remove" line goes to stderr, the file is kept as it was,
#      and the update or install still finishes with rc 0;
#   h. cr_engine_order with no pin follows engines.json, and a pin in the shell
#      still forces one engine; the settings file the installer leaves behind
#      gives the owner's order; with a stub claude and a stub Keychain, the
#      engine list shows claude-code signed in (and, as a control, shows only
#      codex while the old pin is there).
#
# CFW_PIN_TEST_REPO=<dir> runs the installer and the engine from another checkout
# of this repo (used to show the checks FAIL against the old install.sh).
#
# Safe to run alone: every installer run has HOME, TMPDIR and the Playwright
# cache inside one temp folder, CFW_RENDER_SKIP_LAUNCHCTL=1 and
# CFW_RENDER_INSTALL_NO_LAUNCHCTL=1 (no launchctl, no LaunchAgent), a stand-in
# Director command (so no real codex or claude is run), and a mock CFW server on
# 127.0.0.1. It never reads the real ~/.cfw-render, ~/CFW Render or
# ~/Library/LaunchAgents. Never run test/run-tests.sh for this.
#
# It does not depend on the host's tools. The full install runs the toolchain
# preflight (cr_preflight, WI17), which resolves ffmpeg, ffprobe, magick, node,
# npx and whisper with `command -v` on PATH (and the --dry check at the end wants a
# claude) and asks ffmpeg for the ass filter
# (libass) and the libx264 encoder. A host ffmpeg built without libass (the
# Homebrew /opt/homebrew/bin/ffmpeg, which the gate puts first on PATH) failed
# the full-install cases there while they passed on a developer PATH. The
# preflight has no environment override that points at a tools folder (WI17's
# CFW_RENDER_TOOLS_DIR only changes the PATH the worker gets), so, like WI17's
# own preflight cases in run-tests.sh, this test puts stand-ins for those seven
# tools first on the installer's PATH. curl and python3 stay real (the mock
# server needs them). The Keychain command is a stand-in too
# (CFW_RENDER_SECURITY_CMD, and first on PATH): it answers "not found" (exit 44),
# or a mock render key from a file in the one Keychain-only adopt case, and logs
# every call. The last check fails if any call was not a com.cfw.render lookup.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${CFW_PIN_TEST_REPO:-$(cd "$TEST_DIR/.." && pwd)}"
INSTALL="$REPO_DIR/install/install.sh"
MOCK="$TEST_DIR/mock-server.py"
# The shell the desktop app starts install.sh with (desktop/src-tauri/src/updates.rs,
# setup.rs run it as `bash`; on macOS that is /bin/bash 3.2), whatever shell runs this test.
INSTALL_SHELL=/bin/bash

PASS_COUNT=0
FAILURES=0
SKIPS=0
pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }
skip() { printf '  SKIP  %s — %s\n' "$1" "$2"; SKIPS=$((SKIPS+1)); }

[[ -x "$INSTALL_SHELL" ]] || { echo "install-engine-pin: $INSTALL_SHELL is missing" >&2; exit 2; }
[[ -f "$INSTALL" && -f "$REPO_DIR/bin/cfw-render-engine.sh" ]] || { echo "install-engine-pin: $REPO_DIR is not a cfw-render checkout" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cfw-engine-pin.XXXXXX")" || { echo "install-engine-pin: cannot make a temp folder" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)" || exit 2
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; fi
  if [[ -n "${ROOT:-}" && -d "$ROOT" ]]; then rm -rf -- "$ROOT"; fi
}
trap cleanup EXIT

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
count_matching() { # count_matching <pattern> <file> — lines that match (0 when none or no file)
  local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)" || true; printf '%s' "${n:-0}"
}
temp_leftovers() { find "$1" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' '; }

# The pinned Playwright browser cache, as the installer's preflight wants it
# (config/playwright-pin.json). A finished fixture, so no run downloads anything.
PW="$ROOT/pw"
pin_field() { ( source "$REPO_DIR/bin/cfw-render-lib.sh" 2>/dev/null; cr_playwright_pin_field "$1" ); }
crev="$(pin_field chromiumRevision)"; hrev="$(pin_field chromiumHeadlessShellRevision)"
if [[ -z "$crev" || -z "$hrev" ]]; then echo "install-engine-pin: cannot read config/playwright-pin.json" >&2; exit 2; fi
mkdir -p "$PW/chromium-$crev" "$PW/chromium_headless_shell-$hrev" || exit 2
: > "$PW/chromium-$crev/INSTALLATION_COMPLETE"
: > "$PW/chromium_headless_shell-$hrev/INSTALLATION_COMPLETE"

# The mock CFW server (test/mock-server.py): lets the full install end with rc 0.
PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null)"
MOCK_OK=0
if [[ -n "$PORT" && -f "$MOCK" ]]; then
  mkdir -p "$ROOT/mock-state"; echo '[]' > "$ROOT/mock-queue.json"
  python3 "$MOCK" "$PORT" "$ROOT/mock-state" "$ROOT/mock-queue.json" > "$ROOT/mock.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 60); do
    curl -sS --max-time 1 "http://127.0.0.1:$PORT/api/v1/mcp" >/dev/null 2>&1 && { MOCK_OK=1; break; }
    sleep 0.1
  done
fi
API="http://127.0.0.1:$PORT"
# What the mock hands out on a key exchange (test/mock-server.py). A --from-app
# run rewrites these two settings lines, so the fixture holds the same values and
# the "other lines stay the same" check can compare the whole file.
MOCK_RENDER_KEY="cfw_render_mock-brand_xchg-0Ab9_Zq1"

# A stand-in launchctl first on PATH for every installer run: it records the call
# and does nothing. No run is meant to call it (CFW_RENDER_SKIP_LAUNCHCTL=1); the
# last check fails if one did, and the real launchctl is never reached.
STUB_BIN="$ROOT/stubbin"; LAUNCHCTL_LOG="$ROOT/launchctl.calls"
mkdir -p "$STUB_BIN" || exit 2
cat > "$STUB_BIN/launchctl" <<EOF
#!/bin/sh
echo "launchctl called" >> "$LAUNCHCTL_LOG"
exit 0
EOF
chmod 755 "$STUB_BIN/launchctl"

# Toolchain stand-ins for the preflight (see the header). ffmpeg answers the two
# questions the preflight asks, in WI17's own format; the rest only have to exist.
cat > "$STUB_BIN/ffmpeg" <<'EOF'
#!/bin/sh
if [ "$1" = "-hide_banner" ] && [ "$2" = "-filters" ]; then printf '%s\n' ' .. ass               V->V       Render ASS subtitles'; exit 0; fi
if [ "$1" = "-hide_banner" ] && [ "$2" = "-encoders" ]; then printf '%s\n' ' V..... libx264              libx264 H.264'; exit 0; fi
exit 0
EOF
printf '#!/bin/sh\necho "Version: ImageMagick 7.1.1-47 stand-in"\nexit 0\n' > "$STUB_BIN/magick"
for tool in ffprobe node npx whisper; do printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$tool"; done
# The --dry check at the end of the full install wants a `claude` on PATH (it only looks it up).
printf '#!/bin/sh\necho "0.0.0 (stand-in)"\nexit 0\n' > "$STUB_BIN/claude"
chmod 755 "$STUB_BIN/ffmpeg" "$STUB_BIN/magick" "$STUB_BIN/ffprobe" "$STUB_BIN/node" "$STUB_BIN/npx" "$STUB_BIN/whisper" "$STUB_BIN/claude"

# A stand-in `security`. The installer reaches the Keychain through
# CFW_RENDER_SECURITY_CMD (fa_keychain_worker_key, cr_keychain_render_worker_key)
# and otherwise runs /usr/bin/security itself. It logs argv (never a secret) and
# answers exit 44 (item not found), except for the render-worker lookup when
# FAKE_RENDER_KEY_FILE names a file: then it prints that file.
SECURITY_LOG="$ROOT/security.calls"
cat > "$STUB_BIN/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SECURITY_LOG:?}"
if [ "$1" = "find-generic-password" ] && [ -n "${FAKE_RENDER_KEY_FILE:-}" ] && [ -f "$FAKE_RENDER_KEY_FILE" ]; then
  case " $* " in *" -a render-worker "*) cat "$FAKE_RENDER_KEY_FILE"; exit 0 ;; esac
fi
exit 44
EOF
chmod 755 "$STUB_BIN/security"
sec_calls() { if [[ -f "$SECURITY_LOG" ]]; then wc -l < "$SECURITY_LOG" | tr -d ' '; else echo 0; fi; }

# new_case <name> [env-file line ...] — a fresh HOME with the settings file at its
# default place (~/.cfw-render/cfw-render.env), mode 600. No lines = no file.
CASE=""; ENVF=""
new_case() {
  local name="$1"; shift
  CASE="$ROOT/$name"; ENVF="$CASE/home/.cfw-render/cfw-render.env"
  mkdir -p "$CASE/home/.cfw-render" "$CASE/tmp" || exit 2
  if (( $# )); then printf '%s\n' "$@" > "$ENVF"; chmod 600 "$ENVF"; fi
  printf 'KEEP-THIS-LINE\n' > "$CASE/stdin"
}

# run_installer <args...> — install.sh in $CASE with a fully scrubbed environment.
# Sets RC; stdout in $CASE/out, stderr in $CASE/err, what stdin still held in
# $CASE/rest. Refuses to run unless HOME is inside the temp folder. EXTRA_ENV
# (words like NAME=value, no spaces) is added to the installer's environment.
RC=0; EXTRA_ENV=""; PATH_PREFIX=""   # PATH_PREFIX: a folder (with a trailing colon) put first on PATH
run_installer() {
  case "$CASE" in "$ROOT"/*) ;; *) echo "install-engine-pin: refusing to run outside $ROOT" >&2; exit 2 ;; esac
  RC=0
  {
    # shellcheck disable=SC2086
    ( cd "$CASE" && env -i PATH="$PATH_PREFIX$STUB_BIN:$PATH" HOME="$CASE/home" TMPDIR="$CASE/tmp" PLAYWRIGHT_BROWSERS_PATH="$PW" \
        CFW_RENDER_SKIP_LAUNCHCTL=1 CFW_RENDER_INSTALL_NO_LAUNCHCTL=1 CFW_RENDER_DIRECTOR_CMD=/usr/bin/true \
        CFW_RENDER_PROBE_POLL_SEC=0.1 CFW_RENDER_SECURITY_CMD="$STUB_BIN/security" FAKE_SECURITY_LOG="$SECURITY_LOG" $EXTRA_ENV \
        "$INSTALL_SHELL" "$INSTALL" "$@" > "$CASE/out" 2> "$CASE/err" ) || RC=$?
    cat > "$CASE/rest"
  } < "$CASE/stdin"
}

want_env() { printf '%s\n' "$@" > "$CASE/want.env"; } # want_env <line ...>
env_is_want() { cmp -s "$CASE/want.env" "$ENVF"; }
one_updated_line() { [[ "$(cat "$CASE/out")" == '{"step": "ready", "state": "done", "message": "Updated"}' ]]; }
tail_of() { tail -c "${TAIL_BYTES:-300}" "$1" 2>/dev/null | tr '\n' ' '; }

KEY_LINE="CFW_RENDER_WORKER_KEY=cfw_render_dummy0000000000"
MODE_LINE="CFW_RENDER_MODE=byoa"
BASE_LINE="CFW_API_BASE=http://127.0.0.1:9"

echo "=== a. --from-app --update takes the pin out and changes nothing else ==="
new_case ua "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "$BASE_LINE" "$KEY_LINE"
run_installer --mode byoa --non-interactive --from-app --update
want_env "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
[[ "$RC" == 0 ]] && pass "a: rc 0" || fail "a: rc" "rc=$RC err=$(tail_of "$CASE/err")"
! grep -q '^[[:space:]]*CFW_RENDER_ENGINE=' "$ENVF" && pass "a: no CFW_RENDER_ENGINE line left" || fail "a: pin left" "$(cat "$ENVF")"
env_is_want && pass "a: every other line is the same, in the same order" || fail "a: other lines" "$(tr '\n' '|' < "$ENVF")"
[[ "$(mode_of "$ENVF")" == 600 ]] && pass "a: settings file is still mode 600" || fail "a: mode" "$(mode_of "$ENVF")"
[[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 1 && "$(count_matching "removed CFW_RENDER_ENGINE=codex from $ENVF; the app's AI Providers order picks the engine now\$" "$CASE/err")" == 1 ]] \
  && pass "a: exactly one \"removed CFW_RENDER_ENGINE=codex from <file>; ...\" line, on stderr" || fail "a: removed message" "stderr: $(tail_of "$CASE/err")"
[[ "$(count_matching "$KEY_LINE" "$CASE/err")" == 0 && "$(count_matching "$BASE_LINE" "$CASE/err")" == 0 ]] \
  && pass "a: no other line of the settings file is echoed" || fail "a: echo" "$(tail_of "$CASE/err")"
[[ "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] \
  && pass "a: the app's stdout channel has no engine text" || fail "a: stdout" "$(cat "$CASE/out")"
one_updated_line && pass "a: stdout is still exactly one Updated JSON line" || fail "a: stdout" "$(cat "$CASE/out")"
[[ "$(cat "$CASE/rest")" == "KEEP-THIS-LINE" ]] && pass "a: stdin was not read" || fail "a: stdin" "$(cat "$CASE/rest")"
[[ "$(temp_leftovers "$CASE/tmp")" == 0 ]] && pass "a: no temp file left behind" || fail "a: temp file" "$(ls -A "$CASE/tmp" | tr '\n' ' ')"
cmp -s "$REPO_DIR/VERSION" "$CASE/home/CFW Render/app/VERSION" && pass "a: the update still copied the app files" || fail "a: update" "VERSION not copied"
A_ENVF="$ENVF"

echo "=== b. no pin: the settings file is untouched and no message is printed ==="
new_case ub "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
run_installer --mode byoa --non-interactive --from-app --update
want_env "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
[[ "$RC" == 0 ]] && one_updated_line && pass "b: rc 0 and one Updated line" || fail "b: run" "rc=$RC out=$(cat "$CASE/out")"
env_is_want && pass "b: the file is byte for byte the same (no pin added)" || fail "b: file changed" "$(tr '\n' '|' < "$ENVF")"
[[ "$(mode_of "$ENVF")" == 600 ]] && pass "b: still mode 600" || fail "b: mode" "$(mode_of "$ENVF")"
[[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 0 && "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] \
  && pass "b: no \"removed\" message" || fail "b: message" "$(tail_of "$CASE/err")"
new_case ub2
run_installer --mode byoa --non-interactive --from-app --update
[[ "$RC" == 0 ]] && one_updated_line && [[ ! -e "$ENVF" ]] && pass "b: no settings file at all: still none, still one Updated line" \
  || fail "b: no file" "rc=$RC exists=$([[ -e "$ENVF" ]] && echo yes || echo no) out=$(cat "$CASE/out")"
[[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 0 ]] && pass "b: no message without a settings file" || fail "b: message" "$(tail_of "$CASE/err")"

echo "=== c. an indented pin and an export pin go; comments and the other ENGINE keys stay ==="
new_case uc "$MODE_LINE" "# CFW_RENDER_ENGINE=codex  (a comment)" "  CFW_RENDER_ENGINE=claude-code" "CFW_RENDER_ENGINE_CMD=true" "CFW_RENDER_ENGINE_PROMPT_FILE=/tmp/prompt.md" "$BASE_LINE" "$KEY_LINE"
run_installer --mode byoa --non-interactive --from-app --update
want_env "$MODE_LINE" "# CFW_RENDER_ENGINE=codex  (a comment)" "CFW_RENDER_ENGINE_CMD=true" "CFW_RENDER_ENGINE_PROMPT_FILE=/tmp/prompt.md" "$BASE_LINE" "$KEY_LINE"
[[ "$RC" == 0 ]] && one_updated_line && pass "c: rc 0 and one Updated line" || fail "c: run" "rc=$RC out=$(cat "$CASE/out")"
! grep -q '^[[:space:]]*CFW_RENDER_ENGINE=' "$ENVF" && pass "c: the indented pin line is gone" || fail "c: pin left" "$(cat "$ENVF")"
env_is_want && pass "c: the comment, CFW_RENDER_ENGINE_CMD and CFW_RENDER_ENGINE_PROMPT_FILE were kept, order kept" || fail "c: other lines" "$(tr '\n' '|' < "$ENVF")"
[[ "$(mode_of "$ENVF")" == 600 && "$(count_matching 'removed CFW_RENDER_ENGINE=claude-code from' "$CASE/err")" == 1 ]] \
  && pass "c: mode 600 and exactly one \"removed CFW_RENDER_ENGINE=claude-code\" line" || fail "c: mode or message" "mode=$(mode_of "$ENVF") $(tail_of "$CASE/err")"
new_case uc3 "$MODE_LINE" "export CFW_RENDER_ENGINE=codex" "# export CFW_RENDER_ENGINE=codex" "  export   CFW_RENDER_ENGINE='claude-code'" "export CFW_RENDER_ENGINE_CMD=true" "$BASE_LINE" "$KEY_LINE"
run_installer --mode byoa --non-interactive --from-app --update
want_env "$MODE_LINE" "# export CFW_RENDER_ENGINE=codex" "export CFW_RENDER_ENGINE_CMD=true" "$BASE_LINE" "$KEY_LINE"
[[ "$RC" == 0 ]] && one_updated_line && pass "c: export: rc 0 and one Updated line" || fail "c: export run" "rc=$RC out=$(cat "$CASE/out")"
env_is_want && pass "c: export: both \"export CFW_RENDER_ENGINE=\" lines are gone, the export comment and export CFW_RENDER_ENGINE_CMD stay" || fail "c: export lines" "$(tr '\n' '|' < "$ENVF")"
[[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 1 && "$(count_matching 'removed CFW_RENDER_ENGINE=claude-code from' "$CASE/err")" == 1 ]] \
  && pass "c: export: one \"removed\" line, naming the last pin's value" || fail "c: export message" "$(tail_of "$CASE/err")"
new_case uc4 "$MODE_LINE" "CFW_RENDER_ENGINE=co;de" "$BASE_LINE" "$KEY_LINE"
run_installer --mode byoa --non-interactive --from-app --update
want_env "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
env_is_want && [[ "$(count_matching 'removed CFW_RENDER_ENGINE from' "$CASE/err")" == 1 && "$(count_matching 'co;de' "$CASE/err")" == 0 ]] \
  && pass "c: a value that is not a plain engine name is removed but not echoed" || fail "c: odd value" "$(tail_of "$CASE/err")"
new_case uc2 "CFW_RENDER_ENGINE=codex"
run_installer --mode byoa --non-interactive --from-app --update
[[ "$RC" == 0 && -f "$ENVF" && ! -s "$ENVF" && "$(mode_of "$ENVF")" == 600 ]] \
  && pass "c: a file that held only the pin is left empty, mode 600" || fail "c: pin-only file" "rc=$RC size=$(wc -c < "$ENVF" 2>/dev/null) mode=$(mode_of "$ENVF")"

echo "=== d. the full install (no --from-app) neither writes nor keeps a pin ==="
if (( MOCK_OK )); then
  new_case nd "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "CFW_API_BASE=$API" "$KEY_LINE"
  run_installer --mode byoa
  want_env "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  [[ "$RC" == 0 ]] && pass "d: rc 0 (install and --dry both pass)" || fail "d: rc" "rc=$RC out=$(tail_of "$CASE/out") err=$(tail_of "$CASE/err")"
  ! grep -q '^[[:space:]]*CFW_RENDER_ENGINE=' "$ENVF" && pass "d: no CFW_RENDER_ENGINE line in the settings file" || fail "d: pin" "$(cat "$ENVF")"
  env_is_want && pass "d: every other line is the same, in the same order" || fail "d: other lines" "$(tr '\n' '|' < "$ENVF")"
  [[ "$(mode_of "$ENVF")" == 600 ]] && pass "d: still mode 600" || fail "d: mode" "$(mode_of "$ENVF")"
  [[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/out")" == 1 && "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 0 ]] \
    && pass "d: exactly one \"removed\" line, on stdout" || fail "d: message" "out: $(tail_of "$CASE/out")"
  grep -q '^install.sh: engine=codex$' "$CASE/out" && pass "d: the engine check still ran and printed install.sh: engine=codex" || fail "d: engine line" "$(grep 'engine=' "$CASE/out")"
  [[ "$(count_matching 'set CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] && pass "d: no \"set CFW_RENDER_ENGINE\" line" || fail "d: set line" "$(grep 'set CFW_RENDER_ENGINE' "$CASE/out")"
  [[ "$(temp_leftovers "$CASE/tmp")" == 0 ]] && pass "d: no temp file left behind" || fail "d: temp file" "$(ls -A "$CASE/tmp" | tr '\n' ' ')"
  new_case nd2 "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  run_installer --mode byoa
  want_env "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  [[ "$RC" == 0 ]] && env_is_want && ! grep -q 'CFW_RENDER_ENGINE' "$ENVF" \
    && pass "d: no pin in, no pin out (the installer adds none)" || fail "d: pin added" "rc=$RC file: $(tr '\n' '|' < "$ENVF")"
  [[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] && pass "d: no \"removed\" message without a pin" || fail "d: message" "$(grep removed "$CASE/out")"
  new_case nd3
  run_installer --mode byoa
  [[ "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/err")" == 0 && "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] \
    && pass "d: no settings file: the NOTE no longer tells the owner to add CFW_RENDER_ENGINE" || fail "d: NOTE" "$(grep 'CFW_RENDER_ENGINE' "$CASE/err" "$CASE/out")"
  grep -q "add 'CFW_RENDER_MODE=byoa'" "$CASE/err" && pass "d: no settings file: the CFW_RENDER_MODE NOTE is still there" || fail "d: mode NOTE" "$(tail_of "$CASE/err")"
else
  fail "d: mock server" "could not start $MOCK on port ${PORT:-?}: $(tail_of "$ROOT/mock.log")"
fi
# AC1: the engine check still stops the install when no engine runs
# (CFW_RENDER_TEST_NO_ENGINE=1 is the installer's seam for a computer with none).
new_case nd4 "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
EXTRA_ENV="CFW_RENDER_TEST_NO_ENGINE=1"
run_installer --mode byoa
EXTRA_ENV=""
want_env "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
[[ "$RC" != 0 ]] && grep -q 'ABORTING — no engine runs' "$CASE/err" \
  && pass "d: no engine runs: the install still aborts (rc $RC, \"ABORTING — no engine runs\")" || fail "d: no-engine abort" "rc=$RC err=$(tail_of "$CASE/err")"
env_is_want && ! grep -q 'CFW_RENDER_ENGINE' "$ENVF" && [[ ! -e "$CASE/home/CFW Render/app/bin" ]] \
  && pass "d: no engine runs: no pin written, the settings file untouched, nothing installed" || fail "d: no-engine side effects" "$(tr '\n' '|' < "$ENVF")"

echo "=== e. the full install with --from-app keeps stdout to JSON lines ==="
if (( MOCK_OK )); then
  new_case fe "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "CFW_API_BASE=$API" "CFW_RENDER_WORKER_KEY=$MOCK_RENDER_KEY"
  printf 'cfw_pintestbrandkey0123456789\n' > "$CASE/stdin"
  run_installer --mode byoa --non-interactive --from-app
  want_env "$MODE_LINE" "CFW_API_BASE=$API" "CFW_RENDER_WORKER_KEY=$MOCK_RENDER_KEY"
  [[ "$RC" == 0 ]] && pass "e: rc 0" || fail "e: rc" "rc=$RC err=$(tail_of "$CASE/err")"
  steps="$(python3 -c '
import json, sys
print(" ".join(json.loads(l)["step"] + ":" + json.loads(l)["state"] for l in open(sys.argv[1]) if l.strip()))' "$CASE/out" 2>/dev/null || echo NONJSON)"
  [[ "$steps" == *"installing:done"* && "$steps" == *"ready:done" ]] \
    && pass "e: every stdout line is JSON, and the steps run through to ready:done" || fail "e: stdout" "steps=$steps"
  [[ "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] && pass "e: the \"removed\" line is not on the JSON channel" || fail "e: stdout" "$(grep ENGINE "$CASE/out")"
  [[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 1 ]] && pass "e: exactly one \"removed\" line, on stderr" || fail "e: stderr" "$(tail_of "$CASE/err")"
  ! grep -q '^[[:space:]]*CFW_RENDER_ENGINE=' "$ENVF" && env_is_want && [[ "$(mode_of "$ENVF")" == 600 ]] \
    && pass "e: no pin, the other lines are the same, mode 600" || fail "e: settings file" "mode=$(mode_of "$ENVF") $(tr '\n' '|' < "$ENVF")"
else
  fail "e: mock server" "could not start $MOCK on port ${PORT:-?}"
fi
new_case fe2 "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
printf 'cfw_pintestbrandkey0123456789\n' > "$CASE/stdin"
EXTRA_ENV="CFW_RENDER_TEST_NO_ENGINE=1"
run_installer --mode byoa --non-interactive --from-app
EXTRA_ENV=""
want_env "$MODE_LINE" "$BASE_LINE" "$KEY_LINE"
last_json="$(tail -n 1 "$CASE/out" 2>/dev/null)"
[[ "$RC" == 3 && "$last_json" == '{"step": "checking", "state": "failed", "message": "No AI engine is signed in on this computer"'* ]] \
  && pass "e: no engine runs: the checking step fails (rc 3, JSON failed line)" || fail "e: no-engine abort" "rc=$RC last=$last_json"
env_is_want && pass "e: no engine runs: no pin written, the settings file untouched" || fail "e: no-engine side effects" "$(tr '\n' '|' < "$ENVF")"

echo "=== f. the adopt path (already set up, no key on stdin) removes the pin too ==="
if (( MOCK_OK )); then
  new_case fa "$MODE_LINE" "CFW_RENDER_ENGINE=claude-code" "CFW_API_BASE=$API" "$KEY_LINE"
  mkdir -p "$CASE/home/Library/LaunchAgents" && printf '<plist/>\n' > "$CASE/home/Library/LaunchAgents/com.cfw.render.plist"
  : > "$CASE/stdin"
  sec_before="$(sec_calls)"
  run_installer --mode byoa --non-interactive --from-app
  want_env "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  steps="$(python3 -c '
import json, sys
print(" ".join(json.loads(l)["step"] + ":" + json.loads(l)["state"] + ":" + json.loads(l)["message"].replace(" ", "_") for l in open(sys.argv[1]) if l.strip()))' "$CASE/out" 2>/dev/null || echo NONJSON)"
  [[ "$RC" == 0 && "$steps" == "checking:started:Checking_this_computer ready:done:Already_set_up" ]] \
    && pass "f: adopt: rc 0, stdout is the two JSON steps (checking, ready: Already set up)" || fail "f: adopt run" "rc=$RC steps=$steps err=$(tail_of "$CASE/err")"
  env_is_want && ! grep -q 'CFW_RENDER_ENGINE' "$ENVF" && [[ "$(mode_of "$ENVF")" == 600 ]] \
    && pass "f: adopt: the pin is gone, the other lines are the same, mode 600" || fail "f: adopt file" "mode=$(mode_of "$ENVF") $(tr '\n' '|' < "$ENVF")"
  [[ "$(count_matching 'removed CFW_RENDER_ENGINE=claude-code from' "$CASE/err")" == 1 && "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] \
    && pass "f: adopt: one \"removed\" line on stderr, none on the JSON channel" || fail "f: adopt message" "$(tail_of "$CASE/err")"
  [[ "$(sec_calls)" == "$sec_before" ]] && pass "f: adopt with the key in the settings file does not ask the Keychain" || fail "f: adopt keychain" "$(sec_calls) calls, was $sec_before"
  new_case fa2 "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  mkdir -p "$CASE/home/Library/LaunchAgents" && printf '<plist/>\n' > "$CASE/home/Library/LaunchAgents/com.cfw.render.plist"
  : > "$CASE/stdin"
  run_installer --mode byoa --non-interactive --from-app
  want_env "$MODE_LINE" "CFW_API_BASE=$API" "$KEY_LINE"
  [[ "$RC" == 0 ]] && env_is_want && [[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 0 ]] \
    && pass "f: adopt without a pin: file untouched, no message" || fail "f: adopt no pin" "rc=$RC $(tr '\n' '|' < "$ENVF")"
  # Keychain-only set-up (WI17): no worker key in the settings file, the render key is in the Keychain.
  new_case fk "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "CFW_API_BASE=$API"
  mkdir -p "$CASE/home/Library/LaunchAgents" && printf '<plist/>\n' > "$CASE/home/Library/LaunchAgents/com.cfw.render.plist"
  : > "$CASE/stdin"
  printf 'cfw_render_keychainonlymock0123456789\n' > "$CASE/keychain-key"
  sec_before="$(sec_calls)"
  EXTRA_ENV="FAKE_RENDER_KEY_FILE=$CASE/keychain-key"
  run_installer --mode byoa --non-interactive --from-app
  EXTRA_ENV=""
  want_env "$MODE_LINE" "CFW_API_BASE=$API"
  steps="$(python3 -c '
import json, sys
print(" ".join(json.loads(l)["step"] + ":" + json.loads(l)["state"] + ":" + json.loads(l)["message"].replace(" ", "_") for l in open(sys.argv[1]) if l.strip()))' "$CASE/out" 2>/dev/null || echo NONJSON)"
  [[ "$RC" == 0 && "$steps" == "checking:started:Checking_this_computer ready:done:Already_set_up" ]] \
    && pass "f: Keychain-only adopt: rc 0, \"Already set up\" (the render key came from the Keychain stand-in)" || fail "f: keychain adopt run" "rc=$RC steps=$steps err=$(tail_of "$CASE/err")"
  env_is_want && [[ "$(count_matching 'removed CFW_RENDER_ENGINE=codex from' "$CASE/err")" == 1 && "$(count_matching 'CFW_RENDER_ENGINE' "$CASE/out")" == 0 ]] \
    && pass "f: Keychain-only adopt: the pin is removed, nothing else changes, one \"removed\" line on stderr" || fail "f: keychain adopt file" "$(tr '\n' '|' < "$ENVF") $(tail_of "$CASE/err")"
  [[ "$(( $(sec_calls) - sec_before ))" == 1 && "$(tail -n 1 "$SECURITY_LOG")" == "find-generic-password -s com.cfw.render -a render-worker -w" ]] \
    && pass "f: Keychain-only adopt: one render-worker lookup, and it went to the stand-in" || fail "f: keychain calls" "$(( $(sec_calls) - sec_before )) new, last: $(tail -n 1 "$SECURITY_LOG")"
  new_case fn "$MODE_LINE" "CFW_API_BASE=$API"
  mkdir -p "$CASE/home/Library/LaunchAgents" && printf '<plist/>\n' > "$CASE/home/Library/LaunchAgents/com.cfw.render.plist"
  : > "$CASE/stdin"
  sec_before="$(sec_calls)"
  run_installer --mode byoa --non-interactive --from-app
  last_json="$(tail -n 1 "$CASE/out" 2>/dev/null)"
  [[ "$RC" == 5 && "$last_json" == '{"step": "connecting", "state": "failed", "message": "No key was given"'* && "$(( $(sec_calls) - sec_before ))" == 1 ]] \
    && pass "f: no key in the file and none in the Keychain (exit 44): \"No key was given\" (rc 5) after one lookup" || fail "f: no key anywhere" "rc=$RC last=$last_json calls=$(( $(sec_calls) - sec_before ))"
else
  fail "f: mock server" "could not start $MOCK on port ${PORT:-?}"
fi

echo "=== g. a pin that cannot be removed: one clear line, file kept, the install still finishes ==="
if [[ "$(id -u)" == 0 ]]; then
  skip "g: read-only settings file" "running as root: root can write a mode 0400 file"
else
  new_case gr "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "$BASE_LINE" "$KEY_LINE"
  cp "$ENVF" "$CASE/orig.env"; chmod 400 "$ENVF"
  run_installer --mode byoa --non-interactive --from-app --update
  [[ "$RC" == 0 ]] && one_updated_line && cmp -s "$REPO_DIR/VERSION" "$CASE/home/CFW Render/app/VERSION" \
    && pass "g: read-only file: the update still finishes (rc 0, one Updated line, app files copied)" || fail "g: read-only run" "rc=$RC out=$(cat "$CASE/out") err=$(tail_of "$CASE/err")"
  [[ "$(count_matching "install.sh: could not remove CFW_RENDER_ENGINE from $ENVF (the file is read-only); remove that line by hand so the app's provider order is used\$" "$CASE/err")" == 1 ]] \
    && pass "g: read-only file: one \"could not remove ... (the file is read-only); remove that line by hand ...\" line on stderr" || fail "g: read-only message" "$(tail_of "$CASE/err")"
  [[ "$(count_matching 'removed CFW_RENDER_ENGINE' "$CASE/err")" == 0 ]] && pass "g: read-only file: no false \"removed\" line" || fail "g: false removed" "$(tail_of "$CASE/err")"
  cmp -s "$CASE/orig.env" "$ENVF" && [[ "$(mode_of "$ENVF")" == 400 ]] \
    && pass "g: read-only file: the file is kept as it was, mode 400" || fail "g: read-only file changed" "mode=$(mode_of "$ENVF") $(tr '\n' '|' < "$ENVF")"
  [[ "$(temp_leftovers "$CASE/tmp")" == 0 ]] && pass "g: read-only file: no temp file left behind" || fail "g: temp file" "$(ls -A "$CASE/tmp" | tr '\n' ' ')"
fi
new_case gt "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "$BASE_LINE" "$KEY_LINE"
cp "$ENVF" "$CASE/orig.env"
# macOS mktemp falls back to its own folder when TMPDIR is bad, so a failing mktemp is a stand-in.
mkdir -p "$CASE/nomktemp" && printf '#!/bin/sh\nexit 1\n' > "$CASE/nomktemp/mktemp" && chmod 755 "$CASE/nomktemp/mktemp"
PATH_PREFIX="$CASE/nomktemp:"
run_installer --mode byoa --non-interactive --from-app --update
PATH_PREFIX=""
[[ "$RC" == 0 ]] && one_updated_line && cmp -s "$CASE/orig.env" "$ENVF" \
  && [[ "$(count_matching "could not remove CFW_RENDER_ENGINE from $ENVF (no temp file could be made); remove that line by hand" "$CASE/err")" == 1 ]] \
  && pass "g: mktemp fails: one \"could not remove ... (no temp file could be made)\" line, file kept, update finished" || fail "g: no temp file" "rc=$RC out=$(cat "$CASE/out") err=$(tail_of "$CASE/err")"
if [[ "$(id -u)" != 0 ]] && (( MOCK_OK )); then
  new_case ga "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "CFW_API_BASE=$API" "$KEY_LINE"
  mkdir -p "$CASE/home/Library/LaunchAgents" && printf '<plist/>\n' > "$CASE/home/Library/LaunchAgents/com.cfw.render.plist"
  : > "$CASE/stdin"
  cp "$ENVF" "$CASE/orig.env"; chmod 400 "$ENVF"
  run_installer --mode byoa --non-interactive --from-app
  [[ "$RC" == 0 && "$(grep -c '"message": "Already set up"' "$CASE/out")" == 1 && "$(count_matching 'could not remove CFW_RENDER_ENGINE from' "$CASE/err")" == 1 ]] && cmp -s "$CASE/orig.env" "$ENVF" \
    && pass "g: adopt, read-only file: still ends \"Already set up\" (rc 0), one \"could not remove\" line, file kept" || fail "g: adopt read-only" "rc=$RC out=$(cat "$CASE/out") err=$(tail_of "$CASE/err")"
  new_case gf "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "CFW_API_BASE=$API" "$KEY_LINE"
  cp "$ENVF" "$CASE/orig.env"; chmod 400 "$ENVF"
  run_installer --mode byoa
  [[ "$RC" == 0 && "$(count_matching 'running validation (--dry)' "$CASE/out")" == 1 ]] \
    && pass "g: full install, read-only file: the install carries on to its --dry check and ends rc 0" || fail "g: full install" "rc=$RC out=$(tail_of "$CASE/out") err=$(tail_of "$CASE/err")"
  [[ "$(count_matching 'could not remove CFW_RENDER_ENGINE from' "$CASE/err")" == 1 ]] && cmp -s "$CASE/orig.env" "$ENVF" \
    && pass "g: full install, read-only file: one \"could not remove\" line, file kept" || fail "g: full install message" "$(tail_of "$CASE/err")"
fi

# --- h. the worker's engine order -------------------------------------------
# engine_order [VAR=value ...] — cr_engine_order in a scrubbed subshell. Uses
# $STATE as the state folder (engines.json) and $ENGINE_ENVFILE if set (sourced
# the way the worker's cr_load_config sources its settings file).
STATE="$ROOT/f-state"; mkdir -p "$STATE" "$ROOT/f-home" "$ROOT/f-tmp" "$ROOT/f-logs"
ENGINE_ENVFILE=""
engine_order() {
  (
    unset CFW_RENDER_ENGINE CFW_RENDER_ENGINE_CMD
    export HOME="$ROOT/f-home" TMPDIR="$ROOT/f-tmp" CFW_RENDER_LOG_DIR="$ROOT/f-logs" CFW_RENDER_STATE_DIR="$STATE"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-lib.sh" || exit 2
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-engine.sh" || exit 2
    cr_log() { :; }
    # shellcheck source=/dev/null
    if [[ -n "$ENGINE_ENVFILE" ]]; then source "$ENGINE_ENVFILE"; fi
    cr_engine_order
  )
}
known="$( source "$REPO_DIR/bin/cfw-render-engine.sh" 2>/dev/null; echo "${CR_ENGINES_KNOWN[*]}" )"
printf '{"order":["gemini","claude-code","codex"]}\n' > "$STATE/engines.json"

echo "=== h. cr_engine_order: no pin follows the owner's order; a pin in the shell still forces one ==="
got="$(engine_order | tr '\n' ' ')"; got="${got% }"
first3="$(engine_order | head -n 3 | tr '\n' ' ')"
[[ "$first3" == "gemini claude-code codex " ]] && pass "h: no pin: engines.json order comes first (gemini, claude-code, codex)" || fail "h: order" "got: $got"
[[ "$(engine_order | sort | tr '\n' ' ')" == "$(printf '%s\n' $known | sort | tr '\n' ' ')" && "$(engine_order | wc -l | tr -d ' ')" == "$(printf '%s\n' $known | wc -l | tr -d ' ')" ]] \
  && pass "h: no pin: every known engine is listed, once" || fail "h: list" "got: $got known: $known"
[[ "$(engine_order CFW_RENDER_ENGINE=codex)" == "codex" ]] && pass "h: CFW_RENDER_ENGINE=codex still forces codex only" || fail "h: forced" "$(engine_order CFW_RENDER_ENGINE=codex | tr '\n' ' ')"
rm -f "$STATE/engines.json"
[[ "$(engine_order | tr '\n' ' ')" == "$(printf '%s\n' $known | tr '\n' ' ')" ]] \
  && pass "h: no pin, no engines.json: the default order lists every known engine" || fail "h: default" "$(engine_order | tr '\n' ' ')"
printf '{"order":["gemini","claude-code","codex"]}\n' > "$STATE/engines.json"

# The settings file as the installer left it (case a), against the old pin.
printf '%s\n' "$MODE_LINE" "CFW_RENDER_ENGINE=codex" "$BASE_LINE" > "$ROOT/old-pin.env"
ENGINE_ENVFILE="$ROOT/old-pin.env"
[[ "$(engine_order)" == "codex" ]] && pass "h: control: with the old pin in the settings file only codex is listed" || fail "h: control" "$(engine_order | tr '\n' ' ')"
ENGINE_ENVFILE="$A_ENVF"
[[ "$(engine_order | head -n 3 | tr '\n' ' ')" == "gemini claude-code codex " ]] \
  && pass "h: after the installer ran, the settings file gives the owner's order" || fail "h: after install" "$(engine_order | tr '\n' ' ')"

# (e) A stub claude and a stub Keychain: claude-code shows as signed in when
# nothing is pinned, and is not even listed while the old pin is there.
mkdir -p "$ROOT/bin" "$ROOT/keychain"
cat > "$ROOT/bin/security" <<'EOF'
#!/usr/bin/env bash
# Fake `security find-generic-password -s com.cfw.render -a <account>`: rc 0 iff
# $FAKE_KEYCHAIN/<account> exists. Never prints a secret.
[[ "${1:-}" == find-generic-password ]] || exit 1
shift; svc=""; acct=""
while (($#)); do
  case "$1" in -s) svc="${2:-}"; shift 2 ;; -a) acct="${2:-}"; shift 2 ;; *) shift ;; esac
done
[[ "$svc" == com.cfw.render && -n "$acct" && -f "${FAKE_KEYCHAIN:?}/$acct" ]] || exit 44
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/claude"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin/codex"
chmod 755 "$ROOT/bin/security" "$ROOT/bin/claude" "$ROOT/bin/codex"
: > "$ROOT/keychain/claude-code"
claude_signed_in() { # claude_signed_in — "True", "False" or "absent" for claude-code in cr_engines_json
  (
    unset CFW_RENDER_ENGINE CFW_RENDER_ENGINE_CMD
    export HOME="$ROOT/f-home" TMPDIR="$ROOT/f-tmp" CFW_RENDER_LOG_DIR="$ROOT/f-logs" CFW_RENDER_STATE_DIR="$STATE"
    export PATH="$ROOT/bin:$PATH" CFW_RENDER_SECURITY_CMD="$ROOT/bin/security" FAKE_KEYCHAIN="$ROOT/keychain"
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-lib.sh" || exit 2
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-engine.sh" || exit 2
    cr_log() { :; }
    # shellcheck source=/dev/null
    if [[ -n "$ENGINE_ENVFILE" ]]; then source "$ENGINE_ENVFILE"; fi
    python3 -c 'import json, sys
rows = [r for r in json.loads(sys.argv[1]) if r["name"] == "claude-code"]
print(rows[0]["signedIn"] if rows else "absent")' "$(cr_engines_json)"
  )
}
ENGINE_ENVFILE="$ROOT/old-pin.env"
[[ "$(claude_signed_in)" == absent ]] && pass "h: control: with the old pin claude-code is not listed at all" || fail "h: control list" "$(claude_signed_in)"
ENGINE_ENVFILE="$A_ENVF"
[[ "$(claude_signed_in)" == True ]] && pass "h: after the installer ran, claude-code shows signed in (Connected)" || fail "h: claude-code" "$(claude_signed_in)"

echo "=== i. no run reached launchctl or the real Keychain ==="
[[ ! -s "$LAUNCHCTL_LOG" ]] && pass "i: the stand-in launchctl was never called by any installer run" || fail "i: launchctl" "$(wc -l < "$LAUNCHCTL_LOG" | tr -d ' ') call(s)"
(( $(sec_calls) >= 3 )) && pass "i: the Keychain lookups of the installer runs reached the stand-in security ($(sec_calls) calls)" || fail "i: security reached" "$(sec_calls) calls logged"
bad_sec="$(grep -v '^find-generic-password -s com\.cfw\.render ' "$SECURITY_LOG" 2>/dev/null | head -n 3 | tr '\n' '|')"
[[ -z "$bad_sec" ]] && pass "i: every security call was a com.cfw.render lookup (no other Keychain item was asked for)" || fail "i: security calls" "$bad_sec"

echo "-------------------------------------"
echo "PASS: $PASS_COUNT   FAIL: $FAILURES   SKIP: $SKIPS"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
