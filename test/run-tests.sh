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

# ===========================================================================
# CFW-291: resolved-binary worker PATH + headless claude probe + Linux
# coverage. None of the cases below need the mock server — these are pure
# bash-function and template-rendering checks (same "no live services" rule
# already governing this file).
# ===========================================================================

echo "=== Case Q1: cr_resolve_worker_path finds a nonstandard binary location ==="
q1_tmp="$(mktemp -d)"
mkdir -p "$q1_tmp/weird"
cp "$TEST_DIR/fake-claude.sh" "$q1_tmp/weird/claude"
chmod +x "$q1_tmp/weird/claude"
q1_out="$(
  export PATH="$q1_tmp/weird:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ ":$q1_out:" == *":$q1_tmp/weird:"* ]]; then
  pass "cr_resolve_worker_path: resolves a nonstandard claude location (not the CFW-279 guessed list)"
else
  fail "cr_resolve_worker_path: nonstandard location" "expected $q1_tmp/weird in: $q1_out"
fi
rm -rf "$q1_tmp"

echo "=== Case Q2: cr_resolve_worker_path dedups + preserves the static fallback dirs ==="
q2_tmp="$(mktemp -d)"
mkdir -p "$q2_tmp/custom"
for q2_b in curl python3; do
  q2_real="$(command -v "$q2_b")"
  [[ -n "$q2_real" ]] && ln -s "$q2_real" "$q2_tmp/custom/$q2_b"
done
q2_out="$(
  export PATH="$q2_tmp/custom:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
q2_count="$(printf '%s\n' "$q2_out" | tr ':' '\n' | grep -c "^$q2_tmp/custom\$")"
if [[ "$q2_count" == "1" ]]; then
  pass "cr_resolve_worker_path: two bins resolved into the same custom dir → that dir appears exactly once"
else
  fail "cr_resolve_worker_path: dedup" "expected 1 occurrence of $q2_tmp/custom, got $q2_count in: $q2_out"
fi
if [[ ":$q2_out:" == *":/usr/local/bin:"* && ":$q2_out:" == *":/opt/homebrew/bin:"* && ":$q2_out:" == *":/usr/bin:"* && ":$q2_out:" == *":/bin:"* ]]; then
  pass "cr_resolve_worker_path: static fallback dirs still present (CFW-279's Homebrew-case regression, now automated)"
else
  fail "cr_resolve_worker_path: fallback preserved" "missing a fallback dir in: $q2_out"
fi
rm -rf "$q2_tmp"

echo "=== Case Q3: cr_probe_claude_headless — the money test (catches what CFW-279's naive check could not) ==="
q3_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude-env-dependent.sh" "$q3_tmp/claude"
chmod +x "$q3_tmp/claude"
q3_naive_rc=1
(
  export PATH="$q3_tmp:$PATH"
  export FAKE_NVM_DIR=1
  command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1
)
q3_naive_rc=$?
if [[ "$q3_naive_rc" == "0" ]]; then
  pass "money test setup: naive 'command -v claude && claude --version' succeeds in the harness's own (rich) env — the exact CFW-279 gap"
else
  fail "money test setup" "naive command -v/claude --version unexpectedly failed in the harness's own env (rc=$q3_naive_rc)"
fi
(
  export PATH="$q3_tmp:$PATH"
  export FAKE_NVM_DIR=1
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q3_tmp:/usr/local/bin:/usr/bin:/bin"
) >/dev/null 2>&1
q3_probe_rc=$?
if [[ "$q3_probe_rc" != "0" ]]; then
  pass "money test: cr_probe_claude_headless FAILS under env -i (FAKE_NVM_DIR stripped) — caught at install time, not the first real tick"
else
  fail "money test: probe" "expected non-zero, cr_probe_claude_headless returned 0"
fi
rm -rf "$q3_tmp"

echo "=== Case Q4: cr_probe_claude_headless — success case, and empty-output-is-still-a-failure ==="
q4_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$q4_tmp/claude"
chmod +x "$q4_tmp/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_tmp"
) >/dev/null 2>&1
q4_rc=$?
if [[ "$q4_rc" == "0" ]]; then
  pass "cr_probe_claude_headless: succeeds against a claude that prints output and exits 0"
else
  fail "cr_probe_claude_headless: success case" "expected 0, got $q4_rc"
fi
rm -rf "$q4_tmp"

q4_empty="$(mktemp -d)"
cat > "$q4_empty/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
exit 0
FAKECLAUDE
chmod +x "$q4_empty/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_empty"
) >/dev/null 2>&1
q4_empty_rc=$?
if [[ "$q4_empty_rc" != "0" ]]; then
  pass "cr_probe_claude_headless: exit 0 but empty output is still a FAIL (mirrors cr_preflight's own claude --version rule)"
