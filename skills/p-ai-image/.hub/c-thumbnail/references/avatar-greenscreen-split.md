# Recipe — Green-screen avatar cutout → before/after split thumbnail

Proven on the CFW Food & Beverage VSL (thumbnail: **"3 → 45 POSTS / MONTH · FOR FOOD
BUSINESSES"** with the host cut out of his HeyGen green-screen render and centered over
the split). Reusable for any talking-head + comparison thumbnail. Same avatar/technique
serves both **CFW (cfw-marketing / CFW Social)** and **Mr Growth Guide**.

Template: `template-before-after-split.html` (in this folder). Output: 1280×720, < 2 MB.

> **Automated:** the steps below are wrapped by `scripts/frame-from-avatar.sh`
> (`scan` → vision-pick → `cut`) and `scripts/build-thumbnail.sh`. This doc is the
> manual walkthrough / what the scripts do under the hood — see SKILL.md
> § "Avatar video → thumbnail".

---

## 1 — Pick the frame (from the render already used in the video)

Source = the green-screen avatar track that's already in the cut, e.g.
`interim/vsl/avatar-green.mp4`, `src/avatar-*-green.mp4`, or the hook render
`src/avatar-hook-driven-green.mp4`.

These are **continuous narration** — there is usually no big closed-mouth grin. Scan
densely for the warmest *eye-contact* frame, don't expect a posed smile:

```bash
SRC=interim/vsl/avatar-green.mp4
for t in $(seq 0 0.3 11); do
  ffmpeg -nostdin -v error -ss $t -i "$SRC" -frames:v 1 \
    -vf "crop=820:620:550:70,scale=240:-1" /tmp/sc/$(printf '%04.1f' $t).jpg -y
done
magick montage /tmp/sc/*.jpg -font /System/Library/Fonts/AppleSDGothicNeo.ttc \
  -tile 6x -geometry +2+2 -background black /tmp/sheet.jpg     # eyeball, pick t
ffmpeg -nostdin -ss <T> -i "$SRC" -frames:v 1 frame.png        # full-res 1920×1080
```

## 2 — Cut out the avatar with rembg (NOT chroma key)

rembg AI matting beats `colorkey`/`chromakey`: clean hair edges, zero green spill.
**The rembg CLI is broken** (`ModuleNotFoundError: filetype` on py3.14) — use the API:

```python
from rembg import remove
from PIL import Image
out = remove(Image.open('frame.png'))
out.save('avatar-cut.png')
```
```bash
magick avatar-cut.png -trim +repage avatar-trim.png        # tight bbox
# QC for green fringe — composite on magenta; any lime edge = spill
magick -size 1100x1060 xc:magenta avatar-trim.png -gravity center -composite /tmp/qc.png
```
(Green here was `0x13FF06` bright lime, uniform — but still prefer rembg.)

## 3 — Compose (HTML, CFW palette)

Copy `template-before-after-split.html` next to `avatar-trim.png`. Palette: bg
`#0F172A`, accent `#7C5CFC`, fg `#F1F5F9`, muted `#94A3B8`. Fonts Anton (numbers +
banner) / Oswald / Inter via Google-Fonts `@import`. Layout that works:

- Diagonal `clip-path` split — left **muted** (before), right **purple glow** (after).
- A glowing seam strip rotated ~7°.
- `BEFORE` / `AFTER` pills top corners.
- **Huge Anton numbers flank the avatar** (left + right thirds) so they're never hidden
  behind the centered face. Before number desaturated grey; after number white + glow.
- Avatar `position:bottom`, centered, ~680px tall, behind a radial accent glow + a
  `drop-shadow`. Container `overflow:hidden` crops the mic/hands at the bottom.
- Bottom **two-tone banner** for the audience line ("FOR FOOD BUSINESSES") — it also
  masks the mic poking up.

Swap per use: the two numbers, the BEFORE/AFTER captions, the banner text, the
`avatar` `src`, and the grid count (JS loop builds N squares for the "after" grid).

## 4 — Render (headless Chrome)

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1280,720 --virtual-time-budget=5000 \
  --screenshot=thumb-1280x720.png "file://$PWD/thumb.html"
```
`--virtual-time-budget` lets Google Fonts + the grid-building JS finish before capture.

## 5 — Compress < 2 MB (YouTube limit)

```bash
magick thumb-1280x720.png -quality 90 thumb-1280x720.jpg   # ~150 KB at q90
```

## Gotchas
- rembg **CLI is broken → Python API** (`from rembg import remove`).
- Numbers must **flank**, not sit behind, the centered avatar.
- Bottom banner doubles as a **mic / raised-hand mask**.
- `montage` needs an explicit `-font` on this machine (IMv7).
- Set custom thumbnail on YouTube via Studio → video → Thumbnail → Upload (channel must
  be verified; the file must be < 2 MB).
