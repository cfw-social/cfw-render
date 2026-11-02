#!/usr/bin/env bash
# test/heygen-gate.test.sh — standalone check of the HeyGen claim gate in
# bin/cfw-render.sh (spawn_director). Safe to run alone: no server, no engine,
# no network, no process stops, no writes outside its own temp folder.
#
#   bash test/heygen-gate.test.sh        # exit 0 iff every case passes
#
# The gate is inline in spawn_director, so this test cuts the REAL block out of
# bin/cfw-render.sh (from its `local heygen_mode=` line up to the integrity
# gate comment) and runs it inside a small function with stubbed cr_log /
# cr_mcp_call / cr_recent_append. If the markers move the test fails loudly
# instead of passing on nothing. cr_recipe_needs_heygen is the real one from
# bin/cfw-render-lib.sh.
#
# The fixtures use fake values. The test also asserts that no fixture key or
# token ever shows up in a log line, an MCP call, a recent entry or the journal.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS_COUNT=0
FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }

WORK="$(mktemp -d)" || { echo "heygen-gate.test.sh: cannot make a temp folder" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"      # this case only
ALL="$WORK/all-calls.log"    # every case, for the secret scan
JOURNAL="$WORK/journal.tsv"
: > "$ALL"; : > "$JOURNAL"
# shellcheck disable=SC2034  # read by the cut block, which runs through eval
CFW_WORKER_ID="worker-fixture"

# shellcheck disable=SC1091
source "$REPO_DIR/bin/cfw-render-lib.sh" || { echo "heygen-gate.test.sh: cannot source the lib" >&2; exit 2; }

# Stubs replace the lib's versions AFTER the source above.
cr_log() { printf 'LOG %s\n' "$*" >> "$CALLS"; }
cr_mcp_call() { printf 'MCP %s %s\n' "$1" "${2:-}" >> "$CALLS"; }
cr_recent_append() { printf 'RECENT %s\n' "$*" >> "$CALLS"; }

# --- cut the real gate out of bin/cfw-render.sh ------------------------------
GATE_BLOCK="$(awk '
  /^  local heygen_mode=/ { on = 1 }
  /^  # Integrity gate/    { on = 0 }
  on { print }
' "$REPO_DIR/bin/cfw-render.sh")"
# shellcheck disable=SC2016  # the needle is literal text, not an expansion
if [[ -z "$GATE_BLOCK" ]] \
   || [[ "$(grep -c 'local heygen_mode=' <<< "$GATE_BLOCK")" != 1 ]] \
   || ! grep -q 'cr_recipe_needs_heygen "\$recipe"' <<< "$GATE_BLOCK" \
   || ! grep -q 'return 1' <<< "$GATE_BLOCK"; then
  echo "heygen-gate.test.sh: could not cut the HeyGen gate out of bin/cfw-render.sh (markers moved?)" >&2
  exit 2
fi

# gate_under_test <recipe> <order-json> — the cut block, run as spawn_director
# would. The block's own `return 1` is the block; falling off the end is a pass.
gate_under_test() {
  # shellcheck disable=SC2034  # all of these are read by the cut block (eval)
  local recipe="$1" order_json="$2"
  # shellcheck disable=SC2034
  local order_id="order-fixture-1" brand_slug="test-brand" kind="video" recent_identity="ident-1"
  eval "$GATE_BLOCK"
  return 0
}

# check <name> <expect: pass|block> <recipe> <order-json>
check() {
  local name="$1" expect="$2" recipe="$3" json="$4" rc
  : > "$CALLS"
  gate_under_test "$recipe" "$json"; rc=$?
  cat "$CALLS" >> "$ALL"
  if [[ "$expect" == pass && "$rc" == 0 && ! -s "$CALLS" ]]; then
    pass "$name"
  elif [[ "$expect" == block && "$rc" == 1 ]] && grep -q '^MCP block_render_order ' "$CALLS"; then
    pass "$name"
  else
    fail "$name" "expected $expect, got rc=$rc, calls: $(tr '\n' '|' < "$CALLS" | cut -c1-300)"
  fi
}

OAUTH_GOOD='"taskOrder":{"recipe":"x","credentials":{"heygen":{"mode":"oauth","accessToken":"fixture-oauth-token-0123","expiresAt":"2099-01-01T00:00:00Z","creditPool":"plan_credits"}}}'
OAUTH_EXPIRED='"taskOrder":{"recipe":"x","credentials":{"heygen":{"mode":"oauth","accessToken":"fixture-oauth-token-0123","expiresAt":"2000-01-01T00:00:00Z"}}}'
OAUTH_BADMODE='"taskOrder":{"recipe":"x","credentials":{"heygen":{"mode":"apikey","accessToken":"fixture-oauth-token-0123"}}}'
NO_CRED='"taskOrder":{"recipe":"x"}'
MANIFEST='"manifest":{"recipe":"x","steps":[{"id":"s1"}]}'
PK_GOOD='"providerKeys":[{"provider":"heygen","value":"fixture-heygen-key-0123"}]'

RECIPES="p-reels-pip-heygen p-reels-spotlight-heygen p-reels-split-heygen"

echo "=== (a) taskOrder.credentials.heygen oauth block still passes (today's rule, unchanged) ==="
check "oauth present, no providerKeys" pass p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_GOOD}"
check "oauth present on a manifest order" pass p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_GOOD,$MANIFEST}"

