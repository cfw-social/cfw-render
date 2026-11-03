#!/usr/bin/env bash
# plan_covers_runtime: plan_broll check. The harness runs `bash checks/<id>.sh <step workdir>`:
# exit 0 = pass, anything else = fail, and the last 400 characters of the output are the reason.
# Rows run from 0 to the duration with no gap or overlap; the LAST row is the end card.
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$SKILL_DIR/scripts/end-card.py" verify-plan --dir "${1:-.}"
