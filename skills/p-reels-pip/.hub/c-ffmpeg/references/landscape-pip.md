# FFmpeg — Landscape PIP Composite (16:9 VSL)

All outputs: 1920×1080. Input: `$BASE` (avatar on background, 1920×1080), `$BROLL` (overlay clip).

## Audio-Per-Segment Architecture (MANDATORY)

**NEVER separate audio from video in composites.** Each segment must carry its own synced audio.

- AVATAR segments: cut from `avatar-on-bg.mp4` WITH audio, output-level seeking
- PIP/FULLSCREEN segments: audio from `$BASE` at matching timecode (`-map "1:a"`)
- Pre-render avatar-on-bg.mp4 with `-g 25` (keyframe every 1s) for seek accuracy

```bash
# Pre-render avatar-on-bg with keyframes for accurate seeking
ffmpeg -i "$BG_IMG" -i "$AVATAR_GREEN" \
  -filter_complex "
    [0:v]scale=1920:1080[bg];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01[keyed];
    [bg][keyed]overlay=0:0[composited]
  " \
  -map "[composited]" -map "1:a" \
  -c:v libx264 -pix_fmt yuv420p -g 25 -c:a aac -y "$AVATAR_ON_BG"
```

---

## Framed-Inset PIP — DEFAULT avatar treatment (rounded-rect, gold border, soft shadow)

**This is the mandated default PIP look** (owner-approved 2026-07, ref render
`cfw-marketing/docs/vsl/dfy/renders/restaurants-3min-premium-v1.mp4`). The avatar sits inside a
**rounded-rectangle framed inset** — thin gold border + soft outer drop shadow — in a bottom corner,
**alternating left / right across pip beats**. The old circular/plain-rect PIP is **RETIRED as the
default** (kept only as the "Legacy" note at the bottom of this section).

> ### ⚠️ CLONE-FROM-CIRCULAR TRAP — read before you copy a build script
> The framed-inset avatar is produced by **exactly two** compositing steps and **nothing else** on
> the face: **(1)** the rounded-rect `pip-mask.png` applied via `alphamerge`, and **(2)** the
> `pip-frame.png` overlay (gold border + soft outer shadow). The corner radius, the gold border and
> the drop-shadow are the ONLY treatments — the face must show **fully, edge-to-edge, evenly lit**
> inside the rounded-rect, at the **same brightness as the source avatar**. **No circle/oval mask, no
> vignette, no darkening, no second overlay on the face.**
>
> **`pip-frame.png` is overlaid ON TOP of the face — so its interior MUST be fully transparent
> (alpha≈0).** The drop-shadow must be drawn **strictly OUTSIDE** the rounded-rect (in the 48px pad
> ring), never as a filled/inner shadow. A frame whose interior is a filled+blurred black rect (a
> common generator bug — see step 2b below) darkens the whole face by ~55%. If the composited face is
> darker than the raw avatar, the frame shadow is bleeding inward — that is the cause, not the key.
>
> **The legacy circular PIP (e.g. `06.19-coaches-dfy/coaches-build.sh`) clips the avatar to a circle
> with a `geq` ellipse alpha:**
> ```
> geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte((X-180)*(X-180)+(Y-180)*(Y-180),180*180),alpha(X,Y),0)'
> ```
> **If you clone a circular-PIP production and leave that `geq` (or any `circle-mask.png` /
> `gold-ring.png` asset) in the avatar filterchain, the round crop shows as a BLACK OVAL over/around
> the face inside the rounded-rect frame.** When switching a clone to framed-inset you MUST:
> 1. **DELETE** the `geq=...a='if(lte(...))'` circle/ellipse step from the avatar filterchain.
> 2. **DELETE** the leftover `circle-mask.png` and `gold-ring.png` assets so nothing can reference them.
> 3. Use ONLY the `pip-mask.png` (rounded-rect) `alphamerge` + `pip-frame.png` overlay below.
>
> Grep the cloned build before rendering: `grep -nE "geq|circle|ellipse|gold-ring" build.sh` must return
> **nothing** in the avatar/PIP path. Then vision-QA 3–4 pip beats: face fully visible, no oval, border +
> shadow clean, corners alternating.

**Geometry (1920×1080 canvas):**

