#!/usr/bin/env bash
# test/engine-sandbox-chrome.test.sh — standalone check of the coder write
# sandbox in bin/cfw-render-engine.sh for browser renders (B33).
#
#   bash test/engine-sandbox-chrome.test.sh      # exit 0 iff every case passes
#
# Since WI2.109 a coder step runs under sandbox-exec with writes allowed only in
# the step folder, the isolated config dirs and a private tmp. A HyperFrames
# render needs two more things: Chrome's profile-lock socket folder under the
# macOS user temp dir (Chrome ignores TMPDIR), and the HyperFrames font cache.
# This test builds the profile the way cr_engine_run does and checks:
#   1. the profile text: one added write rule, nothing on the read side;
#   2. what the real sandbox allows and refuses (needs sandbox-exec to apply);
#   3. HYPERFRAMES_FONT_CACHE_DIR is exported inside the coder's private tmp;
#   4. headless Chrome starts once inside the sandbox (skipped without Chrome),
#      and fails without the allowance (control).
# The allowance is for folders Chrome creates afresh inside the sandboxed run.
# A Chrome folder that already exists under the user temp dir when the profile is
# built (the owner's live desktop Chrome, updater leftovers) is denied (review
# S1 of B33); sections 1 and 2 build such a folder first and check that it stays
# untouched while a new one is allowed.
#
# Safe to run alone: no server, no network, no engine CLI, no secrets. It never
# stops a process except the one headless Chrome it starts. It creates only
# uniquely named folders under the user temp dir and removes exactly those.
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
note() { printf '  NOTE  %s\n' "$1"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "engine-sandbox-chrome: SKIP (macOS sandbox-exec only)"
  exit 0
fi

ROOT="$(mktemp -d)" || { echo "engine-sandbox-chrome: cannot make a temp folder" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
UT_RAW="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || { echo "engine-sandbox-chrome: getconf DARWIN_USER_TEMP_DIR failed" >&2; exit 2; }
UT="${UT_RAW%/}"               # logical path, as Chrome uses it (/var/folders/...)
UT_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]).rstrip("/"))' "$UT")" || exit 2
TAG="CfwB33x$$"                # unique suffix for everything created under the user temp dir
CLEAN=()                       # exact paths created under the user temp dir
cleanup() {
  local p
  for p in "${CLEAN[@]+"${CLEAN[@]}"}"; do
    case "$p" in "$UT"/*) rm -rf -- "$p" ;; esac
  done
  rm -rf -- "$ROOT"
}
trap cleanup EXIT

export CFW_RENDER_LOG_DIR="$ROOT/logs" CFW_RENDER_STATE_DIR="$ROOT/state"
mkdir -p "$CFW_RENDER_LOG_DIR" "$CFW_RENDER_STATE_DIR"
FAKE_HOME="$ROOT/home"
mkdir -p "$FAKE_HOME/.cache/hyperframes/fonts"

# shellcheck disable=SC1091
source "$REPO_DIR/bin/cfw-render-lib.sh" || { echo "engine-sandbox-chrome: cannot source the lib" >&2; exit 2; }
# shellcheck disable=SC1091
source "$REPO_DIR/bin/cfw-render-engine.sh" || { echo "engine-sandbox-chrome: cannot source the engine" >&2; exit 2; }

# Chrome folders that exist BEFORE the profile is built, standing in for the
# owner's live desktop Chrome (a SingletonSocket folder under the user temp dir)
# and the updater's folders. Made here, outside any sandbox. The profile must
# deny writes to them.
PRE_DIR="$UT/com.google.Chrome.PRE$TAG"
PRE_DOT_DIR="$UT/.org.chromium.Chromium.PRE$TAG"
for d in "$PRE_DIR" "$PRE_DOT_DIR"; do
  CLEAN+=("$d")
  mkdir -p -- "$d" || { echo "engine-sandbox-chrome: cannot make $d" >&2; exit 2; }
  printf 'owner-chrome-%s\n' "$TAG" > "$d/SingletonSocket"
done

# Build the profile exactly as cr_engine_run does (prepare_isolate, write_profile).
WORK="$ROOT/work"
mkdir -p "$WORK"
cr_engine_prepare_isolate "$WORK" || { echo "engine-sandbox-chrome: cr_engine_prepare_isolate failed" >&2; exit 2; }
PROFILE="$CR_CODER_ROOT/profile.sb"
cr_engine_write_profile "$PROFILE" "$WORK" "$CR_CODER_CLAUDE_DIR" "$CR_CODER_CODEX_DIR" "$CR_CODER_TMP" \
  || { echo "engine-sandbox-chrome: cr_engine_write_profile failed" >&2; exit 2; }

echo "=== 1. profile text: one added write rule; the read side is untouched ==="
rules="$(grep -c 'regex' "$PROFILE")"
if [[ "$rules" == 1 ]]; then pass "exactly one regex rule in the profile"; else fail "regex rule count" "found $rules"; fi

bad_lines=""
while IFS= read -r line; do
  case "$line" in
    '(version 1)'|'(allow default)'|'(deny file-write*)') ;;
    '(allow file-write* (literal "'*'"))') ;;
    '(allow file-write* (subpath "'*'"))') ;;
    '(allow file-write* (regex #"^'*'$"))') ;;
    '(deny file-write* (subpath "'*'"))') ;;
    *) bad_lines="${bad_lines}[${line}] " ;;
  esac
done < "$PROFILE"
if [[ -z "$bad_lines" ]]; then
  pass "every profile line is a header, a write allow (literal, subpath), the one regex allow or a Chrome-folder write deny"
else
  fail "profile line shapes" "$bad_lines"
fi

# Review S1: the folders that existed when the profile was built are denied.
for d in "$PRE_DIR" "$PRE_DOT_DIR"; do
  if grep -F -q "(deny file-write* (subpath \"$UT_REAL/${d##*/}\"))" "$PROFILE"; then
    pass "profile denies the pre-existing ${d##*/}"
  else
    fail "pre-existing Chrome folder deny" "no deny line for ${d##*/}"
  fi
