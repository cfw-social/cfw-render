#!/usr/bin/env bash
# test/run-tests.sh — behavioral suite against test/mock-server.py. No live
# services (implementation-plan.md §10). Boots a fresh mock server per case,
# runs bin/cfw-render.sh against it with CFW_RENDER_DIRECTOR_CMD pointed at
# test/fake-director.sh, and asserts on calls.jsonl / journal.tsv / scratch
# state. Exit 0 iff every case passes.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

FAILURES=0
PASS_COUNT=0

pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }

FAKE_BIN="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

OLLAMA_KEYS_FIXTURE="$(mktemp)"
cat > "$OLLAMA_KEYS_FIXTURE" <<'EOF'
OLLAMA_KEY_GOOFY_HUGLE_463_B=test-dummy-key-goofy
OLLAMA_KEY_RECURSING_PIKE_357=test-dummy-key-pike
EOF

MOCK_PORT_BASE=38100
CASE_N=0

order_fixture() {
  # order_fixture <id> <brandId> <kind> -> writes a one-order queue seed to stdout
  local id="$1" brand="$2" kind="$3"
  python3 -c '
import json, sys
oid, brand, kind = sys.argv[1:4]
order = {
    "id": oid, "brandId": brand, "workspaceId": "ws-1", "kind": kind,
    "recipe": "p-reels-spotlight", "status": "queued",
    "taskOrder": {
        "version": 1, "orderId": oid,
        "brand": {"id": brand, "slug": "test-brand", "brief": "test brand"},
        "kind": kind, "recipe": "p-reels-spotlight", "workspaceId": "ws-1",
        "intent": "test render", "ingredients": [],
        "targets": ["instagram", "tiktok", "youtube", "threads"],
        "acceptance": {"gate": "c-shorts-qa-gate"},
    },
    "priority": 0, "attempts": 1,
}
print(json.dumps([order]))
' "$id" "$brand" "$kind"
}

empty_queue() { echo '[]'; }

order_fixture_heygen() {
  # order_fixture_heygen <id> <brandId> <kind> [cred-json]
  # [CFW-313] Same shape as order_fixture() but on a `*-heygen` recipe, with
  # an optional taskOrder.credentials.heygen literal (compact JSON, NO
  # spaces — this string travels through run_case's unquoted word-split, so
  # a space inside it would split into extra, wrong positional args).
  # Omitting the 4th arg entirely means "this brand has no HeyGen account
  # connected" — taskOrder.credentials.heygen is absent, same as real life.
  local id="$1" brand="$2" kind="$3" cred="${4:-}"
  python3 -c '
import json, sys
oid, brand, kind, cred_raw = sys.argv[1:5]
task = {
    "version": 1, "orderId": oid,
    "brand": {"id": brand, "slug": "test-brand", "brief": "test brand"},
    "kind": kind, "recipe": "p-reels-spotlight-heygen", "workspaceId": "ws-1",
    "intent": "test render", "ingredients": [],
    "targets": ["instagram", "tiktok", "youtube", "threads"],
    "acceptance": {"gate": "c-shorts-qa-gate"},
}
if cred_raw:
    task["credentials"] = {"heygen": json.loads(cred_raw)}
order = {
    "id": oid, "brandId": brand, "workspaceId": "ws-1", "kind": kind,
    "recipe": "p-reels-spotlight-heygen", "status": "queued",
    "taskOrder": task,
    "priority": 0, "attempts": 1,
}
print(json.dumps([order]))
' "$id" "$brand" "$kind" "$cred"
}

start_mock() {
  # NOTE: must redirect the background server's stdout/stderr away from the
  # inherited pipe — backgrounding inside a `$(...)` command substitution
  # without redirecting keeps that pipe's write end open for the server's
  # whole lifetime, so the substitution never sees EOF and hangs forever.
  local seed_file="$1" state_dir="$2" port="$3"
  python3 "$TEST_DIR/mock-server.py" "$port" "$state_dir" "$seed_file" \
    > "$state_dir/../mock-server.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 50); do
    curl -sS --max-time 1 "http://127.0.0.1:$port/api/v1/mcp" >/dev/null 2>&1 && break
    sleep 0.1
  done
  echo "$pid"
}

run_case() {
  # run_case <name> <mode> <order-json-producer> <extra_env...>
  local name="$1" mode="$2" order_producer="$3"; shift 3
  CASE_N=$((CASE_N+1))
  local port=$((MOCK_PORT_BASE + CASE_N))
  local case_dir; case_dir="$(mktemp -d)"
  local seed="$case_dir/queue.json" state="$case_dir/mockstate"
  mkdir -p "$state"
  # Intentional word-splitting: order_producer is "fn arg1 arg2 ..." built by
  # the call site (e.g. "order_fixture order-happy-1 brand-1 video").
  # shellcheck disable=SC2086
  $order_producer > "$seed"

  local mock_pid; mock_pid="$(start_mock "$seed" "$state" "$port")"

  local cr_state="$case_dir/cr-state" cr_scratch="$case_dir/cr-scratch"
  mkdir -p "$cr_state" "$cr_scratch"

  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$cr_state"
    export CFW_RENDER_SCRATCH="$cr_scratch"
    export CFW_RENDER_SKILLS_DIR="$case_dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export FAKE_DIRECTOR_MODE="$mode"
    export CFW_RENDER_TIMEOUT_VIDEO="${CASE_TIMEOUT_VIDEO:-30}"
    export CFW_RENDER_TIMEOUT_IMAGE="${CASE_TIMEOUT_IMAGE:-30}"
    export CFW_RENDER_CONCURRENCY="${CASE_CONCURRENCY:-1}"
    "$@"
    "$REPO_DIR/bin/cfw-render.sh" --once
  )
  local drainer_exit=$?

  kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null

  : "$name"  # kept for call-site readability; not otherwise referenced
  CASE_STATE="$cr_state"
  CASE_MOCKSTATE="$state"
  CASE_SCRATCH="$cr_scratch"
  CASE_DRAINER_EXIT="$drainer_exit"
}

calls_count() {  # calls_count <tool>
  # NOTE: `grep -c` already prints "0" on no match but exits 1 — a naive
  # `|| echo 0` fallback double-prints ("0\n0") and breaks arithmetic
  # comparisons downstream. Only fall back when the file is genuinely absent.
  local f="$CASE_MOCKSTATE/calls.jsonl"
  [[ -f "$f" ]] || { echo 0; return; }
  grep -c "\"tool\": \"$1\"" "$f"
}

