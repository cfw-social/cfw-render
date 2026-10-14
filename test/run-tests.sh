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

# [M3-01] The worker pauses on battery (cr_on_battery → pmset). Every case must
# be independent of the host's power state, so a stub pmset reporting AC power
# is the default for the whole suite; the M3-01a cases flip it via the
# FAKE_PMSET_BATTERY marker file.
FAKE_PMSET_BATTERY="$(mktemp -u)"; export FAKE_PMSET_BATTERY
cat > "$FAKE_BIN/pmset" <<'EOF2'
#!/usr/bin/env bash
if [[ -e "${FAKE_PMSET_BATTERY:-/nonexistent}" ]]; then echo "Now drawing from 'Battery Power'"; else echo "Now drawing from 'AC Power'"; fi
EOF2
chmod +x "$FAKE_BIN/pmset"
export CFW_RENDER_PMSET_CMD="$FAKE_BIN/pmset"

# The worker skips normal claims while the 1-minute load average is above the
# CPU count (cr_capacity_ok). On a busy dev Mac that made the capacity cases
# (25-29) fail with "normal claims skipped, urgent only". Pin the load seam for
# the whole suite so no case depends on what else the host is running; a case
# that needs a busy machine sets CFW_RENDER_CAPACITY_LOAD itself.
export CFW_RENDER_CAPACITY_LOAD=0

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

# owner_layout <home> — undo run_case's test pins (logs in the state dir, no
# kept copies) so a case sees the real owner defaults under <home>.
owner_layout() {
  unset CFW_RENDER_LOG_DIR CFW_RENDER_KEEP_OUTPUTS
  export "CFW_RENDER_HOME=$1"
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
    export CFW_RENDER_LOG_DIR="$cr_state" CFW_RENDER_KEEP_OUTPUTS=0
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
  export CFW_RENDER_LOG_DIR="$case_dir_dry/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
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
if ! grep -q "kept .* finished file" "$CASE_STATE/cfw-render.log" 2>/dev/null; then
  pass "happy (CFW_RENDER_KEEP_OUTPUTS=0): no local copy kept"
else
  fail "happy (KEEP_OUTPUTS=0): local copy" "a local copy was kept with KEEP_OUTPUTS=0"
fi

echo "=== Case 2g: owner computer (byoa) layout — finished files kept in 'CFW Render/outputs' after CFW accepted them; logs in 'CFW Render/logs' ==="
c2g_root="$(mktemp -d)"
c2g_home="$c2g_root/CFW Render"   # the space is deliberate: the real folder name has one
run_case "byoa-keep" "happy" "order_fixture order-keep-1 brand-1 video" \
  owner_layout "$c2g_home"
if [[ "$(calls_count complete_render_order)" -ge 1 ]]; then
  pass "byoa-keep: complete_render_order called"
else
  fail "byoa-keep: complete" "no complete_render_order call"
fi
c2g_kept="$(find "$c2g_home/outputs/test-brand" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [[ "$(basename "$c2g_kept" 2>/dev/null)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_order-keep-1$ ]]; then
  pass "byoa-keep: kept folder is outputs/<brand>/<YYYY-MM-DD>_<order>"
else
  fail "byoa-keep: kept folder" "expected outputs/test-brand/<date>_order-keep-1, found: '$c2g_kept' ($(find "$c2g_root" 2>/dev/null | head -20 | tr '\n' ' '))"
fi
c2g_uploaded="$(grep -c "order-keep-1" "$CASE_MOCKSTATE/uploads.jsonl" 2>/dev/null || true)"
c2g_kept_n="$(find "$c2g_kept" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ -n "$c2g_kept" && "$c2g_kept_n" -ge 2 && "$c2g_kept_n" == "$c2g_uploaded" ]]; then
  pass "byoa-keep: every uploaded file kept locally ($c2g_kept_n of $c2g_uploaded, incl. $(find "$c2g_kept" -type f -name '*.png' | wc -l | tr -d ' ') png)"
else
  fail "byoa-keep: kept files" "kept=$c2g_kept_n uploaded=$c2g_uploaded"
fi
if grep -q "order order-keep-1 — kept $c2g_kept_n finished file" "$c2g_home/logs/cfw-render.log" 2>/dev/null \
   && [[ ! -f "$CASE_STATE/cfw-render.log" ]]; then
  pass "byoa-keep: renderer log is in 'CFW Render/logs', not the hidden state dir"
else
  fail "byoa-keep: log location" "logs/: $(ls "$c2g_home/logs" 2>&1 | tr '\n' ' ') state: $(ls "$CASE_STATE" 2>&1 | tr '\n' ' ')"
fi
if compgen -G "$c2g_home/logs/runs/order-keep-1-*.out" >/dev/null; then
  pass "byoa-keep: render transcript in 'CFW Render/logs/runs'"
else
  fail "byoa-keep: transcript" "no logs/runs/order-keep-1-*.out"
fi
if [[ -f "$CASE_STATE/journal.tsv" && ! -d "$CASE_SCRATCH/test-brand/order-keep-1" ]]; then
  pass "byoa-keep: journal stays in the hidden state dir; scratch wiped"
else
  fail "byoa-keep: state/scratch" "journal or scratch wrong"
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

echo "=== Case 3b: owner computer (byoa) — a blocked render keeps nothing in outputs ==="
c3b_home="$(mktemp -d)/CFW Render"
run_case "byoa-gate-fail" "gate-fail" "order_fixture order-gatefail-2 brand-1 video" \
  owner_layout "$c3b_home"
if [[ "$(calls_count block_render_order)" -ge 1 && -z "$(find "$c3b_home/outputs" -type f 2>/dev/null)" ]]; then
  pass "byoa-gate-fail: blocked, and outputs/ holds no file"
else
  fail "byoa-gate-fail: outputs" "files: $(find "$c3b_home/outputs" -type f 2>/dev/null | tr '\n' ' ')"
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
  export CFW_RENDER_LOG_DIR="$lock_state" CFW_RENDER_KEEP_OUTPUTS=0
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

echo "=== Case 8: default settings file is ~/.cfw-render/cfw-render.env (legacy ~/ecosystem/vault only as fallback); no ~/.gsai/secrets (CFW-289) ==="
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
if echo "$c289_out" | grep -qF "$c289_home/.cfw-render/cfw-render.env" && ! echo "$c289_out" | grep -q 'ecosystem/vault\|\.gsai'; then
  pass "cr_load_config: default env path is ~/.cfw-render/cfw-render.env (no ecosystem/vault, no .gsai)"
else
  fail "cr_load_config: default env path" "expected ~/.cfw-render/cfw-render.env with no ecosystem/vault or .gsai mention, got: $c289_out"
fi

# 1b. An install from before the folder layout change keeps its settings file
#     at ~/ecosystem/vault — still read when the new file is absent.
c8_legacy_home="$(mktemp -d)"
mkdir -p "$c8_legacy_home/ecosystem/vault"
printf 'CFW_API_BASE=http://legacy.example\nCFW_RENDER_WORKER_KEY=cfw_render_legacykey\n' > "$c8_legacy_home/ecosystem/vault/cfw-render.env"
c8_legacy_out="$(
  env -i HOME="$c8_legacy_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    CFW_WORKER_ID=test-worker cr_load_config >/dev/null 2>&1 || { echo LOAD_FAILED; exit 0; }
    echo "base=$CFW_API_BASE"
  ' 2>&1
)"
if [[ "$c8_legacy_out" == "base=http://legacy.example" ]]; then
  pass "cr_load_config: legacy ~/ecosystem/vault/cfw-render.env still loads when the new file is absent"
else
  fail "cr_load_config: legacy env fallback" "got: $c8_legacy_out"
fi

# 1c. When both exist, the new location wins.
mkdir -p "$c8_legacy_home/.cfw-render"
printf 'CFW_API_BASE=http://new.example\nCFW_RENDER_WORKER_KEY=cfw_render_newkey\n' > "$c8_legacy_home/.cfw-render/cfw-render.env"
c8_both_out="$(
  env -i HOME="$c8_legacy_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    CFW_WORKER_ID=test-worker cr_load_config >/dev/null 2>&1 || { echo LOAD_FAILED; exit 0; }
    echo "base=$CFW_API_BASE"
  ' 2>&1
)"
if [[ "$c8_both_out" == "base=http://new.example" ]]; then
  pass "cr_load_config: ~/.cfw-render/cfw-render.env wins over the legacy file"
else
  fail "cr_load_config: new env file precedence" "got: $c8_both_out"
fi
rm -rf "$c8_legacy_home"

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
    CFW_RENDER_LOG_DIR="$c289_home/cr-state" \
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

echo "=== Case 9b: static guard — the guides installed on an owner's computer never point at the maintainer's ~/ecosystem/vault ==="
# install/*.md are maintainer/fleet docs and may name the legacy location to
# explain the fallback; AGENTS.md + CLAUDE.md ship into every owner install.
c9b_out="$(grep -n 'ecosystem/vault' "$REPO_DIR/AGENTS.md" "$REPO_DIR/CLAUDE.md" 2>/dev/null)"
if [[ -z "$c9b_out" ]]; then
  pass "static guard: AGENTS.md and CLAUDE.md mention no ecosystem/vault path"
else
  fail "static guard: ecosystem/vault in a public guide" "$c9b_out"
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

echo "=== Case 14: sync-skills.py strips brand-overrides host paths + redacts bare host paths + stamps index.json sourceSha (CFW-318) ==="
# Copy the fixture source tree OUTSIDE this repo's working tree first — a
# `git -C <dir> rev-parse HEAD` resolves upward to the nearest enclosing
# repo, so pointing CFW_SKILLS_SRC straight at test/fixtures/skills-src (a
# subdir OF this repo) would silently return cfw-render's own HEAD instead
# of exercising git_head_sha()'s non-git soft-fail path.
c318_src_copy="$(mktemp -d)"
cp -R "$TEST_DIR/fixtures/skills-src/." "$c318_src_copy/"
c318_out="$(mktemp -d)"
c318_sync_log="$(
  CFW_SKILLS_SRC="$c318_src_copy" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$c318_out" --skip-manifest 2>&1
)"
c318_sync_rc=$?
if [[ "$c318_sync_rc" == "0" ]]; then
  pass "sync-skills.sh: fixture sync + check-no-host-paths gate exit 0 (CFW-318)"
else
  fail "sync-skills.sh: fixture sync (CFW-318)" "expected exit 0, got $c318_sync_rc — log: $c318_sync_log"
fi

c318_brand_json="$c318_out/p-fixture-recipe/brand-overrides/fixture-brand/brand.json"
c318_outro_path="$(python3 -c "import json; print(json.load(open('$c318_brand_json'))['outro']['path'])" 2>/dev/null)"
if [[ "$c318_outro_path" == "None" ]]; then
  pass "sync-skills.py: brand-overrides outro.path nulled (CFW-318)"
else
  fail "sync-skills.py: outro.path strip" "got: $c318_outro_path"
fi

c318_outro_relative="$(python3 -c "import json; print(json.load(open('$c318_brand_json'))['outro']['relative'])" 2>/dev/null)"
if [[ "$c318_outro_relative" == "fixture-assets/outro.png" ]]; then
  pass "sync-skills.py: outro.relative survives untouched (CFW-318)"
else
  fail "sync-skills.py: outro.relative" "got: $c318_outro_relative"
fi

if python3 -c "import json,sys; d=json.load(open('$c318_brand_json')); sys.exit(0 if 'hero_portrait' not in d else 1)"; then
  pass "sync-skills.py: hero_portrait key dropped entirely (CFW-318)"
else
  fail "sync-skills.py: hero_portrait" "key still present in $c318_brand_json"
fi

c318_doc="$c318_out/p-fixture-recipe/docs/HOST-PATH-NOTE.md"
if grep -q '/Users/<redacted>/some/scratch/path/mirror' "$c318_doc" 2>/dev/null; then
  pass "sync-skills.py: bare host-path string redacted in a doc file (CFW-318)"
else
  fail "sync-skills.py: generic redaction" "redacted placeholder not found in $c318_doc"
fi

if grep -q 'testuser' "$c318_doc" 2>/dev/null && ! grep -q '/Users/testuser' "$c318_doc" 2>/dev/null; then
  pass "sync-skills.py: negative case — bare 'testuser' with no /Users/ prefix left untouched (CFW-318)"
else
  fail "sync-skills.py: negative case" "unexpected content in $c318_doc"
fi

if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$c318_out" >/dev/null 2>&1; then
  pass "check-no-host-paths.sh: PASS on the rewritten fixture bundle (CFW-318)"
else
  fail "check-no-host-paths.sh: fixture bundle" "expected exit 0 after rewrite"
fi

c318_sha="$(python3 -c "import json; print(json.load(open('$c318_out/index.json'))['sourceSha'])" 2>/dev/null)"
if [[ "$c318_sha" == "None" ]]; then
  pass "sync-skills.py: index.json sourceSha stays null for a non-git fixture source (soft-fail path, CFW-318)"
else
  fail "sync-skills.py: sourceSha soft-fail" "expected None, got: $c318_sha"
fi
rm -rf "$c318_out" "$c318_src_copy"

echo "=== Case 14a: check-no-host-paths.sh red/green — FAILs on a deliberately unrewritten host path (CFW-318) ==="
c318_dirty_base="$(mktemp -d)"
mkdir -p "$c318_dirty_base/p-dirty-recipe"
printf 'leftover path: /Users/testuser/leftover/path\n' > "$c318_dirty_base/p-dirty-recipe/NOTE.md"
if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$c318_dirty_base" >/dev/null 2>&1; then
  fail "check-no-host-paths.sh: red case" "expected exit 1 on a deliberately unrewritten fixture"
else
  pass "check-no-host-paths.sh: FAILs on a deliberately unrewritten host path (red/green proof, CFW-318)"
fi
rm -rf "$c318_dirty_base"

echo "=== Case 14b: static guard — no bare host path anywhere in the committed skills/ bundle (CFW-318) ==="
if "$REPO_DIR/scripts/check-no-host-paths.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no bare host path"
else
  c318_real_out="$("$REPO_DIR/scripts/check-no-host-paths.sh" 2>&1)"
  fail "static guard: bare host path found in committed bundle" "$c318_real_out"
fi

echo "=== Case 14c: index.json sourceSha stamped from a real git source repo (CFW-318) ==="
c318_git_src="$(mktemp -d)"
mkdir -p "$c318_git_src/p-git-fixture"
cat > "$c318_git_src/p-git-fixture/SKILL.md" <<'EOF'
---
name: p-git-fixture
kind: pipeline
visibility: catalog
---

# p-git-fixture (CFW-318 test fixture — git sourceSha stamping)
EOF
(
  cd "$c318_git_src" &&
  git init -q &&
  git config user.email test@example.com &&
  git config user.name test &&
  git add -A &&
  git commit -q -m fixture
) >/dev/null 2>&1
c318_git_recipes="$(mktemp)"
python3 -c "import json; json.dump({'recipes': [{'name': 'p-git-fixture', 'version': '1.0.0', 'providers': []}]}, open('$c318_git_recipes', 'w'))"
c318_git_out="$(mktemp -d)"
CFW_SKILLS_SRC="$c318_git_src" "$REPO_DIR/scripts/sync-skills.sh" \
  --recipes "$c318_git_recipes" --out-dir "$c318_git_out" --skip-manifest >/dev/null 2>&1
c318_expected_sha="$(git -C "$c318_git_src" rev-parse HEAD)"
c318_got_sha="$(python3 -c "import json; print(json.load(open('$c318_git_out/index.json'))['sourceSha'])" 2>/dev/null)"
if [[ "$c318_got_sha" == "$c318_expected_sha" ]]; then
  pass "sync-skills.py: index.json sourceSha matches git rev-parse HEAD of the source repo (CFW-318)"
else
  fail "sync-skills.py: sourceSha from real git source" "expected $c318_expected_sha, got $c318_got_sha"
fi
rm -rf "$c318_git_src" "$c318_git_out" "$c318_git_recipes"

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
    export CFW_RENDER_LOG_DIR="$pf_dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
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
  cr_probe_claude_headless "$q4_tmp:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
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
  cr_probe_claude_headless "$q4_empty:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
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
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
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

# Open-box guide ships with the install (AGENTS.md + the CLAUDE.md pointer).
for q6_guide in AGENTS.md CLAUDE.md; do
  if [[ -f "$q6_prefix/$q6_guide" ]] && cmp -s "$REPO_DIR/$q6_guide" "$q6_prefix/$q6_guide"; then
    pass "install.sh: copies $q6_guide into the prefix"
  else
    fail "install.sh: $q6_guide in prefix" "missing or differs at $q6_prefix/$q6_guide"
  fi
done
# ── Q6b: --mode byoa with NO --prefix / --env-file → the owner folder layout.
q6b_home="$(mktemp -d)"
mkdir -p "$q6b_home/.cfw-render"
q6b_env="$q6b_home/.cfw-render/cfw-render.env"
printf 'CFW_API_BASE=http://127.0.0.1:1\nCFW_RENDER_WORKER_KEY=cfw_render_q6bkey\n' > "$q6b_env"
chmod 644 "$q6b_env"
(
  export HOME="$q6b_home"
  export PATH="$q6_test_path"
  export PLAYWRIGHT_BROWSERS_PATH="$q6_real_home/Library/Caches/ms-playwright"
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
  "$REPO_DIR/install/install.sh" --mode byoa >"$q6b_home/install.log" 2>&1
)
q6b_app="$q6b_home/CFW Render/app"
if [[ -x "$q6b_app/bin/cfw-render.sh" && -f "$q6b_app/skills/index.json" && -f "$q6b_app/AGENTS.md" ]]; then
  pass "install.sh --mode byoa: default prefix is '\$HOME/CFW Render/app' (bin, skills, AGENTS.md)"
else
  fail "install.sh: default byoa prefix" "missing under $q6b_app — install.log tail: $(tail -15 "$q6b_home/install.log" 2>/dev/null)"
fi
if [[ -d "$q6b_home/CFW Render/outputs" && -d "$q6b_home/CFW Render/logs" ]]; then
  pass "install.sh --mode byoa: creates 'CFW Render/outputs' and 'CFW Render/logs'"
else
  fail "install.sh: visible folders" "$(ls -la "$q6b_home/CFW Render" 2>&1 | tr '\n' ' ')"
fi
q6b_mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$q6b_env" 2>/dev/null)"
if [[ "$q6b_mode" == "0o600" ]]; then
  pass "install.sh --mode byoa: settings file ~/.cfw-render/cfw-render.env is mode 600"
else
  fail "install.sh: env file mode" "expected 0o600, got $q6b_mode"
fi
q6b_plist_check="$(python3 -c '
import plistlib, sys
home = sys.argv[2]
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
want = {
  "program": home + "/CFW Render/app/bin/cfw-render.sh",
  "env": home + "/.cfw-render/cfw-render.env",
  "out": home + "/CFW Render/logs/cfw-render.out.log",
  "err": home + "/CFW Render/logs/cfw-render.err.log",
}
got = {
  "program": d.get("ProgramArguments", [""])[0],
  "env": d.get("EnvironmentVariables", {}).get("CFW_RENDER_ENV", ""),
  "out": d.get("StandardOutPath", ""),
  "err": d.get("StandardErrorPath", ""),
}
bad = [k + "=" + repr(got[k]) for k in want if got[k] != want[k]]
print("OK" if not bad else "BAD " + "; ".join(bad))
' "$q6b_home/Library/LaunchAgents/com.cfw.render.plist" "$q6b_home" 2>&1)"
if [[ "$q6b_plist_check" == "OK" ]]; then
  pass "install.sh --mode byoa: plist runs from 'CFW Render/app', reads ~/.cfw-render/cfw-render.env, logs to 'CFW Render/logs'"
else
  fail "install.sh: byoa plist paths" "$q6b_plist_check"
fi
if [[ -s "$q6b_home/.cfw-render/worker-id" && ! -e "$q6b_home/cfw-render-scratch" && ! -e "$q6b_home/cfw-render" && ! -e "$q6b_home/ecosystem" ]]; then
  pass "install.sh --mode byoa: worker-id in ~/.cfw-render; nothing else sprayed into \$HOME"
else
  fail "install.sh: stray folders" "home has: $(ls -A "$q6b_home" | tr '\n' ' ')"
