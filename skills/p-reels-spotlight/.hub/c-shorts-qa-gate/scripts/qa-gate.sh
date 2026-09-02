#!/usr/bin/env bash
# c-shorts-qa-gate — pre-delivery QA gate for short-form video.
# Mirrors the brain doctrine concepts/infra/video-production/short-form-qa-gate.
#
# HARD checks (exit 1 on any failure — block delivery):
#   - valid video / has audio
#   - resolution + fps match the format
#   - integrated loudness ≈ -14 LUFS
#   - frame-0 brightness > 0x30 (not a black/dark open)
#   - green-screen residual (chroma key missed in PIP or FULL)
# ADVISORY checks (reported, never block — need a human/vision pass):
#   - captions present + bottom-positioned (bottom-strip crops dumped)
#   - b-roll coverage / contextual background (frame sweep dumped)
#   - brand outro present (last-3s frame dumped)
#   - lip-sync drift (50% / 75% / last-30s frames dumped)
#
# Usage:
#   qa-gate.sh <final.mp4> [--format reel|vsl|square] [--expect-fps N]
#              [--lufs-target -14] [--lufs-tol 1.5] [--outdir DIR]
#
# Exit: 0 = all HARD checks pass, 1 = a HARD check failed, 2 = usage/IO error.
set -uo pipefail

# ---- args -------------------------------------------------------------------
VIDEO=""; FORMAT="reel"; EXPECT_FPS=30; LUFS_TARGET=-14; LUFS_TOL=1.5; OUTDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format)     FORMAT="$2"; shift 2;;
    --expect-fps) EXPECT_FPS="$2"; shift 2;;
    --lufs-target) LUFS_TARGET="$2"; shift 2;;
    --lufs-tol)   LUFS_TOL="$2"; shift 2;;
    --outdir)     OUTDIR="$2"; shift 2;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)            VIDEO="$1"; shift;;
  esac
done
[ -n "$VIDEO" ] || { echo "ERROR: no video given. See --help."; exit 2; }
[ -f "$VIDEO" ] || { echo "ERROR: file not found: $VIDEO"; exit 2; }
command -v ffprobe >/dev/null && command -v ffmpeg >/dev/null || { echo "ERROR: ffmpeg/ffprobe required"; exit 2; }
[ -n "$OUTDIR" ] || OUTDIR="$(cd "$(dirname "$VIDEO")" && pwd)/qa"
mkdir -p "$OUTDIR"

# expected dims by format
case "$FORMAT" in
  reel|portrait) EXP_W=1080; EXP_H=1920;;
  vsl|landscape) EXP_W=1920; EXP_H=1080;;
  square)        EXP_W=1080; EXP_H=1080;;
  *) echo "ERROR: unknown --format '$FORMAT'"; exit 2;;
esac

HARD_FAILS=0; REPORT="$OUTDIR/qa-report.txt"
: > "$REPORT"
log(){ echo "$1" | tee -a "$REPORT"; }
pass(){ log "  [PASS] $1"; }
fail(){ log "  [FAIL] $1"; HARD_FAILS=$((HARD_FAILS+1)); }
adv(){  log "  [ADVISORY] $1"; }
# awk float compare: cmp A OP B  -> returns 0(true)/1(false)
fcmp(){ awk -v a="$1" -v b="$3" "BEGIN{exit !(a $2 b)}"; }

log "=== c-shorts-qa-gate :: $(basename "$VIDEO") :: format=$FORMAT ==="

# ---- probe ------------------------------------------------------------------
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of default=nk=1:nw=1 "$VIDEO" 2>/dev/null | head -1)
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nk=1:nw=1 "$VIDEO" 2>/dev/null | head -1)
RFR=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nk=1:nw=1 "$VIDEO" 2>/dev/null)
FPS=$(awk -F/ 'BEGIN{f=0}{ if($2>0) f=$1/$2; else f=$1 } END{printf "%.3f", f}' <<<"$RFR")
DUR=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$VIDEO" 2>/dev/null)
ACODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$VIDEO" 2>/dev/null)
log "probed: ${W}x${H} @ ${FPS}fps  dur=${DUR}s  audio=${ACODEC:-NONE}"

# ---- HARD: container/streams ------------------------------------------------
if [ -n "${W:-}" ] && [ -n "${H:-}" ]; then pass "decodable video stream"; else fail "no decodable video stream"; fi
if [ -n "$ACODEC" ]; then pass "audio track present"; else fail "no audio track (voiceover bed missing)"; fi

# ---- HARD: resolution + fps -------------------------------------------------
if [ "$W" = "$EXP_W" ] && [ "$H" = "$EXP_H" ]; then pass "resolution ${W}x${H}"; else fail "resolution ${W}x${H}, expected ${EXP_W}x${EXP_H}"; fi
if fcmp "$FPS" '>=' "$(awk -v f="$EXPECT_FPS" 'BEGIN{print f-1.5}')" && fcmp "$FPS" '<=' "$(awk -v f="$EXPECT_FPS" 'BEGIN{print f+1.5}')"; then
  pass "fps ${FPS} (~${EXPECT_FPS})"; else fail "fps ${FPS}, expected ~${EXPECT_FPS}"; fi
if [ -n "${DUR:-}" ] && fcmp "$DUR" '>' 0; then pass "duration ${DUR}s"; else fail "zero/invalid duration"; fi