echo "=== Case 1: --dry makes zero tools/call ==="
case_dir_dry="$(mktemp -d)"; mkdir -p "$case_dir_dry/mockstate"
empty_queue > "$case_dir_dry/queue.json"
dry_port=$((MOCK_PORT_BASE + 90))
dry_pid="$(start_mock "$case_dir_dry/queue.json" "$case_dir_dry/mockstate" "$dry_port")"
(
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$dry_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
  export CFW_RENDER_STATE_DIR="$case_dir_dry/cr-state"
  export CFW_RENDER_SCRATCH="$case_dir_dry/cr-scratch"
  export CFW_RENDER_SKILLS_DIR="$case_dir_dry/skills"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
  "$REPO_DIR/bin/cfw-render.sh" --dry
)
dry_exit=$?
kill "$dry_pid" 2>/dev/null; wait "$dry_pid" 2>/dev/null
if [[ "$dry_exit" == "0" ]]; then pass "--dry exits 0 against a reachable mock"; else fail "--dry exit code" "expected 0, got $dry_exit"; fi
if [[ -f "$case_dir_dry/mockstate/calls.jsonl" ]]; then
  dry_calls="$(wc -l < "$case_dir_dry/mockstate/calls.jsonl" | tr -d ' ')"
else
  dry_calls=0
fi
if [[ "$dry_calls" == "0" ]]; then pass "--dry makes zero tools/call"; else fail "--dry tools/call count" "expected 0, got $dry_calls"; fi

echo "=== Case 2: happy path (video) ==="
run_case "happy-path" "happy" "order_fixture order-happy-1 brand-1 video" true
if [[ "$(calls_count claim_render_order)" -ge 1 ]]; then pass "happy: claim_render_order called"; else fail "happy: claim" "no claim_render_order call"; fi
if [[ "$(calls_count append_render_event)" -ge 3 ]]; then pass "happy: stage events emitted"; else fail "happy: stage events" "expected >=3 append_render_event calls"; fi
if grep -q '"tool": "append_render_event".*"kind": "subagent"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "happy: subagent event recorded"
else
  fail "happy: subagent event" "no kind=subagent append_render_event found"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "order-happy-1" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "happy: upload happened"
else
  fail "happy: upload" "no upload recorded for order-happy-1"
fi
if [[ "$(calls_count complete_render_order)" -ge 1 ]]; then
  pass "happy: complete_render_order called"
else
  fail "happy: complete" "no complete_render_order call"
fi
complete_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if echo "$complete_line" | grep -q '"fanout": \["glm-5.2"\]'; then
  pass "happy: models rollup contains fanout model glm-5.2"
else
  fail "happy: models rollup" "fanout model not found in: $complete_line"
fi
# CFW-136: reel completion = video (cover) + cover.png (poster) + per-platform captions.
happy_check="$(printf '%s' "$complete_line" | python3 -c '
import json, sys
try:
    call = json.loads(sys.stdin.read())
except Exception as e:
    print("ERR parse " + str(e)); sys.exit(0)
a = call.get("args", {})
outs = a.get("outputs") or []
caps = a.get("captions") or {}
problems = []
if len(outs) != 2: problems.append("outputs=%d" % len(outs))
if not (outs and outs[0].get("kind") == "video" and outs[0].get("role") == "cover"): problems.append("video not role cover")
if not (len(outs) > 1 and outs[1].get("url", "").endswith("-cover.png") and outs[1].get("kind") == "image" and outs[1].get("role") == "poster"): problems.append("cover.png not role poster")
if a.get("outputUrl") != (outs[0].get("url") if outs else None): problems.append("outputUrl != video")
if sorted(caps.keys()) != ["instagram", "tiktok", "youtube"]: problems.append("caption keys %r" % sorted(caps.keys()))
if "threads" in caps: problems.append("blank threads caption was sent")
if any(not v.strip() for v in caps.values()): problems.append("blank caption value")
if not caps.get("youtube", "").startswith("Day 14 of 30: The 3 AI Tools"): problems.append("youtube title line lost")
print("OK" if not problems else "BAD " + "; ".join(problems) + " :: " + json.dumps(a)[:300])
')"
if [[ "$happy_check" == "OK" ]]; then
  pass "happy: reel payload — video role cover, cover.png role poster, captions lower-cased/non-blank per target (blank threads dropped)"
else
  fail "happy: reel payload" "$happy_check"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "cover.png" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "happy: cover.png uploaded via /render/upload"
else
  fail "happy: cover.png upload" "cover.png not in uploads.jsonl"
fi
if [[ ! -d "$CASE_SCRATCH/test-brand/order-happy-1" ]]; then
  pass "happy: scratch dir wiped after complete"
else
  fail "happy: scratch wipe" "scratch dir still present"
fi
if grep -q "order-happy-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "happy: journal row outcome=complete"
else
  fail "happy: journal row" "no complete journal row found"
fi

echo "=== Case 2b: carousel — outputUrls[] + outputs[] (CFW-135) ==="
run_case "carousel" "carousel" "order_fixture order-carousel-1 brand-1 image" true
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "carousel: exactly one complete_render_order call"
else
  fail "carousel: complete count" "expected 1, got $(calls_count complete_render_order)"
fi
carousel_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
carousel_check="$(printf '%s' "$carousel_line" | python3 -c '
import json, sys
try:
    call = json.loads(sys.stdin.read())
except Exception as e:
    print("ERR parse " + str(e)); sys.exit(0)
a = call.get("args", {})
urls = a.get("outputUrls") or []
outs = a.get("outputs") or []
ok = (
    len(urls) == 4
    and urls[0].endswith("-slide-1.png") and urls[3].endswith("-carousel.pdf")
    and a.get("outputUrl") == urls[0]
    and len(outs) == 4
    and [o["order"] for o in outs] == [0, 1, 2, 3]
    and [o["kind"] for o in outs] == ["image", "image", "image", "doc"]
    and outs[3]["mimeType"] == "application/pdf"
    and all("brands/brand-1/renders/order-carousel-1/" in u for u in urls)
)
print("OK" if ok else "BAD " + json.dumps(a)[:400])
')"
if [[ "$carousel_check" == "OK" ]]; then
  pass "carousel: outputUrl=cover, outputUrls=4 in order, outputs[] typed (pdf → doc/application/pdf)"
else
  fail "carousel: complete payload" "$carousel_check"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "carousel.pdf" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "carousel: PDF uploaded via /render/upload"
else
  fail "carousel: PDF upload" "carousel.pdf not in uploads.jsonl"
fi
# No append_render_event may follow the complete call (the order is terminal).
post_complete="$(python3 -c '
import json, sys
seen = False; late = 0
for line in open(sys.argv[1]):
    c = json.loads(line)
    if c.get("tool") == "complete_render_order": seen = True; continue
    if seen and c.get("tool") == "append_render_event": late += 1
print(late)
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo 99)"
if [[ "$post_complete" == "0" ]]; then
  pass "carousel: no stage event after complete"
else
  fail "carousel: post-complete event" "$post_complete append_render_event call(s) after complete"
fi
if grep -q "order-carousel-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "carousel: journal row outcome=complete"
else
  fail "carousel: journal row" "no complete journal row found"