else
  fail "cr_probe_claude_headless: empty output" "expected non-zero, got 0"
fi
rm -rf "$q4_empty"

echo "=== Case Q5: cr_probe_claude_headless respects the stub-Director skip ==="
q5_empty_path="$(mktemp -d)"
(
  export PATH="$q5_empty_path"
  export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q5_empty_path"
) >/dev/null 2>&1
q5_rc=$?
if [[ "$q5_rc" == "0" ]]; then
  pass "cr_probe_claude_headless: SKIPs (returns 0) when CFW_RENDER_DIRECTOR_CMD is set, even with no claude anywhere on PATH"
else
  fail "cr_probe_claude_headless: stub skip" "expected 0 (SKIP), got $q5_rc"
fi
rm -rf "$q5_empty_path"

# ---------------------------------------------------------------------------
# _q291_relocate_bin <full_path> <custom_dir> <relocate_bin>
# Shared helper for Cases Q6/Q7 below — resolves <relocate_bin> on
# <full_path> and symlinks it alone into <custom_dir>. Unlike Case P (which
# must HIDE one tool while keeping everything else reachable, hence a full
# PATH mirror), Q6/Q7 only need to prove a relocated bin is found in a
# nonstandard location while every other tool keeps resolving normally — so
# the caller just puts <custom_dir> ahead of the real PATH; ordinary PATH
# precedence does the rest without mirroring every binary on the system
# (mirroring is what made this loop O(size of $PATH) and slow on boxes with
# a large ambient PATH).
# ---------------------------------------------------------------------------
_q291_relocate_bin() {
  local full_path="$1" custom="$2" relocate="$3" real
  real="$(PATH="$full_path" command -v "$relocate" 2>/dev/null)" || return 0
  ln -s "$real" "$custom/$relocate" 2>/dev/null
}

echo "=== Case Q6: install.sh renders the resolved WORKER_PATH into the macOS plist ==="
q6_real_home="$HOME"
q6_home="$(mktemp -d)"
q6_prefix="$(mktemp -d)"
q6_custom="$(mktemp -d)"
q6_env="$(mktemp)"
cat > "$q6_env" <<EOF
CFW_API_BASE=http://127.0.0.1:1
CFW_RENDER_WORKER_KEY=cfw_render_test0000000000000000
CFW_RENDER_STATE_DIR=$q6_home/cfw-render-state
CFW_RENDER_SCRATCH=$q6_home/cfw-render-scratch
EOF

_q291_relocate_bin "$REPO_DIR/bin:$FAKE_BIN:$PATH" "$q6_custom" ffmpeg
q6_test_path="$q6_custom:$REPO_DIR/bin:$FAKE_BIN:$PATH"

q6_expected_worker_path="$(
  export PATH="$q6_test_path"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"

(
  export HOME="$q6_home"
  export PATH="$q6_test_path"
  # PLAYWRIGHT_BROWSERS_PATH: cr_preflight_chromium's search is $HOME-relative
  # by default; since HOME is deliberately overridden to a scratch dir for
  # this hermetic test, point it back at the real cache so the unrelated
  # chromium/fonts preflight rows still PASS on a dev box that has Playwright
  # installed under the real $HOME — this test is about WORKER_PATH
  # rendering, not about re-testing chromium discovery.
  export PLAYWRIGHT_BROWSERS_PATH="$q6_real_home/Library/Caches/ms-playwright"
  "$REPO_DIR/install/install.sh" --mode byoa --prefix "$q6_prefix" --env-file "$q6_env" >"$q6_home/install.log" 2>&1
)

q6_plist="$q6_home/Library/LaunchAgents/com.cfw.render.plist"
if [[ -f "$q6_plist" ]]; then
  pass "install.sh: renders com.cfw.render.plist"
else
  fail "install.sh: plist written" "not found at $q6_plist — install.log tail: $(tail -20 "$q6_home/install.log" 2>/dev/null)"
fi

if [[ -f "$q6_plist" ]] && grep -qF '{{WORKER_PATH}}' "$q6_plist"; then
  fail "install.sh: leftover WORKER_PATH token" "plist still contains the literal {{WORKER_PATH}} placeholder"
else
  pass "install.sh: no leftover {{WORKER_PATH}} token in the plist"
fi

q6_plist_path_value=""
if [[ -f "$q6_plist" ]]; then
  q6_plist_path_value="$(python3 -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
    print(d.get("EnvironmentVariables", {}).get("PATH", ""))
except Exception as e:
    print("ERR " + str(e))
' "$q6_plist")"
fi
if [[ "$q6_plist_path_value" == "$q6_expected_worker_path" ]]; then
  pass "install.sh: plist PATH == cr_resolve_worker_path's output for the same PATH"