fi
if grep -qF "finished renders: $q6b_home/CFW Render/outputs/<brand>/" "$q6b_home/install.log"; then
  pass "install.sh --mode byoa: prints where renders, the app and logs live"
else
  fail "install.sh: where-things-are summary" "not in install.log"
fi

# ── Q6c: an older install whose settings file is only at ~/ecosystem/vault
#    keeps using it (no --env-file given).
q6c_home="$(mktemp -d)"
mkdir -p "$q6c_home/ecosystem/vault"
printf 'CFW_API_BASE=http://127.0.0.1:1\nCFW_RENDER_WORKER_KEY=cfw_render_q6ckey\n' > "$q6c_home/ecosystem/vault/cfw-render.env"
(
  export HOME="$q6c_home"
  export PATH="$q6_test_path"
  export PLAYWRIGHT_BROWSERS_PATH="$q6_real_home/Library/Caches/ms-playwright"
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
  "$REPO_DIR/install/install.sh" --mode byoa >"$q6c_home/install.log" 2>&1
)
q6c_env="$(python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get("EnvironmentVariables", {}).get("CFW_RENDER_ENV", ""))
' "$q6c_home/Library/LaunchAgents/com.cfw.render.plist" 2>&1)"
if [[ "$q6c_env" == "$q6c_home/ecosystem/vault/cfw-render.env" ]]; then
  pass "install.sh --mode byoa: an existing legacy settings file keeps working"
else
  fail "install.sh: legacy env fallback" "plist CFW_RENDER_ENV=$q6c_env"
fi
rm -rf "$q6b_home" "$q6c_home"

rm -rf "$q6_home" "$q6_prefix" "$q6_custom"
rm -f "$q6_env"


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

echo "=== Case 15: check-no-handle-defaults.sh red — FAILs on a literal shell handle default (CFW-354) ==="
c354_dirty_base="$(mktemp -d)"
mkdir -p "$c354_dirty_base/p-dirty-recipe"
printf '# setup\nCTA_TEXT="${CTA_TEXT:-FOLLOW}"\nCTA_HANDLE="${CTA_HANDLE:-@someone}"\n' > "$c354_dirty_base/p-dirty-recipe/SKILL.md"
c354_dirty_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_dirty_base" 2>&1)"
c354_dirty_rc=$?
if [[ "$c354_dirty_rc" == "1" ]]; then
  pass "check-no-handle-defaults.sh: FAILs (exit 1) on a literal \${VAR:-@…} default (red/green proof, CFW-354)"
else
  fail "check-no-handle-defaults.sh: red case" "expected exit 1, got $c354_dirty_rc: $c354_dirty_out"
fi
if grep -q 'p-dirty-recipe/SKILL.md:3' <<< "$c354_dirty_out"; then
  pass "check-no-handle-defaults.sh: red case names the offending path:line"
else
  fail "check-no-handle-defaults.sh: red case output" "expected 'p-dirty-recipe/SKILL.md:3' in: $c354_dirty_out"
fi
rm -rf "$c354_dirty_base"

echo "=== Case 15a: check-no-handle-defaults.sh red — FAILs on a literal @mr.growthguide anywhere (CFW-354) ==="
c354_leak_base="$(mktemp -d)"
mkdir -p "$c354_leak_base/p-dirty-recipe"
printf 'Follow @mr.growthguide for more.\n' > "$c354_leak_base/p-dirty-recipe/NOTE.md"
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_leak_base" >/dev/null 2>&1; then
  fail "check-no-handle-defaults.sh: leaked-handle red case" "expected exit 1 on a literal @mr.growthguide in NOTE.md"
else
  pass "check-no-handle-defaults.sh: FAILs on a literal @mr.growthguide outside brand-overrides/ (CFW-354)"
fi
rm -rf "$c354_leak_base"

echo "=== Case 15a1: check-no-handle-defaults.sh red — a backslash-continued default can't dodge the gate (CFW-354 QA F1) ==="
c354_cont_base="$(mktemp -d)"
mkdir -p "$c354_cont_base/p-dirty-recipe"
printf 'x\nCTA_HANDLE="${CTA_HANDLE:-\\\n@split}"\n' > "$c354_cont_base/p-dirty-recipe/SKILL.md"
c354_cont_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_cont_base" 2>&1)"
c354_cont_rc=$?
if [[ "$c354_cont_rc" == "1" && "$c354_cont_out" == *"p-dirty-recipe/SKILL.md:2"* ]]; then
  pass "check-no-handle-defaults.sh: FAILs on a \${VAR:-@…} default split across a backslash continuation, naming line 2"
else
  fail "check-no-handle-defaults.sh: continuation red case" "expected exit 1 naming p-dirty-recipe/SKILL.md:2, got $c354_cont_rc: $c354_cont_out"
fi
rm -rf "$c354_cont_base"

echo "=== Case 15a2: check-no-handle-defaults.sh — rendered kicker MR GROWTH GUIDE is red, prose 'Mr Growth Guide' is green (CFW-354 QA F2) ==="
c354_kick_base="$(mktemp -d)"
mkdir -p "$c354_kick_base/p-dirty-recipe"
printf '{"type":"kicker","text":"MR GROWTH GUIDE"}\n' > "$c354_kick_base/p-dirty-recipe/cta-card.json"
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_kick_base" >/dev/null 2>&1; then
  fail "check-no-handle-defaults.sh: kicker red case" "expected exit 1 on a literal MR GROWTH GUIDE kicker"
else
  pass "check-no-handle-defaults.sh: FAILs on the rendered kicker literal MR GROWTH GUIDE outside brand-overrides/ (CFW-354)"
fi
printf 'This avatar serves both CFW and Mr Growth Guide.\n' > "$c354_kick_base/p-dirty-recipe/cta-card.json"
c354_kick_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_kick_base" 2>&1)"
c354_kick_rc=$?
if [[ "$c354_kick_rc" == "0" ]]; then
  pass "check-no-handle-defaults.sh: prose 'Mr Growth Guide' (not the rendered kicker) stays clean"
else
  fail "check-no-handle-defaults.sh: kicker prose green case" "expected exit 0, got $c354_kick_rc: $c354_kick_out"
fi
rm -rf "$c354_kick_base"

echo "=== Case 15b: check-no-handle-defaults.sh green — empty default, prose @handle, brand.json handle all clean (CFW-354) ==="
c354_clean_base="$(mktemp -d)"
mkdir -p "$c354_clean_base/p-clean-recipe/brand-overrides/x"
printf 'CTA_HANDLE="${CTA_HANDLE:-}"\nAdd the `@handle` if known.\n' > "$c354_clean_base/p-clean-recipe/SKILL.md"
printf '{"cta":{"handle":"@legit"}}\n' > "$c354_clean_base/p-clean-recipe/brand-overrides/x/brand.json"
c354_clean_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_clean_base" 2>&1)"
c354_clean_rc=$?
if [[ "$c354_clean_rc" == "0" ]]; then
  pass "check-no-handle-defaults.sh: PASSes on empty default + prose @handle + brand-overrides/<slug>/brand.json handle"
else
  fail "check-no-handle-defaults.sh: green case" "expected exit 0, got $c354_clean_rc: $c354_clean_out"
fi
rm -rf "$c354_clean_base"

echo "=== Case 15c: static guard — no literal handle default anywhere in the committed skills/ bundle (CFW-354) ==="
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no literal handle default"
else
  c354_real_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" 2>&1)"
  fail "static guard: literal handle default found in committed bundle" "$c354_real_out"
fi

echo "=== Case 15d: Spotlight end card (step 8) — handle/kicker layers are per-brand, omitted when unset (CFW-354) ==="
c354_cta_py="$REPO_DIR/skills/p-reels-spotlight/scripts/cta-card.py"
if [[ -f "$c354_cta_py" ]]; then
  c354_cta_dir="$(mktemp -d)"
  printf '{"brand":{"bg":"#0F172A","accent":"#F97316","fg":"#F1F5F9"}}\n' > "$c354_cta_dir/plan.json"
  c354_cta_types() {  # $1 = out.json → comma-joined layer types
    python3 -c 'import json,sys; print(",".join(l.get("type","") for l in json.load(open(sys.argv[1]))["layers"]))' "$1" 2>/dev/null
  }
  if CTA_HANDLE=@brand_a BRAND_NAME='Brand A' python3 "$c354_cta_py" "$c354_cta_dir/plan.json" "$c354_cta_dir/a.json" >/dev/null 2>&1; then
    c354_a_types="$(c354_cta_types "$c354_cta_dir/a.json")"
    if [[ "$c354_a_types" == "kicker,hero,handle,arrow" ]]; then
      pass "cta-card.py: with CTA_HANDLE + BRAND_NAME set, layers are exactly kicker,hero,handle,arrow"
    else
      fail "cta-card.py: branded layer types" "expected kicker,hero,handle,arrow, got '$c354_a_types'"
    fi
    c354_a_handle="$(python3 -c 'import json,sys; print(next((l.get("text","") for l in json.load(open(sys.argv[1]))["layers"] if l.get("type")=="handle"), ""))' "$c354_cta_dir/a.json" 2>/dev/null)"
    if [[ "$c354_a_handle" == "@brand_a" ]]; then
      pass "cta-card.py: handle layer text is the brand's own handle (@brand_a)"
    else
      fail "cta-card.py: handle layer text" "expected '@brand_a', got '$c354_a_handle'"
    fi
  else
    fail "cta-card.py: branded run" "python3 cta-card.py exited non-zero with CTA_HANDLE=@brand_a BRAND_NAME='Brand A'"
  fi
  if CTA_HANDLE="" BRAND_NAME="" python3 "$c354_cta_py" "$c354_cta_dir/plan.json" "$c354_cta_dir/b.json" >/dev/null 2>&1; then
    c354_b_types="$(c354_cta_types "$c354_cta_dir/b.json")"
    if [[ "$c354_b_types" == "hero,arrow" ]]; then
      pass "cta-card.py: with CTA_HANDLE and BRAND_NAME empty, layers are exactly hero,arrow"
    else
      fail "cta-card.py: unbranded layer types" "expected hero,arrow, got '$c354_b_types'"
    fi
    if ! grep -qi 'growthguide' "$c354_cta_dir/b.json" && ! grep -q '@' "$c354_cta_dir/b.json"; then
      pass "cta-card.py: unbranded output contains no growthguide and no @"
    else
      fail "cta-card.py: unbranded output leak" "found growthguide or @ in: $(cat "$c354_cta_dir/b.json")"
    fi
  else
    fail "cta-card.py: unbranded run" "python3 cta-card.py exited non-zero with CTA_HANDLE='' BRAND_NAME=''"
  fi
  rm -rf "$c354_cta_dir"
else
  fail "cta-card.py: Spotlight end-card script present" "expected $c354_cta_py (arrives with the CFW-354 skills re-sync) — not found"
fi

echo "=== Case 16: recipe manifest v1 — Spotlight manifest validates (M1-01) ==="
c16_validator="$REPO_DIR/scripts/validate-manifests.py"
c16_fixtures="$TEST_DIR/fixtures/manifests"
c16_out="$(python3 "$c16_validator" 2>&1)"
c16_rc=$?
if [[ "$c16_rc" == "0" ]] && grep -q 'OK .*skills/p-reels-spotlight/manifest.json' <<< "$c16_out"; then
  pass "validate-manifests.py: committed skills/*/manifest.json (Spotlight) validate, exit 0"
else
  fail "validate-manifests.py: committed manifests" "expected exit 0 + OK line for p-reels-spotlight, got rc=$c16_rc: $c16_out"
fi
c16_spot="$REPO_DIR/skills/p-reels-spotlight/manifest.json"
c16_shape="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["recipeVersion"], ",".join(s["id"] for s in m["steps"]), ",".join(i["id"] for i in m["inputs"]), sum(s["weight"] for s in m["steps"]))
' "$c16_spot" 2>/dev/null)"
c16_want="2026.10.2 research,script,prepare_footage,transcribe,plan_edit,plan_broll,render_scenes,assemble,final_checks talking_head,broll,cta 100"
if [[ "$c16_shape" == "$c16_want" ]]; then
  pass "Spotlight manifest: recipeVersion 2026.10.2 (M1-09), 9 steps in contract order, 3 inputs, computer weights sum to 100"
else
  fail "Spotlight manifest shape" "expected '$c16_want', got '$c16_shape'"
fi
c16_steps_dir="$REPO_DIR/skills/p-reels-spotlight"
c16_missing_ins=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  [[ -f "$c16_steps_dir/$rel" ]] || c16_missing_ins="$c16_missing_ins $rel"
done < <(python3 -c 'import json,sys; [print(s.get("instructions","")) for s in json.load(open(sys.argv[1]))["steps"] if s["runsOn"]=="computer"]' "$c16_spot" 2>/dev/null)
if [[ -z "$c16_missing_ins" ]]; then
  pass "Spotlight manifest: every computer step's instructions file exists under steps/"
else
  fail "Spotlight manifest: instructions files" "missing:$c16_missing_ins"
fi
# [M2-06 batch 1] the five new manifests + Spotlight: OK lines, instructions files, providers, no c-composio.
c16_batch="p-reels-spotlight p-reels-pip p-reels-split p-reels-spotlight-heygen p-reels-pip-heygen p-reels-split-heygen"
for c16_r in $c16_batch; do
  c16_m="$REPO_DIR/skills/$c16_r/manifest.json"
  if grep -q "OK .*skills/$c16_r/manifest.json" <<< "$c16_out"; then
    pass "validate-manifests.py: OK line for $c16_r"
  else
    fail "validate-manifests.py: $c16_r" "no OK line in: $c16_out"
  fi
  c16_missing_ins=""
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    [[ -f "$REPO_DIR/skills/$c16_r/$rel" ]] || c16_missing_ins="$c16_missing_ins $rel"
  done < <(python3 -c 'import json,sys; [print(s.get("instructions","")) for s in json.load(open(sys.argv[1]))["steps"] if s["runsOn"]=="computer"]' "$c16_m" 2>/dev/null)
  if [[ -z "$c16_missing_ins" && -f "$REPO_DIR/skills/$c16_r/steps/_shared.md" ]]; then
    pass "$c16_r manifest: every computer step's instructions file + steps/_shared.md exist"
  else
    fail "$c16_r manifest: instructions files" "missing:$c16_missing_ins (_shared.md present: $([[ -f "$REPO_DIR/skills/$c16_r/steps/_shared.md" ]] && echo yes || echo no))"
  fi
  c16_prov="$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["needs"]["providers"])))' "$c16_m" 2>/dev/null)"
  case "$c16_r" in
    p-reels-split-heygen) c16_prov_want="elevenlabs,heygen" ;;
    *-heygen)             c16_prov_want="heygen" ;;
    *)                    c16_prov_want="" ;;
  esac
  if [[ "$c16_prov" == "$c16_prov_want" ]]; then
    pass "$c16_r manifest: needs.providers = [${c16_prov_want}]"
  else
    fail "$c16_r manifest: needs.providers" "expected '$c16_prov_want', got '$c16_prov'"
  fi
done
if ! grep -q 'c-composio' <<< "$c16_out"; then
  pass "validate-manifests.py: no c-composio line (component, not a recipe manifest)"
else
  fail "validate-manifests.py: c-composio" "unexpected line: $(grep c-composio <<< "$c16_out")"
fi
c16_shape_h="$(python3 -c '
import json, sys
for r in sys.argv[1:]:
    m = json.load(open(r)); st = m["steps"]
    print(r.split("/")[-2], st[0]["id"], st[0]["runsOn"], ",".join(st[0].get("canAsk", [])), m["inputs"][0]["id"], m["inputs"][0]["neededAt"], sum(s["weight"] for s in st))
' "$REPO_DIR/skills/p-reels-spotlight-heygen/manifest.json" "$REPO_DIR/skills/p-reels-pip-heygen/manifest.json" "$REPO_DIR/skills/p-reels-split-heygen/manifest.json" 2>/dev/null)"
c16_shape_h_want="p-reels-spotlight-heygen generate_avatar computer script,avatar_id,voice_id script start 100
p-reels-pip-heygen generate_avatar computer script,avatar_id,voice_id script start 100
p-reels-split-heygen generate_avatar computer script,avatar_id,voice_id script start 100"
if [[ "$c16_shape_h" == "$c16_shape_h_want" ]]; then
  pass "-heygen manifests: leading generate_avatar (computer, canAsk script/avatar_id/voice_id), script neededAt start, weights sum to 100"
else
  fail "-heygen manifest shape" "expected '$c16_shape_h_want', got '$c16_shape_h'"
fi
if python3 "$c16_validator" "$c16_fixtures/valid-minimal/manifest.json" >/dev/null 2>&1; then
  pass "validate-manifests.py: valid-minimal fixture passes (exit 0)"
else
  fail "validate-manifests.py: valid-minimal fixture" "expected exit 0"
fi

echo "=== Case 16a: validate-manifests.py red — canAsk names a missing input (M1-01) ==="
c16a_out="$(python3 "$c16_validator" "$c16_fixtures/bad-canask-unknown-input/manifest.json" 2>&1)"
c16a_rc=$?
if [[ "$c16a_rc" == "1" ]]; then
  pass "validate-manifests.py: exit 1 when canAsk references an unknown input"
else
  fail "validate-manifests.py: canAsk red case" "expected exit 1, got $c16a_rc: $c16a_out"
fi
if grep -q "steps\[prepare\].canAsk: references unknown input 'missing_input'" <<< "$c16a_out"; then
  pass "validate-manifests.py: canAsk error names the step (prepare) and the input (missing_input)"
else
  fail "validate-manifests.py: canAsk error text" "expected step+input named in: $c16a_out"
fi

echo "=== Case 16b: validate-manifests.py red — two steps share an id (M1-01) ==="
c16b_out="$(python3 "$c16_validator" "$c16_fixtures/bad-duplicate-step-id/manifest.json" 2>&1)"
c16b_rc=$?
if [[ "$c16b_rc" == "1" ]] && grep -q "steps: duplicate id 'prepare'" <<< "$c16b_out"; then
  pass "validate-manifests.py: exit 1 + names the duplicate step id"
else
  fail "validate-manifests.py: duplicate step id" "expected exit 1 + duplicate id 'prepare', got rc=$c16b_rc: $c16b_out"
fi

echo "=== Case 16c: validate-manifests.py red — a step's instructions file is missing (M1-01) ==="
c16c_out="$(python3 "$c16_validator" "$c16_fixtures/bad-missing-instructions/manifest.json" 2>&1)"
c16c_rc=$?
if [[ "$c16c_rc" == "1" ]]; then
  pass "validate-manifests.py: exit 1 when a step's instructions file is missing"
else
  fail "validate-manifests.py: missing instructions red case" "expected exit 1, got $c16c_rc: $c16c_out"
fi
if grep -q "steps\[finish\].instructions: file not found: .*bad-missing-instructions/steps/99-does-not-exist.md" <<< "$c16c_out"; then
  pass "validate-manifests.py: missing-instructions error names the step and the path"
else
  fail "validate-manifests.py: missing instructions error text" "expected path steps/99-does-not-exist.md in: $c16c_out"
fi

echo "=== Case 16d: validate-manifests.py red — alternatives[].runsSteps names a missing step; hand checks hold without jsonschema (M1-01) ==="
c16d_out="$(python3 "$c16_validator" "$c16_fixtures/bad-runssteps-unknown-step/manifest.json" 2>&1)"
c16d_rc=$?
if [[ "$c16d_rc" == "1" ]] && grep -q "inputs\[clip\].alternatives\[0\].runsSteps: references unknown step 'nope'" <<< "$c16d_out"; then
  pass "validate-manifests.py: exit 1 + names the input, alternative and unknown step"
else
  fail "validate-manifests.py: runsSteps red case" "expected exit 1 + unknown step 'nope', got rc=$c16d_rc: $c16d_out"
fi
# Same four red fixtures with the optional jsonschema package masked out, so the
# gate is proven identical on a machine without it (runtime-free repo rule).
c16d_nojs="$(python3 - "$c16_validator" "$c16_fixtures" <<'PY' 2>&1
import runpy, sys
validator, fixtures = sys.argv[1], sys.argv[2]
sys.modules["jsonschema"] = None
bad = ["bad-canask-unknown-input", "bad-duplicate-step-id", "bad-missing-instructions", "bad-runssteps-unknown-step"]
sys.argv = [validator] + [f"{fixtures}/{b}/manifest.json" for b in bad] + [f"{fixtures}/valid-minimal/manifest.json"]
try:
    runpy.run_path(validator, run_name="__main__")