fi

echo "=== Case 2c: no captions.json — WARN, still completes, no captions key (CFW-136) ==="
run_case "no-captions" "no-captions" "order_fixture order-nocap-1 brand-1 video" true
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "no-captions: complete_render_order still called (server falls back to copy/intent)"
else
  fail "no-captions: complete count" "expected 1, got $(calls_count complete_render_order)"
fi
nocap_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if printf '%s' "$nocap_line" | python3 -c 'import json,sys; a=json.loads(sys.stdin.read()).get("args",{}); sys.exit(0 if "captions" not in a else 1)'; then
  pass "no-captions: no captions key sent (never an empty map)"
else
  fail "no-captions: captions key" "an empty/absent captions.json must not send a captions key: $nocap_line"
fi
if grep -q "order-nocap-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "no-captions: journal row outcome=complete"
else
  fail "no-captions: journal row" "no complete journal row found"
fi

echo "=== Case 2d: 6 MiB reel via the presigned path (CFW-144, default mode) ==="
run_case "large-presign" "large" "order_fixture order-large-1 brand-1 video" true
presign_check="$(python3 - "$CASE_MOCKSTATE/uploads.jsonl" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e:
    print("ERR " + str(e)); sys.exit(0)
rows = [r for r in rows if r.get("orderId") == "order-large-1"]
problems = []
by = {r["files"][0]: r for r in rows}
if set(by) != {"out.mp4", "cover.png"}: problems.append("files %r" % sorted(by))
if any(r.get("via") != "presign" for r in rows): problems.append("not every file went via presign: %r" % [(r["files"], r.get("via")) for r in rows])
if by.get("out.mp4", {}).get("bytes") != 6291456: problems.append("reel bytes %r" % by.get("out.mp4", {}).get("bytes"))
if any(r.get("puts") != 1 for r in rows): problems.append("PUT retried (ETag/MD5 check should pass first try): %r" % [(r["files"], r.get("puts")) for r in rows])
print("OK" if not problems else "BAD " + "; ".join(problems))
PY
)"
if [[ "$presign_check" == "OK" ]]; then
  pass "large: reel (6 MiB) + cover both delivered via upload-url → PUT → upload-complete, bytes verified, ETag=MD5 matched on the first PUT"
else
  fail "large: presign delivery" "$presign_check"
fi
if [[ "$(calls_count complete_render_order)" -eq 1 ]]; then
  pass "large: exactly one complete_render_order"
else
  fail "large: complete" "expected 1 complete_render_order call, got $(calls_count complete_render_order)"
fi
complete_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if echo "$complete_line" | grep -q 'brands/brand-1/renders/order-large-1/' && echo "$complete_line" | grep -q '"role": "poster"'; then
  pass "large: completion carries namespaced CDN URLs + the poster role (report contract unchanged)"
else
  fail "large: completion payload" "$complete_line"
fi
if grep -q "order-large-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "large: journal row outcome=complete"
else
  fail "large: journal row" "no complete journal row found"
fi

echo "=== Case 2e: auto mode — small file multipart, large file presign (CFW-144) ==="
run_case "large-auto" "large" "order_fixture order-auto-1 brand-1 video" export CFW_RENDER_UPLOAD_MODE=auto
auto_check="$(python3 - "$CASE_MOCKSTATE/uploads.jsonl" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e:
    print("ERR " + str(e)); sys.exit(0)
by = {r["files"][0]: r.get("via") for r in rows if r.get("orderId") == "order-auto-1"}
print("OK" if by == {"out.mp4": "presign", "cover.png": "multipart"} else "BAD %r" % by)
PY
)"
if [[ "$auto_check" == "OK" ]]; then
  pass "auto: cover.png (≤4 MiB) via multipart, out.mp4 (6 MiB) via presign"
else
  fail "auto: routing" "$auto_check"
fi
if [[ "$(calls_count complete_render_order)" -eq 1 ]]; then pass "auto: completed"; else fail "auto: complete" "no complete call"; fi

echo "=== Case 2f: multipart-only mode with a 6 MiB reel → platform 413, order blocked, no completion (CFW-144 fail-fast) ==="
run_case "large-multipart" "large" "order_fixture order-mp-1 brand-1 video" export CFW_RENDER_UPLOAD_MODE=multipart
if [[ "$(calls_count complete_render_order)" -eq 0 ]]; then
  pass "multipart: no complete_render_order (upload refused, nothing partial minted)"
else
  fail "multipart: complete" "expected 0 complete calls"
fi
if [[ "$(calls_count block_render_order)" -ge 1 ]]; then
  pass "multipart: order blocked with a reason (no silent fallback to presign)"
else
  fail "multipart: block" "expected block_render_order"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q '"via": "presign"' "$CASE_MOCKSTATE/uploads.jsonl"; then
  fail "multipart: fallback" "a presign upload happened in multipart-only mode"
else
  pass "multipart: no presign fallback"
fi

echo "=== Case 3: gate-fail path ==="
run_case "gate-fail" "gate-fail" "order_fixture order-gatefail-1 brand-1 video" true
if [[ "$(calls_count block_render_order)" -ge 1 ]]; then pass "gate-fail: block_render_order called"; else fail "gate-fail: block" "no block_render_order call"; fi
if [[ -d "$CASE_SCRATCH/test-brand/order-gatefail-1" ]]; then
  pass "gate-fail: scratch retained"
else
  fail "gate-fail: scratch retained" "scratch dir missing (should be kept for the 48h janitor)"
fi
if grep -q "order-gatefail-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "gate-fail: journal row outcome=block"
else
  fail "gate-fail: journal row" "no block journal row found"
fi

echo "=== Case 4: watchdog timeout ==="
CASE_TIMEOUT_VIDEO=3 run_case "watchdog" "watchdog" "order_fixture order-watchdog-1 brand-1 video" true
if [[ "$(calls_count block_render_order)" -ge 1 ]] && grep -q "time budget" "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "watchdog: block_render_order called with time-budget reason"
else
  fail "watchdog: block reason" "expected a block_render_order call mentioning 'time budget'"
fi
if grep -q "order-watchdog-1.*timeout" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "watchdog: journal row outcome=timeout"
else
  fail "watchdog: journal row" "no timeout journal row found"
fi
# [CFW-286] The watchdog kill must reach the WHOLE process group, not just the
# subshell — a straggler the Director backgrounded must not survive a
# watchdog-triggered block any more than a clean exit does.
watchdog_bg_pidfile="$CASE_SCRATCH/test-brand/order-watchdog-1/watchdog-bg.pid"
if [[ -f "$watchdog_bg_pidfile" ]]; then
  watchdog_bg_pid="$(cat "$watchdog_bg_pidfile" 2>/dev/null)"
  if [[ -n "$watchdog_bg_pid" ]] && ! kill -0 "$watchdog_bg_pid" 2>/dev/null; then
    pass "watchdog: backgrounded straggler reaped (group-kill on the watchdog path)"
  else
    fail "watchdog: straggler reap" "pid $watchdog_bg_pid is still alive after the tick"
  fi