done
# Every deny line names a Chrome-family entry directly under the real temp dir.
bad_deny=""
while IFS= read -r line; do
  case "$line" in
    '(deny file-write* (subpath "'"$UT_REAL"'/'*'"))')
      nm="${line#*"$UT_REAL"/}"; nm="${nm%\"))}"
      case "$nm" in
        */*) bad_deny="${bad_deny}[$nm] " ;;
        com.google.[Cc]hrome|com.google.[Cc]hrome.*|org.chromium.Chromium|org.chromium.Chromium.*|.com.google.[Cc]hrome|.com.google.[Cc]hrome.*|.org.chromium.Chromium|.org.chromium.Chromium.*) ;;
        *) bad_deny="${bad_deny}[$nm] " ;;
      esac ;;
    '(deny file-write* (subpath'*) bad_deny="${bad_deny}[${line}] " ;;
  esac
done < "$PROFILE"
if [[ -z "$bad_deny" ]]; then
  pass "every folder-level deny is a Chrome-family name directly under the real user temp dir"
else
  fail "deny line shapes" "$bad_deny"
fi
deny_dirs="$(grep -c '^(deny file-write\* (subpath' "$PROFILE")"
if [[ "$deny_dirs" -ge 2 ]]; then
  pass "at least the two pre-existing folders made here are denied ($deny_dirs deny lines on this Mac)"
else
  fail "deny count" "deny lines $deny_dirs"
fi

if grep -q 'file-read' "$PROFILE"; then fail "read side" "profile mentions file-read"; else pass "no file-read rule: reads stay open exactly as before"; fi

default_n="$(grep -n -F '(allow default)' "$PROFILE" | head -n 1 | cut -d: -f1)"
deny_n="$(grep -n -F '(deny file-write*)' "$PROFILE" | head -n 1 | cut -d: -f1)"
regex_n="$(grep -n 'regex' "$PROFILE" | head -n 1 | cut -d: -f1)"
if [[ -n "$default_n" && -n "$deny_n" && -n "$regex_n" && "$default_n" -lt "$deny_n" && "$deny_n" -lt "$regex_n" ]]; then
  pass "the regex allow comes after the write deny (a later rule wins)"
else
  fail "rule order" "default=$default_n deny=$deny_n regex=$regex_n"
fi
first_dir_deny_n="$(grep -n '^(deny file-write\* (subpath' "$PROFILE" | head -n 1 | cut -d: -f1)"
if [[ -n "$first_dir_deny_n" && -n "$regex_n" && "$regex_n" -lt "$first_dir_deny_n" ]]; then
  pass "the Chrome-folder denies come after the regex allow (the later rule wins)"
else
  fail "deny order" "regex=$regex_n first folder deny=$first_dir_deny_n"
fi

if grep -F -q "(subpath \"$UT\"" "$PROFILE" || grep -F -q "(subpath \"$UT_REAL\"" "$PROFILE" \
   || grep -F -q "(subpath \"$UT/\"" "$PROFILE" || grep -F -q "(subpath \"$UT_REAL/\"" "$PROFILE"; then
  fail "user temp dir" "profile allows the whole user temp dir"
else
  pass "no subpath rule for the whole user temp dir"
fi
if grep -F -q '.cache' "$PROFILE" || grep -F -q "$HOME" "$PROFILE"; then
  fail "home" "profile names ~/.cache or the home dir"
else
  pass "profile names neither ~/.cache nor the home dir"
fi
rule="$(grep 'regex' "$PROFILE")"
for want in 'com\.google\.[Cc]hrome' 'org\.chromium\.Chromium'; do
  case "$rule" in *"$want"*) ;; *) fail "regex content" "missing $want" ;; esac
done
case "$rule" in
  *'.*'*'.*'*) fail "regex content" "more than one open wildcard" ;;
  *) pass "regex names only the Chrome and Chromium folders; one trailing wildcard under them" ;;
esac

# Run one write attempt under the real profile. $1 = bash snippet, rest = args.
sb_try() {
  local script="$1"; shift
  SB_ERR="$(/usr/bin/sandbox-exec -f "$PROFILE" /bin/bash -c "$script" _ "$@" 2>&1 >/dev/null)"
  SB_RC=$?
}
expect_allowed() {  # <label> <snippet> <args...>
  local label="$1"; shift
  sb_try "$@"
  if [[ "$SB_RC" == 0 ]]; then pass "allowed: $label"; else fail "allowed: $label" "rc=$SB_RC ${SB_ERR:0:160}"; fi
}
expect_denied() {   # <label> <snippet> <args...>
  local label="$1"; shift
  sb_try "$@"
  if [[ "$SB_RC" != 0 && "$SB_ERR" == *"Operation not permitted"* ]]; then
    pass "denied: $label"
  else
    fail "denied: $label" "rc=$SB_RC ${SB_ERR:0:160}"
  fi
}

cr_engine_sandbox_probe
echo "=== 2. what the real sandbox allows and refuses (sandbox mode: $CR_ENGINE_SANDBOX_MODE) ==="
if [[ "$CR_ENGINE_SANDBOX_MODE" != "apply" ]]; then
  skip "sandbox enforcement" "sandbox-exec cannot apply a profile here (mode $CR_ENGINE_SANDBOX_MODE)"
else
  MK='mkdir -p -- "$1" && : > "$1/SingletonSocket"'
  # Chrome's own socket folders (the observed name is com.google.Chrome.<random>).
  for name in "com.google.Chrome.$TAG" ".org.chromium.Chromium.$TAG" "org.chromium.Chromium.$TAG" "com.google.chrome.for.testing.$TAG"; do
    CLEAN+=("$UT/$name")
    expect_allowed "$name/SingletonSocket under the user temp dir" "$MK" "$UT/$name"
  done
  # Everything else under the user temp dir stays refused.
  expect_denied "a plain file in the user temp dir" ': > "$1"' "$UT/cfw-b33-other-$TAG"
  CLEAN+=("$UT/cfw-b33-other-$TAG")
  expect_denied "another com.google.* folder" "$MK" "$UT/com.google.Keystone.$TAG"
  CLEAN+=("$UT/com.google.Keystone.$TAG")
  expect_denied "a folder that only starts like Chrome's (no dot after the name)" "$MK" "$UT/com.google.Chromeevil$TAG"
  CLEAN+=("$UT/com.google.Chromeevil$TAG")
  expect_denied "a Chrome-named folder one level deeper (not directly under the user temp dir)" "$MK" "$ROOT/com.google.Chrome.$TAG"
  expect_denied "a path that climbs out of an allowed Chrome folder with .." ': > "$1/../cfw-b33-trav-$2"' "$UT/com.google.Chrome.$TAG" "$TAG"
  CLEAN+=("$UT/cfw-b33-trav-$TAG")
  ln -s "$FAKE_HOME/.cache/hyperframes/fonts" "$UT/com.google.Chrome.$TAG/via-link" 2>/dev/null || true
  expect_denied "a write through a link inside an allowed Chrome folder" ': > "$1/via-link/probe"' "$UT/com.google.Chrome.$TAG"
  # Review S1: a Chrome folder that existed before the profile was built (a live
  # desktop Chrome, updater leftovers) is refused, even though its name matches the
  # allow rule; a new one made inside the sandbox is allowed (the loop above, and
  # the NEW case here, which sits next to the denied pre-existing one).
  for pre in "$PRE_DIR" "$PRE_DOT_DIR"; do
    pn="${pre##*/}"
    expect_denied "overwriting the SingletonSocket inside the pre-existing $pn" ': > "$1/SingletonSocket"' "$pre"
    expect_denied "replacing the SingletonSocket inside the pre-existing $pn with a link" 'ln -sf /nonexistent-b33 "$1/SingletonSocket"' "$pre"
    expect_denied "deleting the SingletonSocket inside the pre-existing $pn" 'rm -- "$1/SingletonSocket"' "$pre"
    expect_denied "a new file inside the pre-existing $pn" ': > "$1/cfw-b33-new-$2"' "$pre" "$TAG"
    if [[ "$(cat "$pre/SingletonSocket" 2>/dev/null)" == "owner-chrome-$TAG" && ! -e "$pre/cfw-b33-new-$TAG" ]]; then
      pass "the pre-existing $pn is untouched after the refused writes"
    else
      fail "pre-existing folder intact" "$pn changed"
    fi
  done
  CLEAN+=("$UT/com.google.Chrome.NEW$TAG")
  expect_allowed "a NEW com.google.Chrome.NEW folder next to the denied pre-existing one" "$MK" "$UT/com.google.Chrome.NEW$TAG"
  # A real one: the first Chrome folder already on this Mac that this test did not make.
  real_pre=""
  for cand in "$UT_REAL"/com.google.Chrome.*; do
    [[ -d "$cand" && ! -L "$cand" && "$cand" != *"$TAG" ]] && { real_pre="$cand"; break; }
  done
  if [[ -n "$real_pre" ]]; then
    CLEAN+=("$UT/${real_pre##*/}/cfw-b33-probe-$TAG")
    expect_denied "a new file in an already-existing Chrome folder on this Mac" ': > "$1/cfw-b33-probe-$2"' "$real_pre" "$TAG"
  else
    skip "real pre-existing Chrome folder" "none under the user temp dir"
  fi
  # The cache dir and the rest of home stay refused.
  expect_denied "a file under a ~/.cache/hyperframes/fonts folder (fixture home)" ': > "$1"' "$FAKE_HOME/.cache/hyperframes/fonts/probe"
  expect_denied "a new folder under ~/.cache (fixture home)" 'mkdir -p -- "$1"' "$FAKE_HOME/.cache/barlow-condensed"
  if [[ -d "$HOME/.cache" ]]; then
    expect_denied "a file under the real ~/.cache" ': > "$1"' "$HOME/.cache/cfw-b33-probe-$TAG"
    rm -f -- "$HOME/.cache/cfw-b33-probe-$TAG"
  fi
  # Controls: the step folder and its private tmp stay writable.
  expect_allowed "a file in the step folder" ': > "$1"' "$WORK/ok-$TAG"
  expect_allowed "a file in the coder's private tmp" ': > "$1"' "$CR_CODER_TMP/ok-$TAG"
