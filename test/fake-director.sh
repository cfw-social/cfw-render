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
    cfw-render-report.sh complete final/out.mp4
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
