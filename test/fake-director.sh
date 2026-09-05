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
  gate-fail)
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    cfw-render-report.sh stage vision-qa 50 "Running QA gate"
    cfw-render-report.sh block "gate: sharpness below floor"
    ;;
  watchdog)
    cfw-render-report.sh stage fetch-assets 10 "Gathering ingredients"
    sleep 60
    ;;
  *)
    echo "fake-director: unknown FAKE_DIRECTOR_MODE '$mode'" >&2
    exit 1
    ;;
esac
