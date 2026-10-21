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

### 2. Detect + crop baked-in bars on every side (BEFORE anything else)

Reused HeyGen / studio renders often carry a 16:9 picture baked between flat white, cream or
mint bars (top/bottom or left/right). WI2.71: `work/bars.py` samples three frames, finds rows
and columns that are one flat colour from each edge inwards, and prints `crop=W:H:X:Y,` (or
nothing). A row with any face or picture in it is never flat, so the head is never cut.

```bash
cat > work/bars.py <<'PY'
# WI2.71: find flat bars baked into the clip (any colour, any side) and print an ffmpeg crop.
import json, subprocess, sys
SRC, TOL, MIN_BAR = sys.argv[1], 12, 8
m = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
    "stream=width,height:format=duration", "-of", "json", SRC], capture_output=True, text=True, check=True).stdout)
W, H = int(m["streams"][0]["width"]), int(m["streams"][0]["height"])
DUR = float(m.get("format", {}).get("duration") or 1.0)
def grab(t):
    return subprocess.run(["ffmpeg", "-v", "error", "-ss", "%.2f" % t, "-i", SRC, "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
def px(fr, x, y):
    i = (y * W + x) * 3
    return fr[i:i + 3]
def bar(fr, lines, pts):
    ref, n = None, 0
    for ln in lines:
        row = [px(fr, *p(ln)) for p in pts]
        ref = ref or row[0]
        if any(max(abs(c[k] - ref[k]) for k in range(3)) > TOL for c in row):
            break
        n += 1
    return n
sides = []
for t in (DUR * 0.2, DUR * 0.5, DUR * 0.8):
    fr = grab(t)
    if len(fr) < W * H * 3:
        continue
    xs = [lambda y, x=x: (x, y) for x in range(0, W, 4)]
    ys = [lambda x, y=y: (x, y) for y in range(0, H, 4)]
    sides.append((bar(fr, range(H // 2), xs), bar(fr, range(H - 1, H // 2, -1), xs),
                  bar(fr, range(W // 2), ys), bar(fr, range(W - 1, W // 2, -1), ys)))
if not sides:
    print(""); sys.exit(0)
top, bot, left, right = (min(s[i] for s in sides) for i in range(4))
top, bot, left, right = ((v + 2 if v >= MIN_BAR else 0) for v in (top, bot, left, right))
cw, ch = W - left - right, H - top - bot
cw, ch = cw - cw % 2, ch - ch % 2
if (top or bot or left or right) and cw >= W // 4 and ch >= H // 4:
    print("crop=%d:%d:%d:%d," % (cw, ch, left, top))
else:
    print("")
PY
CROP=$(python3 work/bars.py "$TH") || exit 1
echo "[pip] bar crop: '${CROP:-none}'"
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