except SystemExit as e:
    print(f"RC={e.code}")
PY
)"
if grep -q '^RC=1$' <<< "$c16d_nojs" && grep -q 'FAIL — 4 of 5' <<< "$c16d_nojs"; then
  pass "validate-manifests.py: without jsonschema, hand-written checks still fail exactly the 4 bad fixtures"
else
  fail "validate-manifests.py: no-jsonschema mode" "expected RC=1 and 'FAIL — 4 of 5' in: $c16d_nojs"
fi

echo "=== Case 18: step harness mock — capability-gated claim, report_render_step, control files (M1-08 b) ==="
c18_dir="$(mktemp -d)"
c18_port=$((MOCK_PORT_BASE + 900))
c18_state="$c18_dir/mockstate"; c18_ctl="$c18_dir/control"
mkdir -p "$c18_state" "$c18_ctl"
c18_manifest="$REPO_DIR/skills/p-reels-spotlight/manifest.json"
python3 -c '
import json, sys
print(json.dumps([{"id": "order-m1", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": "p-reels-spotlight", "recipeVersion": "2026.10.2", "manifest": sys.argv[1],
  "status": "queued", "taskOrder": {"version": 1, "orderId": "order-m1"}, "priority": 0, "attempts": 1}]))
' "$c18_manifest" > "$c18_dir/queue.json"
c18_pid="$(CFW_MOCK_CONTROL_DIR="$c18_ctl" start_mock "$c18_dir/queue.json" "$c18_state" "$c18_port")"
c18_run() {
  # c18_run <bash-snippet>: sources the lib against the Case-18 mock; prints stdout, returns the snippet's rc.
  CFW_API_BASE="http://127.0.0.1:$c18_port" CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000" \
    bash -c 'set -uo pipefail; source "$1"; shift; eval "$*"' _ "$REPO_DIR/bin/cfw-render-lib.sh" "$1"
}
c18_caps='{"engine":"codex","os":"macos","manifests":[{"recipe":"p-reels-spotlight","recipeVersion":"2026.10.2"}]}'

echo "--- 18a: claim without capabilities → order null"
c18a_out="$(c18_run 'cr_mcp_call_soft claim_render_order "{\"workerId\":\"w1\"}"')"
if [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["order"])' <<< "$c18a_out")" == "None" ]]; then
  pass "claim: manifest order withheld when claim carries no capabilities"
else
  fail "claim: no-capabilities" "expected order null, got: $c18a_out"
fi

echo "--- 18b: claim with matching capabilities → attempt/manifest/resumeFromStepId"
c18b_out="$(c18_run "cr_mcp_call_soft claim_render_order '{\"workerId\":\"w1\",\"capabilities\":$c18_caps}'")"
c18b_shape="$(python3 -c '
import json, sys
o = json.load(sys.stdin)["order"]
print(o["attempt"]["id"], o["attempt"]["number"], o["manifest"]["recipeVersion"], o["resumeFromStepId"], o["savedOutputs"], o["inputs"], o["answers"])
' <<< "$c18b_out" 2>/dev/null)"
if [[ "$c18b_shape" == "att_1 1 2026.10.2 prepare_footage [] {} {}" ]]; then
  pass "claim: capability match returns attempt att_1/1, manifest, resumeFromStepId=prepare_footage, empty savedOutputs/inputs/answers"
else
  fail "claim: capabilities match" "expected 'att_1 1 2026.10.2 prepare_footage [] {} {}', got '$c18b_shape' from: $c18b_out"
fi

echo "--- 18c: report seq 1,1,2 → reports.ndjson has 2 lines, 2nd reply duplicate:true"
c18c_1="$(c18_run 'cr_report_step order-m1 w1 att_1 1 step_started "{\"stepId\":\"prepare_footage\"}"')"
c18c_2="$(c18_run 'cr_report_step order-m1 w1 att_1 1 step_started "{\"stepId\":\"prepare_footage\"}"')"
c18c_3="$(c18_run 'cr_report_step order-m1 w1 att_1 2 step_completed "{\"stepId\":\"prepare_footage\",\"outputs\":[{\"id\":\"o1\",\"url\":\"https://media.cfw.social/x.mp4\"}]}"')"
c18c_flags="$(python3 -c '
import json, sys
r = [json.loads(x) for x in sys.argv[1:]]
print(" ".join("%s/%s/%s" % (x["ok"], x["duplicate"], x["directive"]) for x in r))
' "$c18c_1" "$c18c_2" "$c18c_3" 2>/dev/null)"
c18c_lines="$(wc -l < "$c18_ctl/reports.ndjson" | tr -d ' ')"
c18c_seqs="$(python3 -c 'import json,sys; print(",".join(str(json.loads(l)["seq"]) for l in open(sys.argv[1]) if l.strip()))' "$c18_ctl/reports.ndjson")"
if [[ "$c18c_flags" == "True/False/continue True/True/continue True/False/continue" && "$c18c_seqs" == "1,2" && "$c18c_lines" == "2" ]]; then
  pass "report_render_step: seq 1,1,2 → second reply duplicate:true (stored nothing); reports.ndjson has 2 lines in order (1,2)"
else
  fail "report_render_step: duplicate seq" "flags='$c18c_flags' seqs='$c18c_seqs' lines=$c18c_lines"
fi

echo "--- 18d: seq 0 after 2 → seq_out_of_order"
c18d_out="$(c18_run 'cr_report_step order-m1 w1 att_1 0 heartbeat')"
if [[ "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d.get("code"), d["directive"])' <<< "$c18d_out")" == "False seq_out_of_order continue" ]]; then
  pass "report_render_step: unseen seq below last → ok:false code seq_out_of_order directive continue"
else
  fail "report_render_step: seq_out_of_order" "got: $c18d_out"
fi

echo "--- 18e: control file directive=cancel → directive cancel"
printf 'cancel' > "$c18_ctl/directive"
c18e_out="$(c18_run 'cr_report_step order-m1 w1 att_1 3 heartbeat')"
rm -f "$c18_ctl/directive"
if [[ "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["directive"])' <<< "$c18e_out")" == "True cancel" ]]; then
  pass "report_render_step: \$CFW_MOCK_CONTROL_DIR/directive=cancel is echoed as directive cancel"
else
  fail "report_render_step: scripted cancel" "got: $c18e_out"
fi

echo "--- 18f: down file → cr_mcp_call_soft returns 75, prints nothing"
touch "$c18_ctl/down"
c18f_out="$(c18_run 'cr_report_step order-m1 w1 att_1 4 heartbeat 2>/dev/null; echo "rc=$?"')"
rm -f "$c18_ctl/down"
if [[ "$c18f_out" == "rc=75" ]]; then
  pass "cr_mcp_call_soft: server down (503) → exit 75 (EX_TEMPFAIL), empty stdout, caller survives"
else
  fail "cr_mcp_call_soft: down" "expected 'rc=75' only, got: $c18f_out"
fi
kill "$c18_pid" 2>/dev/null; wait "$c18_pid" 2>/dev/null
rm -rf "$c18_dir"

echo "=== Case 19: step harness end-to-end — cfw-render.sh claim branch + cr_harness_run + fake engine (M1-08 c) ==="
c19_manifest="$REPO_DIR/test/fixtures/manifests/harness-3step/manifest.json"
# c19_setup <dir> <port> [inputs-json] — seed a manifest order, skills dir, start mock. Sets c19_pid/c19_ctl/c19_state.
c19_setup() {
  local dir="$1" port="$2" inputs="${3:-{\}}"
  c19_state="$dir/mockstate"; c19_ctl="$dir/control"
  mkdir -p "$c19_state" "$c19_ctl" "$dir/skills/harness-3step" "$dir/cr-scratch" "$dir/cr-state"
  cp "$c19_manifest" "$dir/skills/harness-3step/manifest.json"
  python3 -c '
import json, sys
print(json.dumps([{"id": "order-h1", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": "harness-3step", "recipeVersion": "1.0.0", "manifest": sys.argv[1], "inputs": json.loads(sys.argv[2]),
  "status": "queued", "priority": 0, "attempts": 1,
  "taskOrder": {"version": 1, "orderId": "order-h1", "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
                "kind": "video", "recipe": "harness-3step", "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}}]))
' "$c19_manifest" "$inputs" > "$dir/queue.json"
  c19_pid="$(CFW_MOCK_CONTROL_DIR="$c19_ctl" start_mock "$dir/queue.json" "$c19_state" "$port")"
}
# c19_worker <dir> <port> [env assignments...] — one tick of cfw-render.sh against the mock.
c19_worker() {
  local dir="$1" port="$2"; shift 2
  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$dir/cr-state"
    export CFW_RENDER_LOG_DIR="$dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh"
    export CFW_RENDER_HEARTBEAT_SEC=1
    export CFW_RENDER_CONCURRENCY=1
    export CFW_WORKER_ID="w-h"
    export CFW_RENDER_UPLOAD_MODE=multipart
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/bin/cfw-render.sh" > "$dir/worker.out" 2>&1
  )
}
c19_events() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d["event"], d.get("stepId") or "-") for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] != "heartbeat"))' "$1" 2>/dev/null; }
c19_seqs_ok() { python3 -c '
import json, sys
s = [json.loads(l)["seq"] for l in open(sys.argv[1]) if l.strip()]
print("ok" if s == sorted(s) and len(s) == len(set(s)) else "bad:%s" % s)' "$1" 2>/dev/null; }
c19_completed() { grep -c '"tool": "complete_render_order".*"ok": true' "$1/mockstate/calls.jsonl" 2>/dev/null || true; }

echo "--- 19a: full run — a, c run; b skipped; attempt_completed; complete_render_order called"
c19a="$(mktemp -d)"; c19_setup "$c19a" $((MOCK_PORT_BASE + 910))
c19_worker "$c19a" $((MOCK_PORT_BASE + 910))
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19a_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19a_ev" == "step_started:a step_completed:a step_skipped:b step_started:c step_completed:c attempt_completed:-" && "$(c19_seqs_ok "$c19_ctl/reports.ndjson")" == "ok" && "$(c19_completed "$c19a")" == "1" ]]; then
  pass "harness: a→(b skipped)→c→attempt_completed, strictly increasing seq, complete_render_order ok"
else
  fail "harness: full run" "events='$c19a_ev' seqs=$(c19_seqs_ok "$c19_ctl/reports.ndjson") completed=$(c19_completed "$c19a"); worker.out: $(tail -5 "$c19a/worker.out")"
fi
rm -rf "$c19a"

echo "--- 19b: broll present → b runs"
c19b="$(mktemp -d)"; c19_setup "$c19b" $((MOCK_PORT_BASE + 911)) '{"broll":[{"url":"https://cfw-media.test/broll.mp4"}]}'
c19_worker "$c19b" $((MOCK_PORT_BASE + 911))
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19b_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19b_ev" == "step_started:a step_completed:a step_started:b step_completed:b step_started:c step_completed:c attempt_completed:-" ]]; then
  pass "harness: when.inputPresent=broll satisfied → b runs"
else
  fail "harness: broll present" "events='$c19b_ev'"
fi
rm -rf "$c19b"

echo "--- 19c: c fails its check twice (maxCheckRetries 2) → completes"
c19c="$(mktemp -d)"; c19_setup "$c19c" $((MOCK_PORT_BASE + 912))
c19_worker "$c19c" $((MOCK_PORT_BASE + 912)) FAKE_ENGINE_FAIL_STEP=c FAKE_ENGINE_FAIL_CHECK_TIMES=2
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19c_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19c_ev" == *"step_started:c step_started:c step_started:c step_completed:c attempt_completed:-" && "$(c19_completed "$c19c")" == "1" ]]; then
  pass "harness: check fails 2× within maxCheckRetries=2 → third run completes"
else
  fail "harness: retries within cap" "events='$c19c_ev'"
fi
rm -rf "$c19c"

echo "--- 19d: c fails 5× → step_failed c/z_ok then attempt_failed"
c19d="$(mktemp -d)"; c19_setup "$c19d" $((MOCK_PORT_BASE + 913))
c19_worker "$c19d" $((MOCK_PORT_BASE + 913)) FAKE_ENGINE_FAIL_STEP=c FAKE_ENGINE_FAIL_CHECK_TIMES=5
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19d_ev="$(c19_events "$c19_ctl/reports.ndjson")"
c19d_chk="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_failed": print(d["stepId"], d["checks"][0]["id"], d["checks"][0]["passed"])' "$c19_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c19d_ev" == *"step_failed:c attempt_failed:c" && "$c19d_chk" == "c z_ok False" && "$(c19_completed "$c19d")" == "0" ]]; then
  pass "harness: retries exhausted → step_failed {c, z_ok:false} then attempt_failed; no complete"
else
  fail "harness: retries exhausted" "events='$c19d_ev' chk='$c19d_chk'"
fi
rm -rf "$c19d"

echo "--- 19e: directive cancel after a → attempt_cancelled, no c"
c19e="$(mktemp -d)"; c19_setup "$c19e" $((MOCK_PORT_BASE + 914))
# fake engine hook: a watcher writes the mock directive the moment step a's log appears
( for _ in $(seq 1 200); do
    if [[ -f "$c19e/cr-scratch/test-brand/order-h1/logs/a.log" ]]; then printf 'cancel' > "$c19_ctl/directive"; break; fi
    sleep 0.1
  done ) &
c19e_w=$!
c19_worker "$c19e" $((MOCK_PORT_BASE + 914))
wait "$c19e_w" 2>/dev/null
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19e_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19e_ev" == *"attempt_cancelled"* && "$c19e_ev" != *"step_started:c"* ]]; then
  pass "harness: directive cancel → attempt_cancelled, step c never started"
else
  fail "harness: cancel" "events='$c19e_ev'"
fi
rm -rf "$c19e"

echo "--- 19f: server down ~3 s mid-run → after recovery every seq present once, in order"
c19f="$(mktemp -d)"; c19_setup "$c19f" $((MOCK_PORT_BASE + 915)) '{"broll":[{"url":"https://cfw-media.test/broll.mp4"}]}'
( for _ in $(seq 1 200); do
    if [[ -d "$c19f/cr-scratch/test-brand/order-h1/steps/b" ]]; then touch "$c19_ctl/down"; sleep 3; rm -f "$c19_ctl/down"; break; fi
    sleep 0.1
  done ) &
c19f_w=$!
c19_worker "$c19f" $((MOCK_PORT_BASE + 915)) CFW_RENDER_STEP_TIMEOUT_SEC=60
wait "$c19f_w" 2>/dev/null
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19f_ev="$(c19_events "$c19_ctl/reports.ndjson")"
c19f_gap="$(python3 -c '
import json, sys
s = [json.loads(l)["seq"] for l in open(sys.argv[1]) if l.strip()]
print("ok" if s == list(range(1, len(s) + 1)) else "bad:%s" % s)' "$c19_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c19f_ev" == *"attempt_completed:-" && "$c19f_gap" == "ok" ]]; then
  pass "harness: 503 window buffered to pending-reports.ndjson and replayed — seqs 1..N contiguous, in order"
else
  fail "harness: down window" "events='$c19f_ev' seqs=$c19f_gap; $(tail -3 "$c19f/worker.out")"
fi
rm -rf "$c19f"

echo "--- 19g: order without manifest → Director path unchanged"
c19g="$(mktemp -d)"; mkdir -p "$c19g/mockstate" "$c19g/skills" "$c19g/cr-scratch" "$c19g/cr-state"
order_fixture order-plain-1 brand-1 video > "$c19g/queue.json"
c19g_pid="$(start_mock "$c19g/queue.json" "$c19g/mockstate" $((MOCK_PORT_BASE + 916)))"
c19_worker "$c19g" $((MOCK_PORT_BASE + 916)) FAKE_DIRECTOR_MODE=happy
kill "$c19g_pid" 2>/dev/null; wait "$c19g_pid" 2>/dev/null
if grep -q '"tool": "complete_render_order"' "$c19g/mockstate/calls.jsonl" 2>/dev/null && grep -q '"tool": "append_render_event"' "$c19g/mockstate/calls.jsonl" 2>/dev/null; then
  pass "harness: order without manifest still runs the Director path (stage events + complete)"
else
  fail "harness: director path" "calls: $(cat "$c19g/mockstate/calls.jsonl" 2>/dev/null | head -5)"
fi
rm -rf "$c19g"

echo "--- 19h: no credential-looking env/paths leak into logs or reports"
c19h="$(mktemp -d)"; c19_setup "$c19h" $((MOCK_PORT_BASE + 917))
c19_worker "$c19h" $((MOCK_PORT_BASE + 917)) FAKE_TOKEN=sk-abc123 OPENAI_API_KEY=sk-abc123 CODEX_HOME="$HOME/.codex-fake-auth.json"
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
if ! grep -rq 'sk-abc123\|codex-fake-auth' "$c19h/cr-scratch" "$c19_ctl/reports.ndjson" "$c19h/worker.out" 2>/dev/null; then
  pass "harness: planted secret + fake credential path appear nowhere in ORDER_DIR, logs or reports"
else
  fail "harness: credential leak" "$(grep -rl 'sk-abc123\|codex-fake-auth' "$c19h/cr-scratch" "$c19_ctl/reports.ndjson" "$c19h/worker.out" 2>/dev/null)"
fi
rm -rf "$c19h"

echo "--- 19i: the five real batch-1 manifests (M2-06) — every computer step starts and completes against the mock"
# c19i_setup <dir> <port> <recipe> — like c19_setup but on a real skills/<recipe> (manifest + steps copied in),
# inputs {} (the fake engine writes every save; required-at-start inputs are not enforced by the harness),
# and a brand-scoped HeyGen OAuth credential on *-heygen orders so the CFW-313 gate lets the claim through.
c19i_setup() {
  local dir="$1" port="$2" recipe="$3" cred=""
  local man="$REPO_DIR/skills/$recipe/manifest.json"
  c19_state="$dir/mockstate"; c19_ctl="$dir/control"
  mkdir -p "$c19_state" "$c19_ctl" "$dir/skills/$recipe" "$dir/cr-scratch" "$dir/cr-state"
  cp "$man" "$dir/skills/$recipe/manifest.json"; cp -R "$REPO_DIR/skills/$recipe/steps" "$dir/skills/$recipe/steps"
  [[ "$recipe" == *-heygen ]] && cred='{"mode":"oauth","accessToken":"test-heygen-oauth-token-19i","expiresAt":"2099-01-01T00:00:00Z","creditPool":"plan_credits"}'
  python3 -c '
import json, sys
man, recipe, cred = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(man))
task = {"version": 1, "orderId": "order-19i", "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
        "kind": "video", "recipe": recipe, "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}
if cred: task["credentials"] = {"heygen": json.loads(cred)}
print(json.dumps([{"id": "order-19i", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": recipe, "recipeVersion": m["recipeVersion"], "manifest": man, "inputs": {},
  "status": "queued", "priority": 0, "attempts": 1, "taskOrder": task}]))
' "$man" "$recipe" "$cred" > "$dir/queue.json"
  c19_pid="$(CFW_MOCK_CONTROL_DIR="$c19_ctl" start_mock "$dir/queue.json" "$c19_state" "$port")"
}
c19i_port=$((MOCK_PORT_BASE + 918))
for c19i_r in ${CFW_TEST_19I_RECIPES:-p-reels-pip p-reels-split p-reels-spotlight-heygen p-reels-pip-heygen p-reels-split-heygen}; do
  c19i="$(mktemp -d)"; c19i_setup "$c19i" "$c19i_port" "$c19i_r"
  c19_worker "$c19i" "$c19i_port"
  kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
  c19i_ev="$(c19_events "$c19_ctl/reports.ndjson")"
  c19i_want="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
# With inputs {} and no alternative chosen: always-steps run; a step gated on an
# optional input or an alternative is reported skipped; server steps never show.
def one(s):
    if s["runsOn"] != "computer": return ""
    if s.get("when", "always") == "always": return "step_started:%s step_completed:%s" % (s["id"], s["id"])
    return "step_skipped:%s" % s["id"]
print(" ".join(x for x in (one(s) for s in m["steps"]) if x) + " attempt_completed:-")
' "$REPO_DIR/skills/$c19i_r/manifest.json")"
  if [[ "$c19i_ev" == "$c19i_want" && "$(c19_seqs_ok "$c19_ctl/reports.ndjson")" == "ok" && "$(c19_completed "$c19i")" == "1" ]]; then
    pass "harness: $c19i_r — every computer step started+completed in manifest order, attempt_completed, complete_render_order ok"
  else
    fail "harness: $c19i_r" "events='$c19i_ev' want='$c19i_want' seqs=$(c19_seqs_ok "$c19_ctl/reports.ndjson") completed=$(c19_completed "$c19i"); worker.out: $(tail -n "${CFW_TEST_19I_TAIL:-5}" "$c19i/worker.out")"
  fi
  rm -rf "$c19i"; c19i_port=$((c19i_port + 1))
done

echo "=== Case 19j: harness reads the claim's owner files in CFW's array shape (and the old dict shape) ==="
# CFW sends CONTRACTS §7 arrays: inputs [{inputId, items:[{kind,url}]}]. The
# harness used to read only a dict, so a talking-head video or B-roll the
# owner attached never reached inputs/<id>/ and `when: inputPresent` skipped.
c19j="$(mktemp -d)"
printf 'talking head bytes' > "$c19j/take.mp4"
printf 'broll one' > "$c19j/b1.mp4"
printf 'broll two' > "$c19j/b2.mp4"
python3 -c '
import json, sys
d = sys.argv[1]
json.dump({"inputs": [
  {"inputId": "talking_head", "items": [{"kind": "video", "url": d + "/take.mp4"}]},
  {"inputId": "broll", "items": [{"kind": "video", "url": d + "/b1.mp4"}, {"kind": "video", "url": d + "/b2.mp4"}]}],
  "answers": [{"inputId": "cta", "text": "Follow for more"}]}, open(d + "/arr.json", "w"))
json.dump({"inputs": {"talking_head": [{"url": d + "/take.mp4"}]}, "answers": {}}, open(d + "/dict.json", "w"))
json.dump({"inputs": [], "answers": []}, open(d + "/empty.json", "w"))
' "$c19j"
c19j_out="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh" >/dev/null 2>&1
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  mkdir -p "$c19j/wa/inputs" "$c19j/wd/inputs"
  cr_h_stage_inputs "$c19j/wa" "$c19j/arr.json"
  cr_h_stage_inputs "$c19j/wd" "$c19j/dict.json"
  printf '%s %s %s %s ' \
    "$(cr_h_input_present "$c19j/arr.json" broll)" "$(cr_h_input_present "$c19j/arr.json" cta)" \
    "$(cr_h_input_present "$c19j/dict.json" talking_head)" "$(cr_h_input_present "$c19j/empty.json" broll)"
  (cd "$c19j" && find wa wd -type f | sort | tr '\n' ' ')
)"
c19j_want="1 0 1 0 wa/inputs/broll/b1.mp4 wa/inputs/broll/b2.mp4 wa/inputs/talking_head/take.mp4 wd/inputs/talking_head/take.mp4 "
if [[ "$c19j_out" == "$c19j_want" ]]; then
  pass "harness: array-shape claim inputs staged per input id (talking_head + 2 B-roll clips); dict shape still works; inputPresent follows them"
else
  fail "harness: claim inputs array shape" "got '$c19j_out' want '$c19j_want'"
fi
rm -rf "$c19j"

echo "=== Case 20a: check-step-files.py green — ok fixture PASSes, exit 0 (M1-09) ==="
c20_checker="$REPO_DIR/scripts/check-step-files.py"
c20_fixture="$TEST_DIR/fixtures/manifests/stepfiles-ok"
c20_skills="$(mktemp -d)"
cp -R "$c20_fixture" "$c20_skills/p-stepfiles-ok"
c20a_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20a_rc=$?
if [[ "$c20a_rc" == "0" ]] && grep -q '^PASS' <<< "$c20a_out"; then
  pass "check-step-files.py: ok fixture → one-line PASS, exit 0"
else
  fail "check-step-files.py: ok fixture" "expected exit 0 + PASS line, got rc=$c20a_rc: $c20a_out"
fi

echo "=== Case 20b: check-step-files.py red — steps/_shared.md missing (M1-09) ==="
rm -f "$c20_skills/p-stepfiles-ok/steps/_shared.md"
c20b_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20b_rc=$?
if [[ "$c20b_rc" == "1" ]] && grep -q 'steps/_shared.md:0: missing steps/_shared.md' <<< "$c20b_out"; then
  pass "check-step-files.py: exit 1 naming the missing steps/_shared.md"
else
  fail "check-step-files.py: missing _shared.md" "expected exit 1 naming _shared.md, got rc=$c20b_rc: $c20b_out"
fi
cp "$c20_fixture/steps/_shared.md" "$c20_skills/p-stepfiles-ok/steps/_shared.md"

echo "=== Case 20c: check-step-files.py red — planted /opt/cfw-agent/.env host path (M1-09) ==="
printf 'source /opt/cfw-agent/.env\n' >> "$c20_skills/p-stepfiles-ok/steps/01.md"
c20c_line="$(wc -l < "$c20_skills/p-stepfiles-ok/steps/01.md" | tr -d ' ')"
c20c_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20c_rc=$?
if [[ "$c20c_rc" == "1" ]] && grep -q "steps/01.md:${c20c_line}: banned token '/opt/'" <<< "$c20c_out"; then
  pass "check-step-files.py: exit 1 with file:line for the planted /opt/ token (line $c20c_line)"
else
  fail "check-step-files.py: planted /opt/ path" "expected exit 1 + 01.md:$c20c_line, got rc=$c20c_rc: $c20c_out"
fi
cp "$c20_fixture/steps/01.md" "$c20_skills/p-stepfiles-ok/steps/01.md"

echo "=== Case 20d: check-step-files.py red — step file stops mentioning saves/x. (M1-09) ==="
sed -i.bak 's#saves/x\.json#saves/other.json#' "$c20_skills/p-stepfiles-ok/steps/01.md"
rm -f "$c20_skills/p-stepfiles-ok/steps/01.md.bak"
c20d_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20d_rc=$?
if [[ "$c20d_rc" == "1" ]] && grep -q "steps\[one\] never mentions saves/x.<ext> for save 'x'" <<< "$c20d_out"; then
  pass "check-step-files.py: exit 1 naming the unmentioned save id 'x'"
else
  fail "check-step-files.py: missing saves/x. mention" "expected exit 1 naming save 'x', got rc=$c20d_rc: $c20d_out"
fi
rm -rf "$c20_skills"

echo "=== Case 20e: check-step-files.py on the committed skills/ bundle (M1-09) ==="
c20e_out="$(python3 "$c20_checker" --skills-dir "$REPO_DIR/skills" 2>&1)"
c20e_rc=$?
if [[ "$c20e_rc" == "0" ]] && grep -q '^PASS' <<< "$c20e_out"; then
  pass "check-step-files.py: real skills/ tree passes (Spotlight step files clean)"
else
  fail "check-step-files.py: real skills/ tree" "expected exit 0, got rc=$c20e_rc: $c20e_out"
fi

echo "=== Case 20f: check-no-host-paths.sh still green on the real tree after the Spotlight split (M1-09) ==="
if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$REPO_DIR/skills" >/dev/null 2>&1; then
  pass "check-no-host-paths.sh: real skills/ tree still PASSes after the Spotlight step split"
else
  fail "check-no-host-paths.sh after split" "expected exit 0 on the real skills/ tree"
fi

echo "=== Case 21a: cr_probe_engine_headless — codex-only PATH ==="
c21_tmp="$(mktemp -d)"
trap 'rm -rf "$c21_tmp"' EXIT
mkdir -p "$c21_tmp/codex-only" "$c21_tmp/claude-only" "$c21_tmp/silent" "$c21_tmp/empty"
printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$c21_tmp/codex-only/codex"
printf '#!/bin/sh\necho "1.2.3 (Claude Code)"\n' > "$c21_tmp/claude-only/claude"
printf '#!/bin/sh\nexit 0\n' > "$c21_tmp/silent/codex"
printf '#!/bin/sh\nexit 0\n' > "$c21_tmp/silent/claude"
chmod +x "$c21_tmp"/*/codex "$c21_tmp"/*/claude 2>/dev/null || true
c21_base="/usr/bin:/bin"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_engine_headless codex "$c21_tmp/codex-only:$c21_base"
) >/dev/null 2>&1
c21a_codex=$?
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_engine_headless claude "$c21_tmp/codex-only:$c21_base"
) >/dev/null 2>&1
c21a_claude=$?
if [[ "$c21a_codex" == "0" && "$c21a_claude" != "0" ]]; then
  pass "cr_probe_engine_headless: codex-only PATH → codex 0, claude non-zero"
else
  fail "cr_probe_engine_headless codex-only" "codex rc=$c21a_codex claude rc=$c21a_claude"
fi

echo "=== Case 21b: cr_probe_engine_headless — both missing / both silent ==="
c21b_fail=0
for e in codex claude; do
  for d in empty silent; do
    (
      # shellcheck source=/dev/null
      source "$REPO_DIR/bin/cfw-render-lib.sh"
      cr_probe_engine_headless "$e" "$c21_tmp/$d:$c21_base"
    ) >/dev/null 2>&1 && c21b_fail=1
  done
done
if [[ "$c21b_fail" == "0" ]]; then
  pass "cr_probe_engine_headless: both missing → both non-zero; exit-0-but-silent → non-zero"
else
  fail "cr_probe_engine_headless both missing" "a probe unexpectedly returned 0"
fi

echo "=== Case 21c: cr_install_select_engine — picks codex | claude-code | aborts naming both ==="
c21c_sel() { # c21c_sel <path>
  (
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-lib.sh"
    cr_install_select_engine "$1"
  ) 2>/dev/null
}
c21c_codex="$(c21c_sel "$c21_tmp/codex-only:$c21_base")" || true
c21c_claude="$(c21c_sel "$c21_tmp/claude-only:$c21_base")" || true
c21c_none_err="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_install_select_engine "$c21_tmp/empty:$c21_base" 2>&1 >/dev/null
)"
c21c_none_rc=$?
if [[ "$c21c_codex" == "codex" ]]; then
  pass "cr_install_select_engine: codex-only → codex"
else
  fail "cr_install_select_engine codex-only" "got '$c21c_codex'"
fi
if [[ "$c21c_claude" == "claude-code" ]]; then
  pass "cr_install_select_engine: claude-only → claude-code (the value cr_engine_detect accepts)"
else
  fail "cr_install_select_engine claude-only" "got '$c21c_claude'"
fi
if [[ "$c21c_none_rc" == "1" ]] && grep -q 'Codex' <<< "$c21c_none_err" && grep -q 'Claude Code' <<< "$c21c_none_err" && grep -q 'login' <<< "$c21c_none_err"; then
  pass "cr_install_select_engine: neither → rc 1, message names Codex, Claude Code, and login"
else
  fail "cr_install_select_engine neither" "rc=$c21c_none_rc msg: $c21c_none_err"
fi
c21c_pre="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  CFW_RENDER_ENGINE=claude-code cr_install_select_engine "$c21_tmp/codex-only:$c21_tmp/claude-only:$c21_base" 2>/dev/null
)" || true
if [[ "$c21c_pre" == "claude-code" ]]; then
  pass "cr_install_select_engine: preset CFW_RENDER_ENGINE=claude-code honoured when it passes"
