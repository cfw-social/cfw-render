# Prepare footage

Build the **voice bed**: the one continuous, never-cut talking-head track every later step rides
on. Its duration is the master reel length; its audio is the only audio in the reel.

## You receive

- `inputs/talking_head/` — exactly one video file (any orientation, 20–60 s), already on local
  disk. Pick it with `TH=$(ls inputs/talking_head/* | head -1)`. Script-driven variants of this
  recipe deliver it as `prior/talking_head.mp4` instead — if `inputs/talking_head/` is absent, use
  `TH=prior/talking_head.mp4`.
- `brief.json` — nothing specific; the brand block is for later steps.

No other prior saves: this is the first compositing step.

## You must produce

- `saves/voice_track.mp4` — the talking head at its **source** dimensions (white side-bands
  cropped away), 30 fps, H.264 yuv420p, AAC 48 kHz stereo, loudnormed **once**
  (`I=-16:TP=-1.5:LRA=11`). No scaling to the canvas here: the PIP card is sized in `composite`.

## How

`mkdir -p work saves`.

### 1. Probe the source — duration is the master reel length

```bash
TH=$(ls inputs/talking_head/* 2>/dev/null | head -1); [ -n "$TH" ] || TH=prior/talking_head.mp4
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TH")
read TH_W TH_H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of default=noprint_wrappers=1 "$TH" | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$TH" | grep -q audio \
  || { echo "talking-head video has no audio track"; exit 1; }
echo "[pip] source ${TH_W}x${TH_H} ${BED_DUR}s"
```

### 2. Detect + crop white side-bands (BEFORE anything else)

Reused 16:9 studio renders often carry baked-in white/cream bands down the left and right. Sample
a frame, measure thin edge columns against the centre and crop LEFT/RIGHT only — never the top.

```bash
ffmpeg -y -ss 1 -i "$TH" -frames:v 1 work/probe.png
CROP=$(python3 - "$TH_W" "$TH_H" <<'PY'
import sys
from PIL import Image
W, H = int(sys.argv[1]), int(sys.argv[2])
im = Image.open('work/probe.png').convert('L')
def col_mean(x): return sum(im.getpixel((x, y)) for y in range(0, H, 8)) / len(range(0, H, 8))
def band(xs):
    n = 0
    for x in xs:
        if col_mean(x) > 225: n += 1
        else: break
    return n
left, right = band(range(0, W // 3)), band(range(W - 1, W - W // 3, -1))
if left + right > 8: print(f"crop={W-left-right}:{H}:{left}:0,")
else: print("")
PY
)
echo "[pip] side-band crop: '${CROP:-none}'"
```

### 3. Seal the bed — loudnorm ONCE

```bash
ffmpeg -y -i "$TH" \
  -vf "${CROP}fps=30,setsar=1,format=yuv420p" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:v libx264 -preset medium -crf 18 -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart saves/voice_track.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 saves/voice_track.mp4
ffmpeg -ss 1 -i saves/voice_track.mp4 -frames:v 1 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*'
```

The bed is now sealed: no later step may cut, re-time or loudnorm it again.

## If you cannot proceed

This step may ask for **`talking_head` only**. Write `needs_input.json` and stop (no save) when
the supplied file is not a decodable video, has no audio stream, or is shorter than 15 s / longer
than 75 s:

```json
{ "inputId": "talking_head", "reason": "The talking-head video could not be used — please upload a 20–60 second clip with the speaker's voice.", "count": 1 }
```

A missing tool (ffmpeg, PIL) is a failure, not an ask: exit non-zero with one plain line.

## Checks the harness runs

- `bed_has_audio` — `saves/voice_track.mp4` has one audio stream (AAC 48 kHz stereo).
- `bed_not_black` — a frame sampled at 1 s has mean luma above 16/255.
