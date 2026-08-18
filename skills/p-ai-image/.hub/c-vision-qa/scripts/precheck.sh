#!/usr/bin/env bash
# precheck.sh — cheap, scripted mechanical QA for STILL images.
# Catches obviously-broken renders (black/blank/wrong-size) BEFORE spending a vision call.
# Perceptual judgment is the agent's job (READ the image); this is only the floor.
#
# Usage:
#   bash precheck.sh <image...> [--aspect WxH | --aspect W:H] [--outdir DIR]
#
# Exit: 0 all hard checks pass · 1 a hard check failed · 2 usage/IO error.
set -uo pipefail

IMAGES=(); ASPECT=""; OUTDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --aspect) ASPECT="${2:-}"; shift 2 ;;
    --outdir) OUTDIR="${2:-}"; shift 2 ;;
    -*) echo "precheck: unknown flag $1" >&2; exit 2 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done

[ "${#IMAGES[@]}" -gt 0 ] || { echo "precheck: no images given" >&2; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "precheck: ffprobe (ffmpeg) required" >&2; exit 2; }

# Parse --aspect into either exact dims or a ratio.
EXP_W=""; EXP_H=""; EXP_RATIO=""
if [ -n "$ASPECT" ]; then
  if [[ "$ASPECT" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    EXP_W="${BASH_REMATCH[1]}"; EXP_H="${BASH_REMATCH[2]}"
    EXP_RATIO=$(awk "BEGIN{printf \"%.5f\", $EXP_W/$EXP_H}")
  elif [[ "$ASPECT" =~ ^([0-9]+):([0-9]+)$ ]]; then
    EXP_RATIO=$(awk "BEGIN{printf \"%.5f\", ${BASH_REMATCH[1]}/${BASH_REMATCH[2]}}")
  else
    echo "precheck: bad --aspect '$ASPECT' (want WxH or W:H)" >&2; exit 2
  fi
fi

OUTDIR="${OUTDIR:-$(dirname "${IMAGES[0]}")/qa}"
mkdir -p "$OUTDIR" 2>/dev/null
REPORT="$OUTDIR/precheck-report.txt"; : > "$REPORT"

hex() { printf '%d' "$1"; }                 # 0x18 -> 24, plain int passthrough
BLACK_MIN=$(hex 0x18)                        # YAVG must exceed this (not black)
RANGE_MIN=$(hex 0x20)                         # YMAX-YMIN must exceed this (not single-color/blank).
                                             # Absolute range, NOT percentile spread: a premium card
                                             # that is mostly whitespace still has dark text → wide range.

fails=0
for img in "${IMAGES[@]}"; do
  if [ ! -f "$img" ]; then echo "FAIL $img — missing file" | tee -a "$REPORT"; fails=$((fails+1)); continue; fi

  # Dimensions (two single-value probes — csv multi-field parsing is fragile).
  w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of default=nk=1:nw=1 "$img" 2>/dev/null)
  h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nk=1:nw=1 "$img" 2>/dev/null)
  if [ -z "$w" ] || [ -z "$h" ]; then echo "FAIL $img — not a decodable image" | tee -a "$REPORT"; fails=$((fails+1)); continue; fi

  img_fail=0; notes=""

  # Aspect: match the RATIO, not exact pixels — 2x/retina renders (deviceScaleFactor)
  # are desirable (sharper), so WxH is a target ratio + minimum resolution, never an
  # exact-equality gate. Smaller-than-target is an advisory, not a hard fail.
  if [ -n "$EXP_RATIO" ]; then
    r=$(awk "BEGIN{printf \"%.5f\", $w/$h}")
    ok=$(awk "BEGIN{print (($r/$EXP_RATIO)>0.99 && ($r/$EXP_RATIO)<1.01)?1:0}")
    [ "$ok" = "1" ] || { img_fail=1; notes+="ratio ${r}≠${EXP_RATIO} (${w}x${h}); "; }
  fi
  if [ -n "$EXP_W" ] && [ -n "$w" ]; then
    [ "$w" -lt "$EXP_W" ] && notes+="ADVISORY under-res ${w}<${EXP_W}px wide; "
  fi

  # Brightness + flatness via signalstats. metadata=print:file=- forces the values to
  # STDOUT so `-v error` doesn't swallow them (the info-level log is suppressed otherwise).
  stats=$(ffmpeg -v error -i "$img" -vf "signalstats,metadata=print:file=-" -f null - 2>/dev/null)
  yavg=$(printf '%s\n' "$stats" | sed -n 's/.*signalstats\.YAVG=\([0-9.]*\).*/\1/p' | head -1)
  ymin=$(printf '%s\n' "$stats" | sed -n 's/.*signalstats\.YMIN=\([0-9.]*\).*/\1/p' | head -1)
  ymax=$(printf '%s\n' "$stats" | sed -n 's/.*signalstats\.YMAX=\([0-9.]*\).*/\1/p' | head -1)

  if [ -n "$yavg" ]; then
    isblack=$(awk "BEGIN{print ($yavg<=$BLACK_MIN)?1:0}")
    [ "$isblack" = "1" ] && { img_fail=1; notes+="black/near-black (YAVG=$yavg); "; }
  fi
  if [ -n "$ymin" ] && [ -n "$ymax" ]; then
    range=$(awk "BEGIN{printf \"%.0f\", $ymax-$ymin}")
    isflat=$(awk "BEGIN{print (($ymax-$ymin)<=$RANGE_MIN)?1:0}")
    [ "$isflat" = "1" ] && { img_fail=1; notes+="flat/blank (range=$range); "; }
  fi

  if [ "$img_fail" = "1" ]; then
    echo "FAIL $img — ${notes%; }" | tee -a "$REPORT"; fails=$((fails+1))
  else
    echo "PASS $img — ${w}x${h} YAVG=${yavg:-?}" | tee -a "$REPORT"
  fi
done

echo "--- precheck: $((${#IMAGES[@]}-fails))/${#IMAGES[@]} passed, report: $REPORT"
[ "$fails" = "0" ] || { echo "precheck: $fails image(s) failed the mechanical floor — re-render before the vision pass." >&2; exit 1; }
exit 0