fi

# A stand-in coder. It reports what it sees and tries the writes B33 is about.
STUB="$ROOT/stub-coder.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
r="${B33_REPORT:?}"
{
  printf 'FONTDIR=%s\n' "${HYPERFRAMES_FONT_CACHE_DIR:-}"
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
  printf 'SANDBOX=%s\n' "${CFW_RENDER_CODER_SANDBOX:-}"
} > "$r"
if mkdir -p "${HYPERFRAMES_FONT_CACHE_DIR:-/nonexistent-b33}/barlow-condensed" 2>/dev/null \
   && : > "${HYPERFRAMES_FONT_CACHE_DIR}/barlow-condensed/probe.woff2" 2>/dev/null; then
  echo 'FONTWRITE=ok' >> "$r"
else
  echo 'FONTWRITE=fail' >> "$r"
fi
if : > "${B33_HOME_PROBE:-/nonexistent-b33}" 2>/dev/null; then
  echo 'HOMEWRITE=ok' >> "$r"
else
  echo 'HOMEWRITE=fail' >> "$r"
fi
exit 0
STUBEOF

# Run cr_engine_run on a stand-in coder. $1 = label. Rest: env assignments for the run.
run_stub() {
  local label="$1"; shift
  local work="$ROOT/run-$label"
  mkdir -p "$work" "$ROOT/logs"
  printf 'render the fixture\n' > "$work/prompt.md"
  (
    export CFW_RENDER_ENGINE=claude-code CFW_RENDER_ENGINE_CMD="bash $STUB"
    export B33_REPORT="$work/report.txt" B33_HOME_PROBE="$FAKE_HOME/.cache/hyperframes/fonts/probe"
    export HOME="$FAKE_HOME"
    for kv in "$@"; do export "${kv?}"; done
    unset CODEX_HOME CLAUDE_CONFIG_DIR
    cr_engine_run claude-code "$work/prompt.md" "$work" "$ROOT/logs/$label.log" > /dev/null 2>&1
    printf '%s\n' "$?" > "$work/rc"
  )
  RUN_WORK="$work"
}
field() { sed -n "s/^$1=//p" "$2" | tail -n 1; }

