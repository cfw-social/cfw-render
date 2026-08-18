---
name: c-thumbnail
description: Render YouTube/social thumbnail variants from an avatar VIDEO (auto frame-pick + green-screen cutout) or an avatar/generated frame + topic — bold HTML-GFX layouts at 1280x720 through headless Chrome, compressed under 2 MB. Produces N variants for selection. Reusable component invoked by image recipes; not an owner-facing pipeline.
when_to_use: Trigger on c-thumbnail, make thumbnail, YouTube thumbnail, thumbnail variants, click-through image, video cover, thumbnail from frame, thumbnail from avatar video, thumbnail from my HeyGen render.
allowed-tools: Bash, Read, Write
kind: component
visibility: internal
requires: ffmpeg, chromium
dependsOn: [c-html-gfx, c-ffmpeg]
---


# c-thumbnail — Thumbnail Rendering

Bold, high-contrast HTML-GFX thumbnails from a face/avatar frame + topic. Renders
N variants at 1280x720 and compresses each under 2 MB. The recipe owns variant
SELECTION (presenting + picking a winner); this component owns the render mechanics.

## Inputs

| Input | Required | Default | Notes |
|-------|----------|---------|-------|
| topic | Yes | — | Drives the headline copy |
| frame | Yes* | — | PNG face/avatar frame (or a generated image). If it's a **green-screen** avatar still, cut it out first — see § Green-screen cutout. |
| avatar_video | Yes* | — | *Alternative to `frame`*: a (green-screen) talking-head/HeyGen render. The skill auto-picks a frame + cuts it out — see § Avatar video → thumbnail. (Supply `frame` **or** `avatar_video`.) |
| num_variants | No | `3` | How many layouts to render |
| style | No | brand-ref.md | `text-heavy`, `face-focus`, or `split` (split → proven template at `references/template-before-after-split.html`) |

## Steps

### 1 — Plan variants
Read `brand-ref.md` for the thumbnail style guide (colors, font, any CTR notes).
Plan `num_variants` layouts, e.g.:
- A: face left, text right
- B: full face, text overlay bottom
- C: split — before/after or comparison

Write 3 headline options per variant (shock / curiosity / result-first).

### 2 — Render each variant
→ LOAD: `c-html-gfx` — author HTML per variant at 1280x720: the frame embedded as
  a positioned image, dark/bold brand-palette background, headline 80px+ bold high
  contrast. Screenshot with `--window-size=1280,860` cropped to 1280x720. Run a
  Unicode check after every render. Output `interim/broll/gfx/thumb-{A/B/C}-v1.png`.

### 3 — Compress
→ LOAD: `c-ffmpeg` — JPEG `-q:v 2`; verify each is < 2 MB (YouTube limit). Output
  `interim/broll/gfx/thumb-{A/B/C}-v1.jpg`.

### 4 — Return variants
Return all variant paths to the calling recipe for presentation/selection. On an
iteration request, adjust copy/layout and re-render that variant only. The winner
is delivered by the recipe as `final/ls-tnail01-{topic-slug}.jpg` (1280x720, <2 MB).

## Avatar video → thumbnail (automated path)
When the input is an **avatar video** (not a frame), run the end-to-end scripts. Frame
selection needs a model's eyes (a "smile" is not an ffmpeg signal) — so it's a scan →
**vision pick** → cut → build loop, not a black box:

```bash
S=scripts            # under this skill folder
# 1) Scan → labeled contact sheet (+ timestamps.txt). Dense step for short hooks.
$S/frame-from-avatar.sh scan  <avatar.mp4> <outdir> 0.6
# 2) VISION PICK: Read <outdir>/contactsheet.png, choose the warmest smiling +
#    eye-contact timestamp T (8 frames/row, `step` apart; map in timestamps.txt).
# 3) Cut → rembg matte + trim → <outdir>/avatar-trim.png (QC: avatar-qc.png on magenta).
$S/frame-from-avatar.sh cut   <avatar.mp4> <outdir> <T>
# 4) Build → fill template, render 1280x720, compress < 2 MB.
$S/build-thumbnail.sh <outdir> NUM_B=3 NUM_A=45 BANNER_PRE="FOR FOOD" BANNER_HI="BUSINESSES" \
   GRID_COUNT=45 DOTS_FILLED=3 DOTS_TOTAL=5
# → <outdir>/thumb-1280x720.jpg
```
For N variants, re-run step 4 with different copy/numbers (and/or a different `T`).
Setting it on the video: hand the jpg to `r-youtube-data-api` (`--thumbnail`), or the
owner uploads it in Studio (the browser file-upload tool no longer accepts host paths).

## Green-screen cutout (HeyGen avatar → transparent PNG)
When the `frame` comes from a green-screen avatar render, matte the person out BEFORE
composing. Use **rembg** (AI matting — clean hair, no green spill); do NOT chroma-key.
The rembg CLI is broken (`ModuleNotFoundError: filetype`) — use the Python API:
```python
from rembg import remove
from PIL import Image
remove(Image.open('frame.png')).save('avatar-cut.png')
```
Then `magick avatar-cut.png -trim +repage avatar-trim.png`. These renders are
continuous narration → scan densely for the warmest eye-contact frame; don't expect a
posed grin. Full walkthrough + render/compress commands: `references/avatar-greenscreen-split.md`.

## Scripts & reference recipes
- `scripts/frame-from-avatar.sh` — `scan` (contact sheet for the vision pick) + `cut`
  (rembg matte → `avatar-trim.png` + magenta QC). The avatar-video → frame engine.
- `scripts/build-thumbnail.sh` — fills the tokenized template, renders 1280×720 via
  headless Chrome, compresses < 2 MB. Keys: `NUM_B NUM_A CAP_B CAP_A TAG_B TAG_A
  BANNER_PRE BANNER_HI BRAND AVATAR_SRC GRID_COUNT DOTS_FILLED DOTS_TOTAL`.
- `references/template-before-after-split.tmpl.html` — the tokenized template the build
  script fills (`references/template-before-after-split.html` is the literal proven copy).
- `references/avatar-greenscreen-split.md` — the manual walkthrough behind the scripts
  (proven on the CFW F&B VSL: "3 → 45 posts/month · FOR FOOD BUSINESSES"). Serves both
  **CFW / CFW Social** and **Mr Growth Guide** (same host avatar).