else
  fail "watchdog: straggler reap" "watchdog-bg.pid not found — fake-director.sh didn't record it"
fi

echo "=== Case 4a: orphaned background — grace window absorbs a near-miss (CFW-286) ==="
# A background step that finishes WELL inside CFW_RENDER_ORPHAN_GRACE_SECS,
# after the Director itself has already exited 0 — the grace-poll must catch
# it and still land outcome=complete, not a false orphaned/crashed.
run_case "orphan-just-in-time" "orphan-just-in-time" "order_fixture order-orphan-jit-1 brand-1 video" \
  export CFW_RENDER_ORPHAN_GRACE_SECS=3 FAKE_DIRECTOR_ORPHAN_SLEEP=1
if grep -q "order-orphan-jit-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "orphan-just-in-time: journal row outcome=complete"
else
  fail "orphan-just-in-time: journal row" "no complete journal row found — grace window failed to absorb the near-miss"
fi
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "orphan-just-in-time: complete_render_order called exactly once"
else
  fail "orphan-just-in-time: complete call" "expected 1 complete_render_order, got $(calls_count complete_render_order)"
fi
if [[ ! -d "$CASE_SCRATCH/test-brand/order-orphan-jit-1" ]]; then
  pass "orphan-just-in-time: scratch wiped"
else
  fail "orphan-just-in-time: scratch" "scratch dir still present after a complete outcome"
fi

echo "=== Case 4b: orphaned background — past the grace window (CFW-286, the bug itself) ==="
# A background step that would finish PAST the grace window — the exact
# "Director ends its turn with background work still running" sequence.
# Must land outcome=orphaned (never crashed), block_render_order with the
# orphaned-specific reason, the process group reaped, and NO
# complete_render_order racing in after the block.
run_case "orphan-late" "orphan-late" "order_fixture order-orphan-late-1 brand-1 video" \
  export CFW_RENDER_ORPHAN_GRACE_SECS=2 FAKE_DIRECTOR_ORPHAN_SLEEP=15
if grep -q "order-orphan-late-1.*orphaned" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "orphan-late: journal row outcome=orphaned"
else
  fail "orphan-late: journal row" "no orphaned journal row found (got: $(grep 'order-orphan-late-1' "$CASE_STATE/journal.tsv" 2>/dev/null))"
fi
if [[ "$(calls_count block_render_order)" -ge 1 ]] && grep -q "background step was still running" "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "orphan-late: block_render_order called with the orphaned-specific reason"
else
  fail "orphan-late: block reason" "expected a block_render_order call mentioning 'background step was still running'"
fi
if [[ "$(calls_count complete_render_order)" == "0" ]]; then
  pass "orphan-late: no complete_render_order landed after the block (straggler didn't race the drainer's decision)"
else
  fail "orphan-late: stale complete" "a complete_render_order call landed — the reaped background process raced the block"
fi
orphan_bg_pidfile="$CASE_SCRATCH/test-brand/order-orphan-late-1/orphan-bg.pid"
if [[ -f "$orphan_bg_pidfile" ]]; then
  orphan_bg_pid="$(cat "$orphan_bg_pidfile" 2>/dev/null)"
  if [[ -n "$orphan_bg_pid" ]] && ! kill -0 "$orphan_bg_pid" 2>/dev/null; then
    pass "orphan-late: backgrounded straggler reaped, no longer alive"
  else
    fail "orphan-late: straggler reap" "pid $orphan_bg_pid is still alive after the tick"
  fi
else
  fail "orphan-late: straggler reap" "orphan-bg.pid not found — fake-director.sh didn't record it"
fi

echo "=== Case 4d: heartbeat + renderer identity (CFW-146) ==="
# A 2-second pulse against an ~8-second Director → at least 2 heartbeats, each
# carrying the renderer kind and no pct, and NONE after the order is terminal.
run_case "heartbeat" "heartbeat" "order_fixture order-hb-1 brand-1 video" export CFW_RENDER_HEARTBEAT_SECS=2
hb_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
hb = [c for c in calls if c.get("tool") == "append_render_event" and c.get("args", {}).get("kind") == "heartbeat"]
claim = next((c for c in calls if c.get("tool") == "claim_render_order"), None)
problems = []
if len(hb) < 2:
    problems.append("heartbeats=%d (expected >=2)" % len(hb))
if any(c["args"].get("pct") is not None for c in hb):
    problems.append("a heartbeat carried a pct")
kinds = {c["args"].get("stage") for c in hb}
if kinds and not kinds <= {"mac", "box", "byo", "fleet"}:
    problems.append("bad renderer kinds on heartbeats: %r" % kinds)
if any(not c.get("ok") for c in hb):
    problems.append("a heartbeat was rejected by the server")
if not claim or not isinstance(claim["args"].get("renderer"), dict):
    problems.append("claim carried no renderer identity")
elif claim["args"]["renderer"].get("kind") not in ("mac", "box", "byo", "fleet"):
    problems.append("claim renderer kind %r" % claim["args"]["renderer"].get("kind"))
# nothing may follow the terminal call
seen_terminal = False
late = 0
for c in calls:
    if c.get("tool") in ("complete_render_order", "block_render_order"):
        seen_terminal = True
        continue
    if seen_terminal and c.get("tool") == "append_render_event":
        late += 1
if late:
    problems.append("%d event(s) after the order went terminal" % late)
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$hb_check" == "OK" ]]; then
  pass "heartbeat: >=2 pulses with renderer kind, no pct, none after terminal; claim carries the renderer"
else
  fail "heartbeat" "$hb_check"
fi
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "heartbeat: the render still completed normally"
else
  fail "heartbeat: complete" "expected 1 complete_render_order, got $(calls_count complete_render_order)"
fi
if ! pgrep -f "cfw-render" >/dev/null 2>&1 || true; then :; fi

echo "=== Case 4e: block carries `needs` (CFW-146) ==="
run_case "needs-ingredient" "needs-ingredient" "order_fixture order-needs-1 brand-1 video" true
needs_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
blocks = [c for c in calls if c.get("tool") == "block_render_order"]
if not blocks:
    print("BAD no block_render_order call"); raise SystemExit
a = blocks[-1]["args"]
if a.get("needs") != "ingredient":
    print("BAD needs=%r" % a.get("needs")); raise SystemExit
if not blocks[-1].get("ok"):
    print("BAD block rejected by the server"); raise SystemExit
print("OK")
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$needs_check" == "OK" ]]; then
  pass "needs: block_render_order carries needs=ingredient (card offers an upload)"
else
  fail "needs" "$needs_check"
