# Build the top-zone track

Render every beat of the beat list into a silent **1080×960** clip and concatenate them into the
one top-zone track that is stacked above the face. `graphics` beats render as illustrative
HyperFrames cards from the split motion-card template (or `c-typing-ui` `VARIANT=top-half` for a
typing / hook scene); `broll` beats are wrapped as a rounded brand-bordered card on the brand
canvas with `wowx-motions` (`broll_style=card`) or blurred-filled into 1080×960. The track is
verified not-black BEFORE stacking.

## You receive

- `prior/beat_list.json` — the beats (`kind`, `start`, `end`, `broll`, `scene`).
- `prior/transcripts.json` — `.words` (card copy comes from what is said in each window).
- `prior/voice_track.mp4` — probe for `BED_DUR` only; never re-encode it here.
- `inputs/broll/` — the clips the `broll` beats reference.
- `brief.json` — `brand` (palette, typography, name), `options.broll_style` (`card`).

## You must produce

- `saves/top_track.mp4` — 1080×960, 30 fps, H.264 yuv420p, **no audio**, duration = `BED_DUR`
  (±0.1 s), every sampled frame non-black. Every card fills the full 960 px zone.

## How

```bash
mkdir -p work/top_beats saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
TYPING_UI_DIR="$SKILL_DIR/.hub/c-typing-ui"; WOWX_DIR="$SKILL_DIR/.hub/wowx-motions"
GSAP="$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js"; TEMPLATE="$SKILL_DIR/templates/split-motion-card.html"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
N_BEATS=$(python3 -c "import json; print(len(json.load(open('prior/beat_list.json'))['beats']))")
python3 -c "import json; json.dump(json.load(open('brief.json')).get('brand') or {}, open('work/brand.json','w'))"
BROLL_STYLE=$(python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('broll_style','card'))")
BRAND_BG=$(python3 -c "import json;print((json.load(open('work/brand.json')).get('bg') or '#0F172A').lstrip('#'))")
```

### 1. Render each beat (concurrently, `nproc-1` jobs)

For beat `i` with `kind`, `start`, `end` (`dur = end - start`, `IN`/`OUT` from `beat.broll`):

- **`broll`, `broll_style=card`** — trim first, then wrap: `ffmpeg -y -ss "$IN" -to "$OUT" -i
  "inputs/broll/$CLIP" -an work/top_beats/_in$i.mp4` then
  `python3 "$WOWX_DIR/wowx_motion.py" work/top_beats/_in$i.mp4 -m <card-orbit if i%4==2 else card-focus> work/top_beats/top_beat$i.mp4 --bg "0x$BRAND_BG" --canvas 1080x960 --card-scale 0.86 --corner-radius 0.04 --intensity 1.1`.
- **`broll`, `broll_style=blurred-fill`** — `ffmpeg -y -ss "$IN" -t "$DUR" -i "inputs/broll/$CLIP" -filter_complex "[0:v]split[a][b];[a]scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,boxblur=40:2,setsar=1[bg];[b]scale=1080:960:force_original_aspect_ratio=decrease,setsar=1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[v]" -map "[v]" -an -c:v libx264 -preset medium -crf 20 work/top_beats/top_beat$i.mp4`.
- **`graphics`, typing / hook scene** — `bash "$TYPING_UI_DIR/scripts/render.sh" --text "<copy>" --duration "$DUR" --brand work/brand.json --variant top-half --out work/top_beats/top_beat$i.mp4` (see `$TYPING_UI_DIR/SKILL.md`); if `top-half` is unsupported, render `pip-safe` and crop: `-vf crop=1080:960:0:0`.
- **`graphics`, motion card** — write `work/gfx_$i/index.html` from `$TEMPLATE`: fill
  `{{DURATION}}`, `{{EYEBROW}}`, `{{GHOST}}`, `{{TITLE_HTML}}`, `{{ACCENT}}`, `{{BG}}`, `{{FG}}`
  from the scene + `work/brand.json`; turn `<div class="sc-root">` into
  `<div class="sc-root" data-composition-id="root" data-start="0" data-duration="$DUR" data-width="1080" data-height="960">`;
  wrap in a full document whose `html,body` are `1080px × 960px`, `overflow:hidden`; copy `$GSAP`
  in as `gsap.min.js`; strip `<template>` wrappers and HTML comments; collapse `##` → `#`; then
  `( cd work/gfx_$i && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output ../top_beats/top_beat$i.mp4 --quality high --fps 30 )`.
  Every card pairs its title with an **illustrative animation** (feed grid, count-up stat,
  stacked chips, waveform…) enlarged and vertically centred so the card FILLS the zone.

```bash
for i in $(seq 0 $((N_BEATS-1))); do
  [ -s "work/top_beats/top_beat$i.mp4" ] || { echo "top beat $i did not render"; exit 1; }
done
```

### 2. Concatenate + normalise

```bash
for i in $(seq 0 $((N_BEATS-1))); do echo "file '$PWD/work/top_beats/top_beat$i.mp4'"; done > work/top_concat.txt
ffmpeg -y -f concat -safe 0 -i work/top_concat.txt \
  -vf "scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,setsar=1,fps=30,format=yuv420p" \
  -t "$BED_DUR" -an -c:v libx264 -preset medium -crf 20 -movflags +faststart saves/top_track.mp4
```

### 3. Verify — dims, duration, not black

```bash
read TW TH < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 saves/top_track.mp4 | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
[ "$TW" = 1080 ] && [ "$TH" = 960 ] || { echo "top track is ${TW}x${TH}, not 1080x960"; exit 1; }
TOP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/top_track.mp4)
python3 -c "assert abs(float('$TOP_DUR')-float('$BED_DUR'))<0.15, 'top track $TOP_DUR != bed $BED_DUR'"
for t in 1 $(python3 -c "print(round(float('$BED_DUR')/2,1))") $(python3 -c "print(round(float('$BED_DUR')-1,1))"); do
  Y=$(ffmpeg -ss "$t" -i saves/top_track.mp4 -frames:v 1 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*' | cut -d= -f2)
  python3 -c "assert float('$Y')>16, 'top zone black at ${t}s (YAVG=$Y)'"
done
echo "[split] top track OK: ${TOP_DUR}s"
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A beat that will not render, a missing
template / vendored component or a black frame is a failure: exit non-zero with one plain line
naming the beat index and the cause.

## Checks the harness runs

- `top_track_dims` — `saves/top_track.mp4` is exactly 1080×960.
- `top_track_not_black` — frames at 1 s, mid and end−1 s have mean luma above 16/255.
- `top_track_matches_bed` — duration equals the voice bed within 0.15 s.
