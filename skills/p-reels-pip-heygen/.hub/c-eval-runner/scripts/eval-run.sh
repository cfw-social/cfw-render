#!/usr/bin/env bash
# eval-run.sh — thin wrapper around eval_run.py (the engine). Lets recipes call
# the eval gate with the same `bash scripts/...` convention as every other step.
#   bash .hub/c-eval-runner/scripts/eval-run.sh <FILE> --recipe-dir "$SKILL_DIR" [--step NAME] [--brand SLUG]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
exec python3 "$HERE/eval_run.py" "$@"