fi
if grep -q "order-needs-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "needs: journal row outcome=block"
else
  fail "needs: journal row" "no block journal row found"
fi

echo "=== Case 5: empty queue ==="
run_case "empty-queue" "happy" empty_queue true
if [[ "$CASE_DRAINER_EXIT" == "0" ]]; then pass "empty-queue: drainer exits 0"; else fail "empty-queue: exit" "expected 0, got $CASE_DRAINER_EXIT"; fi
if [[ "$(calls_count claim_render_order)" -ge 1 ]]; then pass "empty-queue: claim was attempted"; else fail "empty-queue: claim" "expected at least one claim attempt"; fi
if [[ "$(calls_count block_render_order)" == "0" && "$(calls_count complete_render_order)" == "0" ]]; then
  pass "empty-queue: no spawn (no complete/block calls)"
else
  fail "empty-queue: no spawn" "unexpected complete/block calls on an empty queue"
fi

echo "=== Case 6: tick lock exclusion ==="
lock_state="$(mktemp -d)"
mkdir -p "$lock_state/tick.lock"
printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock_state/tick.lock/info"
lock_seed="$(mktemp)"; order_fixture order-lock-1 brand-1 video > "$lock_seed"
lock_mock_state="$(mktemp -d)"
lock_port=$((MOCK_PORT_BASE + 80))
lock_pid="$(start_mock "$lock_seed" "$lock_mock_state" "$lock_port")"
lock_scratch_dir="$(mktemp -d)"
lock_skills_dir="$(mktemp -d)"
(
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$lock_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
  export CFW_RENDER_STATE_DIR="$lock_state"
  export CFW_RENDER_SCRATCH="$lock_scratch_dir"
  export CFW_RENDER_SKILLS_DIR="$lock_skills_dir"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
  "$REPO_DIR/bin/cfw-render.sh" --once
)
lock_exit=$?
kill "$lock_pid" 2>/dev/null; wait "$lock_pid" 2>/dev/null
if [[ "$lock_exit" == "0" ]]; then pass "tick-lock: second invocation exits 0"; else fail "tick-lock: exit" "expected 0, got $lock_exit"; fi
lock_calls="$(wc -l < "$lock_mock_state/calls.jsonl" 2>/dev/null | tr -d ' ')"
[[ -z "$lock_calls" ]] && lock_calls=0
if [[ "$lock_calls" == "0" ]]; then pass "tick-lock: no claim while lock held"; else fail "tick-lock: claim count" "expected 0 tool calls, got $lock_calls"; fi

echo "=== Case 7: fleet-enable operator surface (set + read) ==="
# Exercises bin/cfw-render-fleet.sh against the mock's master-key admin brands
# route. Master key differs from the worker key on purpose — flipping
# renderFleetEnabled is a privileged operator action.
fleet_master_key="master-test-key-cfw16"
fleet_seed="$(mktemp)"; order_fixture order-fleet-1 brand-fleet-1 video > "$fleet_seed"
fleet_state="$(mktemp -d)"
fleet_port=$((MOCK_PORT_BASE + 70))
MOCK_MASTER_KEY="$fleet_master_key" \
  python3 "$TEST_DIR/mock-server.py" "$fleet_port" "$fleet_state" "$fleet_seed" \
  > "$fleet_state/mock-server.log" 2>&1 &
fleet_pid=$!
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:$fleet_port/api/v1/mcp" >/dev/null 2>&1 && break
  sleep 0.1
done

fleet_run() {  # fleet_run <extra-env-assignments...> -- <fleet args...>
  local envs=()
  while [[ "${1:-}" != "--" && $# -gt 0 ]]; do envs+=("$1"); shift; done
  shift || true
  env "${envs[@]}" \
    CFW_API_BASE="http://127.0.0.1:$fleet_port" \
    CFW_RENDER_ADMIN_ENV="/nonexistent-admin-env-for-tests" \
    "$REPO_DIR/bin/cfw-render-fleet.sh" "$@"
}

# 1. initial read: false
out="$(fleet_run "CFW_MASTER_API_KEY=$fleet_master_key" -- status brand-fleet-1 2>/dev/null)"
if echo "$out" | grep -q "brand-fleet-1.*renderFleetEnabled=false"; then
  pass "fleet: initial status reads false"
else
  fail "fleet: initial status" "expected renderFleetEnabled=false, got: $out"
fi

# 2. enable, then read back true
out="$(fleet_run "CFW_MASTER_API_KEY=$fleet_master_key" -- enable brand-fleet-1 2>/dev/null)"; rc=$?
if [[ "$rc" == 0 ]] && echo "$out" | grep -q "brand-fleet-1.*renderFleetEnabled=true"; then
  pass "fleet: enable flips to true and reads back"
else
  fail "fleet: enable" "expected rc=0 + renderFleetEnabled=true, got rc=$rc: $out"
fi
out="$(fleet_run "CFW_MASTER_API_KEY=$fleet_master_key" -- status brand-fleet-1 2>/dev/null)"
if echo "$out" | grep -q "brand-fleet-1.*renderFleetEnabled=true"; then
  pass "fleet: status reflects enabled state (persisted)"
else
  fail "fleet: status after enable" "expected renderFleetEnabled=true, got: $out"
fi

# 3. disable, read back false (reversible)
out="$(fleet_run "CFW_MASTER_API_KEY=$fleet_master_key" -- disable brand-fleet-1 2>/dev/null)"; rc=$?
if [[ "$rc" == 0 ]] && echo "$out" | grep -q "brand-fleet-1.*renderFleetEnabled=false"; then
  pass "fleet: disable flips back to false (reversible)"
else
  fail "fleet: disable" "expected rc=0 + renderFleetEnabled=false, got rc=$rc: $out"
fi

# 4. missing master key: refuse (fail fast, no call)
if fleet_run "CFW_RENDER_ADMIN_ENV=/nonexistent" -- status brand-fleet-1 >/dev/null 2>&1; then
  fail "fleet: missing master key" "expected non-zero exit when CFW_MASTER_API_KEY unset"
else
  pass "fleet: refuses without a master key"
fi

# 5. wrong master key: 401, non-zero exit
if fleet_run "CFW_MASTER_API_KEY=wrong-key" -- enable brand-fleet-1 >/dev/null 2>&1; then
  fail "fleet: wrong master key" "expected non-zero exit on 401"
else
  pass "fleet: rejects a wrong master key"
fi

kill "$fleet_pid" 2>/dev/null; wait "$fleet_pid" 2>/dev/null

echo "=== Case 8: default credential paths resolve into ~/ecosystem/vault, not ~/.gsai/secrets (CFW-289) ==="
# Regression for CFW-289: bin/cfw-render-lib.sh's three credential-path
# defaults used to point at the retired ~/.gsai/secrets vault. Each sub-case
# runs under a throwaway $HOME so the assertions don't depend on (or touch)
# this machine's real vault state, and the --dry sub-case talks to a mock
# server — never a live CFW_API_BASE.
c289_home="$(mktemp -d)"

# 1. cr_load_config: default CFW_RENDER_ENV path, no required vars set — the
#    "missing required" error interpolates the path it checked.
c289_out="$(
  env -i HOME="$c289_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    cr_load_config
  ' 2>&1
)"
if echo "$c289_out" | grep -q "ecosystem/vault/cfw-render.env" && ! echo "$c289_out" | grep -q '\.gsai'; then
  pass "cr_load_config: default env path is ~/ecosystem/vault, not ~/.gsai/secrets"
else
  fail "cr_load_config: default env path" "expected ecosystem/vault/cfw-render.env with no .gsai mention, got: $c289_out"
fi

# 2. cr_load_admin_config: default CFW_RENDER_ADMIN_ENV path.
c289_admin_out="$(
  env -i HOME="$c289_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    cr_load_admin_config
  ' 2>&1
)"
if echo "$c289_admin_out" | grep -q "ecosystem/vault/cfw-render-admin.env" && ! echo "$c289_admin_out" | grep -q '\.gsai'; then
  pass "cr_load_admin_config: default admin-env path is ~/ecosystem/vault, not ~/.gsai/secrets"
