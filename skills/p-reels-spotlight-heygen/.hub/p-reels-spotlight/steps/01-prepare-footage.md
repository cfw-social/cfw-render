# Prepare footage

Build the **speaker bed**: the one continuous, never-cut voice track every later step rides on.
Everything downstream (captions, takeovers, b-roll, end card) is timed against this file, so its
duration is the master reel length.

## You receive

- `inputs/talking_head/` — exactly one video file (any orientation, 20–60 s). Pick it with
  `AVATAR=$(ls inputs/talking_head/* | head -1)`. It is already on local disk; never composite
  from a remote URL.
- `brief.json` — read `options.avatar_layout` (`fill` default, or `letterbox`).

No prior saves: this is the first computer step.

## You must produce

- `saves/voice_track.mp4` — 1080×1920, 30 fps, H.264 yuv420p, AAC 48 kHz stereo, loudnormed
  **once** (`I=-16:TP=-1.5:LRA=11`), leading dead air trimmed, audio otherwise untouched.

## How

Work in `work/`; `mkdir -p work saves`.

### 1. Probe the source — the duration is the master reel length

```bash
AVATAR=$(ls inputs/talking_head/* | head -1)
ffprobe -v error -show_entries format=duration -of csv=p=0 "$AVATAR"
ffmpeg -hide_banner -i "$AVATAR" -af "silencedetect=noise=-35dB:d=0.5" -f null - 2>&1 \
  | grep -E "silence_(start|end)" || echo "narration continuous"
```

### 2. Detect & crop white side bands (BEFORE anything else)

Reused 16:9 studio renders often carry baked-in white/cream bands down the left and right. Measure
thin edge columns against the centre and, if bands exist, crop LEFT/RIGHT only — **never the top**
(the head must not be cut). `crop=W:H:X:0` — the y-offset `0` guarantees the top edge is kept.

```bash
W_SRC=$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "$AVATAR")
H_SRC=$(ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$AVATAR")
col_luma () {
  v=$(ffmpeg -hide_banner -loglevel error -ss 13 -i "$AVATAR" -vframes 1 \
        -vf "crop=2:$H_SRC:$1:0,scale=1:1,format=gray" -f rawvideo - 2>/dev/null | xxd -p)
  echo $((16#$v))
}
LEFT=0;  for x in $(seq 0 5 $((W_SRC/2)));    do [ "$(col_luma $x)" -lt 245 ] && { LEFT=$x;  break; }; done
RIGHT=$W_SRC; for x in $(seq $((W_SRC-2)) -5 $((W_SRC/2))); do [ "$(col_luma $x)" -lt 245 ] && { RIGHT=$((x+2)); break; }; done
CW=$(( RIGHT - LEFT )); CW=$(( CW - CW % 2 ))
if [ "$LEFT" -gt 4 ] || [ "$RIGHT" -lt $((W_SRC-4)) ]; then
  ffmpeg -y -i "$AVATAR" -vf "crop=$CW:$H_SRC:$LEFT:0,setsar=1" \
    -c:v libx264 -pix_fmt yuv420p -c:a copy work/avatar-clean.mp4
  AVATAR_CLEAN=work/avatar-clean.mp4
else
  AVATAR_CLEAN="$AVATAR"
fi
```

### 3. Build the bed — full length, scale-to-cover, loudnormed ONCE

```bash
ffmpeg -y -i "$AVATAR_CLEAN" \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/base.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 work/base.mp4)
```

`avatar_layout: letterbox` → replace the `-vf` with
`scale=1080:-2,pad=1080:1920:0:(1920-ih)/2:color=0x0F172A,setsar=1,fps=30` (use the brand `bg` hex
from `brief.json` when known). **Do not slice the bed** — one unbroken audio track. Loudnorm
happens here and never again in any later step.

### 4. Trim leading dead air only (mandatory, guarded)

Strip the silent buffer before the first word, but ONLY if the first detected silence genuinely
starts within the first 1.0 s — an internal pause mid-content must never be trimmed.

