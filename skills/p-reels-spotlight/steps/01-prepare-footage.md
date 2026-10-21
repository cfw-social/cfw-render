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

### 2. Detect & crop a baked-in bar pair (BEFORE anything else)

Reused HeyGen / studio renders often carry a 16:9 picture baked between two flat bars (white,
cream or mint) at the top and bottom, or a 9:16 picture between two side bars. WI2.71: the
`bars.py` helper samples three frames and prints `crop=W:H:X:Y,` only for a **matched pair** —
top+bottom (or left+right) bars of about the same size and the same flat colour that leave a
picture within 5 % of 16:9 or 9:16. Anything else (a speaker on a plain backdrop, a one-sided
margin) prints nothing and nothing is cropped, so the head is never cut. It measures frames the
way ffmpeg shows them (rotation applied), so a rotated phone clip is read on the right axes.

```bash
cat > work/bars.py <<'PY'
# WI2.71: find a matched pair of flat bars baked into the clip and print an ffmpeg crop.
# Crops only top+bottom (or left+right) bars of about the same size and the same flat
# colour, and only when what is left is within 5% of 16:9 or 9:16. Anything else: no crop.
import subprocess, sys
SRC, TOL, MIN_BAR, ASPECT_TOL = sys.argv[1], 12, 8, 0.05
def grab(t):
    # One frame as PPM. Its header gives the size ffmpeg shows after autorotation, so a
    # rotated phone clip is measured on the same axes the later -vf crop sees.
    out = subprocess.run(["ffmpeg", "-v", "error", "-ss", "%.2f" % t, "-i", SRC, "-frames:v", "1",
        "-f", "image2pipe", "-c:v", "ppm", "-"], capture_output=True, check=True).stdout
    if not out.startswith(b"P6"):
        return None
    head, pos = [], 2
    while len(head) < 3:
        while out[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while out[end:end + 1] and not out[end:end + 1].isspace():
            end += 1
        head.append(int(out[pos:end])); pos = end
    w, h, data = head[0], head[1], out[pos + 1:]
    return (w, h, data) if len(data) >= w * h * 3 else None
def duration():
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", SRC],
        capture_output=True, text=True, check=True).stdout.strip()
    try:
        return float(r)
    except ValueError:
        return 1.0
def close(a, b):
    return max(abs(a[k] - b[k]) for k in range(3)) <= TOL
def run(fr, w, lines, pts):
    # how many lines from this edge inwards are one flat colour -> (count, colour)
    ref, n = None, 0
    for ln in lines:
        row = [fr[(y * w + x) * 3:(y * w + x) * 3 + 3] for x, y in pts(ln)]
        ref = ref or row[0]
        if not all(close(c, ref) for c in row):
            break
        n += 1
    return n, ref
D = duration()
frames = [f for f in (grab(D * p) for p in (0.2, 0.5, 0.8)) if f]
if not frames or len({(f[0], f[1]) for f in frames}) != 1:
    print(""); sys.exit(0)
W, H = frames[0][0], frames[0][1]
sides = [(run(fr, W, range(H // 2), lambda y: [(x, y) for x in range(0, W, 4)]),
          run(fr, W, range(H - 1, H // 2, -1), lambda y: [(x, y) for x in range(0, W, 4)]),
          run(fr, W, range(W // 2), lambda x: [(x, y) for y in range(0, H, 4)]),
          run(fr, W, range(W - 1, W // 2, -1), lambda x: [(x, y) for y in range(0, H, 4)]))
         for _, _, fr in frames]
def edge(i):
    # bar size = the smallest run over the sampled frames; its colour must hold in every frame
    n, cols = min(s[i][0] for s in sides), [s[i][1] for s in sides]
    if n < MIN_BAR or not all(close(c, cols[0]) for c in cols):
        return 0, None
    return n, cols[0]
(top, ct), (bot, cb), (left, cl), (right, cr) = (edge(i) for i in range(4))
def pair(a, ca, b, cb_, side):
    # a matched pair: both bars present, the same flat colour, sizes within 2% of the side
    return bool(a and b and close(ca, cb_) and abs(a - b) <= max(4, side * 0.02))
def aspect_ok(w, h):
    return any(abs((w / h) / r - 1) <= ASPECT_TOL for r in (16 / 9, 9 / 16))
tb, lr = pair(top, ct, bot, cb, H), pair(left, cl, right, cr, W)
cands = ([(top, bot, left, right)] if tb and lr else []) + ([(top, bot, 0, 0)] if tb else []) \
    + ([(0, 0, left, right)] if lr else [])
for t, b, l, r in cands:
    t, l = t + t % 2, l + l % 2          # even x/y (yuv420p); never keeps a bar row
    cw, ch = W - l - r, H - t - b
    cw, ch = cw - cw % 2, ch - ch % 2    # even w/h
    if cw >= W // 4 and ch >= H // 4 and aspect_ok(cw, ch):
        print("crop=%d:%d:%d:%d," % (cw, ch, l, t)); sys.exit(0)
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

This step may not ask for inputs: `talking_head` is a required start input and the harness only
starts the run once it is present. If the file is not a decodable video (ffprobe fails), exit
non-zero with a one-line owner-readable message — that is a failure, not an ask. Do not write
`needs_input.json`.

## Checks the harness runs

- `bed_dims` — `saves/voice_track.mp4` video stream is exactly 1080×1920.
- `bed_not_black` — mean luma of the full frame sampled at 10/30/50/70/90 % of the duration is
  above the floor (16/255): the bed is a real picture, not black or padding-only.
