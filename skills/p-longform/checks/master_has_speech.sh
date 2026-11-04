#!/usr/bin/env bash
# master_has_speech: post_process check. The harness runs `bash checks/<id>.sh <step workdir>`:
# exit 0 = pass, anything else = fail, and the last 400 characters of the output are the reason.
#   1. saves/mastered_video.mp4 carries speech: volumedetect mean volume between -32 and -8 dB.
#   2. When the owner chose captions, work/captions.ass covers the speech: no stretch of speech longer
#      than 3 s without a caption, at least 97 % of the speech time captioned, nothing over the end card
#      (scripts/captions.py verify, B51). Captions off: nothing more to check.
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-.}"
VIDEO="$WORK/saves/mastered_video.mp4"
if [ ! -s "$VIDEO" ]; then
  echo "the mastered video was not saved (saves/mastered_video.mp4)"
  exit 1
fi
LEVEL="$(ffmpeg -hide_banner -nostats -nostdin -i "$VIDEO" -vn -af volumedetect -f null - 2>&1 \
  | sed -n 's/.*mean_volume: *\(-\{0,1\}[0-9.]*\) dB.*/\1/p' | tail -1)"
if [ -z "$LEVEL" ]; then
  echo "could not measure the audio level of saves/mastered_video.mp4"
  exit 1
fi
if ! awk -v v="$LEVEL" 'BEGIN { exit !(v >= -32 && v <= -8) }'; then
  echo "the mix does not carry speech: mean volume $LEVEL dB, expected -32 to -8 dB"
  exit 1
fi
exec python3 "$SKILL_DIR/scripts/captions.py" verify --dir "$WORK"