else
  fail "cr_install_select_engine preset" "got '$c21c_pre'"
fi

echo "=== Case 21d: credentials are never read — marker never surfaces; lib never names the files ==="
c21d_home="$(mktemp -d)"
mkdir -p "$c21d_home/.codex" "$c21d_home/.claude"
c21d_marker="CFW_SECRET_MARKER_$$_DO_NOT_LEAK"
printf '{"token":"%s"}\n' "$c21d_marker" > "$c21d_home/.codex/auth.json"
printf '{"token":"%s"}\n' "$c21d_marker" > "$c21d_home/.claude/.credentials.json"
c21d_out="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  HOME="$c21d_home" cr_install_select_engine "$c21_tmp/codex-only:$c21_tmp/claude-only:$c21_base" 2>&1
  HOME="$c21d_home" cr_install_select_engine "$c21_tmp/empty:$c21_base" 2>&1 || true
)"
if ! grep -q "$c21d_marker" <<< "$c21d_out"; then
  pass "credentials: marker planted in ~/.codex/auth.json + ~/.claude/.credentials.json never appears in output"
else
  fail "credentials leak" "marker surfaced in: $c21d_out"
fi
c21d_body="$(awk '/^cr_(install_select_engine|probe_engine_headless)\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$REPO_DIR/bin/cfw-render-lib.sh")"
if [[ -n "$c21d_body" ]] && ! grep -qiE 'auth\.json|\.credentials|credentials\.json|\.codex/|\.claude/' <<< "$c21d_body"; then
  pass "credentials: cr_install_select_engine + cr_probe_engine_headless bodies reference no auth.json / credentials / vendor dot-dirs"
else
  fail "credentials grep" "engine-selection function bodies mention a credential file (or body not found)"
fi
rm -rf "$c21d_home"
# ===========================================================================
# M2-04: capacity, parallel claims, stop_after_step, resume, kept-alive loop
# ===========================================================================
# c21_setup <dir> <port> <manifest-name> <orders-json> [mock env...] — seeds N
# manifest orders (orders-json is a list of {id, urgent?}), starts the mock.
c21_setup() {
  local dir="$1" port="$2" mname="$3" orders="$4"; shift 4
  c21_state="$dir/mockstate"; c21_ctl="$dir/control"
  mkdir -p "$c21_state" "$c21_ctl" "$dir/skills/$mname" "$dir/cr-scratch" "$dir/cr-state"
  cp "$REPO_DIR/test/fixtures/manifests/$mname/manifest.json" "$dir/skills/$mname/manifest.json"
  python3 -c '
import json, sys
mpath, mname, specs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
out = []
for sp in specs:
    out.append({"id": sp["id"], "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
      "recipe": mname, "recipeVersion": "1.0.0", "manifest": mpath, "inputs": {}, "urgent": bool(sp.get("urgent")),
      "status": "queued", "priority": 0, "attempts": 1,
      "taskOrder": {"version": 1, "orderId": sp["id"], "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
                    "kind": "video", "recipe": mname, "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}})
print(json.dumps(out))' "$dir/skills/$mname/manifest.json" "$mname" "$orders" > "$dir/queue.json"
  # Extra KEY=VALUE args become env for the mock. A subshell keeps them off
  # this shell; the function call stays in-process (functions are not
  # exported, so `bash -c` would not see start_mock).
  c21_pid="$(
    export CFW_MOCK_CONTROL_DIR="$c21_ctl"
    for kv in "$@"; do export "${kv?}"; done
    start_mock "$dir/queue.json" "$c21_state" "$port"
  )"
}
export -f start_mock
# c21_worker <dir> <port> <mode: --once|--loop> [env assignments...]
c21_worker() {
  local dir="$1" port="$2" mode="$3"; shift 3
  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$dir/cr-state"
    export CFW_RENDER_LOG_DIR="$dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh"
    export CFW_RENDER_HEARTBEAT_SEC=1
    export CFW_RENDER_CONCURRENCY=1
    export CFW_WORKER_ID="w-m2"
    export CFW_RENDER_UPLOAD_MODE=multipart
    export CFW_RENDER_SECURITY_CMD=/usr/bin/false   # [M3-08b] no Keychain keys unless a case adds a stub
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/bin/cfw-render.sh" "$mode" > "$dir/worker.out" 2>&1
  )
}
# c21_claims <dir> — "running/max" per claim call, space-separated, in order
c21_claims() { python3 -c '
import json, sys
out = []
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["tool"] != "claim_render_order": continue
    c = d["args"].get("capacity")
    out.append("%s/%s" % (c["running"], c["max"]) if isinstance(c, dict) else "none")
print(" ".join(out))' "$1/mockstate/calls.jsonl" 2>/dev/null; }
c21_events_for() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d["event"], d.get("stepId") or "-") for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] != "heartbeat" and d["orderId"] == sys.argv[2]))' "$1" "$2" 2>/dev/null; }

