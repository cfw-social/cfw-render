#!/usr/bin/env bash
# fake-engine.sh — stands in for codex/claude via CFW_RENDER_ENGINE_CMD.
# Invoked by cr_engine_run with cwd = the step workdir, prompt.md on stdin and
# CFW_RENDER_ENGINE_PROMPT_FILE in env. The harness also exports
#   CFW_STEP_SAVES="<id>:<ext> ..."   CFW_STEP_ID=<stepId>
# which is what this script uses to know which saves/<id>.<ext> to write.
# Knobs:
#   FAKE_ENGINE_FAIL_STEP=<stepId> + FAKE_ENGINE_FAIL_CHECK_TIMES=<n>
#       leave the first save EMPTY for the first n runs of that step
#   FAKE_ENGINE_ASK_STEP=<stepId>
#       write needs_input.json for inputId `broll` the first time that step runs
#   FAKE_ENGINE_LIMIT_ENGINE=<codex|claude-code|all> + FAKE_ENGINE_LIMIT_STEP=<stepId>
#       [M3-01b] when CFW_ENGINE_NAME matches on that step, print the vendor
#       usage-limit fixture and exit 1 without writing saves
#   FAKE_ENGINE_SLEEP=<secs>   sleep before writing saves (status.json requests test)
set -euo pipefail
cat > /dev/null   # consume the prompt
step="${CFW_STEP_ID:-}"
counter=".fake-engine-runs"
runs=0; [[ -f "$counter" ]] && runs="$(cat "$counter")"
runs=$((runs + 1)); printf '%s' "$runs" > "$counter"
echo "fake-engine: step=$step run=$runs saves='${CFW_STEP_SAVES:-}'"
if [[ -n "${FAKE_ENGINE_ASK_STEP:-}" && "$FAKE_ENGINE_ASK_STEP" == "$step" && "$runs" == "1" ]]; then
  printf '{"inputId":"broll","reason":"need b-roll to continue"}' > needs_input.json
  exit 0
fi
if [[ -n "${FAKE_ENGINE_LIMIT_ENGINE:-}" && "${FAKE_ENGINE_LIMIT_STEP:-}" == "$step" ]] \
   && [[ "$FAKE_ENGINE_LIMIT_ENGINE" == "all" || "$FAKE_ENGINE_LIMIT_ENGINE" == "${CFW_ENGINE_NAME:-}" ]]; then
  fx="codex-limit.txt"; [[ "${CFW_ENGINE_NAME:-}" == "claude-code" ]] && fx="claude-limit.txt"
  cat "$(dirname "${BASH_SOURCE[0]}")/fixtures/engine-limits/$fx"
  exit 1
fi
[[ -n "${FAKE_ENGINE_SLEEP:-}" ]] && sleep "$FAKE_ENGINE_SLEEP"
mkdir -p saves
first=1
for sv in ${CFW_STEP_SAVES:-}; do
  f="saves/${sv%%:*}.${sv##*:}"
  if (( first )) && [[ "${FAKE_ENGINE_FAIL_STEP:-}" == "$step" ]] && (( runs <= ${FAKE_ENGINE_FAIL_CHECK_TIMES:-0} )); then
    : > "$f"
  else
    printf 'fake %s bytes for %s run %s\n' "${sv##*:}" "$sv" "$runs" > "$f"
  fi
  first=0
done
exit 0