| Property | Value | % of frame |
|---|---|---|
| Card size (content) | `PIP_W=304 × PIP_H=380` (portrait ~4:5) | 15.8% W / 35.2% H |
| Corner radius | `PIP_R=24` px | ~7.9% of PIP width |
| Border | `PIP_BW=4` px, gold `#D4A84C` | — |
| Drop shadow | offset (0,+6), Gaussian blur 22, `rgba(0,0,0,0.45)` | — |
| Margin from active edge + bottom | `PIP_MARGIN=72` px | ~3.75% W |
| Position | bottom corner, **alternating L↔R** per pip beat | — |
| Overlay padding (shadow room) | `PIP_PAD=48` px | — |

Reference render measured ~17.7% W / 39% H; this default is **slightly smaller** (owner ask).
Right-beat placement: `X=1544, Y=628`. Left-beat placement: `X=72, Y=628`.

### One-time: generate the rounded mask + frame overlay (shadow + gold border)

```bash
python3 - "$WORK" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter
W,H,R,BW,PAD = 304,380,24,4,48
GOLD = (212,168,76,255)          # #D4A84C
work = sys.argv[1]
# (1) rounded-rect alpha mask for the avatar card content
m = Image.new("L",(W,H),0)
ImageDraw.Draw(m).rounded_rectangle([0,0,W-1,H-1], radius=R, fill=255)
m.save(f"{work}/pip-mask.png")
# (2) frame overlay: EXTERNAL-ONLY soft drop shadow + gold border, FULLY TRANSPARENT centre.
from PIL import ImageChops
CW,CH = W+2*PAD, H+2*PAD
# 2a. blurred shadow from a filled rounded-rect (offset +6 down)
sh = Image.new("RGBA",(CW,CH),(0,0,0,0))
ImageDraw.Draw(sh).rounded_rectangle([PAD,PAD+6,PAD+W-1,PAD+H-1+6], radius=R, fill=(0,0,0,150))
sh = sh.filter(ImageFilter.GaussianBlur(22))
# 2b. ⚠️ PUNCH OUT the card interior so the shadow is STRICTLY OUTSIDE the rounded-rect and
#     NEVER covers the avatar face. WITHOUT this step the blurred black fill (alpha ~150) sits
#     over the whole face when the frame is overlaid on top → the face renders ~55% darker than
#     the source avatar. This is the single most important line in the frame generator.
cut = Image.new("L",(CW,CH),0)
ImageDraw.Draw(cut).rounded_rectangle([PAD,PAD,PAD+W-1,PAD+H-1], radius=R, fill=255)
sh.putalpha(ImageChops.subtract(sh.getchannel("A"), cut))   # clear shadow inside the card
# 2c. gold border riding the card edge (thin 4px ring at the rounded-rect boundary)
bd = Image.new("RGBA",(CW,CH),(0,0,0,0))
ImageDraw.Draw(bd).rounded_rectangle([PAD,PAD,PAD+W-1,PAD+H-1], radius=R, outline=GOLD, width=BW)
Image.alpha_composite(sh,bd).save(f"{work}/pip-frame.png")
PY
# Assets: $WORK/pip-mask.png (304×380) + $WORK/pip-frame.png (400×476, border+shadow).
# INVARIANT — pip-frame.png interior (inside the rounded-rect, past the 4px border) must be
# alpha≈0. The drop-shadow lives ONLY in the 48px pad OUTSIDE the card. Verify before rendering:
#   python3 -c "from PIL import Image; import numpy as np; \
#     a=np.asarray(Image.open('$WORK/pip-frame.png').convert('RGBA'))[56:420,56:344,3]; \
#     print('frame interior mean alpha', a.mean())   # must be < 1.0, NOT ~140"
```

> ### ⚠️ QA GATE — composited PIP face brightness MUST match the source avatar
> After compositing, extract the PIP crop at 3–4 pip beats and compare the **face-region mean
> luminance** against the same region of the **raw** avatar (`avatar-green-raw.mp4`, before keying).
> They must be close (within ~10–15%). **If the composited face is markedly darker (~2–3×), the
> `pip-frame.png` drop-shadow is bleeding INWARD over the face** — its interior alpha is non-zero.
> Regenerate the frame with the interior punch-out above (step 2b). Do NOT "fix" it by adding an
> `eq`/`curves` brightness lift on the avatar — that masks the bug; remove the inward shadow instead.
> (A mild lift `eq=brightness=0.03:contrast=1.05` is only acceptable AFTER the overlay is gone, if the
> face still reads dim on dark-card beats.)