else
  fail "cr_load_admin_config: default admin-env path" "expected ecosystem/vault/cfw-render-admin.env with no .gsai mention, got: $c289_admin_out"
fi

# 3. cr_load_config's ollama-keys default, surfaced via `cfw-render.sh --dry`'s
#    health table (against a mock server, not a live CFW_API_BASE).
c289_seed="$(mktemp)"; empty_queue > "$c289_seed"
c289_state="$(mktemp -d)"
c289_port=$((MOCK_PORT_BASE + 80))
c289_pid="$(start_mock "$c289_seed" "$c289_state" "$c289_port")"
c289_dry_out="$(
  env -i HOME="$c289_home" PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH" \
    CFW_API_BASE="http://127.0.0.1:$c289_port" \
    CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000" \
    CFW_RENDER_STATE_DIR="$c289_home/cr-state" \
    CFW_RENDER_SCRATCH="$c289_home/cr-scratch" \
    CFW_RENDER_SKILLS_DIR="$c289_home/skills" \
    "$REPO_DIR/bin/cfw-render.sh" --dry 2>&1
)"
kill "$c289_pid" 2>/dev/null; wait "$c289_pid" 2>/dev/null
if echo "$c289_dry_out" | grep -q "ecosystem/vault/ollama-keys.env" && ! echo "$c289_dry_out" | grep -q '\.gsai'; then
  pass "cfw-render.sh --dry: default ollama-keys path is ~/ecosystem/vault, not ~/.gsai/secrets"
else
  fail "cfw-render.sh --dry: default ollama-keys path" "expected ecosystem/vault/ollama-keys.env with no .gsai mention, got: $c289_dry_out"
fi

echo "=== Case 9: static guard — no live reference to the retired ~/.gsai/secrets vault ==="
# Cheap grep gate so a future doc edit can't copy the old prose back in.
# backlog/ is excluded on purpose — those are dated historical task records
# from when ~/.gsai/secrets was the live convention (see design notes).
c289_grep_raw="$(grep -rn '\.gsai/secrets' "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/config" "$REPO_DIR"/install/*.md "$REPO_DIR/README.md" "$REPO_DIR/docs" 2>/dev/null)"
# README's "Ollama keys vs zai.env" note intentionally keeps ONE historical
# mention — the task text's original wrong *file*, not the retired vault
# *directory* (see the design doc for CFW-289). Exclude that single known line.
c289_grep_out="$(printf '%s\n' "$c289_grep_raw" | grep -v "README.md:.*task text originally said")"
c289_grep_out="$(printf '%s\n' "$c289_grep_out" | sed '/^$/d')"
if [[ -z "$c289_grep_out" ]]; then
  pass "static guard: no live bin/lib/config/docs reference to ~/.gsai/secrets"
else
  fail "static guard: retired vault path" "found live references: $c289_grep_out"
fi

echo "=== Case 10: sync-skills.py rewrites host-path sub-skill resolvers to .hub/ (CFW-312) ==="
c312_out="$(mktemp -d)"
c312_sync_log="$(
  CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$c312_out" --skip-manifest 2>&1
)"
c312_sync_rc=$?
if [[ "$c312_sync_rc" == "0" ]]; then
  pass "sync-skills.sh: fixture sync + portability gate exit 0"
else
  fail "sync-skills.sh: fixture sync" "expected exit 0, got $c312_sync_rc — log: $c312_sync_log"
fi

c312_top_skill_dir="$(grep '^SKILL_DIR=' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null)"
if [[ "$c312_top_skill_dir" == 'SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-fixture-recipe"' ]]; then
  pass "sync-skills.py: top-level recipe's own-dir line anchors on CFW_RENDER_SKILLS_DIR"
else
  fail "sync-skills.py: own-dir rewrite" "got: $c312_top_skill_dir"
fi

c312_sub_dir="$(grep '^FIXTURE_DEP_DIR=' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null)"
if [[ "$c312_sub_dir" == 'FIXTURE_DEP_DIR="$SKILL_DIR/.hub/c-fixture-dep"' ]]; then
  pass "sync-skills.py: sub-skill-dir line resolves against bundled .hub/, not a host find"
else
  fail "sync-skills.py: sub-skill-dir rewrite" "got: $c312_sub_dir"
fi

if grep -q '\[ -n "\$FIXTURE_DEP_DIR" \]' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null; then
  fail "sync-skills.py: dead fallback" "the now-dead '[ -n ... ] || ...' fallback line should have been dropped"
else
  pass "sync-skills.py: dead fallback line dropped (rewritten assignment is unconditional)"
fi

c312_nested_skill_dir="$(grep '^SKILL_DIR=' "$c312_out/p-fixture-recipe/.hub/c-fixture-dep/SKILL.md" 2>/dev/null)"
if [[ "$c312_nested_skill_dir" == 'SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-fixture-recipe/.hub/c-fixture-dep"' ]]; then
  pass "sync-skills.py: vendored dep's own-dir line resolves to its actual on-disk .hub/ location"
else
  fail "sync-skills.py: vendored dep own-dir rewrite" "got: $c312_nested_skill_dir"
fi

if "$REPO_DIR/scripts/check-skills-portability.sh" --skills-dir "$c312_out" >/dev/null 2>&1; then
  pass "check-skills-portability.sh: PASS on the rewritten fixture bundle"
else
  fail "check-skills-portability.sh: fixture bundle" "expected exit 0 after rewrite"
fi

if "$REPO_DIR/scripts/check-skills-portability.sh" --skills-dir "$c312_out" c-fixture-clean >/dev/null 2>&1; then
  pass "check-skills-portability.sh: clean recipe (no dependsOn, no resolver) doesn't false-positive"
