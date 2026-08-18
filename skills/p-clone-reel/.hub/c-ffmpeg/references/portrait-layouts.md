# FFmpeg — Portrait Composite Layouts (9:16)

All layouts output 1080x1920. Input: `$BASE` (green-screen avatar), `$BROLL` (b-roll clip), `$BG` (background).

## Chroma Key Standard

Always apply before any compositing:
```
colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01
```

---

## Layout 1: Bottom Avatar (60/40 split)

Avatar occupies bottom 40% (768px). B-roll fills top 60% (1152px).

```bash
ffmpeg -i "$BG" -i "$BROLL" -i "$BASE" \
  -filter_complex "
    [0:v]scale=1080:1920[bg];
    [1:v]scale=1080:1152[broll];
    [2:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=1080:768[avatar];
    [bg][broll]overlay=0:0[with_broll];
    [with_broll][avatar]overlay=0:1152
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## Layout 2: Split Equal (50/50)

Avatar and b-roll side by side. 540px each.

```bash
ffmpeg -i "$BG" -i "$BROLL" -i "$BASE" \
  -filter_complex "
    [0:v]scale=1080:1920[bg];
    [1:v]scale=540:1920[broll];
    [2:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=540:1920[avatar];
    [bg][broll]overlay=0:0[with_broll];
    [with_broll][avatar]overlay=540:0
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## Layout 3: Split B-Roll (b-roll dominant — 70/30)

B-roll: 756px wide. Avatar: 324px wide, right side.

```bash
ffmpeg -i "$BG" -i "$BROLL" -i "$BASE" \
  -filter_complex "
    [0:v]scale=1080:1920[bg];
    [1:v]scale=756:1920[broll];
    [2:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=324:1920[avatar];
    [bg][broll]overlay=0:0[with_broll];
    [with_broll][avatar]overlay=756:0
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## Layout 4: PIP B-Roll (full-screen avatar, b-roll insert)

Avatar fills frame. B-roll in upper-right box (360×202px), inset 20px from edge.

```bash
BROLL_W=360; BROLL_H=202
BROLL_X=700; BROLL_Y=20  # top-right inset

ffmpeg -i "$BG" -i "$BASE" -i "$BROLL" \
  -filter_complex "
    [0:v]scale=1080:1920[bg];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01[avatar_keyed];
    [bg][avatar_keyed]overlay=0:0[with_avatar];
    [2:v]scale=${BROLL_W}:${BROLL_H}[pip];
    [with_avatar][pip]overlay=${BROLL_X}:${BROLL_Y}
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## Layout 5: Popout Avatar

Avatar in lower-left quadrant (cropped/zoomed), full-bleed b-roll behind.

```bash
# Dynamic crop values — run pip-crop-detect first
CROP_FILTER="crop=1258:1080:314:0,scale=384:330"
AVATAR_X=20; AVATAR_Y=1570  # bottom-left

ffmpeg -i "$BROLL" -i "$BASE" \
  -filter_complex "
    [0:v]scale=1080:1920[broll_bg];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,${CROP_FILTER}[avatar_small];
    [broll_bg][avatar_small]overlay=${AVATAR_X}:${AVATAR_Y}
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## Layout 6: Full-Screen Avatar (no b-roll)

Clean avatar on background. Used for CTA segments or when no b-roll is available.

```bash
ffmpeg -i "$BG" -i "$BASE" \
  -filter_complex "
    [0:v]scale=1080:1920[bg];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01[avatar_keyed];
    [bg][avatar_keyed]overlay=0:0
  " \
  -map "0:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -y "$OUT"
```

---

## PIP Crop Detection

Run before any PIP/popout layout to get accurate crop values for the current avatar render:

```bash
# Sample frame at 30s
ffmpeg -ss 30 -i "$BASE" -vframes 1 -y /tmp/avatar-sample.png

# Analyze column density to find body boundaries (excludes chair arms)
python3 _scripts/pip-crop-detect.py /tmp/avatar-sample.png --threshold 0.15
# Returns: crop=W:H:X:Y
```

CFW Marcus reference values: `crop=1258:1080:314:0,scale=384:330` at `x=1512, y=726`

---

## Non-16:9 B-Roll in Portrait Composites

For b-roll with non-standard aspect ratio (e.g., square 1:1 clips):

```bash
# Pillarbox to fill 1080×1920 without distortion
[broll_raw]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black[broll]
```

NEVER force-scale non-native AR — causes visible distortion.
