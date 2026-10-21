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

- `saves/voice_track.mp4` — the talking head at its **source** dimensions (a matched pair of
  baked-in bars cropped away — step 2), 30 fps, H.264 yuv420p, AAC 48 kHz stereo, loudnormed **once**
  (`I=-16:TP=-1.5:LRA=11`). No scaling to the canvas here: the PIP card is sized in `composite`.

## How

`mkdir -p work saves`.

### 1. Probe the source — duration is the master reel length

```bash
TH=prior/talking_head.mp4
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TH")
read TH_W TH_H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of default=noprint_wrappers=1 "$TH" | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$TH" | grep -q audio \
  || { echo "talking-head video has no audio track"; exit 1; }
echo "[pip] source ${TH_W}x${TH_H} ${BED_DUR}s"
```

### 2. Detect + crop a baked-in bar pair (BEFORE anything else)

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

This step has no `canAsk` in the HeyGen variant: the talking head is `prior/talking_head.mp4`,
produced by `generate_avatar`. Never write `needs_input.json`. If that file is not a decodable
video, has no audio stream or is outside 15–75 s, exit non-zero with one plain owner-readable
line — the fix is a rerun of `generate_avatar`, not an ask.

## Checks the harness runs

- `bed_has_audio` — `saves/voice_track.mp4` has one audio stream (AAC 48 kHz stereo).
- `bed_not_black` — a frame sampled at 1 s has mean luma above 16/255.