else
  fail "check-skills-portability.sh: clean recipe" "expected exit 0 for c-fixture-clean"
fi
rm -rf "$c312_out"

echo "=== Case 11: static guard — bundled skills resolve sub-skills from .hub/, not host paths (CFW-312) ==="
if "$REPO_DIR/scripts/check-skills-portability.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no host-path sub-skill resolver"
else
  c312_real_out="$("$REPO_DIR/scripts/check-skills-portability.sh" 2>&1)"
  fail "static guard: host-path resolver in committed bundle" "$c312_real_out"
fi

echo "=== Case 12: static guard — no worker-vault HeyGen credential in bin/lib/config (CFW-313) ==="
if "$REPO_DIR/scripts/check-no-worker-heygen-credential.sh" >/dev/null 2>&1; then
  pass "static guard: no worker-vault HeyGen credential reference in bin/lib/config"
else
  c313_guard_out="$("$REPO_DIR/scripts/check-no-worker-heygen-credential.sh" 2>&1)"
  fail "static guard: worker-vault HeyGen credential reference found" "$c313_guard_out"
fi

echo "=== Case 13: HeyGen credential present + unexpired — exported into the Director's env, never HEYGEN_API_KEY (CFW-313) ==="
run_case "heygen-present" "heygen-cred" \
  'order_fixture_heygen order-heygen-ok-1 brand-1 video {"mode":"oauth","accessToken":"test-heygen-oauth-token-abc123","expiresAt":"2099-01-01T00:00:00Z","creditPool":"plan_credits"}' \
  true
if [[ "$(calls_count block_render_order)" == "1" ]]; then
  pass "heygen-present: Director spawned and ran (it blocked itself — this fixture is a probe, not a real render)"
else
  fail "heygen-present: director spawn" "expected exactly 1 block_render_order (from the Director's own probe block), got $(calls_count block_render_order)"
fi
heygen_env_file="$CASE_SCRATCH/test-brand/order-heygen-ok-1/heygen-env.txt"
if [[ -f "$heygen_env_file" ]]; then
  pass "heygen-present: Director's env was captured"
else
  fail "heygen-present: env capture" "heygen-env.txt not found at $heygen_env_file"
fi
heygen_env_check="$(python3 -c '
import sys
vals = {}
try:
    for line in open(sys.argv[1] if len(sys.argv) > 1 else "/dev/null"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            vals[k] = v
except FileNotFoundError:
    print("BAD file missing"); raise SystemExit
problems = []
if vals.get("HEYGEN_OAUTH_TOKEN") != "test-heygen-oauth-token-abc123":
    problems.append("HEYGEN_OAUTH_TOKEN=%r" % vals.get("HEYGEN_OAUTH_TOKEN"))
if vals.get("HEYGEN_CREDIT_POOL") != "plan_credits":
    problems.append("HEYGEN_CREDIT_POOL=%r" % vals.get("HEYGEN_CREDIT_POOL"))
if vals.get("HEYGEN_TOKEN_EXPIRES_AT") != "2099-01-01T00:00:00Z":
    problems.append("HEYGEN_TOKEN_EXPIRES_AT=%r" % vals.get("HEYGEN_TOKEN_EXPIRES_AT"))
if vals.get("HEYGEN_API_KEY"):
    problems.append("HEYGEN_API_KEY was set (%r) — must never be, this is an OAuth credential" % vals.get("HEYGEN_API_KEY"))
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$heygen_env_file" 2>/dev/null || echo "BAD could not read $heygen_env_file")"
if [[ "$heygen_env_check" == "OK" ]]; then
  pass "heygen-present: HEYGEN_OAUTH_TOKEN/HEYGEN_CREDIT_POOL/HEYGEN_TOKEN_EXPIRES_AT landed correctly, HEYGEN_API_KEY never set"
else
  fail "heygen-present: env values" "$heygen_env_check"
fi

echo "=== Case 13b: HeyGen credential absent — blocked with needs=decision, Director never spawned (CFW-313) ==="
run_case "heygen-absent" "heygen-cred" "order_fixture_heygen order-heygen-absent-1 brand-1 video" true
if [[ "$(calls_count append_render_event)" == "0" ]]; then
  pass "heygen-absent: no append_render_event — the Director was never spawned"
else
  fail "heygen-absent: no spawn" "expected 0 append_render_event calls, got $(calls_count append_render_event)"
fi
if [[ "$(calls_count complete_render_order)" == "0" ]]; then
  pass "heygen-absent: no complete_render_order"
else
  fail "heygen-absent: complete" "expected 0 complete_render_order calls"
fi
heygen_absent_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
blocks = [c for c in calls if c.get("tool") == "block_render_order"]
if len(blocks) != 1:
    print("BAD block_render_order called %d times (expected 1)" % len(blocks)); raise SystemExit
a = blocks[0]["args"]
problems = []
if a.get("needs") != "decision":
    problems.append("needs=%r" % a.get("needs"))
if "connect" not in (a.get("reason") or "").lower():
    problems.append("reason does not mention connecting the account: %r" % a.get("reason"))
if not blocks[0].get("ok"):
    problems.append("block rejected by the server")
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$heygen_absent_check" == "OK" ]]; then
  pass "heygen-absent: block_render_order carries needs=decision + an owner-actionable reason"
else
  fail "heygen-absent" "$heygen_absent_check"
fi
if grep -q "order-heygen-absent-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "heygen-absent: journal row outcome=blocked"
else
  fail "heygen-absent: journal row" "no blocked journal row found"
fi

echo "=== Case 13c: HeyGen credential present but expired — treated identically to absent (CFW-313) ==="
run_case "heygen-expired" "heygen-cred" \
  'order_fixture_heygen order-heygen-expired-1 brand-1 video {"mode":"oauth","accessToken":"test-heygen-oauth-token-expired","expiresAt":"2000-01-01T00:00:00Z","creditPool":"plan_credits"}' \
  true
if [[ "$(calls_count append_render_event)" == "0" ]]; then
  pass "heygen-expired: no append_render_event — the Director was never spawned"
else
  fail "heygen-expired: no spawn" "expected 0 append_render_event calls, got $(calls_count append_render_event)"
fi
if grep -q "order-heygen-expired-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "heygen-expired: journal row outcome=blocked (expired token treated as absent)"
else
  fail "heygen-expired: journal row" "no blocked journal row found"
fi

echo "=== Case P: toolchain preflight refuses to claim on a half-provisioned host ==="
# CFW-199 / CFW-188. hst had NO ImageMagick and was one `systemctl enable` from
# claiming production orders it could not finish. The drainer must now refuse.
pf_dir="$(mktemp -d)"; mkdir -p "$pf_dir/mockstate"
order_fixture order-preflight-1 brand-1 video > "$pf_dir/queue.json"
pf_port=$((MOCK_PORT_BASE + 95))
pf_pid="$(start_mock "$pf_dir/queue.json" "$pf_dir/mockstate" "$pf_port")"

# A PATH shim that hides exactly ONE required tool — ImageMagick — and passes
# everything else through unchanged. That is the shape of the CFW-188 box: fully
# provisioned except for the one binary the recipes need.
pf_shim="$(mktemp -d)"
pf_full_path="$REPO_DIR/bin:$FAKE_BIN:$PATH"
IFS=':' read -ra pf_path_dirs <<< "$pf_full_path"
for pf_d in "${pf_path_dirs[@]}"; do
  [[ -n "$pf_d" && -d "$pf_d" ]] || continue
  for pf_f in "$pf_d"/*; do
    [[ -f "$pf_f" || -L "$pf_f" ]] || continue
    [[ -x "$pf_f" ]] || continue
    pf_b="${pf_f##*/}"
    [[ "$pf_b" == "magick" || "$pf_b" == "convert" ]] && continue
    [[ -e "$pf_shim/$pf_b" ]] || ln -s "$pf_f" "$pf_shim/$pf_b" 2>/dev/null
  done
