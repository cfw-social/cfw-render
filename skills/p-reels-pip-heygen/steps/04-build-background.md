# Build the background track

Render every beat of the beat list into a silent 1080×1920 clip and concatenate them into the one
background track the PIP card is composited over. `graphics` beats render via `c-typing-ui`
(`VARIANT=pip-safe`) or a brand motion-card HyperFrames template; `broll` beats are trimmed with
scale-to-COVER. The background is verified not-black BEFORE compositing.

## You receive

- `prior/beat_list.json` — the beats (`kind`, `start`, `end`, `broll`, `scene`).
- `prior/transcripts.json` — `.words` (card copy comes from what is said in each window).
- `prior/voice_track.mp4` — probe for `BED_DUR` only; never re-encode it here.
- `inputs/broll/` — the clips the `broll` beats reference.
- `brief.json` — `brand` (palette, typography, name) for the cards.

## You must produce

- `saves/background.mp4` — 1080×1920, 30 fps, H.264 yuv420p, **no audio**, duration = `BED_DUR`
  (±0.1 s), every sampled frame non-black. Graphics content stays above y≈1040 (pip-safe).

## How

```bash
mkdir -p work/bg_beats saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
TYPING_UI_DIR="$SKILL_DIR/.hub/c-typing-ui"; GSAP="$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
N_BEATS=$(python3 -c "import json; print(len(json.load(open('prior/beat_list.json'))['beats']))")
python3 -c "import json; json.dump(json.load(open('brief.json')).get('brand') or {}, open('work/brand.json','w'))"
```

### 1. Render each beat (concurrently, `nproc-1` jobs)

For beat `i` with `kind`, `start`, `end` (`dur = end - start`):

- **`broll`** — `ffmpeg -y -ss "$IN" -t "$DUR" -i "$CLIP" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" -an -c:v libx264 -preset medium -crf 20 work/bg_beats/bg_beat$i.mp4`.
- **`graphics`, typing / hook scene** — `VARIANT=pip-safe` with `c-typing-ui`:
  `bash "$TYPING_UI_DIR/scripts/render.sh" --text "<copy>" --duration "$DUR" --brand work/brand.json --variant pip-safe --out work/bg_beats/bg_beat$i.mp4` (see `$TYPING_UI_DIR/SKILL.md` for the exact flags).
- **`graphics`, motion card** — write `work/gfx_$i/index.html` from the brand motion-card
  template: `<div class="mc-root" data-composition-id="root" data-start="0" data-duration="$DUR"
  data-width="1080" data-height="1920">` with the headline / eyebrow / ghost text from the scene,
  brand palette from `work/brand.json`, `--pip-band: 680px` reserved at the bottom; copy `$GSAP` in
  as `gsap.min.js`; strip HTML comments; then
  `( cd work/gfx_$i && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output ../bg_beats/bg_beat$i.mp4 --quality high --fps 30 )`.

```bash
for i in $(seq 0 $((N_BEATS-1))); do
  [ -s "work/bg_beats/bg_beat$i.mp4" ] || { echo "beat $i did not render"; exit 1; }
done
```

### 2. Concatenate + normalise

```bash
for i in $(seq 0 $((N_BEATS-1))); do echo "file '$PWD/work/bg_beats/bg_beat$i.mp4'"; done > work/bg_concat.txt
ffmpeg -y -f concat -safe 0 -i work/bg_concat.txt \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -t "$BED_DUR" -an -c:v libx264 -preset medium -crf 20 -movflags +faststart saves/background.mp4
```

### 3. Verify not-black BEFORE compositing

```bash
for t in 1 $(python3 -c "print(round(float('$BED_DUR')/2,1))") $(python3 -c "print(round(float('$BED_DUR')-1,1))"); do
  ffmpeg -ss "$t" -i saves/background.mp4 -frames:v 1 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*'
done
BG_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/background.mp4)
python3 -c "assert abs(float('$BG_DUR')-float('$BED_DUR'))<0.15, 'background length mismatch'"
```

`YAVG` near 0 on any sample means a beat rendered black — find it (`bg_beat$i.mp4`), fix the
composition and rebuild; do not composite over a black background.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A beat that will not render after one
fix attempt, a missing `node`/Chromium, or a length mismatch is a failure: exit non-zero with one
plain line naming the beat index.

## Checks the harness runs

- `bg_not_black` — frames at 1 s, mid and end-1 s of `saves/background.mp4` have mean luma above
  16/255.
- `bg_matches_bed` — `saves/background.mp4` is 1080×1920 and within 0.15 s of the bed duration,
  with no audio stream.