### Alternation helper (per pip beat)

```bash
# Call once per pip beat with a 0-based pip-beat counter (NOT the beat index).
# Even → bottom-right, odd → bottom-left. Emits: PIP_X PIP_Y PIP_FX PIP_FY
pip_place(){ local n=$1
  local W=304 H=380 PAD=48 M=72
  if (( n % 2 == 0 )); then local X=$((1920-M-W)); else local X=$M; fi
  local Y=$((1080-M-H))
  echo "$X $Y $((X-PAD)) $((Y-PAD))"   # card x/y, frame x/y (card minus pad)
}
```

### Composite one fullscreen-PIP segment (both source types)

```bash
START=60; END=90; DUR=$((END-START))
read PIP_X PIP_Y PIP_FX PIP_FY < <(pip_place "$PIP_N")   # $PIP_N = this beat's pip counter
MASK="$WORK/pip-mask.png"; FRAME="$WORK/pip-frame.png"

# --- (a) GREEN-SCREEN avatar (DFY golden cuts): key out green, drop the person onto a solid
#     card backdrop (so the inset reads as a framed card, not a floating cut-out), mask, frame.
ffmpeg \
  -ss $START -i "$AVATAR_ON_BG" \
  -ss $START -i "$AVATAR_GREEN" \
  -ss 0     -i "$BROLL" \
  -loop 1 -i "$WORK/context-bg.png" \
  -i "$MASK" -i "$FRAME" \
  -filter_complex "
    [0:v]trim=duration=$DUR,setpts=PTS-STARTPTS[base];
    [2:v]scale=1920:1080,trim=duration=$DUR,setpts=PTS-STARTPTS[broll_scaled];
    [3:v]scale=304:380:force_original_aspect_ratio=increase,crop=304:380,eq=brightness=-0.05,setsar=1[card_bg];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=304:380:force_original_aspect_ratio=increase,crop=304:380,setsar=1[person];
    [card_bg][person]overlay=0:0,format=rgba,trim=duration=$DUR,setpts=PTS-STARTPTS[card_raw];
    [card_raw][4:v]alphamerge[pip];
    [base][broll_scaled]overlay=0:0[with_broll];
    [with_broll][pip]overlay=$PIP_X:$PIP_Y[with_pip];
    [with_pip][5:v]overlay=$PIP_FX:$PIP_FY[out]
  " \
  -map "[out]" -map "1:a" -t $DUR -c:v libx264 -pix_fmt yuv420p -c:a aac -y "seg-fullscreen-pip.mp4"

# --- (b) NO-GREEN-SCREEN studio avatar (uploaded / studio-bg cut, e.g. the 3-min ref): frame the
#     studio inset directly — NO colorkey, keep the avatar's own background inside the card.
ffmpeg \
  -ss $START -i "$AVATAR_ON_BG" \
  -ss $START -i "$AVATAR_STUDIO" \
  -ss 0     -i "$BROLL" \
  -i "$MASK" -i "$FRAME" \
  -filter_complex "
    [0:v]trim=duration=$DUR,setpts=PTS-STARTPTS[base];
    [2:v]scale=1920:1080,trim=duration=$DUR,setpts=PTS-STARTPTS[broll_scaled];
    [1:v]scale=304:380:force_original_aspect_ratio=increase,crop=304:380,setsar=1,format=rgba,trim=duration=$DUR,setpts=PTS-STARTPTS[card_raw];
    [card_raw][3:v]alphamerge[pip];
    [base][broll_scaled]overlay=0:0[with_broll];
    [with_broll][pip]overlay=$PIP_X:$PIP_Y[with_pip];
    [with_pip][4:v]overlay=$PIP_FX:$PIP_FY[out]
  " \
  -map "[out]" -map "1:a" -t $DUR -c:v libx264 -pix_fmt yuv420p -c:a aac -y "seg-fullscreen-pip.mp4"
```

