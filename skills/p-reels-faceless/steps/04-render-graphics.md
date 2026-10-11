# Render the graphics

Render every beat of the beat list — one HyperFrames composition per graphics beat, one trimmed
segment per b-roll beat — and concatenate them in order into the silent **body track**. This is
the biggest step; parallelise beat renders if your engine offers sub-tasks.

## You receive

- `prior/beat_list.json` — the beats (`index`, `kind`, `slug`, `start`, `end`, scene fields).
- `prior/scene_plan.json` — the copy and hero type per graphics scene.
- `prior/voice_bed.mp4` — for the bed duration (the body must match it).
- `inputs/broll/` — the clips referenced by `broll` beats (`clip` path).
- `inputs/cta/cta.json` — `text`, `brandName`, `handle` for the CTA beat when supplied; else
  `brief.json.brand`.
- `brief.json` — `brand` palette / typography (Visual Identity Gate).

## You must produce

- `saves/body_video.mp4` — 1080×1920, 30 fps, H.264 yuv420p, **no audio**, duration equal to the
  bed (± 0.2 s), every beat present in order.

## How

```bash
mkdir -p work/gfx work/seg saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-faceless"
GSAP="$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js"; TYPING_UI="$SKILL_DIR/.hub/c-typing-ui"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_bed.mp4)
```

### 1. Resolve the Visual Identity Gate ONCE

Compute `BG`, `ACCENT`, `FG`, fonts from `brief.json.brand` (fallback `#0F172A` / `#F97316` /
`#F1F5F9`, Oswald + JetBrains Mono) and pass the same values verbatim to every beat. Collapse any
double-hash hex (`##0F172A` → `#0F172A`).

### 2. Graphics beats — one HyperFrames composition each

For each `kind: graphic` beat (span = `end - start`):

```bash
cd work/gfx && npx hyperframes@0.7.5 init "$SLUG" --non-interactive && cd "$SLUG"
cp "$GSAP" gsap.min.js          # local tag only: <script src="gsap.min.js"></script>
# author index.html: <div id="root" data-composition-id="main" data-start="0" data-duration="$SPAN">
npx hyperframes@0.7.5 lint      # 0 errors REQUIRED
npx hyperframes@0.7.5 render --output "$SLUG.mp4" --fps 30 --quality high
cd ../../..
```

Rules per composition: `type: hook`/`typing-ui` → start from the `c-typing-ui` template in
`$TYPING_UI` (strip the `<template>` wrapper, FULL variant); other types → author a brand
motion-graphic whose hero depicts the point (`stat` count-up with unit, `checklist` items ticking
in, `terminal` lines typing, `chips` popping with `back.out`, `flow` arrows drawing). Grid + glow +
vignette background in the brand palette, headline in the top ~65 %, ghost glyph behind, ambient
motion for the full span, `gsap.from()` only. The `cta` beat is the end card: offer line, brand
name, handle only if one exists.

### 3. B-roll beats — trimmed, silent, portrait

```bash
ffmpeg -y -ss "$CLIP_IN" -t "$SPAN" -i "$CLIP" -an \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -c:v libx264 -preset medium -crf 18 "work/seg/seg-broll_$(printf %02d "$IDX").mp4"
```

Pick `CLIP_IN` from the beat's `clip_start` when the planner set it, else the clip's most
motion-rich second (never the first black frame).

### 4. Normalise + concat in beat order

```bash
python3 - <<'PY'
import json, subprocess
bl = json.load(open("prior/beat_list.json")); lines = []
for b in sorted(bl["beats"], key=lambda x: x["index"]):
    raw = f"work/seg/seg-broll_{b['index']:02d}.mp4" if b["kind"] == "broll" else f"work/gfx/{b['slug']}/{b['slug']}.mp4"
    out = f"work/seg/norm-{b['index']:02d}.mp4"; span = round(b["end"] - b["start"], 3)
    subprocess.run(["ffmpeg","-y","-i",raw,"-t",str(span),"-vf","scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p",
                    "-an","-c:v","libx264","-preset","medium","-crf","18",out], check=True)
    lines.append(f"file '{out}'")
open("work/seglist.txt", "w").write("\n".join(lines) + "\n")
PY
ffmpeg -y -f concat -safe 0 -i work/seglist.txt -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -an saves/body_video.mp4
BODY_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/body_video.mp4)
python3 -c "b=float('$BED_DUR'); v=float('$BODY_DUR'); assert abs(b-v) < 0.2, f'body {v:.2f}s != bed {b:.2f}s'; print('body OK')"
```

### 5. Proof of motion (per beat)

For every graphics beat extract frames at 20 % and 80 % of the beat and confirm they differ
(`compare -metric RMSE` > 0.02) and neither is black. A static or blank beat is re-authored, not
shipped.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A lint error, a failed render or a
blank beat is a failure: fix the composition and retry; if it still fails, exit non-zero naming
the beat slug.

## Checks the harness runs

- `body_dims` — `saves/body_video.mp4` video stream is exactly 1080×1920.
- `body_not_black` — frames at 10/30/50/70/90 % have mean luma above 16/255.
- `body_matches_bed` — body duration equals the bed duration ± 0.2 s.
