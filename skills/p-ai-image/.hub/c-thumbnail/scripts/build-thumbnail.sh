#!/usr/bin/env bash
# c-thumbnail · build-thumbnail.sh
# Fill the before/after split template, render 1280x720 via headless Chrome,
# compress < 2 MB (YouTube limit).
#
#   build-thumbnail.sh <outdir> [KEY=value ...]
#   keys (defaults): NUM_B=3 NUM_A=45 CAP_B="POSTS / MONTH" CAP_A="POSTS / MONTH"
#     TAG_B=BEFORE TAG_A=AFTER BANNER_PRE="FOR FOOD" BANNER_HI=BUSINESSES
#     BRAND="Content Flywheel Social" AVATAR_SRC=avatar-trim.png
#     GRID_COUNT=45 DOTS_FILLED=3 DOTS_TOTAL=5
#   AVATAR_SRC is resolved relative to <outdir> (where frame-from-avatar.sh cut it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMPL="$HERE/references/template-before-after-split.tmpl.html"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
out="${1:-}"; [ -n "$out" ] || { echo "usage: build-thumbnail.sh <outdir> [KEY=val ...]"; exit 1; }
shift || true
mkdir -p "$out"
html="$out/thumb.html"

python3 - "$TMPL" "$html" "$@" <<'PY'
import sys
tmpl, out = sys.argv[1], sys.argv[2]
v = dict(NUM_B="3", NUM_A="45", CAP_B="POSTS / MONTH", CAP_A="POSTS / MONTH",
         TAG_B="BEFORE", TAG_A="AFTER", BANNER_PRE="FOR FOOD", BANNER_HI="BUSINESSES",
         BRAND="Content Flywheel Social", AVATAR_SRC="avatar-trim.png",
         GRID_COUNT="45", DOTS_FILLED="3", DOTS_TOTAL="5")
for kv in sys.argv[3:]:
    k, _, val = kv.partition("=")
    v[k] = val
s = open(tmpl).read()
for k, val in v.items():
    s = s.replace("{{%s}}" % k, val)
open(out, "w").write(s)
PY

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1280,720 --virtual-time-budget=5000 \
  --screenshot="$out/thumb-1280x720.png" "file://$html" >/dev/null 2>&1

magick "$out/thumb-1280x720.png" -quality 90 "$out/thumb-1280x720.jpg"
sz=$(stat -f%z "$out/thumb-1280x720.jpg" 2>/dev/null || stat -c%s "$out/thumb-1280x720.jpg")
dim=$(magick identify -format '%wx%h' "$out/thumb-1280x720.jpg")
echo "thumbnail: $out/thumb-1280x720.jpg ($dim, $sz bytes)"
[ "$sz" -gt 2000000 ] && echo "WARN: > 2 MB — re-run with a lower -quality in this script."
exit 0
