#!/usr/bin/env bash
# fake-director.sh — scripted director for test/run-tests.sh, wired in as
# CFW_RENDER_DIRECTOR_CMD. Runs with CWD = the order's scratch dir and the
# repo bin/ on PATH, exactly like a real Director subprocess. Behavior is
# selected via $FAKE_DIRECTOR_MODE so run-tests.sh can drive every case
# (happy path, gate-fail, watchdog-timeout) with one script.
set -u

mode="${FAKE_DIRECTOR_MODE:-happy}"

case "$mode" in
  happy)
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-subagent.sh glm-5.2 -p "render clip 1" || exit 1
    cfw-render-report.sh stage render-clips 40 "Rendering clips"
    cfw-render-report.sh stage assemble 70 "Assembling"
    cfw-render-report.sh stage grade 85 "Grading"
    cfw-render-report.sh stage vision-qa 95 "Running QA gate"
    mkdir -p final
    echo "fake video bytes" > final/out.mp4
    # CFW-136: a reel delivers its cover.png (poster) + per-platform captions.
    echo "fake cover png" > final/cover.png
    cat > final/captions.json <<'JSON'
{ "Instagram": "Day 14 of 30. The 3 AI tools that survived two weeks of building. #AItools",
  "tiktok": "Day 14 of 30 — the 3 tools that made the cut 👇 #AItools",
  "youtube": "Day 14 of 30: The 3 AI Tools That Survived Two Weeks\nTwo weeks in — Claude, n8n, Opus Clip.",
  "threads": "   " }
JSON
    cfw-render-report.sh complete final/out.mp4 final/cover.png
    ;;
  large)
    # CFW-144: a real-sized reel (6 MiB > the 4.5 MB Vercel body cap) + its
    # cover — only the presigned path can deliver it.
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh stage vision-qa 95 "Running QA gate"
    mkdir -p final
    head -c 6291456 /dev/urandom > final/out.mp4
    echo "fake cover png" > final/cover.png
    cat > final/captions.json <<'JSON'
{ "instagram": "Big reel, small function.", "tiktok": "Big reel, small function.", "youtube": "Big reel, small function.", "threads": "Big reel, small function." }
JSON
    cfw-render-report.sh complete final/out.mp4 final/cover.png
    ;;
  no-captions)
    # CFW-136: a Director that forgot captions.json — the report WARNS, still
    # completes (cfw-social falls back to the order copy/intent), sends NO
    # captions key.
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh stage vision-qa 95 "Running QA gate"
    mkdir -p final
    echo "fake video bytes" > final/out.mp4
    cfw-render-report.sh complete final/out.mp4
    ;;
  carousel)
    # CFW-135: a multi-slide carousel + its LinkedIn PDF — every deliverable in
    # ONE complete call, cover first, PDF last.
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh stage assemble 70 "Plating 3 cards"
    cfw-render-report.sh stage vision-qa 95 "Running QA gate"
    mkdir -p final
    echo "slide 1" > final/slide-1.png
    echo "slide 2" > final/slide-2.png
    echo "slide 3" > final/slide-3.png
    echo "%PDF-1.4 fake" > final/carousel.pdf
    cfw-render-report.sh complete final/slide-1.png final/slide-2.png final/slide-3.png final/carousel.pdf
    ;;
  heartbeat)
    # CFW-146: a slow render — the drainer must pulse `heartbeat` on its own
    # while this Director works, so cfw-social can tell "slow" from "dead".
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    sleep 5
    cfw-render-report.sh stage assemble 70 "Assembling"
    sleep 3
    mkdir -p final
    echo "fake video bytes" > final/out.mp4
    cat > final/captions.json <<'JSON'
{ "instagram": "Slow but steady." }
JSON
    cfw-render-report.sh complete final/out.mp4
    ;;
  needs-ingredient)
    # CFW-146: a block that names WHAT it needs → the owner card offers upload.
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh block "I need a clip of the workspace to cut this" ingredient
    ;;
  gate-fail)
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh stage vision-qa 50 "Running QA gate"
    cfw-render-report.sh block "gate: sharpness below floor"
    ;;
  watchdog)
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    # [CFW-286] Also background a marker-writing straggler, same as a
    # Director that backgrounds a step AND then gets watchdog-killed — proves
    # the group-kill on the watchdog path reaps it too, not just the
    # foreground subshell. Its pid is recorded so run-tests.sh can assert it
    # is no longer alive once the tick completes.
    ( sleep 300; touch watchdog-bg-marker ) &
    echo $! > watchdog-bg.pid
    sleep 60
    ;;
  orphan-just-in-time)
    # [CFW-286] Backgrounds a step that finishes WELL INSIDE the grace window
    # (CFW_RENDER_ORPHAN_GRACE_SECS), then exits 0 immediately without
    # waiting on it — exercises the grace-poll absorbing a near-miss so it
    # still lands outcome=complete instead of a false orphaned/crashed.
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    (
      sleep "${FAKE_DIRECTOR_ORPHAN_SLEEP:-1}"
      mkdir -p final
      echo "fake video bytes" > final/out.mp4
      cat > final/captions.json <<'JSON'
{ "instagram": "Landed just inside the grace window." }
JSON
      cfw-render-report.sh complete final/out.mp4
    ) &
    echo $! > orphan-bg.pid
    exit 0
    ;;
  orphan-late)
    # [CFW-286] Reproduces the bug directly: backgrounds a step that would
    # finish PAST the grace window, then exits 0 immediately — the exact
    # "Director ends its turn with background work still running" sequence.
    # The wrapper's grace window expires, reaps this process group (killing
    # the sleep below before it ever gets to call complete), and reports
    # outcome=orphaned instead of the old opaque "crashed".
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    (
      sleep "${FAKE_DIRECTOR_ORPHAN_SLEEP:-30}"
      mkdir -p final
      echo "fake video bytes" > final/out.mp4
      cfw-render-report.sh complete final/out.mp4
    ) &
    echo $! > orphan-bg.pid
    exit 0
    ;;
  heygen-cred)
    # [CFW-313] Proves the brand-scoped HeyGen credential the gate resolved
    # actually reached the Director's env, under the right names — never
    # HEYGEN_API_KEY. Written to disk, then BLOCKS (rather than completing)
    # so run-tests.sh can inspect the file before the scratch dir is wiped —
    # a completed order's scratch dir is deleted by the drainer right after.
    {
      echo "HEYGEN_OAUTH_TOKEN=${HEYGEN_OAUTH_TOKEN:-}"
      echo "HEYGEN_CREDIT_POOL=${HEYGEN_CREDIT_POOL:-}"
      echo "HEYGEN_TOKEN_EXPIRES_AT=${HEYGEN_TOKEN_EXPIRES_AT:-}"
      echo "HEYGEN_API_KEY=${HEYGEN_API_KEY:-}"
    } > heygen-env.txt
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh block "test probe only — not a real render"
    ;;
  *)
    echo "fake-director: unknown FAKE_DIRECTOR_MODE '$mode'" >&2
    exit 1
    ;;
esac
