#!/usr/bin/env bash
# cta_visible_end: final_checks check, and the end_card_final hard check in acceptance.json.
# Two callers, two argument shapes:
#   the harness   bash checks/cta_visible_end.sh <step workdir>          (exit 0 = pass)
#   the eval gate bash checks/cta_visible_end.sh <final video> [args]    (c-eval-runner "custom";
#                 it runs inside the step workdir, so brief.json, prior/ and inputs/ are in the cwd)
# The video must end on the brand end card: the frame 1 s before the end of the card matches the
# reference still, the frame 14 s earlier does not, and the last frame is not black.
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "${1:-.}" ]; then
  exec python3 "$SKILL_DIR/scripts/end-card.py" verify-final --dir "${1:-.}"
fi
exec python3 "$SKILL_DIR/scripts/end-card.py" verify-final --dir "$PWD" --video "$1"