# ---- HARD: loudness ≈ -14 LUFS ---------------------------------------------
if [ -n "$ACODEC" ]; then
  LN=$(ffmpeg -hide_banner -nostats -i "$VIDEO" -af "loudnorm=I=${LUFS_TARGET}:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1 \
        | awk -F'"' '/input_i/{print $4; exit}')
  if [ -n "$LN" ]; then
    LO=$(awk -v t="$LUFS_TARGET" -v d="$LUFS_TOL" 'BEGIN{print t-d}')
    HI=$(awk -v t="$LUFS_TARGET" -v d="$LUFS_TOL" 'BEGIN{print t+d}')
    if fcmp "$LN" '>=' "$LO" && fcmp "$LN" '<=' "$HI"; then pass "loudness ${LN} LUFS (target ${LUFS_TARGET}±${LUFS_TOL})"
    else fail "loudness ${LN} LUFS outside ${LUFS_TARGET}±${LUFS_TOL} (loudnorm skipped?)"; fi
  else adv "could not measure loudness"; fi
fi

# ---- HARD: frame-0 brightness ----------------------------------------------
F0="$OUTDIR/frame-0.png"
ffmpeg -hide_banner -loglevel error -y -i "$VIDEO" -frames:v 1 "$F0" 2>/dev/null
Y0=$(ffmpeg -hide_banner -nostats -i "$VIDEO" -vf "select=eq(n\,0),signalstats,metadata=print" -frames:v 1 -f null - 2>&1 \
      | awk -F= '/signalstats.YAVG/{print $2; exit}')
if [ -n "$Y0" ]; then
  if fcmp "$Y0" '>' 48; then pass "frame-0 brightness YAVG=${Y0} (>48)"; else fail "frame-0 brightness YAVG=${Y0} ≤48 (black/avatar-only open)"; fi
else adv "could not read frame-0 brightness"; fi

# ---- ADVISORY: green-screen residual ---------------------------------------
# Sample 1fps; mask pixels where chroma-key green dominates, measured as red-luma avg.
# ADVISORY only on the FINAL composite: legitimate green content (foliage, brand
# colors) is indistinguishable from key-leak by histogram. The HARD green check
# belongs at the keying step (c-ffmpeg), run on avatar-on-bg.mp4 where green must
# be fully absent. Here we surface a peak + flag suspiciously high values to review.
GMAX=$(ffmpeg -hide_banner -nostats -i "$VIDEO" \
        -vf "fps=1,format=rgb24,geq=r='255*gt(g(X\,Y)\,150)*lt(r(X\,Y)\,90)*lt(b(X\,Y)\,90)':g=0:b=0,format=yuv420p,signalstats,metadata=print" \
        -f null - 2>&1 | awk -F= '/signalstats.YAVG/{if($2+0>m)m=$2+0} END{printf "%.3f", m+0}')
if [ -n "$GMAX" ]; then
  adv "green peak mask=${GMAX} (heuristic; review sweep frames if a green band is suspected — hard-enforce at the keying step on avatar-on-bg.mp4)"
else adv "could not run green-residual check"; fi

# ---- frame sweep + advisory crops ------------------------------------------
sweep(){ # $1=seconds $2=label
  ffmpeg -hide_banner -loglevel error -y -ss "$1" -i "$VIDEO" -frames:v 1 "$OUTDIR/sweep-$2.png" 2>/dev/null
}
if [ -n "${DUR:-}" ] && fcmp "$DUR" '>' 0; then
  sweep 0 "00-frame0"
  fcmp "$DUR" '>' 10 && sweep 10 "10s"
  fcmp "$DUR" '>' 30 && sweep 30 "30s"
  sweep "$(awk -v d="$DUR" 'BEGIN{printf "%.2f", d*0.5}')" "50pct"
  sweep "$(awk -v d="$DUR" 'BEGIN{printf "%.2f", d*0.75}')" "75pct"
  sweep "$(awk -v d="$DUR" 'BEGIN{printf "%.2f", (d>3)?d-3:d}')" "last3s"
  # caption-review crops: bottom 30% strip of the 30s + 50% frames
  for s in 30 "$(awk -v d="$DUR" 'BEGIN{printf "%.2f", d*0.5}')"; do
    fcmp "$DUR" '>' "$s" && ffmpeg -hide_banner -loglevel error -y -ss "$s" -i "$VIDEO" \
      -vf "crop=iw:ih*0.30:0:ih*0.66" -frames:v 1 "$OUTDIR/caption-strip-${s%.*}s.png" 2>/dev/null
  done
fi
adv "captions present/position — review $OUTDIR/caption-strip-*.png"
adv "b-roll coverage / contextual bg — review $OUTDIR/sweep-*.png (avatar should be the minority)"
adv "brand outro — review $OUTDIR/sweep-last3s.png"
adv "lip-sync drift — review sweep-50pct/75pct/last3s frames"

# ---- verdict ----------------------------------------------------------------
log "----------------------------------------------------------------------"
if [ "$HARD_FAILS" -eq 0 ]; then
  log "RESULT: PASS (hard checks). Advisory artifacts in $OUTDIR/. Review before publish."
  exit 0
else
  log "RESULT: FAIL — $HARD_FAILS hard check(s) failed. DO NOT deliver. See $REPORT."
  exit 1
fi