echo "=== Case 22: capacity table via seams — 32 GB / 8 perf cores → 4; 8 GB → 1 and the setup line (M2-04, D52/D78) ==="
c21a_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((32*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=8 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
c21b_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((8*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
c21b_note="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((8*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_setup_note' _ "$REPO_DIR")"
c21c_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((32*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
if [[ "$c21a_max" == "4" && "$c21b_max" == "1" && "$c21c_max" == "2" ]]; then
  pass "capacity table: 32GB/8 cores → 4; 8GB → 1; 32GB/4 cores → 2 (cores ÷ 2 cap)"
else
  fail "capacity table" "32GB/8c=$c21a_max (want 4) 8GB=$c21b_max (want 1) 32GB/4c=$c21c_max (want 2)"
fi
if [[ "$c21b_note" == "This computer runs one request at a time. It still serves your brands; bigger jobs just take turns." ]]; then
  pass "capacity: max 1 → setup summary says 'This computer runs one request at a time…' (D78)"
else
  fail "capacity setup line" "got: $c21b_note"
fi
if grep -q 'install.sh: \$(cr_capacity_setup_note)' "$REPO_DIR/install/install.sh"; then
  pass "install.sh prints the capacity setup note"
else
  fail "install.sh capacity note" "install.sh does not call cr_capacity_setup_note"
fi

echo "=== Case 23: 3 running + a normal 4th queued → no 4th claim; urgent 4th → claimed alongside (M2-04, D51) ==="
c22a="$(mktemp -d)"
c21_setup "$c22a" $((MOCK_PORT_BASE + 920)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"},{"id":"o4"}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c22a" $((MOCK_PORT_BASE + 920)) --once CFW_RENDER_CONCURRENCY=3
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c22a_claims="$(c21_claims "$c22a")"
c22a_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c22a/mockstate/calls.jsonl" 2>/dev/null || true)"
c22a_o4="$(grep -c '"orderId": "o4"' "$c21_ctl/reports.ndjson" 2>/dev/null || true)"
if [[ "$c22a_claims" == "0/3 3/3" && "$c22a_done" == "3" && "$c22a_o4" == "0" ]]; then
  pass "capacity: orders[] claim 0/3 took three; the full ask (3/3) returned nothing for a normal o4; 3 completed"
else
  fail "capacity: 3 running + normal" "claims='$c22a_claims' (want '0/3 3/3') done=$c22a_done o4-reports=$c22a_o4; $(tail -3 "$c22a/worker.out")"
fi
rm -rf "$c22a"
c22b="$(mktemp -d)"
c21_setup "$c22b" $((MOCK_PORT_BASE + 921)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"},{"id":"o4","urgent":true}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c22b" $((MOCK_PORT_BASE + 921)) --once CFW_RENDER_CONCURRENCY=3
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c22b_claims="$(c21_claims "$c22b")"
c22b_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c22b/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c22b_claims" == "0/3 3/3" && "$c22b_done" == "4" ]] && grep -q "urgent ask with running=3 max=3 returned 1 order" "$c22b/cr-state/cfw-render.log"; then
  pass "capacity: full ask (3/3) returned the urgent o4 → started alongside; 4 completed"
else
  fail "capacity: 3 running + urgent" "claims='$c22b_claims' done=$c22b_done; log: $(grep -i 'capacity\|urgent' "$c22b/cr-state/cfw-render.log" | tail -3)"
fi
rm -rf "$c22b"

echo "=== Case 24: free memory under the floor → no normal claim; urgent-only ask only once the server has shown it honours capacity (M2-04) ==="
# 23a: fresh process, floor breached, server never answered yet → no ask at all
# (an old server would hand a normal order to a starved computer).
c23="$(mktemp -d)"
c21_setup "$c23" $((MOCK_PORT_BASE + 922)) harness-3step '[{"id":"o1"}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c23" $((MOCK_PORT_BASE + 922)) --once CFW_RENDER_CONCURRENCY=2 CFW_RENDER_CAPACITY_FREE_MB=1000
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c23_claims="$(c21_claims "$c23")"
c23_done="$(grep -c '"tool": "complete_render_order"' "$c23/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c23_claims" == "" && "$c23_done" == "0" ]] && grep -q "normal claims skipped, urgent only" "$c23/cr-state/cfw-render.log"; then
  pass "capacity: free 1000 MB < 3072 floor on a fresh process → no claim at all (server not yet known to honour capacity), o1 left queued, logged"
else
  fail "capacity: floor (fresh)" "claims='$c23_claims' (want '') done=$c23_done; log: $(grep capacity "$c23/cr-state/cfw-render.log" | tail -2)"
fi
rm -rf "$c23"
# 23b: --loop with the floor breached from the 2nd round on: round 1 claims
# normally (teaches the worker the server honours capacity), later rounds
# make only the full ask (2/2) and o2 stays queued.
c23b="$(mktemp -d)"
c21_setup "$c23b" $((MOCK_PORT_BASE + 923)) harness-3step '[{"id":"o1"},{"id":"o2"}]' CFW_MOCK_ORDERS_ARRAY=1 CFW_MOCK_MAX_PER_CLAIM=1
c23b_floor="$c23b/floor"; : > "$c23b_floor"
c21_worker "$c23b" $((MOCK_PORT_BASE + 923)) --loop CFW_RENDER_CONCURRENCY=2 CFW_RENDER_CAPACITY_UNIT_SECS=0.05 CFW_RENDER_CAPACITY_FREE_MB_FILE="$c23b_floor" &
c23b_w=$!
for _ in $(seq 1 100); do grep -q '"tool": "claim_render_order"' "$c23b/mockstate/calls.jsonl" 2>/dev/null && break; sleep 0.1; done
printf '1000' > "$c23b_floor"
sleep 3
pkill -P "$c23b_w" 2>/dev/null; kill "$c23b_w" 2>/dev/null; wait "$c23b_w" 2>/dev/null
pkill -f "cfw-render.sh --loop" 2>/dev/null || true
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c23b_claims="$(c21_claims "$c23b")"
# Round 1 fills the computer one order per reply (0/2, 1/2, then the full
# ask 2/2); once the floor is breached every later ask is the full one.
c23b_tail="$(sed -E 's/^0\/2 1\/2 2\/2 ?//' <<< "$c23b_claims")"
if [[ "$c23b_claims" == 0/2\ 1/2\ 2/2* && "$(tr ' ' '\n' <<< "$c23b_tail" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')" == "2/2" ]] && grep -q "normal claims skipped, urgent only" "$c23b/cr-state/cfw-render.log"; then
  pass "capacity: floor breached after round 1 → only full asks (2/2) afterwards; logged"
else
  fail "capacity: floor (loop)" "claims='$c23b_claims' (want '0/2 1/2 2/2' then only '2/2'); log: $(grep capacity "$c23b/cr-state/cfw-render.log" | tail -3)"
fi
rm -rf "$c23b"

echo "=== Case 25: stop_after_step → step finishes, uploads, attempt_released revoked, folder gone (M2-04, D76) ==="
c24="$(mktemp -d)"
c21_setup "$c24" $((MOCK_PORT_BASE + 923)) harness-3step '[{"id":"o1"}]' CFW_MOCK_STOP_AFTER_STEP=1
c21_worker "$c24" $((MOCK_PORT_BASE + 923)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c24_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c24_rel="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "attempt_released": print(d.get("stepId"), d.get("reason"))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
c24_up="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_completed" and d.get("stepId") == "a": print(len(d.get("outputs") or []))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c24_ev" == "step_started:a step_completed:a attempt_released:a" && "$c24_rel" == "a revoked" && "$c24_up" == "1" && ! -d "$c24/cr-scratch/test-brand/order-o1" ]]; then
  pass "stop_after_step: a completed with its upload, attempt_released {stepId:a, reason:revoked}, no step c, order folder deleted"
else
  fail "stop_after_step" "events='$c24_ev' released='$c24_rel' uploads=$c24_up dir-exists=$([[ -d "$c24/cr-scratch/test-brand/order-o1" ]] && echo yes || echo no); $(tail -3 "$c24/worker.out")"
fi
rm -rf "$c24"

echo "=== Case 26: resume with two saved outputs → a, b skipped; starts at plan_broll (M2-04, D30) ==="
c25="$(mktemp -d)"
c21_setup "$c25" $((MOCK_PORT_BASE + 924)) harness-resume '[{"id":"o1"}]' CFW_MOCK_RESUME_FROM=plan_broll
c21_worker "$c25" $((MOCK_PORT_BASE + 924)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c25_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c25_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c25/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c25_ev" == "step_started:plan_broll step_completed:plan_broll step_started:c step_completed:c attempt_completed:-" && "$c25_done" == "1" ]] && grep -q "resumes at plan_broll (2 saved output(s) restored)" "$c25/cr-state/cfw-render.log"; then
  pass "resume: savedOutputs a/x + b/y restored, a and b never run, plan_broll → c → attempt_completed"
else
  fail "resume" "events='$c25_ev' done=$c25_done; log: $(grep -i 'resum' "$c25/cr-state/cfw-render.log" | tail -2)"
fi
rm -rf "$c25"

echo "=== Case 27: a saved output 404s → step_failed 'Saved result from step a is missing' + attempt_failed (M2-04) ==="
c26="$(mktemp -d)"
c21_setup "$c26" $((MOCK_PORT_BASE + 925)) harness-resume '[{"id":"o1"}]' CFW_MOCK_RESUME_FROM=plan_broll CFW_MOCK_RESUME_404=a/x
c21_worker "$c26" $((MOCK_PORT_BASE + 925)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c26_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c26_err="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_failed": print(d.get("stepId"), "|", d.get("error") or d.get("reason") or d.get("message") or json.dumps(d))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c26_ev" == *"step_failed:"* && "$c26_ev" == *"attempt_failed:"* && "$c26_ev" != *"step_completed"* && "$c26_err" == *"Saved result from step a is missing"* ]]; then
  pass "resume: a/x 404 → step_failed 'Saved result from step a is missing', attempt_failed, nothing completed"
else
  fail "resume 404" "events='$c26_ev' err='$c26_err'; $(tail -3 "$c26/worker.out")"
fi
rm -rf "$c26"

echo "=== Case 28: old server ignores capacity → M1 behaviour, one order per claim, still fills max (M2-04) ==="
c27="$(mktemp -d)"
c21_setup "$c27" $((MOCK_PORT_BASE + 926)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"}]' CFW_MOCK_IGNORE_CAPACITY=1
c21_worker "$c27" $((MOCK_PORT_BASE + 926)) --once CFW_RENDER_CONCURRENCY=2
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c27_claims="$(c21_claims "$c27")"
c27_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c27/mockstate/calls.jsonl" 2>/dev/null || true)"
c27_orders="$(python3 -c '
import json, sys
print(" ".join(sorted({json.loads(l)["orderId"] for l in open(sys.argv[1]) if l.strip()})))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
# No full ask (2/2) against a server that never answered with orders[]: it
# ignores capacity and would hand a normal o3 to a full computer.
if [[ "$c27_claims" == "0/2 1/2" && "$c27_done" == "2" && "$c27_orders" == "o1 o2" ]]; then
  pass "old server: capacity sent on every claim (0/2 1/2) but ignored → single order per reply; no full ask; 2 ran, o3 stayed queued"
else
  fail "old server" "claims='$c27_claims' (want '0/2 1/2') done=$c27_done orders='$c27_orders'"
fi
rm -rf "$c27"

echo "=== Case 29: --loop claim back-off grows 1u→2u→4u→8u→10u with ONE log line per step (M2-04, D89) ==="
c28="$(mktemp -d)"
c21_setup "$c28" $((MOCK_PORT_BASE + 927)) harness-3step '[{"id":"o1"}]' CFW_MOCK_CLAIM_ERROR=1
c21_worker "$c28" $((MOCK_PORT_BASE + 927)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.05 &
c28_w=$!
# every failed claim costs cr_mcp_call's own curl retries before the back-off
# sleep, so reaching the 10u cap line takes a while: wait for it, bounded.
# ...then at least one more failed claim at the cap, so tries > log lines
# proves the cap step was not logged again.
for _ in $(seq 1 60); do grep -q 'retrying every 0.5s' "$c28/cr-state/cfw-render.log" 2>/dev/null && break; sleep 0.5; done
c28_at_cap="$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)"
for _ in $(seq 1 40); do [[ "$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)" -gt "$c28_at_cap" ]] && break; sleep 0.5; done
# the loop runs cfw-render.sh under a subshell; stop the whole tree
pkill -P "$c28_w" 2>/dev/null; kill "$c28_w" 2>/dev/null; wait "$c28_w" 2>/dev/null
pkill -f "cfw-render.sh --loop" 2>/dev/null || true
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c28_steps="$(grep 'claim back-off: claim_render_order keeps failing' "$c28/cr-state/cfw-render.log" | sed -E 's/.*retrying every ([0-9.]+)s.*/\1/' | tr '\n' ' ' | sed 's/ $//')"
c28_tries="$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)"
c28_lines="$(grep -c 'claim back-off: claim_render_order keeps failing' "$c28/cr-state/cfw-render.log" 2>/dev/null || true)"
if [[ "$c28_steps" == "0.05 0.1 0.2 0.4 0.5" && "$c28_tries" -gt "$c28_lines" ]]; then
  pass "back-off: steps logged once each (0.05 0.1 0.2 0.4 0.5 = base→×2→cap 10u); $c28_tries failed claims, $c28_lines lines"
else
  fail "back-off" "steps='$c28_steps' (want '0.05 0.1 0.2 0.4 0.5') tries=$c28_tries lines=$c28_lines; $(tail -3 "$c28/cr-state/cfw-render.log")"
fi
if grep -q "pid=" "$c28/cr-state/tick.lock/info" 2>/dev/null || grep -q "loop: started" "$c28/cr-state/cfw-render.log"; then
  pass "loop: started under the tick lock (touched each round)"
else
  fail "loop start" "no 'loop: started' line: $(head -3 "$c28/cr-state/cfw-render.log")"
fi
rm -rf "$c28"


# ---------------------------------------------------------------------------
# M3-01a: pause / battery / run-now / version / updateRequired
# ---------------------------------------------------------------------------
FAKE_CAFFEINATE_LOG="$(mktemp)"; export FAKE_CAFFEINATE_LOG
cat > "$FAKE_BIN/caffeinate" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CAFFEINATE_LOG:-/dev/null}"
exec sleep 30
EOF2
chmod +x "$FAKE_BIN/caffeinate"
# m3_tool_count <dir> <tool>
m3_tool_count() { grep -c "\"tool\": \"$2\"" "$1/mockstate/calls.jsonl" 2>/dev/null || true; }
# m3_status <dir> <python expr over d>
m3_status() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1/cr-state/status.json" "$2" 2>/dev/null; }

echo "=== Case M3-01a-1: paused file → no claim, set_computer_paused(owner) once, status.json paused ==="
m1="$(mktemp -d)"
c21_setup "$m1" $((MOCK_PORT_BASE + 940)) harness-3step '[{"id":"o1"}]'
touch "$m1/cr-state/paused"
c21_worker "$m1" $((MOCK_PORT_BASE + 940)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m1_claims="$(m3_tool_count "$m1" claim_render_order)"
m1_paused="$(grep -c '"tool": "set_computer_paused", "args": {"paused": true, "reason": "owner"}' "$m1/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$m1_claims" == "0" && "$m1_paused" == "1" && "$(m3_status "$m1" 'd["computer"]["paused"]')" == "True" && "$(m3_status "$m1" 'd["computer"]["pauseReason"]')" == "owner" ]]; then
  pass "paused: 0 claims, set_computer_paused(owner) once, status.json computer.paused=true"
else
  fail "paused" "claims=$m1_claims paused_calls=$m1_paused status=$(cat "$m1/cr-state/status.json" 2>/dev/null | head -c 300)"
fi
rm -rf "$m1"

echo "=== Case M3-01a-2: on battery → no claim (reason battery); allow-battery → claim ==="
m2="$(mktemp -d)"
c21_setup "$m2" $((MOCK_PORT_BASE + 941)) harness-3step '[]'
touch "$FAKE_PMSET_BATTERY"
c21_worker "$m2" $((MOCK_PORT_BASE + 941)) --once
m2_claims_a="$(m3_tool_count "$m2" claim_render_order)"
m2_batt="$(grep -c '"tool": "set_computer_paused", "args": {"paused": true, "reason": "battery"}' "$m2/mockstate/calls.jsonl" 2>/dev/null || true)"
touch "$m2/cr-state/allow-battery"
c21_worker "$m2" $((MOCK_PORT_BASE + 941)) --once
m2_claims_b="$(m3_tool_count "$m2" claim_render_order)"
rm -f "$FAKE_PMSET_BATTERY"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
if [[ "$m2_claims_a" == "0" && "$m2_batt" == "1" && "$m2_claims_b" -ge 1 && -e "$m2/cr-state/allow-battery" ]]; then
  pass "battery: no claim + set_computer_paused(battery); allow-battery → claim ($m2_claims_b)"
else
  fail "battery" "claims_a=$m2_claims_a batt_calls=$m2_batt claims_b=$m2_claims_b; $(tail -3 "$m2/cr-state/cfw-render.log")"
fi
rm -rf "$m2"

echo "=== Case M3-01a-3: --loop run-now flag wakes the loop; lastCheckAt set ==="
m3="$(mktemp -d)"
c21_setup "$m3" $((MOCK_PORT_BASE + 942)) harness-3step '[]'
c21_worker "$m3" $((MOCK_PORT_BASE + 942)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=2 &
m3_w=$!
# wait for the first round (status.json appears), then ask for another now
for _ in $(seq 1 100); do [[ -f "$m3/cr-state/status.json" ]] && break; sleep 0.1; done
sleep 0.5
m3_before="$(m3_tool_count "$m3" claim_render_order)"
touch "$m3/cr-state/run-now"
m3_after="$m3_before"
for _ in $(seq 1 15); do m3_after="$(m3_tool_count "$m3" claim_render_order)"; [[ "$m3_after" -gt "$m3_before" ]] && break; sleep 0.1; done
m3_flag=0; [[ -e "$m3/cr-state/run-now" ]] && m3_flag=1
m3_last="$(m3_status "$m3" 'd["lastCheckAt"]')"
pkill -P "$m3_w" 2>/dev/null; kill "$m3_w" 2>/dev/null; wait "$m3_w" 2>/dev/null
pkill -f "cfw-render.sh --loop" 2>/dev/null || true
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
if [[ "$m3_after" -gt "$m3_before" && "$m3_flag" == "0" && -n "$m3_last" && "$m3_last" != "None" ]]; then
  pass "run-now: claims ${m3_before}→${m3_after} within 1.5s, flag consumed, lastCheckAt=$m3_last"
else
  fail "run-now" "before=$m3_before after=$m3_after flag=$m3_flag last='$m3_last'; $(tail -3 "$m3/cr-state/cfw-render.log")"
fi
rm -rf "$m3"

echo "=== Case M3-01a-4: capabilities.workerVersion rides on the claim; caffeinate wraps the order ==="
m4="$(mktemp -d)"
c21_setup "$m4" $((MOCK_PORT_BASE + 943)) harness-3step '[{"id":"o1"}]'
: > "$FAKE_CAFFEINATE_LOG"
c21_worker "$m4" $((MOCK_PORT_BASE + 943)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m4_ver="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order": print(d["args"].get("capabilities",{}).get("workerVersion")); break' "$m4/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$m4_ver" == "1.0.0" && "$(m3_status "$m4" 'd["workerVersion"]')" == "1.0.0" ]]; then
  pass "version: claim capabilities.workerVersion=1.0.0, status.json version=1.0.0"
else
  fail "version" "workerVersion='$m4_ver' status=$(m3_status "$m4" 'd["workerVersion"]')"
fi
if grep -q -- '-i -w ' "$FAKE_CAFFEINATE_LOG"; then
  pass "sleep (D90): caffeinate -i -w <pid> started for the order"
else
  fail "caffeinate" "log: $(cat "$FAKE_CAFFEINATE_LOG")"
fi
pkill -f 'sleep 30' 2>/dev/null || true
rm -rf "$m4"

echo "=== Case M3-01a-5: updateRequired reply → no orders, status.json updateRequired + lastError ==="
m5="$(mktemp -d)"
c21_setup "$m5" $((MOCK_PORT_BASE + 944)) harness-3step '[{"id":"o1"}]' CFW_MOCK_UPDATE_REQUIRED=1
c21_worker "$m5" $((MOCK_PORT_BASE + 944)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m5_steps="$(m3_tool_count "$m5" report_render_step)"
if [[ "$m5_steps" == "0" && "$(m3_status "$m5" 'd["computer"]["updateRequired"]')" == "True" && "$(m3_status "$m5" 'd["lastError"]')" == "Update this computer" ]] && grep -q 'update required' "$m5/cr-state/cfw-render.log"; then
  pass "updateRequired: no orders started, status.json updateRequired=true lastError='Update this computer'"
else
  fail "updateRequired" "steps=$m5_steps status=$(head -c 400 "$m5/cr-state/status.json" 2>/dev/null); log: $(tail -4 "$m5/cr-state/cfw-render.log"); calls: $(cat "$m5/mockstate/calls.jsonl" | head -c 600)"
fi
rm -rf "$m5"

echo "=== Case M3-01a-6: older server without set_computer_paused → logged once, exit 0, no claims ==="
m6="$(mktemp -d)"
c21_setup "$m6" $((MOCK_PORT_BASE + 945)) harness-3step '[{"id":"o1"}]' CFW_MOCK_NO_M3_TOOLS=1
touch "$m6/cr-state/paused"
c21_worker "$m6" $((MOCK_PORT_BASE + 945)) --once; m6_rc=$?
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m6_lines="$(grep -c 'set_computer_paused' "$m6/cr-state/cfw-render.log" 2>/dev/null || true)"
if [[ "$m6_rc" == "0" && "$m6_lines" == "1" && "$(m3_tool_count "$m6" claim_render_order)" == "0" ]]; then
  pass "old server: set_computer_paused failure logged once, exit 0, 0 claims"
else
  fail "old server M3" "rc=$m6_rc lines=$m6_lines claims=$(m3_tool_count "$m6" claim_render_order); $(tail -3 "$m6/cr-state/cfw-render.log")"
fi
rm -rf "$m6"
# ===========================================================================
# M3-07a — private toolchain: tools/current/bin PATH precedence + verify.sh
# ===========================================================================

echo "=== Case M3-07a-1: cr_resolve_worker_path prepends tools/current/bin when present ==="
m7_tmp="$(mktemp -d)"
mkdir -p "$m7_tmp/current/bin"
printf '#!/bin/sh\nexit 0\n' >"$m7_tmp/current/bin/ffmpeg"
chmod +x "$m7_tmp/current/bin/ffmpeg"
m7_out="$(
  export CFW_RENDER_TOOLS_DIR="$m7_tmp"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ "$m7_out" == "$m7_tmp/current/bin:"* ]]; then
  pass "M3-07a-1: tools/current/bin is first on the worker PATH"
else
  fail "M3-07a-1" "expected prefix $m7_tmp/current/bin: in: $m7_out"
fi
rm -rf "$m7_tmp"

echo "=== Case M3-07a-2: absent tools dir leaves the worker PATH byte-identical ==="
m7_base="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
m7_none="$(
  export CFW_RENDER_TOOLS_DIR="/nonexistent/cfw-tools-$$"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ "$m7_base" == "$m7_none" && "$m7_none" != *"/nonexistent/"* ]]; then
  pass "M3-07a-2: no tools dir → PATH unchanged"
else
  fail "M3-07a-2" "base=$m7_base none=$m7_none"
fi

echo "=== Case M3-07a-3: make-sums.sh + verify.sh round-trip, then a flipped byte ==="
m7_b="$(mktemp -d)"
mkdir -p "$m7_b/bin"
printf 'hello\n' >"$m7_b/bin/a.txt"
printf 'world\n' >"$m7_b/notes.txt"
if "$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_b" >/dev/null \
   && [[ -s "$m7_b/SHA256SUMS" ]] \
   && "$REPO_DIR/toolchain/scripts/verify.sh" "$m7_b" >/dev/null; then
  pass "M3-07a-3: make-sums + verify → exit 0 on a clean dir"
else
  fail "M3-07a-3 clean" "verify did not pass on a freshly summed dir"
fi
printf 'hellp\n' >"$m7_b/bin/a.txt"
m7_v_out="$("$REPO_DIR/toolchain/scripts/verify.sh" "$m7_b" 2>&1)" && m7_v_rc=0 || m7_v_rc=$?
if [[ "$m7_v_rc" == "1" && "$m7_v_out" == *"bin/a.txt"* ]]; then
  pass "M3-07a-3: flipped byte → exit 1 naming bin/a.txt"
else
  fail "M3-07a-3 tamper" "rc=$m7_v_rc out=$m7_v_out"
fi
rm -rf "$m7_b"

echo "=== Case M3-07a-4: verify.sh Mach-O scan — system binary clean, Homebrew string flagged ==="
m7_m="$(mktemp -d)"
mkdir -p "$m7_m/bin"
cp /bin/ls "$m7_m/bin/ls"
if file -b "$m7_m/bin/ls" | grep -q 'Mach-O'; then
  "$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_m" >/dev/null
  m7_m_out="$("$REPO_DIR/toolchain/scripts/verify.sh" "$m7_m" 2>&1)" && m7_m_rc=0 || m7_m_rc=$?
  if [[ "$m7_m_rc" == "0" && "$m7_m_out" == *"1 Mach-O"* ]]; then
    pass "M3-07a-4: copy of /bin/ls → exit 0 (links /usr/lib only)"
  else
    fail "M3-07a-4 ls" "rc=$m7_m_rc out=$m7_m_out"
  fi
else
  pass "M3-07a-4: skipped (no Mach-O)"
fi
rm -rf "$m7_m"
m7_f="$(mktemp -d)"
mkdir -p "$m7_f/bin"
# Fake Mach-O: magic header (so `file` says Mach-O) + a Homebrew path string.
if file -b /bin/ls | grep -q 'Mach-O'; then
  head -c 4096 /bin/ls >"$m7_f/bin/fake"
else
  printf '\xcf\xfa\xed\xfe' >"$m7_f/bin/fake"
fi
printf '\n/opt/homebrew/lib/libfoo.dylib\n' >>"$m7_f/bin/fake"
"$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_f" >/dev/null
if file -b "$m7_f/bin/fake" | grep -q 'Mach-O'; then
  m7_f_out="$(CFW_VERIFY_FORCE_STRINGS=1 "$REPO_DIR/toolchain/scripts/verify.sh" "$m7_f" 2>&1)" && m7_f_rc=0 || m7_f_rc=$?
  if [[ "$m7_f_rc" == "1" && "$m7_f_out" == *"/opt/homebrew/lib/libfoo.dylib"* && "$m7_f_out" == *"strings"* ]]; then
    pass "M3-07a-4: strings fallback flags /opt/homebrew reference → exit 1"
  else
    fail "M3-07a-4 strings" "rc=$m7_f_rc out=$m7_f_out"
  fi
else
  pass "M3-07a-4: strings fallback skipped (file does not report Mach-O)"
fi
rm -rf "$m7_f"

# ===========================================================================
# [M3-01b] engines, usage limits, failover (contract §1/§3, D107/D109)
# ===========================================================================
m3b_fx="$REPO_DIR/test/fixtures/engine-limits"
m3b_detect() { CFW_RENDER_STATE_DIR="$1" bash -c 'cr_log(){ :; }; source "$1/bin/cfw-render-engine.sh"; cr_engine_limit_detect "$2" "$3" "$4"' _ "$REPO_DIR" "$2" "$3" "$4"; }
# m3b_started <dir> <orderId> — engines of step_started reports, in order
m3b_started() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d.get("stepId"), d.get("engine")) for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] == "step_started" and d["orderId"] == sys.argv[2]))' "$1/control/reports.ndjson" "$2" 2>/dev/null; }
m3b_calls_of() { python3 -c '
import json, sys
print("\n".join(json.dumps(json.loads(l)["args"]) for l in open(sys.argv[1]) if json.loads(l)["tool"] == sys.argv[2]))' "$1/mockstate/calls.jsonl" "$2" 2>/dev/null; }

echo "=== Case M3-01b-1: cr_engine_limit_detect on vendor fixtures ==="
mb1="$(mktemp -d)"
mb1_a="$(m3b_detect "$mb1" codex "$m3b_fx/codex-limit.txt" 1)" && mb1_a_rc=0 || mb1_a_rc=$?
mb1_b="$(m3b_detect "$mb1" claude-code "$m3b_fx/claude-limit.txt" 0)" && mb1_b_rc=0 || mb1_b_rc=$?
mb1_c="$(m3b_detect "$mb1" codex "$m3b_fx/codex-ok.txt" 1)" && mb1_c_rc=0 || mb1_c_rc=$?
if [[ "$mb1_a_rc" == "0" && "$mb1_a" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:40:00Z$ && "$mb1_b_rc" == "0" && "$mb1_b" =~ ^[0-9]{4}- && "$mb1_c_rc" == "1" && -z "$mb1_c" ]]; then
  pass "limit detect: codex-limit → $mb1_a; claude-limit → $mb1_b; codex-ok → rc 1"
else
  fail "limit detect" "codex rc=$mb1_a_rc out=$mb1_a; claude rc=$mb1_b_rc out=$mb1_b; ok rc=$mb1_c_rc out=$mb1_c"
fi
rm -rf "$mb1"

echo "=== Case M3-01b-2: codex hits its limit on step a → step reruns on claude-code, attempt completes ==="
mb2="$(mktemp -d)"
c21_setup "$mb2" $((MOCK_PORT_BASE + 950)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb2" $((MOCK_PORT_BASE + 950)) --once FAKE_ENGINE_LIMIT_ENGINE=codex FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb2_started="$(m3b_started "$mb2" o1)"
mb2_ev="$(c21_events_for "$mb2/control/reports.ndjson" o1)"
mb2_lim="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("codex" if "codex" in d else "no")' "$mb2/cr-state/engine-limits.json" 2>/dev/null)"
if [[ "$mb2_started" == "a:codex a:claude-code c:claude-code" && "$mb2_ev" == *"step_completed:a"* && "$mb2_ev" == *"attempt_completed:-"* && "$mb2_lim" == "codex" ]]; then
  pass "failover: step_started a:codex → a:claude-code, completed; engine-limits.json has codex"
else
  fail "failover" "started='$mb2_started' events='$mb2_ev' limits=$mb2_lim; $(tail -5 "$mb2/cr-state/cfw-render.log" 2>/dev/null)"
fi
rm -rf "$mb2"

echo "=== Case M3-01b-3: every engine limited → attempt_released(engine_limit), set_computer_limit(until); next pass claims nothing ==="
mb3="$(mktemp -d)"
c21_setup "$mb3" $((MOCK_PORT_BASE + 951)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb3" $((MOCK_PORT_BASE + 951)) --once FAKE_ENGINE_LIMIT_ENGINE=all FAKE_ENGINE_LIMIT_STEP=a
mb3_ev="$(c21_events_for "$mb3/control/reports.ndjson" o1)"
mb3_rel="$(grep -c '"event": "attempt_released"' "$mb3/control/reports.ndjson" 2>/dev/null || true)"
mb3_reason="$(python3 -c '
import json,sys
print(" ".join(d.get("reason") or "-" for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"]=="attempt_released"))' "$mb3/control/reports.ndjson" 2>/dev/null)"
mb3_lim="$(m3b_calls_of "$mb3" set_computer_limit)"
mb3_failed="$(grep -c '"event": "attempt_failed"' "$mb3/control/reports.ndjson" 2>/dev/null || true)"
mb3_claims_a="$(m3_tool_count "$mb3" claim_render_order)"
c21_worker "$mb3" $((MOCK_PORT_BASE + 951)) --once FAKE_ENGINE_LIMIT_ENGINE=all FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb3_claims_b="$(m3_tool_count "$mb3" claim_render_order)"
mb3_status="$(m3_status "$mb3" '" ".join(e["limit"] for e in d["engines"] if e["signedIn"])')"
mb3_err="$(m3_status "$mb3" 'd["lastError"]')"
if [[ "$mb3_rel" == "1" && "$mb3_reason" == "engine_limit" && "$(wc -l <<< "$mb3_lim" | tr -d ' ')" == "1" && "$mb3_lim" == *'"until": "20'* && "$mb3_failed" == "0" && "$mb3_claims_b" == "$mb3_claims_a" && "$mb3_status" == "limited limited" && "$mb3_err" == "AI limit reached; resumes "* ]]; then
  pass "both limited: attempt_released(engine_limit) once, set_computer_limit once with until, no attempt_failed; 2nd pass 0 claims, status engines=limited limited"
else
  fail "both limited" "released=$mb3_rel reason=$mb3_reason limit_calls='$mb3_lim' failed=$mb3_failed claims=$mb3_claims_a/$mb3_claims_b status='$mb3_status' err='$mb3_err' ev='$mb3_ev'"
fi
rm -rf "$mb3"

echo "=== Case M3-01b-4: engines.json order → capabilities.engine and engines[0] are claude-code ==="
mb4="$(mktemp -d)"
c21_setup "$mb4" $((MOCK_PORT_BASE + 952)) harness-3step '[]'
printf '{"order":["claude-code","codex"]}' > "$mb4/cr-state/engines.json"
c21_worker "$mb4" $((MOCK_PORT_BASE + 952)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb4_caps="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order":
        c=d["args"]["capabilities"]; print(c["engine"], c["engines"][0]["name"], c["engines"][1]["name"]); break' "$mb4/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$mb4_caps" == "claude-code claude-code codex" ]]; then
  pass "engine order: capabilities.engine=claude-code, engines=[claude-code, codex]"
else
  fail "engine order" "caps='$mb4_caps'"
fi
rm -rf "$mb4"

echo "=== Case M3-01b-5: expired codex limit → claim with codex, entry cleared, set_computer_limit(until=null) ==="
mb5="$(mktemp -d)"
c21_setup "$mb5" $((MOCK_PORT_BASE + 953)) harness-3step '[{"id":"o1"}]'
python3 -c '
import json,sys,datetime
t=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"codex":{"until":t}}, open(sys.argv[1],"w"))' "$mb5/cr-state/engine-limits.json"
c21_worker "$mb5" $((MOCK_PORT_BASE + 953)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb5_engine="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order": print(d["args"]["capabilities"]["engine"]); break' "$mb5/mockstate/calls.jsonl" 2>/dev/null)"
mb5_file="$(python3 -c 'import json,sys; print("codex" if "codex" in json.load(open(sys.argv[1])) else "clear")' "$mb5/cr-state/engine-limits.json" 2>/dev/null)"
mb5_ev="$(c21_events_for "$mb5/control/reports.ndjson" o1)"
mb5_null="$(m3b_calls_of "$mb5" set_computer_limit | grep -c '"until": null' || true)"
if [[ "$mb5_engine" == "codex" && "$mb5_file" == "clear" && "$mb5_ev" == *"attempt_completed:-"* && "$mb5_null" -ge 1 ]]; then
  pass "expired limit: claimed with codex, engine-limits.json cleared, set_computer_limit(until=null), attempt completed"
else
  fail "expired limit" "engine=$mb5_engine file=$mb5_file ev='$mb5_ev' limit_calls='$(m3b_calls_of "$mb5" set_computer_limit)'"
fi
rm -rf "$mb5"

echo "=== Case M3-01b-6: status.json now shows the running step, empty afterwards ==="
mb6="$(mktemp -d)"
c21_setup "$mb6" $((MOCK_PORT_BASE + 954)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb6" $((MOCK_PORT_BASE + 954)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=1 FAKE_ENGINE_SLEEP=3 &
mb6_w=$!
mb6_req=""
for _ in $(seq 1 120); do mb6_req="$(m3_status "$mb6" '" ".join("%s/%s/%s" % (r["step"], r["steps"], r["stepLabel"]) for r in d["now"])')"; [[ -n "$mb6_req" ]] && break; sleep 0.1; done
mb6_after="x"
for _ in $(seq 1 200); do mb6_after="$(m3_status "$mb6" 'len(d["now"])')"; [[ "$mb6_after" == "0" ]] && grep -q '"event": "attempt_completed"' "$mb6/control/reports.ndjson" 2>/dev/null && break; sleep 0.1; done
pkill -P "$mb6_w" 2>/dev/null; kill "$mb6_w" 2>/dev/null; wait "$mb6_w" 2>/dev/null
pkill -f "cfw-render.sh --loop" 2>/dev/null || true
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb6_want="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); s=[x for x in m["steps"] if x.get("runsOn","computer")=="computer"]; print("1/%d/%s" % (len(s), s[0].get("label")))' "$REPO_DIR/test/fixtures/manifests/harness-3step/manifest.json")"
if [[ "$mb6_req" == "$mb6_want"* && "$mb6_after" == "0" && "$(m3_status "$mb6" 'd["activeEngine"]')" == "codex" ]]; then
  pass "status now: '$mb6_req' while running, empty after; activeEngine=codex"
else
  fail "status now" "during='$mb6_req' after=$mb6_after status=$(head -c 400 "$mb6/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mb6"
echo "=== Case M3-07b-1: release.sh dry run writes toolchain-manifest.json with matching sha256 + versioned urls ==="
m7b_d="$(mktemp -d)"
m7b_ver="$(python3 -c 'import json;print(json.load(open("'"$REPO_DIR"'/toolchain/manifest.json"))["version"])')"
printf 'fake-arm\n' >"$m7b_d/cfw-toolchain-$m7b_ver-arm64.tar.zst"
printf 'fake-x86 longer\n' >"$m7b_d/cfw-toolchain-$m7b_ver-x86_64.tar.zst"
m7b_out="$(CFW_RELEASE_DRY_RUN=1 "$REPO_DIR/toolchain/scripts/release.sh" "$m7b_d" 2>&1)" && m7b_rc=0 || m7b_rc=$?
m7b_want_a="$(shasum -a 256 "$m7b_d/cfw-toolchain-$m7b_ver-arm64.tar.zst" | awk '{print $1}')"
m7b_want_x="$(shasum -a 256 "$m7b_d/cfw-toolchain-$m7b_ver-x86_64.tar.zst" | awk '{print $1}')"
m7b_chk="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); a=d["archives"]
ok = a["arm64"]["sha256"]==sys.argv[2] and a["x86_64"]["sha256"]==sys.argv[3] \
  and ("/toolchain/%s/" % d["version"]) in a["arm64"]["url"] and ("/toolchain/%s/" % d["version"]) in a["x86_64"]["url"] \
  and a["x86_64"]["sizeBytes"]==16 and d.get("publishedAt") and d.get("minAppVersion")
print("ok" if ok else "bad")' "$m7b_d/toolchain-manifest.json" "$m7b_want_a" "$m7b_want_x" 2>&1)"
if [[ "$m7b_rc" == "0" && "$m7b_chk" == "ok" && "$m7b_out" == *"DRY: aws s3 cp"*"toolchain/manifest.json"* ]]; then
  pass "M3-07b-1: release.sh dry run → manifest sha256/url/size correct, aws commands printed"
else
  fail "M3-07b-1" "rc=$m7b_rc chk=$m7b_chk out=$m7b_out"
fi
rm -rf "$m7b_d"

echo "=== Case M3-07b-2: build.sh refuses TODO-* sha256 pins unless CFW_TOOLCHAIN_ALLOW_UNPINNED=1 ==="
m7b_t="$(mktemp -d)"
cat >"$m7b_t/manifest.json" <<'JSON'
{"version":"0.0.0-test","minAppVersion":"1.0.0","tools":[
 {"name":"node","version":"1","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
 {"name":"zzz-unpinned-tool","version":"1","sha256":"TODO-fill-from-first-build"}]}
JSON
m7b_out="$(
  unset CFW_TOOLCHAIN_ALLOW_UNPINNED
  CFW_TOOLCHAIN_MANIFEST="$m7b_t/manifest.json" "$REPO_DIR/toolchain/scripts/build.sh" arm64 "$m7b_t/dist" 2>&1
)" && m7b_rc=0 || m7b_rc=$?
if [[ "$m7b_rc" != "0" && "$m7b_out" == *"unpinned"* && "$m7b_out" == *"zzz-unpinned-tool"* && "$m7b_out" != *"fetch:"* ]]; then
  pass "M3-07b-2: unpinned tool → exit $m7b_rc, message names zzz-unpinned-tool, nothing fetched"
else
  fail "M3-07b-2" "rc=$m7b_rc out=$m7b_out"
fi
rm -rf "$m7b_t"

echo "=== Case M3-07b-3: manifest.json parses; tc_arch_triple maps arm64/x86_64 ==="
m7b_tr="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/toolchain/scripts/lib.sh"
  printf '%s %s' "$(tc_arch_triple arm64)" "$(tc_arch_triple x86_64)"
)"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$REPO_DIR/toolchain/manifest.json" \
   && [[ "$m7b_tr" == "aarch64-apple-darwin x86_64-apple-darwin" ]]; then
  pass "M3-07b-3: manifest valid JSON; triples = $m7b_tr"
else
  fail "M3-07b-3" "triples=$m7b_tr"
fi

echo "=== Case M3-01c-1: status.json has exactly the contract keys; engines labelled; activeEngine null for none ==="
mc1="$(mktemp -d)"
c21_setup "$mc1" $((MOCK_PORT_BASE + 960)) harness-3step '[]'
c21_worker "$mc1" $((MOCK_PORT_BASE + 960)) --once CFW_RENDER_ENGINE=none CFW_RENDER_COMPUTER_NAME="Test Mac"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc1_keys="$(m3_status "$mc1" '",".join(sorted(d))')"
mc1_want="$(python3 -c 'print(",".join(sorted("schema workerVersion engines activeEngine computer brands now next recent lastCheckAt lastError".split())))')"
mc1_eng="$(m3_status "$mc1" 'all("label" in e and e["auth"] == "signin" for e in d["engines"])')"
mc1_rest="$(m3_status "$mc1" '(d["schema"], d["activeEngine"], d["computer"]["name"], d["next"])')"
if [[ "$mc1_keys" == "$mc1_want" && "$mc1_eng" == "True" && "$mc1_rest" == "(1, None, 'Test Mac', [])" ]]; then
  pass "status contract: keys exact, schema 1, engines labelled, activeEngine null"
else
  fail "status contract" "keys=$mc1_keys eng=$mc1_eng rest=$mc1_rest"
fi
rm -rf "$mc1"

echo "=== Case M3-01c-2: claim reply computerBrands → status brands ==="
mc2="$(mktemp -d)"
c21_setup "$mc2" $((MOCK_PORT_BASE + 961)) harness-3step '[]' 'CFW_MOCK_COMPUTER_BRANDS=[{"id":"b1","name":"Brand A"}]'
c21_worker "$mc2" $((MOCK_PORT_BASE + 961)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc2_b="$(m3_status "$mc2" 'd["brands"] == [{"id": "b1", "name": "Brand A", "serving": True}]')"
if [[ "$mc2_b" == "True" ]]; then
  pass "status brands from computerBrands"
else
  fail "status brands" "status=$(head -c 400 "$mc2/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mc2"

echo "=== Case M3-01c-3: a completed order lands in status recent ==="
mc3="$(mktemp -d)"
c21_setup "$mc3" $((MOCK_PORT_BASE + 962)) harness-3step '[{"id":"o1"}]' 'CFW_MOCK_ORDER_EXTRA={"shortCode":"R-TEST","brandName":"Brand A"}'
c21_worker "$mc3" $((MOCK_PORT_BASE + 962)) --once
c21_worker "$mc3" $((MOCK_PORT_BASE + 962)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc3_r="$(m3_status "$mc3" 'sorted(d["recent"][0]) == ["brand","finishedAt","result","shortCode"] and (d["recent"][0]["shortCode"], d["recent"][0]["brand"], d["recent"][0]["result"]) == ("R-TEST","Brand A","done") and d["recent"][0]["finishedAt"].endswith("Z")')"
if [[ "$mc3_r" == "True" ]]; then
  pass "status recent: R-TEST / Brand A / done"
else
  fail "status recent" "status=$(head -c 600 "$mc3/cr-state/status.json" 2>/dev/null) ndjson=$(cat "$mc3/cr-state/recent.ndjson" 2>/dev/null)"
fi
rm -rf "$mc3"

echo "=== Case M3-01c-4: status.json never holds the worker key or the word token ==="
mc4="$(mktemp -d)"
# A well-formed key (the worker refuses any other shape) with a random tail,
# built at runtime so this file holds nothing key-like.
mc4_key="cfw_render_m3probe$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
c21_setup "$mc4" $((MOCK_PORT_BASE + 963)) harness-3step '[{"id":"o1"}]'
c21_worker "$mc4" $((MOCK_PORT_BASE + 963)) --once CFW_RENDER_WORKER_KEY="$mc4_key"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc4_claims="$(grep -c '"tool": "claim_render_order"' "$mc4/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$mc4_claims" -ge 1 && -f "$mc4/cr-state/status.json" ]] && ! grep -q "$mc4_key" "$mc4/cr-state/status.json" && ! grep -qi 'token' "$mc4/cr-state/status.json"; then
  pass "status.json holds no key or token (worker ran: $mc4_claims claim(s))"
else
  fail "status secrets" "claims=$mc4_claims status=$(head -c 400 "$mc4/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mc4"

# ── M3-04a: install.sh --from-app (app-driven, no prompts, JSON steps) ──
m4_real_home="$HOME"
# m4_setup <dir> <port> [mock KEY=VALUE...] — temp HOME + mock server.
m4_setup() {
  local dir="$1" port="$2"; shift 2
  mkdir -p "$dir/home" "$dir/prefix" "$dir/mockstate"
  echo '[]' > "$dir/queue.json"
  m4_pid="$(
    for kv in "$@"; do export "${kv?}"; done
    start_mock "$dir/queue.json" "$dir/mockstate" "$port"
  )"
}
# m4_run <dir> <port> <stdin-file> [KEY=VALUE...] — sets m4_rc.
m4_run() {
  local dir="$1" port="$2" in="$3"; shift 3
  (
    export HOME="$dir/home"
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export PLAYWRIGHT_BROWSERS_PATH="$m4_real_home/Library/Caches/ms-playwright"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_SKIP_LAUNCHCTL=1 CFW_RENDER_PROBE_POLL_SEC=0.1
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/install/install.sh" --mode byoa --non-interactive --from-app --prefix "$dir/prefix" \
      < "$in" > "$dir/out.jsonl" 2> "$dir/err.log"
  )
  m4_rc=$?
}
m4_steps() { python3 -c '
import json, sys
print(" ".join(f"{(o:=json.loads(l))["step"]}:{o["state"]}" for l in open(sys.argv[1]) if l.strip()))' "$1/out.jsonl" 2>/dev/null || echo "NONJSON"; }

echo "=== Case M3-04a-1/2: --from-app happy path; brand key never leaks ==="
m4a="$(mktemp -d)"
m4a_key="cfw_m4brand$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
printf '%s\n' "$m4a_key" > "$m4a/stdin"
m4_setup "$m4a" $((MOCK_PORT_BASE + 970))
( for _ in $(seq 1 600); do ps -axo args 2>/dev/null; sleep 0.05; done ) > "$m4a/ps.log" 2>/dev/null &
m4a_ps=$!
m4_run "$m4a" $((MOCK_PORT_BASE + 970)) "$m4a/stdin"
kill "$m4a_ps" 2>/dev/null; wait "$m4a_ps" 2>/dev/null || true
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
rm -f "$m4a/stdin"
m4a_steps="$(m4_steps "$m4a")"
m4a_want="checking:started checking:done installing:started installing:done connecting:started connecting:done test_render:started test_render:done ready:done"
m4a_envf="$m4a/home/.cfw-render/cfw-render.env"
m4a_mode="$(stat -f '%Lp' "$m4a_envf" 2>/dev/null || stat -c '%a' "$m4a_envf" 2>/dev/null)"
m4a_origin="$(python3 -c '
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
r = [x for x in c if x["tool"] == "report_byoa_setup_step"]
steps = [x["args"]["step"] for x in r]
print(all(x["args"].get("origin") == "app" for x in r), steps[:3], steps.count("probe_render"),
      sum(1 for x in c if x["tool"] == "create_probe_render_order"))' "$m4a/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$m4_rc" == "0" && "$m4a_steps" == "$m4a_want" ]]; then
  pass "from-app: exit 0, stdout only JSON, steps in order with started+done"
else
  fail "from-app happy path" "rc=$m4_rc steps=$m4a_steps err=$(tail -15 "$m4a/err.log")"
fi
if grep -q '^CFW_RENDER_WORKER_KEY=cfw_render_mockexchanged000$' "$m4a_envf" 2>/dev/null && [[ "$m4a_mode" == "600" ]]; then
  pass "from-app: env file holds the exchanged render key, mode 600"
else
  fail "from-app env file" "mode=$m4a_mode"
fi
if [[ "$m4a_origin" == "True ['deps', 'credential', 'recipe_fetch'] 3 1" ]]; then
  pass "from-app: setup reports carry origin app; probe polled until ready"
else
  fail "from-app reports" "$m4a_origin"
fi
m4a_ps_lines="$(wc -l < "$m4a/ps.log" | tr -d ' ')"
if ! grep -rqF "$m4a_key" "$m4a/out.jsonl" "$m4a/err.log" "$m4a/home" "$m4a/prefix" "$m4a/mockstate" "$m4a/mock-server.log" "$m4a/ps.log" 2>/dev/null \
   && [[ "$m4a_ps_lines" -gt 0 ]]; then
  pass "from-app: brand key nowhere (stdout, stderr, HOME, mock log, argv over $m4a_ps_lines ps lines)"
else
  fail "from-app brand key leak" "$(grep -rlF "$m4a_key" "$m4a" 2>/dev/null)"
fi
rm -rf "$m4a"

echo "=== Case M3-04a-3: bad key → connecting failed, exit 5, no key written ==="
m4b="$(mktemp -d)"
printf 'cfw_bad\n' > "$m4b/stdin"
m4_setup "$m4b" $((MOCK_PORT_BASE + 971))
m4_run "$m4b" $((MOCK_PORT_BASE + 971)) "$m4b/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4b_steps="$(m4_steps "$m4b")"
if [[ "$m4_rc" == "5" && "$m4b_steps" == *"connecting:failed" ]] && ! grep -q 'CFW_RENDER_WORKER_KEY=' "$m4b/home/.cfw-render/cfw-render.env" 2>/dev/null; then
  pass "from-app: bad key → connecting failed, exit 5, no key written"
else
  fail "from-app bad key" "rc=$m4_rc steps=$m4b_steps"
fi
rm -rf "$m4b"

echo "=== Case M3-04a-4: no engine → checking failed, exit 3, AI Providers action ==="
m4c="$(mktemp -d)"
printf 'cfw_goodkey\n' > "$m4c/stdin"
m4_setup "$m4c" $((MOCK_PORT_BASE + 972))
m4_run "$m4c" $((MOCK_PORT_BASE + 972)) "$m4c/stdin" CFW_RENDER_TEST_NO_ENGINE=1
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
if [[ "$m4_rc" == "3" ]] && grep -q '"step": "checking", "state": "failed".*"action": "Sign in to ChatGPT or Claude in AI Providers"' "$m4c/out.jsonl"; then
  pass "from-app: no engine → exit 3 with the AI Providers action"
else
  fail "from-app no engine" "rc=$m4_rc out=$(cat "$m4c/out.jsonl")"
fi
rm -rf "$m4c"

echo "=== Case M3-04a-5: adopt — existing key + plist, empty stdin → Already set up ==="
m4d="$(mktemp -d)"
m4_setup "$m4d" $((MOCK_PORT_BASE + 973))
mkdir -p "$m4d/home/.cfw-render" "$m4d/home/Library/LaunchAgents"
printf 'CFW_API_BASE=http://127.0.0.1:%s\nCFW_RENDER_WORKER_KEY=cfw_render_existing0\n' $((MOCK_PORT_BASE + 973)) > "$m4d/home/.cfw-render/cfw-render.env"
: > "$m4d/home/Library/LaunchAgents/com.cfw.render.plist"
: > "$m4d/stdin"
m4_run "$m4d" $((MOCK_PORT_BASE + 973)) "$m4d/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4d_ready="$(grep -c '"step": "ready", "state": "done", "message": "Already set up"' "$m4d/out.jsonl" 2>/dev/null || true)"
if [[ "$m4_rc" == "0" && "$m4d_ready" == "1" ]] && ! grep -q '"tool": "exchange"' "$m4d/mockstate/calls.jsonl" 2>/dev/null; then
  pass "from-app adopt: one ready 'Already set up', no exchange"
else
  fail "from-app adopt" "rc=$m4_rc out=$(cat "$m4d/out.jsonl") err=$(tail -5 "$m4d/err.log")"
fi
rm -rf "$m4d"

echo "=== Case M3-04a-6: probe never finishes → test_render failed, exit 7 ==="
m4e="$(mktemp -d)"
printf 'cfw_goodkey\n' > "$m4e/stdin"
m4_setup "$m4e" $((MOCK_PORT_BASE + 974)) CFW_MOCK_PROBE_PENDING=999
m4_run "$m4e" $((MOCK_PORT_BASE + 974)) "$m4e/stdin" CFW_RENDER_PROBE_TIMEOUT_SEC=1
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4e_steps="$(m4_steps "$m4e")"
if [[ "$m4_rc" == "7" && "$m4e_steps" == *"test_render:started test_render:failed" ]]; then
  pass "from-app: probe timeout → test_render failed, exit 7"
else
  fail "from-app probe timeout" "rc=$m4_rc steps=$m4e_steps"
fi
rm -rf "$m4e"

# ── [M3-06a] uninstall + send-logs ─────────────────────────────────────────
# m6_setup <dir> — a fake installed HOME with a render key, logs, outputs and
# a Keychain stub (CFW_RENDER_SECURITY_CMD) holding 3 items.
m6_setup() {
  local d="$1" key="$2"
  mkdir -p "$d/home/.cfw-render" "$d/home/CFW Render/app/bin" "$d/home/CFW Render/logs/runs" \
    "$d/home/CFW Render/outputs/brand" "$d/home/Library/LaunchAgents" "$d/mockstate"
  printf 'CFW_RENDER_MODE=byoa\nCFW_RENDER_WORKER_KEY=%s\nCFW_API_BASE=http://127.0.0.1:1\n' "$key" > "$d/home/.cfw-render/cfw-render.env"
  chmod 600 "$d/home/.cfw-render/cfw-render.env"
  echo '<plist/>' > "$d/home/Library/LaunchAgents/com.cfw.render.plist"
  echo 'kept' > "$d/home/CFW Render/outputs/brand/out.mp4"
  printf 'tick ok key=%s mail me@example.com /Users/alice/x\n' "$key" > "$d/home/CFW Render/logs/cfw-render.log"
  printf 'run %s\n' "$key" > "$d/home/CFW Render/logs/runs/o1.out"
  printf '{"workerVersion":"1"}\n' > "$d/home/.cfw-render/status.json"
  printf 'ts\torder\t%s\n' "$key" > "$d/home/.cfw-render/journal.tsv"
  echo 3 > "$d/keychain"
  cat > "$d/security" <<SEC
#!/usr/bin/env bash
n=\$(cat "$d/keychain"); (( n > 0 )) || exit 44
echo \$((n - 1)) > "$d/keychain"
SEC
  chmod +x "$d/security"
  echo '[]' > "$d/queue.json"
}
# m6_uninstall <dir> <port> [flags...] — sets m6_rc.
m6_uninstall() {
  local d="$1" port="$2"; shift 2
  ( export HOME="$d/home" CFW_RENDER_API_BASE="http://127.0.0.1:$port" CFW_RENDER_SKIP_LAUNCHCTL=1 \
      CFW_RENDER_SECURITY_CMD="$d/security"
    "$REPO_DIR/install/install.sh" --uninstall "$@" > "$d/out.log" 2> "$d/err.log" )
  m6_rc=$?
}

echo "=== Case M3-06a-1: uninstall happy path (outputs kept, revoke once, Keychain emptied) ==="
m6a="$(mktemp -d)"; m6_setup "$m6a" cfw_render_m6akey000
m6a_port=$((MOCK_PORT_BASE + 980))
m6a_pid="$(start_mock "$m6a/queue.json" "$m6a/mockstate" "$m6a_port")"
m6_uninstall "$m6a" "$m6a_port" --yes
kill "$m6a_pid" 2>/dev/null; wait "$m6a_pid" 2>/dev/null || true
m6a_revokes="$(grep -c '"tool": "revoke_this_computer"' "$m6a/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$m6_rc" == "0" && "$m6a_revokes" == "1" && "$(cat "$m6a/keychain")" == "0" \
      && ! -e "$m6a/home/.cfw-render" && ! -e "$m6a/home/CFW Render/app" && ! -e "$m6a/home/CFW Render/logs" \
      && ! -e "$m6a/home/Library/LaunchAgents/com.cfw.render.plist" && -f "$m6a/home/CFW Render/outputs/brand/out.mp4" ]] \
   && ! grep -q "offline" "$m6a/out.log"; then
  pass "uninstall: paths gone, outputs kept, revoke called once, Keychain stub emptied"
else
  fail "uninstall happy path" "rc=$m6_rc revokes=$m6a_revokes kc=$(cat "$m6a/keychain") out=$(cat "$m6a/out.log")"
fi
rm -rf "$m6a"

echo "=== Case M3-06a-2: uninstall --delete-outputs (+ --from-app JSON lines) ==="
m6b="$(mktemp -d)"; m6_setup "$m6b" cfw_render_m6bkey000
m6b_port=$((MOCK_PORT_BASE + 981))
m6b_pid="$(start_mock "$m6b/queue.json" "$m6b/mockstate" "$m6b_port")"
m6_uninstall "$m6b" "$m6b_port" --non-interactive --from-app --delete-outputs
kill "$m6b_pid" 2>/dev/null; wait "$m6b_pid" 2>/dev/null || true
m6b_json="$(python3 -c '
import json, sys
ls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(all(o["step"] == "uninstall" for o in ls), ls[-1]["state"] if ls else "")' "$m6b/out.log" 2>/dev/null || echo NONJSON)"
if [[ "$m6_rc" == "0" && ! -e "$m6b/home/CFW Render/outputs" && "$m6b_json" == "True done" ]]; then
  pass "uninstall --delete-outputs: outputs gone; --from-app prints only uninstall JSON lines"
else
  fail "uninstall --delete-outputs" "rc=$m6_rc json=$m6b_json"
fi
rm -rf "$m6b"

echo "=== Case M3-06a-3: uninstall offline → exit 0 with the offline line ==="
m6c="$(mktemp -d)"; m6_setup "$m6c" cfw_render_m6ckey000
m6_uninstall "$m6c" $((MOCK_PORT_BASE + 982)) --yes
if [[ "$m6_rc" == "0" && ! -e "$m6c/home/.cfw-render" ]] \
   && grep -q "This computer will show as offline in CFW until you remove it there." "$m6c/out.log"; then
  pass "uninstall offline: exit 0, offline line printed, files removed"
else
  fail "uninstall offline" "rc=$m6_rc out=$(cat "$m6c/out.log")"
fi
rm -rf "$m6c"

echo "=== Case M3-06a-3b: uninstall refuses a CFW_RENDER_HOME outside the home folder (rm -rf guard) ==="
m6g="$(mktemp -d)"; m6_setup "$m6g" cfw_render_m6gkey000
mkdir -p "$m6g/elsewhere/app" "$m6g/elsewhere/logs"
: > "$m6g/elsewhere/app/keep.txt"
( export HOME="$m6g/home" CFW_RENDER_HOME="$m6g/elsewhere" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 985))" \
    CFW_RENDER_SKIP_LAUNCHCTL=1 CFW_RENDER_SECURITY_CMD="$m6g/security"
  "$REPO_DIR/install/install.sh" --uninstall --yes > "$m6g/out.log" 2> "$m6g/err.log" )
m6g_rc=$?
if [[ "$m6g_rc" != "0" && -f "$m6g/elsewhere/app/keep.txt" && -d "$m6g/home/.cfw-render" ]] \
   && grep -q "Not removing files" "$m6g/out.log" "$m6g/err.log"; then
  pass "uninstall guard: a CFW_RENDER_HOME outside HOME is refused, nothing deleted, non-zero exit"
else
  fail "uninstall guard" "rc=$m6g_rc keep=$([[ -f "$m6g/elsewhere/app/keep.txt" ]] && echo yes || echo no) out=$(cat "$m6g/out.log" "$m6g/err.log")"
fi
rm -rf "$m6g"

echo "=== Case M3-06a-4: redactor fixture parity ==="
if diff <(python3 "$REPO_DIR/bin/cfw-render-redact.py" < "$REPO_DIR/desktop/src-tauri/tests/fixtures/redact-input.txt") \
     "$REPO_DIR/desktop/src-tauri/tests/fixtures/redact-expected.txt" >/dev/null; then
  pass "cfw-render-redact.py output == redact-expected.txt"
else
  fail "redactor parity" "diff vs redact-expected.txt"
fi

echo "=== Case M3-06a-5: send-logs uploads, LOG-TEST, render key never leaks ==="
m6e="$(mktemp -d)"
m6e_key="cfw_render_m6e$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
m6_setup "$m6e" "$m6e_key"
m6e_port=$((MOCK_PORT_BASE + 983))
m6e_pid="$(start_mock "$m6e/queue.json" "$m6e/mockstate" "$m6e_port")"
( for _ in $(seq 1 200); do ps -axo args 2>/dev/null; sleep 0.05; done ) > "$m6e/ps.log" 2>/dev/null &
m6e_ps=$!
( export HOME="$m6e/home" CFW_RENDER_API_BASE="http://127.0.0.1:$m6e_port"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --yes > "$m6e/out.log" 2> "$m6e/err.log" )
m6e_rc=$?
kill "$m6e_ps" 2>/dev/null; wait "$m6e_ps" 2>/dev/null || true
kill "$m6e_pid" 2>/dev/null; wait "$m6e_pid" 2>/dev/null || true
mkdir -p "$m6e/x"; tar -xzf "$m6e/mockstate/logs-upload.gz" -C "$m6e/x" 2>/dev/null
if [[ "$m6e_rc" == "0" ]] && grep -q "Reference: LOG-TEST — quote it to CFW support." "$m6e/out.log" \
   && [[ -f "$m6e/x/bundle/logs/cfw-render.log" && -f "$m6e/x/bundle/logs/runs/o1.out" && -f "$m6e/x/bundle/journal.tsv" ]]; then
  pass "send-logs: bundle uploaded (logs, runs, journal), Reference LOG-TEST printed"
else
  fail "send-logs upload" "rc=$m6e_rc out=$(cat "$m6e/out.log") err=$(cat "$m6e/err.log")"
fi
m6e_ps_lines="$(wc -l < "$m6e/ps.log" | tr -d ' ')"
if ! grep -rqF "$m6e_key" "$m6e/x" "$m6e/out.log" "$m6e/err.log" "$m6e/ps.log" "$m6e/mockstate" \
   && grep -q "cfw_render_\[redacted\]" "$m6e/x/bundle/logs/cfw-render.log" && grep -q "/Users/\[user\]/" "$m6e/x/bundle/logs/cfw-render.log"; then
  pass "send-logs: render key nowhere (bundle, stdout, stderr, mock log, argv over $m6e_ps_lines ps lines)"
else
  fail "send-logs key leak" "key found or bundle not redacted"
fi
rm -rf "$m6e"

echo "=== Case M3-06a-6: send-logs --dry writes the bundle path, no upload; server down → non-zero ==="
m6f="$(mktemp -d)"; m6_setup "$m6f" cfw_render_m6fkey000
( export HOME="$m6f/home" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 984))" TMPDIR="$m6f"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --dry > "$m6f/dry.log" 2>&1 )
m6f_dry=$?
m6f_path="$(sed -n 's/^path: //p' "$m6f/dry.log")"
( export HOME="$m6f/home" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 984))"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --yes > "$m6f/up.log" 2>&1 )
m6f_up=$?
if [[ "$m6f_dry" == "0" && -s "$m6f_path" && "$m6f_up" != "0" ]] && grep -q "could not reach CFW" "$m6f/up.log"; then
  pass "send-logs --dry: path written, nothing sent; offline upload exits non-zero with a plain message"
else
  fail "send-logs dry/offline" "dry=$m6f_dry path=$m6f_path up=$m6f_up $(cat "$m6f/up.log")"
fi
rm -rf "$m6f"

# ===========================================================================
# [M3-08b] more engines: gemini + API-key providers, credit limits
# ===========================================================================
# m8_keychain <dir> <engine=key>... — a `security` stub; items live in <dir>/kc/<account>.
m8_keychain() {
  local d="$1"; shift
  mkdir -p "$d/kc"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$d/kc/${kv%%=*}"; done
  cat > "$d/security" <<SEC
#!/usr/bin/env bash
acct=""; w=0
while (( \$# )); do case "\$1" in -a) acct="\$2"; shift ;; -w) w=1 ;; esac; shift; done
[[ -n "\$acct" && -f "$d/kc/\$acct" ]] || exit 44
(( w )) && cat "$d/kc/\$acct"
exit 0
SEC
  chmod +x "$d/security"
}
m8_json() { CFW_RENDER_STATE_DIR="$1/cr-state" CFW_RENDER_SECURITY_CMD="$1/security" CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh" \
  bash -c 'cr_log(){ :; }; source "$1/bin/cfw-render-engine.sh"; cr_engines_json' _ "$REPO_DIR"; }

echo "=== Case M3-08b-1: cr_engines_json lists 8 engines with label/auth; Keychain zai item → only zai (of the key engines) signed in ==="
m8a="$(mktemp -d)"; mkdir -p "$m8a/cr-state"; m8_keychain "$m8a" zai=k-zai-000
m8a_out="$(m8_json "$m8a" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join("%s/%s/%s/%s" % (e["name"], e["label"], e["auth"], "Y" if e["signedIn"] else "n") for e in d))')"
m8a_want="codex/ChatGPT/signin/Y claude-code/Claude/signin/Y gemini/Gemini/api_key/n zai/Z.AI/api_key/Y moonshot/Moonshot/api_key/n minimax/MiniMax/api_key/n xai/xAI/api_key/n openrouter/OpenRouter/api_key/n"
if [[ "$m8a_out" == "$m8a_want" ]]; then
  pass "engines json: 8 engines, labels + auth, zai signedIn via Keychain only"
else
  fail "engines json" "got '$m8a_out'"
fi
rm -rf "$m8a"

echo "=== Case M3-08b-2: step on zai → temp CODEX_HOME under the request, key only in engine env, ~/.codex untouched ==="
m8b="$(mktemp -d)"; m8b_key="zai-secret-$RANDOM-$RANDOM"
m8_keychain "$m8b" "zai=$m8b_key"
mkdir -p "$m8b/home/.codex"; echo planted > "$m8b/home/.codex/marker"
# The fake HOME hides the real Playwright cache from preflight: point at it.
m8b_pw="${PLAYWRIGHT_BROWSERS_PATH:-}"
for r in "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/ms-playwright"; do [[ -z "$m8b_pw" && -d "$r" ]] && m8b_pw="$r"; done
c21_setup "$m8b" $((MOCK_PORT_BASE + 990)) harness-3step '[{"id":"o1"}]'
c21_worker "$m8b" $((MOCK_PORT_BASE + 990)) --once CFW_RENDER_ENGINE=zai CFW_RENDER_SECURITY_CMD="$m8b/security" \
  FAKE_ENGINE_DUMP_DIR="$m8b/dump" HOME="$m8b/home" PLAYWRIGHT_BROWSERS_PATH="$m8b_pw"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8b_ev="$(c21_events_for "$m8b/control/reports.ndjson" o1)"
m8b_ch="$(cat "$m8b/dump/zai.codexhome" 2>/dev/null)"
m8b_ok=1; m8b_why=""
[[ "$m8b_ev" == *"attempt_completed:-"* ]] || { m8b_ok=0; m8b_why+=" not-completed"; }
[[ "$m8b_ch" == "$m8b/cr-scratch/"*"/.codex-home-zai" ]] || { m8b_ok=0; m8b_why+=" codexhome=$m8b_ch"; }
[[ -n "$m8b_ch" && ! -e "$m8b_ch" ]] || { m8b_ok=0; m8b_why+=" codexhome-left"; }
grep -qx 'model_provider = "zai"' "$m8b/dump/zai.config.toml" 2>/dev/null && [[ "$(grep -c '^\[model_providers\.' "$m8b/dump/zai.config.toml")" == 1 ]] || { m8b_ok=0; m8b_why+=" config"; }
grep -qxF "ZAI_API_KEY=$m8b_key" "$m8b/dump/zai.env" 2>/dev/null || { m8b_ok=0; m8b_why+=" key-not-in-env"; }
grep -qF "$m8b_key" "$m8b/dump/zai.argv" 2>/dev/null && { m8b_ok=0; m8b_why+=" key-in-argv"; }
grep -qxF "model_provider=zai" "$m8b/dump/zai.argv" 2>/dev/null || { m8b_ok=0; m8b_why+=" no-c-flag"; }
grep -rqF "$m8b_key" "$m8b/cr-state" "$m8b/worker.out" "$m8b/control" "$m8b/mockstate" 2>/dev/null && { m8b_ok=0; m8b_why+=" key-leaked"; }
[[ "$(cat "$m8b/home/.codex/marker")" == planted && "$(ls -A "$m8b/home/.codex")" == marker ]] || { m8b_ok=0; m8b_why+=" home-codex-touched"; }
if (( m8b_ok )); then
  pass "zai step: CODEX_HOME under request (removed after), one provider table, key only as ZAI_API_KEY in engine env, ~/.codex untouched"
else
  fail "zai step" "$m8b_why ev='$m8b_ev'"
fi
rm -rf "$m8b"

echo "=== Case M3-08b-3: apikey-429 → zai limited ~15 min, step fails over to codex ==="
m8c="$(mktemp -d)"; m8_keychain "$m8c" zai=k-zai-c
c21_setup "$m8c" $((MOCK_PORT_BASE + 991)) harness-3step '[{"id":"o1"}]'
echo '{"order":["zai","codex","claude-code"]}' > "$m8c/cr-state/engines.json"
c21_worker "$m8c" $((MOCK_PORT_BASE + 991)) --once CFW_RENDER_SECURITY_CMD="$m8c/security" FAKE_ENGINE_LIMIT_ENGINE=zai FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8c_started="$(m3b_started "$m8c" o1)"
m8c_min="$(python3 -c '
import json, sys, datetime
u = json.load(open(sys.argv[1]))["zai"]["until"]
t = datetime.datetime.fromisoformat(u.replace("Z", "+00:00"))
print(round((t - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 60))' "$m8c/cr-state/engine-limits.json" 2>/dev/null)"
if [[ "$m8c_started" == "a:zai a:codex "* && "$m8c_min" =~ ^1[45]$ ]]; then
  pass "apikey 429: zai limited ${m8c_min} min, failover a:zai → a:codex"
else
  fail "apikey 429" "started='$m8c_started' min='$m8c_min'"
fi
rm -rf "$m8c"

echo "=== Case M3-08b-4: apikey-credit → limited with resetsAt null + reason credit, never expires, clear-limit clears ==="
m8d="$(mktemp -d)"; m8_keychain "$m8d" zai=k-zai-d
c21_setup "$m8d" $((MOCK_PORT_BASE + 992)) harness-3step '[{"id":"o1"}]'
echo '{"order":["zai","codex","claude-code"]}' > "$m8d/cr-state/engines.json"
c21_worker "$m8d" $((MOCK_PORT_BASE + 992)) --once CFW_RENDER_SECURITY_CMD="$m8d/security" FAKE_ENGINE_LIMIT_ENGINE=zai FAKE_ENGINE_LIMIT_STEP=a FAKE_ENGINE_APIKEY_FIXTURE=credit
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8d_started="$(m3b_started "$m8d" o1)"
m8d_file="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("zai")))' "$m8d/cr-state/engine-limits.json" 2>/dev/null)"
m8d_row="$(m8_json "$m8d" | python3 -c '
import json, sys
e = [x for x in json.load(sys.stdin) if x["name"] == "zai"][0]
print(e["limit"], e.get("resetsAt", "missing"), e.get("reason"))')"
# A credit entry carries no timestamp: plant one with an old timestamp too — still limited.
python3 -c 'import json,sys; json.dump({"zai":{"until":"2000-01-01T00:00:00Z","reason":"credit"}}, open(sys.argv[1],"w"))' "$m8d/cr-state/engine-limits.json"
m8d_old="$(m8_json "$m8d" | python3 -c 'import json,sys; print([x for x in json.load(sys.stdin) if x["name"]=="zai"][0]["limit"])')"
CFW_RENDER_STATE_DIR="$m8d/cr-state" "$REPO_DIR/bin/cfw-render-ctl.sh" clear-limit zai > /dev/null 2>&1; m8d_clr=$?
m8d_after="$(m8_json "$m8d" | python3 -c 'import json,sys; print([x for x in json.load(sys.stdin) if x["name"]=="zai"][0]["limit"])')"
if [[ "$m8d_started" == "a:zai a:codex "* && "$m8d_file" == '{"until": null, "reason": "credit"}' && "$m8d_row" == "limited None credit" \
      && "$m8d_old" == limited && "$m8d_clr" == 0 && "$m8d_after" == ok ]]; then
  pass "apikey credit: {until:null,reason:credit}, limited/resetsAt null, survives old timestamp, clear-limit → ok"
else
  fail "apikey credit" "started='$m8d_started' file='$m8d_file' row='$m8d_row' old=$m8d_old clr=$m8d_clr after=$m8d_after"
fi
rm -rf "$m8d"

echo "=== Case M3-08b-4b: ordinary output that mentions credit, billing, 402 or 429 never trips a limit ==="
m8n="$(mktemp -d)"; mkdir -p "$m8n/st"
cat > "$m8n/ok.log" <<'EOF2'
Added a credit line to the end card: "Photo credit: Priya".
Billing page screenshot cropped; 402 frames rendered at 1080x1920.
Scene 3 of 429 total keyframes encoded.
Done. Captions mention the store credit offer.
EOF2
m8n_out=""
for m8n_eng in zai gemini; do
  if m8n_r="$(m3b_detect "$m8n/st" "$m8n_eng" "$m8n/ok.log" 1)"; then m8n_out+="$m8n_eng:$m8n_r "; fi
done
m8n_credit="$(m3b_detect "$m8n/st" zai "$REPO_DIR/test/fixtures/engine-limits/apikey-credit.txt" 1)"
m8n_429="$(m3b_detect "$m8n/st" zai "$REPO_DIR/test/fixtures/engine-limits/apikey-429.txt" 1)"
m8n_gq="$(m3b_detect "$m8n/st" gemini "$REPO_DIR/test/fixtures/engine-limits/gemini-quota.txt" 1)"
if [[ -z "$m8n_out" && "$m8n_credit" == credit && "$m8n_429" == 20* && "$m8n_gq" == 20* ]]; then
  pass "limit detect: ordinary 'credit'/'billing'/'402'/'429' output trips nothing; real vendor credit/429/quota replies still do"
else
  fail "limit detect false positives" "ordinary=[$m8n_out] credit=[$m8n_credit] 429=[$m8n_429] gemini=[$m8n_gq]"
fi
rm -rf "$m8n"

echo "=== Case M3-08b-5: gemini with a Keychain key → GEMINI_API_KEY only in the gemini process env ==="
m8e="$(mktemp -d)"; m8e_key="gem-secret-$RANDOM-$RANDOM"; m8_keychain "$m8e" "gemini=$m8e_key"
c21_setup "$m8e" $((MOCK_PORT_BASE + 993)) harness-3step '[{"id":"o1"}]'
c21_worker "$m8e" $((MOCK_PORT_BASE + 993)) --once CFW_RENDER_ENGINE=gemini CFW_RENDER_SECURITY_CMD="$m8e/security" FAKE_ENGINE_DUMP_DIR="$m8e/dump"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8e_ev="$(c21_events_for "$m8e/control/reports.ndjson" o1)"
if [[ "$m8e_ev" == *"attempt_completed:-"* ]] && grep -qxF "GEMINI_API_KEY=$m8e_key" "$m8e/dump/gemini.env" \
   && grep -qx -- "-p" "$m8e/dump/gemini.argv" && ! grep -qF "$m8e_key" "$m8e/dump/gemini.argv" \
   && ! grep -rqF "$m8e_key" "$m8e/cr-state" "$m8e/worker.out" "$m8e/control" "$m8e/mockstate"; then
  pass "gemini: -p, key only as GEMINI_API_KEY in the engine env, nowhere else"
else
  fail "gemini key" "ev='$m8e_ev' $(cat "$m8e/dump/gemini.argv" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "$m8e"
# ── M3-05a: desktop release script + install.sh --from-app --update ──
# No mock server needed (ports MOCK_PORT_BASE + 1000..1009 reserved).
echo "=== Case M3-05a-1: release.sh --dry-run with no secrets prints every step with placeholders ==="
r5a="$(mktemp -d)"
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --dry-run > "$r5a/out.log" 2> "$r5a/err.log"
r5a_rc=$?
r5a_ok=1
for want in "+ codesign --force --options runtime --timestamp --sign \\<APPLE_SIGNING_IDENTITY\\> --deep" \
  "+ xcrun notarytool submit" "--key \\<APPLE_API_KEY_PATH\\> --key-id \\<APPLE_API_KEY_ID\\> --issuer \\<APPLE_API_ISSUER\\>" \
  "+ xcrun stapler staple" "+ hdiutil create" "+ pnpm tauri build --target universal-apple-darwin --bundles app" \
  "+ pnpm tauri signer sign" "latest.json"; do
  grep -qF -- "$want" "$r5a/out.log" || { r5a_ok=0; echo "    missing: $want"; }
done
[[ "$(grep -c 'notarytool submit' "$r5a/out.log")" == "2" && "$(grep -c 'stapler staple' "$r5a/out.log")" == "2" ]] || r5a_ok=0
if [[ "$r5a_rc" == "0" && "$r5a_ok" == "1" ]] && ! grep -qF '"$' "$r5a/out.log" && [[ ! -e "$REPO_DIR/desktop/dist-release/latest.json" || "$(git -C "$REPO_DIR" status --porcelain desktop/src-tauri/resources)" == "" ]]; then
  pass "release.sh --dry-run: exit 0, codesign/notarytool/stapler/hdiutil with placeholders, no \"\$ leakage"
else
  fail "release.sh --dry-run" "rc=$r5a_rc ok=$r5a_ok $(head -c 600 "$r5a/err.log")"
fi

echo "=== Case M3-05a-2: release.sh without secrets refuses (exit 2) and names them ==="
env -i PATH="$PATH" HOME="$r5a" APPLE_API_KEY_ID=present-id bash "$REPO_DIR/desktop/scripts/release.sh" > "$r5a/real.log" 2>&1
r5b_rc=$?
r5b_ok=1
for n in APPLE_SIGNING_IDENTITY APPLE_API_KEY_PATH APPLE_API_ISSUER TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD DESKTOP_RELEASE_BASE_URL; do
  grep -q "$n" "$r5a/real.log" || r5b_ok=0
done
if [[ "$r5b_rc" == "2" && "$r5b_ok" == "1" ]] && ! grep -q "APPLE_API_KEY_ID\|present-id\|codesign" "$r5a/real.log"; then
  pass "release.sh without secrets: exit 2, lists only the missing names, runs nothing"
else
  fail "release.sh missing secrets" "rc=$r5b_rc ok=$r5b_ok $(cat "$r5a/real.log")"
fi

echo "=== Case M3-05c-1: release.sh --unsigned --dry-run needs no secrets, ad-hoc signs, never notarizes or writes the feed ==="
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --dry-run > "$r5a/u.log" 2> "$r5a/u.err"
r5c_rc=$?
r5c_ok=1
for want in "UNSIGNED tester build (universal)" "+ cp -a" "+ env APPLE_SIGNING_IDENTITY=- pnpm tauri build --target universal-apple-darwin --bundles app" \
  "+ codesign --force --deep --sign -" "+ codesign --verify --deep --strict" "CFW-Render-" "-unsigned-universal.dmg" "desktop/TESTERS.md"; do
  grep -qF -- "$want" "$r5a/u.log" || { r5c_ok=0; echo "    missing: $want"; }
done
for banned in notarytool stapler "signer sign" "latest.json" "--options runtime" "APPLE_API"; do
  grep -qF -- "$banned" "$r5a/u.log" && { r5c_ok=0; echo "    unexpected: $banned"; }
done
if [[ "$r5c_rc" == "0" && "$r5c_ok" == "1" && ! -s "$r5a/u.err" ]]; then
  pass "release.sh --unsigned --dry-run: exit 0 with no secrets, ad-hoc sign + verify + dmg, no notarize/updater/feed"
else
  fail "release.sh --unsigned --dry-run" "rc=$r5c_rc ok=$r5c_ok $(head -c 600 "$r5a/u.err")"
fi

echo "=== Case M3-05c-2: --target picks the arch for tester builds; bad or signed-mode --target refuses ==="
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --target aarch64-apple-darwin --dry-run > "$r5a/a.log" 2>&1
r5d_rc=$?
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --target 'x;touch pwned' --dry-run > "$r5a/bad.log" 2>&1
r5e_rc=$?
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --target aarch64-apple-darwin --dry-run > "$r5a/signed.log" 2>&1
r5f_rc=$?
if [[ "$r5d_rc" == "0" && "$r5e_rc" == "2" && "$r5f_rc" == "2" ]] \
  && grep -qF -- "--target aarch64-apple-darwin --bundles app" "$r5a/a.log" \
  && grep -qF -- "target/aarch64-apple-darwin/release/bundle/macos" "$r5a/a.log" \
  && grep -qF -- "-unsigned-apple-silicon.dmg" "$r5a/a.log" \
  && grep -q "unsupported --target" "$r5a/bad.log" && ! grep -q "codesign\|hdiutil" "$r5a/bad.log" \
  && grep -q "only for --unsigned" "$r5a/signed.log" && ! grep -q "codesign\|hdiutil" "$r5a/signed.log"; then
  pass "release.sh --target: aarch64 → apple-silicon dmg; unknown target and signed-mode --target exit 2 and run nothing"
else
  fail "release.sh --target" "rc=$r5d_rc/$r5e_rc/$r5f_rc $(head -c 400 "$r5a/bad.log") $(head -c 300 "$r5a/signed.log")"
fi
rm -rf "$r5a"

echo "=== Case M3-05a-3: install.sh --from-app --update refreshes CFW Render/app, prints Updated, reads no stdin ==="
r5c="$(mktemp -d)"
mkdir -p "$r5c/home/CFW Render/app/bin" "$r5c/home/CFW Render/app/config"
printf 'stale\n' > "$r5c/home/CFW Render/app/bin/cfw-render.sh"
printf 'local\n' > "$r5c/home/CFW Render/app/config/local-only.json"
printf 'KEEP-THIS-LINE\n' > "$r5c/stdin"
( export HOME="$r5c/home" CFW_RENDER_SKIP_LAUNCHCTL=1
  { "$REPO_DIR/install/install.sh" --mode byoa --non-interactive --from-app --update > "$r5c/out.jsonl" 2> "$r5c/err.log"
    echo "rc=$?" > "$r5c/rc"; cat > "$r5c/rest"; } < "$r5c/stdin" )
if [[ "$(cat "$r5c/rc")" == "rc=0" && "$(cat "$r5c/out.jsonl")" == '{"step": "ready", "state": "done", "message": "Updated"}' ]] \
   && cmp -s "$REPO_DIR/bin/cfw-render.sh" "$r5c/home/CFW Render/app/bin/cfw-render.sh" \
   && cmp -s "$REPO_DIR/VERSION" "$r5c/home/CFW Render/app/VERSION" \
   && [[ -f "$r5c/home/CFW Render/app/config/local-only.json" && "$(cat "$r5c/rest")" == "KEEP-THIS-LINE" ]]; then
  pass "install.sh --update: changed file refreshed, local config kept, one Updated line, stdin untouched"
else
  fail "install.sh --update" "$(cat "$r5c/rc") out=$(cat "$r5c/out.jsonl") rest=$(cat "$r5c/rest") $(head -c 400 "$r5c/err.log")"
fi
rm -rf "$r5c"

echo "-------------------------------------"
echo "PASS: $PASS_COUNT   FAIL: $FAILURES"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
