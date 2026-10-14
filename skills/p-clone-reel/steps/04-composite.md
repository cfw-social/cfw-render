# Composite in the reference format

Rebuild the reference layout around the brand's narration: key the avatar (when there is one),
place it where the reference placed its presenter (PIP) or in a split, fill the rest of the canvas
with brand graphics that follow the reference's visual rhythm, add captions, append the brand
outro / CTA card and master the mix. The narration audio is the spine and is never cut.

## You receive

- `prior/narration.mp4` — the sealed narration (green-screen avatar or solid-colour voice bed).
- `prior/format_analysis.json` — `layout` (`presenter`, `pip`, `split`), `pacing`, `sections`.
- `prior/adapted_script.md` — for captions (word timing comes from a transcription of the
  narration, below).
- `prior/source_video.mp4` — for layout reference ONLY (measure, sample, compare); its frames are
  never placed in the output.
- `inputs/cta/cta.json` — `{"text","brandName","handle"}` when supplied; else `brief.json.brand`.
- `brief.json` — `brand` palette, `options.layout` (`auto|pip|split`), `options.captions`.

## You must produce

- `saves/composite_video.mp4` — 1080×1920, 30 fps, H.264 yuv420p, AAC 48 kHz stereo, mastered to
  −14 LUFS; narration continuous from 0 to its full length, then a 2–3 s brand CTA card.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-clone-reel"
NAR=prior/narration.mp4
NDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$NAR")
# detect mode from the edge pixels: green → avatar, otherwise voice-only bed
MODE=$(ffmpeg -v error -ss 1 -i "$NAR" -vf "crop=40:40:0:0,scale=1:1" -frames:v 1 -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys;r,g,b=sys.stdin.buffer.read()[:3];print('avatar' if g>180 and r<90 and b<90 else 'voice')")
LAYOUT=$(python3 -c "import json;o=json.load(open('brief.json')).get('options') or {};f=json.load(open('prior/format_analysis.json'))['layout'];l=o.get('layout','auto');print(l if l!='auto' else ('split' if f.get('split') else 'pip'))")
echo "mode=$MODE layout=$LAYOUT narration=${NDUR}s"
```

### 1. Background track (brand graphics in the reference rhythm)

Build `work/bg.mp4` (1080×1920, exactly `$NDUR` s) with `c-html-gfx`: one brand card per
reference beat (`sections` + `pacing.cuts_per_10s` set the cut cadence), each card an illustrative
hero (stat, chip row, checklist, diagram) in the brand palette — never a bare title, never a frame
from the reference. Keep card content in the top ~65 % when `LAYOUT=pip` sits the avatar low; for
`split`, the cards fill the top half (1080×960) and the avatar the bottom half.

### 2. Avatar layer

```bash
if [ "$MODE" = avatar ]; then
  if [ "$LAYOUT" = pip ]; then
    read CX CY DIA < <(python3 -c "import json;p=json.load(open('prior/format_analysis.json'))['layout'].get('pip') or {};print(p.get('cx',540),p.get('cy',1500),int(p.get('diameter',420)*1.15))")
    ffmpeg -y -i work/bg.mp4 -i "$NAR" -filter_complex \
      "[1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=${DIA}:-2,crop=${DIA}:${DIA},format=rgba,geq=lum='p(X,Y)':a='if(lte(hypot(X-W/2,Y-H/2),W/2),255,0)'[av];[0:v][av]overlay=${CX}-${DIA}/2:${CY}-${DIA}/2:shortest=1[v]" \
      -map "[v]" -map 1:a -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -c:a copy work/body.mp4
  else
    ffmpeg -y -i work/bg.mp4 -i "$NAR" -filter_complex \
      "[0:v]crop=1080:960:0:0[top];[1:v]colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,scale=1080:-2,crop=1080:960[bot];[top][bot]vstack[v]" \
      -map "[v]" -map 1:a -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -c:a copy work/body.mp4
  fi
else
  ffmpeg -y -i work/bg.mp4 -i "$NAR" -map 0:v -map 1:a -shortest -c:v libx264 -pix_fmt yuv420p -crf 18 -c:a copy work/body.mp4
fi
```

For `split` with an avatar the split background sits behind a brand colour, not the green. Inspect
one keyed frame at 50 % for fringe: a visible green halo means the key thresholds are wrong for
this render — widen the second pass to `0.45:0.01`, never switch to `chromakey`.

### 3. Captions (default on)

Transcribe `prior/narration.mp4` (`c-audio` Whisper, word timestamps) and burn word-synced captions
in the lower third (y ≈ 1450–1700, Oswald, brand accent for the active word), clear of the PIP zone
on `pip` layouts. Latin script only. `options.captions = off` skips this.

### 4. Outro / CTA card and master

Render the end card with `c-html-gfx` from `inputs/cta/cta.json` or `brief.json.brand` (offer
line, brand name, handle only when present), 2.5 s, 1080×1920, then concat (re-encode, never
`-c copy`) and master:

```bash
printf "file '%s'\nfile '%s'\n" "$PWD/work/body-captioned.mp4" "$PWD/work/cta.mp4" > work/concat.txt
ffmpeg -y -f concat -safe 0 -i work/concat.txt -af "loudnorm=I=-14:TP=-1.5:LRA=11" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/composite_video.mp4
ffmpeg -v error -i saves/composite_video.mp4 -f null -
```

Verify: duration ≈ `$NDUR + 2.5`, dims 1080×1920, last frame mean luma > 30/255.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing CTA falls back to the brand;
a narration that fails to decode is a failure of the previous step — exit non-zero and say so.

## Checks the harness runs

- `composite_dims` — video stream is exactly 1080×1920.
- `composite_not_black` — frames at 10/30/50/70/90 % have mean luma above 16/255.
- `vo_continuous_bed` — the narration audio runs uncut from 0 to the narration's length (no
  silence gap > 0.6 s before the outro).