echo "=== (b) providerKeys heygen with a value passes, on every HeyGen recipe ==="
for r in $RECIPES; do
  check "providerKeys heygen, manifest order, $r" pass "$r" "{\"id\":\"o1\",$NO_CRED,$MANIFEST,$PK_GOOD}"
done
check "providerKeys heygen with no taskOrder.credentials at all" pass p-reels-pip-heygen "{\"id\":\"o1\",$MANIFEST,$PK_GOOD}"
check "providerKeys heygen next to elevenlabs" pass p-reels-split-heygen \
  "{\"id\":\"o1\",$MANIFEST,\"providerKeys\":[{\"provider\":\"elevenlabs\",\"value\":\"fixture-eleven-key-0123\"},{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\"}]}"
check "providerKeys heygen with a future expiresAt" pass p-reels-pip-heygen \
  "{\"id\":\"o1\",$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}]}"
check "both oauth and providerKeys present" pass p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_GOOD,$MANIFEST,$PK_GOOD}"

echo "=== (c) neither source blocks, with the same message as before ==="
for r in $RECIPES; do
  check "no credential at all, $r" block "$r" "{\"id\":\"o1\",$NO_CRED,$MANIFEST}"
done
check "no credential, empty providerKeys" block p-reels-pip-heygen "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[]}"
: > "$CALLS"
gate_under_test p-reels-spotlight-heygen "{\"id\":\"o1\",$NO_CRED,$MANIFEST}"
rc=$?
cat "$CALLS" >> "$ALL"
expected_log='LOG spawn_director: order order-fixture-1 (recipe=p-reels-spotlight-heygen) has no usable brand-scoped HeyGen OAuth credential on taskOrder.credentials.heygen and no usable heygen providerKeys entry (mode= expired=0 providerKey=0) — blocking (never falling back to a worker-local key)'
if [[ "$rc" == 1 ]] && grep -qxF "$expected_log" "$CALLS"; then
  pass "blocked log line is byte-for-byte the old message"
else
  fail "blocked log line" "rc=$rc, calls: $(tr '\n' '|' < "$CALLS" | cut -c1-400)"
fi
expected_reason="this brand's HeyGen account isn't connected — connect it in brand settings"
mcp_check="$(grep '^MCP block_render_order ' "$CALLS" | sed 's/^MCP block_render_order //' | python3 -c '
import json, sys
p = json.loads(sys.stdin.read())
want = {"orderId": "order-fixture-1", "workerId": "worker-fixture",
        "reason": sys.argv[1], "needs": "decision"}