done

pf_out=""; pf_exit=0
pf_run() { # pf_run <PATH> — sets $pf_out and $pf_exit (NOT via command
           # substitution: that is a subshell and $pf_out would not survive)
  pf_out="$(
    export PATH="$1"
    export CFW_API_BASE="http://127.0.0.1:$pf_port"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$pf_dir/cr-state"
    export CFW_RENDER_SCRATCH="$pf_dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$pf_dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    "$REPO_DIR/bin/cfw-render.sh" 2>&1
  )"
  pf_exit=$?
}

pf_run "$pf_shim"
if [[ "$pf_exit" != "0" ]]; then
  pass "preflight: a host missing ImageMagick exits non-zero"
else
  fail "preflight: exit code" "expected non-zero on a host without 'magick', got 0"
fi
if echo "$pf_out" | grep -q "magick"; then
  pass "preflight: names the missing tool"
else
  fail "preflight: message" "failure output does not name 'magick': $pf_out"
fi
if echo "$pf_out" | grep -qiE "brew install imagemagick|apt-get install -y imagemagick"; then
  pass "preflight: names how to install it"
else
  fail "preflight: install hint" "no install command in the failure output"
fi
# NB: `grep -c ... || echo 0` double-prints when the file exists but has no
# match (grep exits 1 having already printed "0") — the harness hit that before.
pf_claims=0
if [[ -f "$pf_dir/mockstate/calls.jsonl" ]]; then
  pf_claims="$(grep -c '"tool": "claim_render_order"' "$pf_dir/mockstate/calls.jsonl")" || pf_claims=0
fi
if [[ "$pf_claims" == "0" ]]; then
  pass "preflight: claimed NOTHING (the queued order is untouched)"
else
  fail "preflight: claimed work" "expected 0 claim_render_order calls, got $pf_claims"
fi

# Same host, full PATH restored: the drainer runs normally. Proves the gate is
# the missing tool, not the shim.
pf_run "$REPO_DIR/bin:$FAKE_BIN:$PATH"
pf_ok_exit="$pf_exit"
if [[ "$pf_ok_exit" == "0" ]]; then
  pass "preflight: a fully-provisioned host still runs"
else
  fail "preflight: false negative" "expected 0 on a complete toolchain, got $pf_ok_exit"
fi

kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null
rm -rf "$pf_shim"

echo ""
echo "=== Lint ==="
if "$REPO_DIR/scripts/lint.sh"; then
  pass "scripts/lint.sh"
else
  fail "scripts/lint.sh" "lint failed"
fi

echo ""
echo "=== Case F: fan-out routes a native Claude alias to the worker's own login (CFW-299) ==="
cf_dir="$(mktemp -d)"; mkdir -p "$cf_dir/mockstate" "$cf_dir/work"
empty_queue > "$cf_dir/queue.json"
cf_port=$((MOCK_PORT_BASE + 95))
cf_pid="$(start_mock "$cf_dir/queue.json" "$cf_dir/mockstate" "$cf_port")"
: > "$cf_dir/no-keys.env"   # no live Ollama account at all — the 2026-09-29 state
(
  cd "$cf_dir" || exit 1
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$cf_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_ORDER_ID="order-fanout-test" CFW_WORKER_ID="worker-fanout-test"
  # the Director env always carries these (cfw-render.sh exports them); cr_event
  # runs under set -u and needs the state dir for its best-effort log line
  export CFW_RENDER_STATE_DIR="$cf_dir/cr-state" CFW_RENDER_SCRATCH_DIR="$cf_dir"
  export CFW_RENDER_FANOUT_MODELS="sonnet,glm-5.2"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$cf_dir/no-keys.env"
  "$REPO_DIR/bin/cfw-render-subagent.sh" sonnet -p "render card 1" >/dev/null 2>&1
  echo "$?" > "$cf_dir/rc-native"
  "$REPO_DIR/bin/cfw-render-subagent.sh" glm-5.2 -p "render card 2" >/dev/null 2>&1
  echo "$?" > "$cf_dir/rc-ollama"
)
kill "$cf_pid" 2>/dev/null; wait "$cf_pid" 2>/dev/null
if [[ "$(cat "$cf_dir/rc-native")" == "0" ]]; then
  pass "fanout: native alias 'sonnet' is served (exit 0) with no Ollama key present"
else
  fail "fanout: native alias" "expected exit 0, got $(cat "$cf_dir/rc-native")"
fi
if grep -qx 'sonnet' "$cf_dir/work/.models-fanout" 2>/dev/null; then
  pass "fanout: served model 'sonnet' recorded in work/.models-fanout"
else
  fail "fanout: models-fanout" "expected 'sonnet' in work/.models-fanout, got: $(cat "$cf_dir/work/.models-fanout" 2>/dev/null)"
fi
if grep -qs -- '--model sonnet' "$cf_dir"/work/.subagent-*.out; then
  pass "fanout: native path invoked claude with --model sonnet"
else
  fail "fanout: native invocation" "no '--model sonnet' in $(ls "$cf_dir"/work/.subagent-*.out 2>/dev/null)"
fi
if [[ "$(cat "$cf_dir/rc-ollama")" != "0" ]]; then
  pass "fanout: Ollama model with no live key fails loudly (non-zero), never hangs"
else
  fail "fanout: ollama without keys" "expected non-zero exit, got 0"
fi
if grep -q '"kind": "subagent"' "$cf_dir/mockstate/calls.jsonl" 2>/dev/null; then
  pass "fanout: native subagent event reached the server"
else
  fail "fanout: subagent event" "no kind=subagent append_render_event in mock calls"
fi

echo "-------------------------------------"
echo "PASS: $PASS_COUNT   FAIL: $FAILURES"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
