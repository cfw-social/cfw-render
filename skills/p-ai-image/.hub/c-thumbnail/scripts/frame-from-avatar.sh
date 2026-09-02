#!/usr/bin/env bash
# c-thumbnail · frame-from-avatar.sh
# Pick + cut a clean avatar cutout from a (green-screen) talking-head video.
#
#   scan <video> <outdir> [step_s=4] [crop]
#       Builds <outdir>/contactsheet.png (timestamp-labeled) + timestamps.txt.
#       The CALLER then does a VISION pass on the sheet to choose the warmest
#       smiling + eye-contact timestamp. (Smile is not an ffmpeg signal — a model
#       must look. For short hook renders pass a small step, e.g. 0.3.)
#   cut  <video> <outdir> <timestamp_s>
#       Extracts the full-res frame at T, mattes the person out with rembg
#       (NOT chroma key — clean hair, no green spill), trims -> avatar-trim.png,
#       and writes avatar-qc.png (on magenta) to spot any green fringe.
#
# rembg CLI is broken (ModuleNotFoundError: filetype) -> uses the Python API.
set -euo pipefail
FONT="${TNAIL_FONT:-/System/Library/Fonts/AppleSDGothicNeo.ttc}"
# center-upper crop for the scan thumbnails (talking head sits centered)
CROP_DEFAULT="crop=in_w*0.5:in_h*0.86:in_w*0.27:in_h*0.04"

cmd="${1:-}"; video="${2:-}"; outdir="${3:-}"
[ -n "$cmd" ] && [ -n "$video" ] && [ -n "$outdir" ] || {
  echo "usage: frame-from-avatar.sh scan|cut <video> <outdir> [...]"; exit 1; }
[ -f "$video" ] || { echo "no such video: $video"; exit 1; }
mkdir -p "$outdir"

case "$cmd" in
  scan)
    step="${4:-4}"; crop="${5:-$CROP_DEFAULT}"
    D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video" | cut -d. -f1)
    [ "${D:-0}" -gt 0 ] 2>/dev/null || D=10
    tmp="$outdir/_frames"; rm -rf "$tmp"; mkdir -p "$tmp"
    : > "$outdir/timestamps.txt"; i=0
    for t in $(seq 0 "$step" "$((D-1))"); do
      ffmpeg -nostdin -v error -ss "$t" -i "$video" -frames:v 1 \
        -vf "${crop},scale=240:-1" "$tmp/$(printf '%06.1f' "$t").jpg" -y 2>/dev/null || true
      printf '%d\t%ss\n' "$i" "$t" >> "$outdir/timestamps.txt"; i=$((i+1))
    done
    magick montage "$tmp"/*.jpg -font "$FONT" -tile 8x -geometry +2+2 \
      -background black -pointsize 18 -label '%t' "$outdir/contactsheet.png"
    echo "scan: $outdir/contactsheet.png  ($i frames, ${step}s apart, 8/row; labels = seconds)"
    echo "next: VIEW the sheet, pick the warmest smiling + eye-contact T, then:"
    echo "      frame-from-avatar.sh cut '$video' '$outdir' <T>"
    ;;
  cut)
    t="${4:-}"; [ -n "$t" ] || { echo "cut needs <timestamp_s>"; exit 1; }
    ffmpeg -nostdin -v error -ss "$t" -i "$video" -frames:v 1 "$outdir/avatar-raw.png" -y
    python3 - "$outdir/avatar-raw.png" "$outdir/avatar-cut.png" <<'PY'
import sys
from rembg import remove
from PIL import Image
remove(Image.open(sys.argv[1])).save(sys.argv[2])
PY
    magick "$outdir/avatar-cut.png" -trim +repage "$outdir/avatar-trim.png"
    magick -background magenta "$outdir/avatar-trim.png" -flatten "$outdir/avatar-qc.png" 2>/dev/null || true
    echo "cut: $outdir/avatar-trim.png  (QC on magenta: $outdir/avatar-qc.png — check for green fringe)"
    ;;
  *) echo "usage: frame-from-avatar.sh scan|cut <video> <outdir> [...]"; exit 1;;
esac
