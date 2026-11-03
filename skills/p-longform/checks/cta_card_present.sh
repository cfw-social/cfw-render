#!/usr/bin/env bash
# cta_card_present: build_visuals check. The harness runs `bash checks/<id>.sh <step workdir>`:
# exit 0 = pass, anything else = fail, and the last 400 characters of the output are the reason.
# One end card, its words match the brand, a 1920x1080 reference still, no production labels.
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$SKILL_DIR/scripts/end-card.py" verify-manifest --dir "${1:-.}"
