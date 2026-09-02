# FFmpeg — Delivery Checklist

Run before marking ANY file as final. Zero exceptions.

## Quick Verify Command

```bash
# Full stream info
ffprobe -v error -show_streams -of default "$FINAL" 2>&1 | grep -E "codec_name|width|height|r_frame_rate|sample_rate|bit_rate|duration"

# Duration only
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$FINAL"

# Check loudness
ffmpeg -i "$FINAL" -af loudnorm=print_format=json -f null - 2>&1 | tail -5
```

## 12-Point Checklist

| # | Check | Landscape | Portrait/Shorts |
|---|-------|-----------|----------------|
| 1 | Video codec | H.264 (libx264) | H.264 (libx264) |
| 2 | Pixel format | yuv420p | yuv420p |
| 3 | Audio codec | AAC | AAC |
| 4 | Audio loudness | -14 LUFS (±1) | -16 LUFS (±1) |
| 5 | Captions | Optional | Mandatory — burned in |
| 6 | Outro card | Optional | Mandatory (≥3s) |
| 7 | B-roll coverage | ≥ 70% | ≥ 80% |
| 8 | Resolution | 1920×1080 | 1080×1920 |
| 9 | No black frames | ✓ start/end | ✓ start/end |
| 10 | No audio drift | Check @1,3,5 min | Check @15,30s |
| 11 | Filename prefix | `ls-` | `pr-` or `sq-` |
| 12 | Location | `final/` | `final/` |

## Aspect Ratio Verification

```bash
# Get width and height
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$FINAL")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$FINAL")
echo "Resolution: ${W}x${H}, ratio: $(echo "scale=2; $W/$H" | bc)"
# Landscape: 1.78 (1920/1080)
# Portrait:  0.56 (1080/1920)
# Square:    1.00 (1080/1080)
```

## Common Delivery Fixes

### Wrong pixel format (green tint in some players)
```bash
ffmpeg -i "$INPUT" -c:v libx264 -pix_fmt yuv420p -c:a copy -y "$OUTPUT"
```

### No audio stream
```bash
# Add silent audio track
ffmpeg -i "$INPUT" -f lavfi -i anullsrc=r=48000:cl=stereo \
  -c:v copy -c:a aac -shortest -y "$OUTPUT"
```

### Audio too loud / too quiet (apply loudnorm)
```bash
# See audio-processing.md for two-pass loudnorm procedure
```

### Black frames at start (trim)
```bash
ffmpeg -ss 0.5 -i "$INPUT" -c copy -y "$OUTPUT"
```

### Portrait video pillarboxed in landscape player (do NOT fix — expected)
Portrait finals `pr-*.mp4` display with pillarbox on landscape screens. This is correct.

## Caption Burn-In (Shorts Mandatory)

> ⛔ **NEVER burn a bare `.srt` with `subtitles=$SRT:force_style='FontSize=N'`.**
> An SRT carries NO resolution header, so libass falls back to a phantom
> **384×288** canvas, treats `FontSize` as relative to **288px** tall, then
> scales the whole thing up to the real video height. On a 1080×1920 portrait
> short that multiplies the font by `1920/288 ≈ 6.7×` — a "FontSize=32" caption
> renders at **~213px** and blankets the entire frame. (This exact bug shipped a
> giant-caption short on 2026-06-03.)
>
> **The fix: convert the SRT to ASS with a `PlayResX/PlayResY` header matching the
> video, so `Fontsize` is interpreted in REAL pixels.** Then burn the ASS — no
> `force_style` needed.

```bash
# 1. Probe the actual video dimensions (the ASS PlayRes MUST match these).
#    Use the comma-default CSV (portable across ffprobe builds — the ':s= '
#    separator option fails to parse on some builds and leaves W/H EMPTY, which
#    silently reintroduces the phantom-canvas blow-up). ALWAYS assert non-empty.
DIMS=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0 "$VIDEO")   # -> "1080,1920"
W=${DIMS%,*}; H=${DIMS#*,}
if ! [ "$W" -gt 0 ] 2>/dev/null || ! [ "$H" -gt 0 ] 2>/dev/null; then
  echo "FATAL: could not probe video dimensions (got '$DIMS') — refusing to burn captions blind" >&2
  exit 1
fi

# 2. Pick orientation-correct style. Sizes are REAL pixels (PlayRes == video).
if [ "$H" -ge "$W" ]; then          # portrait (e.g. 1080x1920)
  FONTSIZE=54; ALIGN=2; MARGINV=180; MARGINLR=80   # bottom-center, lifted above safe zone
else                                 # landscape (e.g. 1920x1080)
  FONTSIZE=48; ALIGN=8; MARGINV=80;  MARGINLR=120  # top-center
fi
ASS="${SRT%.srt}.ass"

# 3. SRT -> ASS with a resolution header that matches the video.
python3 - "$SRT" "$ASS" "$W" "$H" "$FONTSIZE" "$ALIGN" "$MARGINV" "$MARGINLR" <<'PY'
import re, sys
srt, ass, W, H, fs, align, mv, mlr = sys.argv[1:9]
def ts(t):  # 00:00:03,820 -> 0:00:03.82
    h, m, rest = t.split(':'); s, ms = rest.split(',')
    return f"{int(h)}:{m}:{s}.{ms[:2]}"
events = []
for blk in re.split(r'\n\s*\n', open(srt, encoding='utf-8').read().strip()):
    lines = blk.strip().split('\n')
    if len(lines) < 3:  # index, timecode, >=1 text line
        continue
    start, end = (x.strip() for x in lines[1].split('-->'))
    text = '\\N'.join(lines[2:]).replace('\n', '\\N')
    events.append((ts(start), ts(end), text))
header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Poppins,{fs},&H00FFFFFF,&H00000000,&H00000000,1,1,4,1,{align},{mlr},{mlr},{mv},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
body = "".join(f"Dialogue: 0,{s},{e},Default,,0,0,0,,{t}\n" for s, e, t in events)
open(ass, 'w', encoding='utf-8').write(header + body)
print(f"wrote {ass}: {len(events)} cues, Fontsize={fs} @ PlayRes {W}x{H}")
PY

# 4. Burn the ASS (font size is now correct; no force_style scaling surprise).
ffmpeg -i "$VIDEO" -vf "ass=$ASS" \
  -c:v libx264 -pix_fmt yuv420p -c:a copy -y "$OUTPUT"
```

Caption style notes:
- **Sizes are real pixels** because `PlayResX/Y` equals the video resolution — never tune FontSize against the 384×288 phantom canvas.
- Portrait: bottom-center (`Alignment=2`), `MarginV=180` (keeps text above the platform UI safe zone).
- Landscape: top-center (`Alignment=8`), `MarginV=80`.
- Keep one sentence per ~2 lines — if a cue is a long full sentence, split it across cues so it never wraps past 2–3 lines.
- Active word highlight: yellow `&H0000FFFF` via ASS inline override tags (`{\c&H0000FFFF&}word{\c&H00FFFFFF&}`) once you have word-level timing.
- Verify after burn: grab a mid-caption frame (`ffmpeg -ss <t> -i "$OUTPUT" -frames:v 1 check.png`) and confirm captions occupy a band, not the whole frame.

## File Naming Before Delivery

```bash
# Rename to standard convention
mv "$RAW_OUTPUT" "ls-$(basename $PROD)-final.mp4"    # landscape
mv "$RAW_OUTPUT" "pr-$(basename $PROD)-final.mp4"    # portrait

# Move to final/
mv "$OUTPUT" "$PROD/final/"
```