else
  fail "install.sh: plist PATH value" "expected [$q6_expected_worker_path] got [$q6_plist_path_value]"
fi

if [[ -f "$q6_plist" ]]; then
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$q6_plist" >/dev/null 2>&1; then
      pass "install.sh: rendered plist is well-formed XML (plutil -lint)"
    else
      fail "install.sh: plist XML" "plutil -lint reported malformed XML"
    fi
  else
    if python3 -c "import xml.dom.minidom, sys; xml.dom.minidom.parse(sys.argv[1])" "$q6_plist" >/dev/null 2>&1; then
      pass "install.sh: rendered plist is well-formed XML (xml.dom.minidom fallback)"
    else
      fail "install.sh: plist XML" "xml.dom.minidom failed to parse the rendered plist"
    fi
  fi
fi

rm -rf "$q6_home" "$q6_prefix" "$q6_custom"
rm -f "$q6_env"

echo "=== Case Q7: install.sh renders WORKER_PATH into the Linux systemd unit, from this macOS dev box (CFW_RENDER_TEST_OS seam) ==="
q7_real_home="$HOME"
q7_home="$(mktemp -d)"
q7_prefix="$(mktemp -d)"
q7_custom="$(mktemp -d)"
q7_env="$(mktemp)"
cat > "$q7_env" <<EOF
CFW_API_BASE=http://127.0.0.1:1
CFW_RENDER_WORKER_KEY=cfw_render_test0000000000000000
CFW_RENDER_STATE_DIR=$q7_home/cfw-render-state
CFW_RENDER_SCRATCH=$q7_home/cfw-render-scratch
EOF

_q291_relocate_bin "$REPO_DIR/bin:$FAKE_BIN:$PATH" "$q7_custom" ffmpeg
q7_test_path="$q7_custom:$REPO_DIR/bin:$FAKE_BIN:$PATH"

q7_expected_worker_path="$(
  export PATH="$q7_test_path"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"

(
  export HOME="$q7_home"
  export PATH="$q7_test_path"
  export PLAYWRIGHT_BROWSERS_PATH="$q7_real_home/Library/Caches/ms-playwright"
  export CFW_RENDER_TEST_OS="Linux"
  "$REPO_DIR/install/install.sh" --mode byoa --prefix "$q7_prefix" --env-file "$q7_env" >"$q7_home/install.log" 2>&1 &
  echo $! > "$q7_home/install.pid"
  wait $!
)
q7_pid="$(cat "$q7_home/install.pid" 2>/dev/null)"
q7_service="/tmp/cfw-render.service.$q7_pid"
q7_timer="/tmp/cfw-render.timer.$q7_pid"

if [[ -n "$q7_pid" && -f "$q7_service" ]]; then
  pass "install.sh: renders cfw-render.service under CFW_RENDER_TEST_OS=Linux (first automated coverage the Linux unit has ever had)"
else
  fail "install.sh: linux unit written" "not found at $q7_service — install.log tail: $(tail -20 "$q7_home/install.log" 2>/dev/null)"
fi

if [[ -f "$q7_service" ]] && grep -qF '{{WORKER_PATH}}' "$q7_service"; then
  fail "install.sh: leftover WORKER_PATH token (linux)" "unit still contains the literal {{WORKER_PATH}} placeholder"
else
  pass "install.sh: no leftover {{WORKER_PATH}} token in the linux unit"
fi

if [[ -f "$q7_service" ]]; then
  q7_order_check="$(python3 -c '
import sys
lines = open(sys.argv[1]).read().splitlines()
env_file_idx = next((i for i, l in enumerate(lines) if l.startswith("EnvironmentFile=")), None)
path_idx = next((i for i, l in enumerate(lines) if l.startswith("Environment=PATH=")), None)
if env_file_idx is None or path_idx is None:
    print("BAD missing EnvironmentFile= or Environment=PATH= line")
else:
    val = lines[path_idx][len("Environment=PATH="):]
    if path_idx > env_file_idx and val == sys.argv[2]:
        print("OK")
    else:
        print("BAD env_file_idx=%d path_idx=%d val=%r" % (env_file_idx, path_idx, val))
' "$q7_service" "$q7_expected_worker_path")"
  if [[ "$q7_order_check" == "OK" ]]; then
    pass "install.sh: linux unit's Environment=PATH matches the resolved WORKER_PATH, positioned after EnvironmentFile= (env file can't clobber it)"
  else
    fail "install.sh: linux unit PATH/ordering" "$q7_order_check"
  fi
fi

rm -rf "$q7_home" "$q7_prefix" "$q7_custom"
rm -f "$q7_env" "$q7_service" "$q7_timer"

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
