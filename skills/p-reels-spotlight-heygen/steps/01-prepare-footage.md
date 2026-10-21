# Prepare footage

Build the **speaker bed**: the one continuous, never-cut voice track every later step rides on.
Everything downstream (captions, takeovers, b-roll, end card) is timed against this file, so its
duration is the master reel length.

## You receive

- `inputs/talking_head/` — exactly one video file (any orientation, 20–60 s). Pick it with
  `AVATAR=prior/talking_head.mp4`. It is already on local disk; never composite
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
AVATAR=prior/talking_head.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 "$AVATAR"
ffmpeg -hide_banner -i "$AVATAR" -af "silencedetect=noise=-35dB:d=0.5" -f null - 2>&1 \
  | grep -E "silence_(start|end)" || echo "narration continuous"
```

### 2. Detect & crop baked-in bars on every side (BEFORE anything else)

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
CROP=$(python3 work/bars.py "$AVATAR") || exit 1
echo "[spotlight] bar crop: '${CROP:-none}'"
AVATAR_CLEAN="$AVATAR"
```

### 3. Build the bed — full length, scale-to-cover, loudnormed ONCE

```bash
ffmpeg -y -i "$AVATAR_CLEAN" \
  -vf "${CROP}scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/base.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 work/base.mp4)
```

`avatar_layout: letterbox` → replace the `-vf` with
`${CROP}scale=1080:-2,pad=1080:1920:0:(1920-ih)/2:color=0x0F172A,setsar=1,fps=30` (use the brand `bg` hex
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

### 5. Seal and save

```bash
cp work/base.mp4 saves/voice_track.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 saves/voice_track.mp4   # 1080,1920
ffprobe -v error -show_entries format=duration -of csv=p=0 saves/voice_track.mp4                             # 20–60 s
```

From here on `voice_track.mp4` is sealed: no later step may cut, re-time or re-normalise it.

## If you cannot proceed

This step has no `canAsk` in the HeyGen variant: the talking head is `prior/talking_head.mp4`,
produced by `generate_avatar`. Never write `needs_input.json`. If that file is not a decodable
video, has no audio stream or is outside 15–75 s, exit non-zero with one plain owner-readable
line — the fix is a rerun of `generate_avatar`, not an ask.

## Checks the harness runs

- `bed_dims` — `saves/voice_track.mp4` video stream is exactly 1080×1920.
- `bed_not_black` — mean luma of the full frame sampled at 10/30/50/70/90 % of the duration is
  above the floor (16/255): the bed is a real picture, not black or padding-only.