The **frame overlay is applied ON TOP** of the placed card so the gold border rides the card edge
and the soft shadow falls on the background ring around it (never over the avatar). Chroma-key runs
**only on the green-screen path**; the studio path keeps its own background inside the card.

**The avatar filterchain contains NO `geq`/circle/ellipse/vignette step** — the only alpha applied to
the face is the rounded-rect `alphamerge` with `pip-mask.png`. If you see `geq=...a='if(lte(...))'`
anywhere in the `[person]`/`[card_raw]` chain, it is a circular-PIP leftover (see the Clone-From-Circular
Trap warning above) and MUST be removed, or a black oval will appear over the face.

### Legacy plain-rect / circular PIP — RETIRED as default (do not use for new work)

> The former default overlaid a hard `crop=1258:1080:314:0,scale=384:330` rectangle (landscape,
> no border/shadow/rounding) at `overlay=1512:726`, and an older uploaded path used a bare
> `radius=32` rounded mask with no border/shadow. Both are **retired as the default** — use the
> framed-inset default above. Kept here only so old builds remain readable:
> `[1:v]colorkey=…,crop=1258:1080:314:0,scale=384:330[pip]; [base][pip]overlay=1512:726`.

---

## Multi-Segment VSL Assembly

### Segment Types

**AVATAR segment** (talking head only):
```bash
START=0; END=30
ffmpeg -ss $START -i "$AVATAR_ON_BG" -t $(($END-$START)) \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -y "seg-01-avatar.mp4"
```

**FULLSCREEN segment** (b-roll fills frame, avatar PIP in corner): use the **Framed-Inset PIP
DEFAULT** above (rounded-rect + gold border + soft shadow + `pip-mask.png`/`pip-frame.png`, corner
alternating per beat via `pip_place`). Do NOT reintroduce the retired hard-rect below — it is kept
only as the legacy reference:
```bash
# ⛔ LEGACY (retired default) — kept for reading old builds only. Prefer the framed-inset default.
START=30; END=90; BROLL="$PROD/interim/broll/segments/wbst01.mp4"
ffmpeg \
  -ss $START -i "$AVATAR_ON_BG" \
  -ss $START -i "$AVATAR_ON_BG" \
  -i "$BROLL" \
  -filter_complex "
    [0:v]trim=duration=60,setpts=PTS-STARTPTS[base];
    [2:v]scale=1920:1080,loop=-1:1,trim=duration=60,setpts=PTS-STARTPTS[broll];
    [1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,crop=1258:1080:314:0,scale=384:330,trim=duration=60,setpts=PTS-STARTPTS[pip];
    [base][broll]overlay=0:0[with_broll];
    [with_broll][pip]overlay=1512:726[out]
  " \
  -map "[out]" -map "1:a" -t 60 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -y "seg-02-broll.mp4"
```

**Concatenate all segments:**
```bash
# Build concat list
for seg in seg-*.mp4; do echo "file '$seg'"; done > concat-list.txt
ffmpeg -f concat -safe 0 -i concat-list.txt -c copy -y "$FINAL"
```

---

## Gap-Free B-Roll Windows

Extend each segment's enable window to the START of the next segment:
- Eliminates 0.5–1.5s avatar flashes between b-roll segments
- Keep intentional AVATAR transitions (> 1.5s with scripted dialogue)

```bash
# enable=between(t,START,NEXT_START) — not between(t,START,END)
overlay=x=0:y=0:enable='between(t,30,90)'  # extends to next segment start
```

---

## Avatar Crop / Zoom (CRITICAL)

**NEVER crop+stretch** — distorts avatar proportions.
**ALWAYS zoom-in then crop:**

```bash
# 1.15x zoom (removes chair arms, 162px from bottom)
scale=2208:1242,crop=1920:1080:144:0
```

For PIP insert, run `pip-crop-detect` script to get accurate body-only crop values per render.

---

## Seeking Rules

- **Output-level seeking** (`-i file -ss $START`): accurate to timecode, slower decode
- **Input-level seeking** (`-ss $START -i file`): snaps to nearest keyframe — avoid for 5+ min videos
- Use `-g 25` on pre-renders so keyframes are every 1s

For 5+ minute base videos: always use output-level seeking.
