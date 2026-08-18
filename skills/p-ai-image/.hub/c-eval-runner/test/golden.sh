#!/usr/bin/env bash
# golden.sh — tripwire test for c-eval-runner. Synthesizes a known-GOOD and a
# known-BAD reel, runs the engine against a minimal spec, and asserts:
#   GOOD → no HARD fail (exit 0)
#   BAD  → verdict FAIL (exit 1)
# If anyone loosens the engine or a spec so the BAD render passes, this goes red.
#
# Requires ffmpeg + python3. Run: bash test/golden.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
ENGINE="$HERE/../scripts/eval_run.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILS=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }

# minimal recipe-dir with a spec exercising every deterministic check type
mkdir -p "$WORK/recipe"
cat > "$WORK/recipe/acceptance.json" <<'JSON'
{ "recipe": "golden", "spec_version": 1,
  "checks": [
    { "id": "canvas", "kind": "geometry", "type": "dims", "w": 1080, "h": 1920 },
    { "id": "dur",    "kind": "mechanical", "type": "duration_window", "min_s": 3, "max_s": 30 },
    { "id": "top_not_black", "kind": "geometry", "type": "luma_floor",
      "crop": "1080:960:0:0", "floor": 16, "samples": [0.2,0.5,0.8] },
    { "id": "loud",   "kind": "mechanical", "type": "loudness", "target": -14, "tol": 1.5 }
  ] }
JSON

mkreel(){ # <out> <top_color>
  ffmpeg -v error -f lavfi -i "color=c=$2:s=1080x960:r=30:d=6" \
    -f lavfi -i "color=c=gray:s=1080x960:r=30:d=6" \
    -f lavfi -i "sine=frequency=220:duration=6" \
    -filter_complex "[0:v][1:v]vstack=inputs=2[v];[2:a]loudnorm=I=-14:TP=-1.5[a]" \
    -map "[v]" -map "[a]" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$1" -y 2>/dev/null
}

echo "=== c-eval-runner golden test ==="
mkreel "$WORK/good.mp4" teal
mkreel "$WORK/bad.mp4"  black     # black top zone → must trip luma_floor

python3 "$ENGINE" "$WORK/good.mp4" --recipe-dir "$WORK/recipe" --outdir "$WORK/eg" >/dev/null 2>&1
[ $? -eq 0 ] && ok "GOOD render → exit 0 (no hard fail)" || no "GOOD render unexpectedly failed"
GV="$(python3 -c "import json;print(json.load(open('$WORK/eg/scorecard.json'))['verdict'])")"
[ "$GV" != "FAIL" ] && ok "GOOD verdict=$GV (not FAIL)" || no "GOOD verdict was FAIL"

python3 "$ENGINE" "$WORK/bad.mp4" --recipe-dir "$WORK/recipe" --outdir "$WORK/eb" >/dev/null 2>&1
[ $? -eq 1 ] && ok "BAD render → exit 1 (blocks delivery)" || no "BAD render did NOT exit 1 — FLOOR BREACHED"
BV="$(python3 -c "import json;print(json.load(open('$WORK/eb/scorecard.json'))['verdict'])")"
[ "$BV" = "FAIL" ] && ok "BAD verdict=FAIL" || no "BAD verdict was $BV — FLOOR BREACHED"

echo ""
[ "$FAILS" -eq 0 ] && { echo "GOLDEN OK — floor holds."; exit 0; }
echo "GOLDEN FAILED ($FAILS) — the eval bar has been weakened."; exit 1