echo "=== 3. HYPERFRAMES_FONT_CACHE_DIR points inside the coder's private tmp ==="
run_stub plain
rep="$RUN_WORK/report.txt"
if [[ -f "$rep" && "$(cat "$RUN_WORK/rc")" == 0 ]]; then
  fd="$(field FONTDIR "$rep")"; td="$(field TMPDIR "$rep")"
  [[ "$td" == "$RUN_WORK/.cfw-coder/tmp" ]] && pass "TMPDIR is the private tmp" || fail "TMPDIR" "$td"
  if [[ "$fd" == "$td/hyperframes-fonts" ]]; then
    pass "HYPERFRAMES_FONT_CACHE_DIR is exported as <private tmp>/hyperframes-fonts"
  else
    fail "HYPERFRAMES_FONT_CACHE_DIR" "got '$fd', want '$td/hyperframes-fonts'"
  fi
  case "$fd" in "$HOME"/*|"$FAKE_HOME"/*|*/.cache/*) fail "font cache location" "under a home cache: $fd" ;; *) pass "the font cache is not under a home or .cache path" ;; esac
  sandbox="$(field SANDBOX "$rep")"
  if [[ "$sandbox" == apply ]]; then
    [[ "$(field FONTWRITE "$rep")" == ok ]] && pass "the coder can create a font folder and file in the cache dir" || fail "font cache write" "$(field FONTWRITE "$rep")"
    [[ "$(field HOMEWRITE "$rep")" == fail ]] && pass "the coder still cannot write ~/.cache/hyperframes/fonts" || fail "home cache write" "allowed"
  else
    skip "write checks inside the stand-in coder" "sandbox mode $sandbox"
  fi
else
  fail "stand-in coder run" "no report or rc != 0 ($(cat "$RUN_WORK/rc" 2>/dev/null))"
fi
run_stub preset HYPERFRAMES_FONT_CACHE_DIR=/elsewhere/fonts
fd="$(field FONTDIR "$RUN_WORK/report.txt" 2>/dev/null)"
if [[ "$fd" == "$RUN_WORK/.cfw-coder/tmp/hyperframes-fonts" ]]; then
  pass "an outer HYPERFRAMES_FONT_CACHE_DIR is overridden by the private tmp"
else
  fail "outer font cache dir" "got '$fd'"
fi

echo "=== 4. headless Chrome starts once inside the sandbox ==="
CHROME=""
for c in "${CHROME_BIN:-}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  if [[ -n "$c" && -x "$c" ]]; then CHROME="$c"; break; fi
done
if [[ -z "$CHROME" ]]; then
  skip "headless Chrome smoke" "no Chrome or Chromium found (set CHROME_BIN)"
elif [[ "$CR_ENGINE_SANDBOX_MODE" != "apply" ]]; then
  skip "headless Chrome smoke" "sandbox mode $CR_ENGINE_SANDBOX_MODE"
else
  # The coder launches Chrome in the background and waits at most 60 s. Only that
  # one Chrome (and its children) is ever signalled.
  cat > "$ROOT/chrome-coder.sh" <<'CHROMEEOF'
#!/usr/bin/env bash
cat >/dev/null
: "${B33_CHROME:?}"
# The flags HyperFrames/puppeteer pass: --no-sandbox (macOS refuses a second
# sandbox inside ours, so Chrome's own one cannot start) and --disable-breakpad.
"$B33_CHROME" --headless=new --no-sandbox --disable-gpu --no-first-run --no-default-browser-check \
  --disable-breakpad --disable-extensions --user-data-dir="$PWD/chrome-profile" --dump-dom about:blank \
  > "$PWD/chrome.out" 2> "$PWD/chrome.err" &
cpid=$!
for _ in $(seq 1 120); do kill -0 "$cpid" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$cpid" 2>/dev/null; then
  pkill -P "$cpid" 2>/dev/null; kill "$cpid" 2>/dev/null
  echo 'CHROME_RC=124' > "$PWD/chrome.rc"
else
  wait "$cpid"; echo "CHROME_RC=$?" > "$PWD/chrome.rc"
fi
exit 0
CHROMEEOF
  chrome_run() {  # <label> [pre-source-hook]
    local label="$1" hook="${2:-}" work="$ROOT/chrome-$1"
    mkdir -p "$work"
    printf 'render the fixture\n' > "$work/prompt.md"
    (
      # The real HOME, as the worker has it: Chrome exits 2 after printing the page
      # under a made-up HOME, which has nothing to do with the sandbox.
      export CFW_RENDER_ENGINE=claude-code CFW_RENDER_ENGINE_CMD="bash $ROOT/chrome-coder.sh" B33_CHROME="$CHROME"
      unset CODEX_HOME CLAUDE_CONFIG_DIR
      [[ -z "$hook" ]] || eval "$hook"
      cr_engine_run claude-code "$work/prompt.md" "$work" "$ROOT/logs/chrome-$label.log" > /dev/null 2>&1
    )
    CHROME_WORK="$work"
  }
  chrome_run with
  rc="$(field CHROME_RC "$CHROME_WORK/chrome.rc" 2>/dev/null)"
  if [[ "$rc" == 0 && "$(cat "$CHROME_WORK/chrome.out" 2>/dev/null)" == *"<html"* ]]; then
    pass "headless Chrome inside the sandbox exits 0 and prints the page"
  else
    fail "headless Chrome inside the sandbox" "rc=${rc:-none} err=$(tr '\n' ' ' < "$CHROME_WORK/chrome.err" 2>/dev/null | cut -c1-200)"
  fi
  # Control: the same run with the Chrome allowance removed must fail the way B33 did.
  chrome_run without 'cr_engine_allow_browser_socket_dirs() { return 0; }'
  rc="$(field CHROME_RC "$CHROME_WORK/chrome.rc" 2>/dev/null)"
  if [[ -n "$rc" && "$rc" != 0 ]] && grep -q -E 'ProcessSingleton|socket directory' "$CHROME_WORK/chrome.err" 2>/dev/null; then
    pass "control: without the allowance Chrome fails inside the sandbox with the B33 error (ProcessSingleton), rc $rc"
  elif [[ -n "$rc" && "$rc" != 0 ]]; then
    fail "control" "Chrome failed (rc $rc) but not with the ProcessSingleton error: $(tr '\n' ' ' < "$CHROME_WORK/chrome.err" 2>/dev/null | cut -c1-200)"
  else
    note "control: Chrome also started without the allowance on this machine, so the smoke case above does not prove the rule"
  fi
fi

echo
echo "engine-sandbox-chrome: $PASS_COUNT passed, $FAILURES failed, $SKIPS skipped"
[[ "$FAILURES" == 0 ]]