print("OK" if p == want else "BAD %r" % (p,))
' "$expected_reason" 2>&1)"
if [[ "$mcp_check" == OK ]]; then
  pass "block_render_order payload: same reason, needs=decision"
else
  fail "block_render_order payload" "$mcp_check"
fi
if grep -qxF "RECENT  blocked order-fixture-1 ident-1 this brand's HeyGen account isn't connected — connect it in brand settings" "$CALLS" \
   && [[ "$(awk -F'\t' '$2=="order-fixture-1" && $5=="blocked" {n++} END {print n+0}' "$JOURNAL")" -ge 1 ]]; then
  pass "recent entry and journal row are the old ones"
else
  fail "recent entry / journal row" "calls: $(tr '\n' '|' < "$CALLS" | cut -c1-400)"
fi

echo "=== (d) a blank or unusable providerKeys entry still blocks ==="
check "providerKeys heygen with a blank value" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"   \"}]}"
check "providerKeys heygen with an empty value" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"\"}]}"
check "providerKeys heygen with a non-string value" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":12345}]}"
check "providerKeys heygen with no value" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\"}]}"
check "providerKeys heygen with a NUL byte in the value (the harness refuses it)" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-\\u00000123\"}]}"
check "providerKeys heygen with a past expiresAt" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\",\"expiresAt\":\"2000-01-01T00:00:00Z\"}]}"
check "providerKeys heygen with an expiresAt that has no timezone" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\",\"expiresAt\":\"2099-01-01T00:00:00\"}]}"
check "providerKeys heygen with an unparsable expiresAt" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\",\"expiresAt\":\"soon\"}]}"
check "providerKeys heygen with a non-string expiresAt" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"heygen\",\"value\":\"fixture-heygen-key-0123\",\"expiresAt\":null}]}"
check "providerKeys for another provider only" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[{\"provider\":\"elevenlabs\",\"value\":\"fixture-eleven-key-0123\"}]}"
check "providerKeys is not a list" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":{\"heygen\":\"fixture-heygen-key-0123\"}}"
check "providerKeys entries are not objects" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$MANIFEST,\"providerKeys\":[\"heygen\",42,null]}"
check "providerKeys heygen on an order with no manifest (the harness would never export it)" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,$PK_GOOD}"
check "providerKeys heygen on an order whose manifest is empty" block p-reels-pip-heygen \
  "{\"id\":\"o1\",$NO_CRED,\"manifest\":{},$PK_GOOD}"
check "not JSON at all" block p-reels-pip-heygen "this is not json"

echo "=== (e) the oauth rule is unchanged where providerKeys does not help ==="
check "oauth expired, no providerKeys" block p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_EXPIRED,$MANIFEST}"
check "oauth wrong mode, no providerKeys" block p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_BADMODE,$MANIFEST}"
check "oauth expired but providerKeys heygen usable" pass p-reels-pip-heygen "{\"id\":\"o1\",$OAUTH_EXPIRED,$MANIFEST,$PK_GOOD}"

echo "=== (f) a recipe that is not gated stays ungated ==="
check "p-reels-pip, no credential" pass p-reels-pip "{\"id\":\"o1\",$NO_CRED,$MANIFEST}"
check "p-longform, no credential" pass p-longform "{\"id\":\"o1\",$NO_CRED,$MANIFEST}"

echo "=== (g) no fixture secret reaches a log line, MCP call, recent entry or the journal ==="
if grep -qF -e fixture-heygen-key -e fixture-oauth-token -e fixture-eleven-key "$ALL" "$JOURNAL"; then
  fail "secret scan" "a fixture key or token appeared in the captured output"
else
  pass "secret scan: $(wc -l < "$ALL" | tr -d ' ') captured lines, no fixture key or token"
fi

echo
echo "heygen-gate: $PASS_COUNT passed, $FAILURES failed"
[[ "$FAILURES" == 0 ]]