```bash
SILENCE_EVENTS=$(ffmpeg -hide_banner -i work/base.mp4 \
  -af "silencedetect=noise=-40dB:d=0.4" -f null - 2>&1 | grep "silence_")
SILENCE_START_0=$(echo "$SILENCE_EVENTS" | grep silence_start | head -1 \
  | grep -oE 'silence_start: [0-9.]+' | grep -oE '[0-9.]+$' || echo "999")
SILENCE_END_0=$(echo "$SILENCE_EVENTS" | grep silence_end | head -1 \
  | grep -oE 'silence_end: [0-9.]+' | grep -oE '[0-9.]+$' || echo "0")
TRIM_START=$(python3 -c "
s_start = float('$SILENCE_START_0'); s_end = float('$SILENCE_END_0')
print(max(0, s_end - 0.05) if (s_start < 1.0 and s_end > 0.3) else 0)
")
if python3 -c "exit(0 if float('$TRIM_START') > 0.3 else 1)"; then
  ffmpeg -y -ss "$TRIM_START" -i work/base.mp4 -c copy work/base-trimmed.mp4 \
    && mv work/base-trimmed.mp4 work/base.mp4
  echo "[spotlight] trimmed ${TRIM_START}s of leading silence"
fi
```

### 4b. Give the end card a silent tail (WI2.89)

The end card never covers speech (WI2.86), so the bed needs room after the last spoken word.
When the speech runs to the end of the clip (or nearly), hold the last frame with silence until
`cta_duration` + 0.5 s follows the speech end (a tail of at most 3.5 s). The speech end is
where the final silence starts (`silencedetect` −40 dB, 0.3 s); with no trailing silence it is
the clip end. `cta_card: off` adds no tail, and a clip that already ends in enough silence is
left as it is. The tail is part of the sealed bed: captions, takeovers, checks and the reel all
time against it, and the end card then shows in full right after the last word.

```bash
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
python3 - work/base.mp4 "$(opt cta_card on)" "$(opt cta_duration 3.0)" <<'PY' || exit 1
# WI2.89: hold the last frame with silence so the end card fits after the last spoken word.
import math, os, re, subprocess, sys
src, card, want = sys.argv[1], sys.argv[2], float(sys.argv[3])
MARGIN, MAX_TAIL = 0.5, 3.5   # speech end + cta_duration + MARGIN, tail at most MAX_TAIL
def dur(p):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)
if card != "on":
    print("[spotlight] end-card tail: cta_card off, no tail"); sys.exit(0)
d = dur(src)
log = subprocess.run(["ffmpeg", "-hide_banner", "-i", src, "-af", "silencedetect=noise=-40dB:d=0.3", "-f", "null", "-"],
                     capture_output=True, text=True).stderr
starts = [float(x) for x in re.findall(r"silence_start: (-?[0-9.]+)", log)]
ends = [float(x) for x in re.findall(r"silence_end: (-?[0-9.]+)", log)]
speech_end = d                       # no silence runs to the end: the speech fills the clip
if starts and (len(ends) < len(starts) or ends[-1] >= d - 0.05):
    speech_end = max(0.0, starts[-1])
tail = math.ceil(max(0.0, min(want + MARGIN, MAX_TAIL) - (d - speech_end)) * 30) / 30
if tail <= 0:
    print("[spotlight] end-card tail: %.2fs of silence already follows the speech, no tail" % (d - speech_end)); sys.exit(0)
tmp = src[:-4] + "-tail.mp4"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf", "tpad=stop_mode=clone:stop_duration=%.3f" % tail,
                "-af", "apad=pad_dur=%.3f" % tail, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
                "-c:a", "aac", "-ar", "48000", "-ac", "2", tmp], check=True)
got = dur(tmp)
if abs(got - (d + tail)) > 0.1:
    sys.exit("end-card tail: bed is %.3fs, expected %.3fs" % (got, d + tail))
os.replace(tmp, src)
print("[spotlight] end-card tail: speech ends %.2fs, held the last frame + silence for %.2fs (bed %.2fs)" % (speech_end, tail, got))
PY
```

### 5. Seal and save

```bash
cp work/base.mp4 saves/voice_track.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 saves/voice_track.mp4   # 1080,1920
ffprobe -v error -show_entries format=duration -of csv=p=0 saves/voice_track.mp4                             # 20–64 s (with the WI2.89 tail)
```

From here on `voice_track.mp4` is sealed: no later step may cut, re-time or re-normalise it.

## If you cannot proceed

This step may not ask for inputs: `talking_head` is a required start input and the harness only
starts the run once it is present. If the file is not a decodable video (ffprobe fails), exit
non-zero with a one-line owner-readable message — that is a failure, not an ask. Do not write
`needs_input.json`.

## Checks the harness runs

- `bed_dims` — `saves/voice_track.mp4` video stream is exactly 1080×1920.
- `bed_not_black` — mean luma of the full frame sampled at 10/30/50/70/90 % of the duration is
  above the floor (16/255): the bed is a real picture, not black or padding-only.
