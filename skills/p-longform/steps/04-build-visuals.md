# Build the visual layer

Render every non-footage visual the composite will place: brand GFX cards (stat reveals, quotes,
offer banners, the CTA card), AI stills, and — for `tutorial` (or `options.remotion = on`) —
HyperFrames / Remotion concept compositions and HTML slides. The format decides the mix.

## You receive

- `prior/transcripts.json` — `sections` in seconds, `words` (what is said when).
- `prior/section_map.json` — section types.
- `inputs/cta/cta.json` — `{"text","brandName","handle"}` when supplied; else `brief.json.brand`.
- `brief.json` — `brand` palette / typography / brief, `options.num_gfx` (6), `options.num_images`
  (4), `options.remotion`, `options.pip_mode`.

`KIE_API_KEY` for AI stills comes ONLY from the environment; unset with `num_images > 0` → render
GFX cards in place of the stills and say so in the log (not a failure).

## You must produce

- `saves/visuals_manifest.json` — every rendered asset lives in `work/visuals/` during this step;
  the composite step re-renders from this manifest's HTML sources, so each entry carries its
  **self-contained source** (inlined HTML/CSS/GSAP or the Remotion props):

```json
{ "canvas": {"w": 1920, "h": 1080, "fps": 25},
  "assets": [
    {"id": "gfx_01_stat", "kind": "gfx", "section": "proof", "at": 412.3, "seconds": 6,
     "html": "<!doctype html>...", "clear_zone": "pip-right"},
    {"id": "img_01", "kind": "still", "section": "problem", "at": 61.0, "seconds": 5, "prompt": "...", "png_b64": "..."},
    {"id": "concept_step_2", "kind": "hyperframes", "section": "step_2", "at": 188.0, "seconds": 22, "html": "..."},
    {"id": "cta", "kind": "gfx", "section": "cta", "at": null, "seconds": 8, "html": "...", "is_cta": true}
  ] }
```

- `saves/gfx_contact_sheet.png` — a 1920×1080 montage of every rendered card (`montage` from
  ImageMagick, 4 columns) for the owner's preview.

## How

```bash
mkdir -p work/visuals saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"
FMT=$(python3 -c "import json;print(json.load(open('prior/section_map.json'))['format'])")
```

### 1. Decide the cards

Walk `prior/transcripts.json.sections`: for each section pick the moments a visual earns its
place — a number ("45 posts a month" → count-up stat), a comparison (before/after columns), a
quote, a list ("three things" → checklist), a named feature (callout). Target
`options.num_gfx` cards spread across sections (never two in the hook), each 5–8 s, placed at the
word's `start`. Every card is **illustrative**: title + hero animation depicting the point.

### 2. Render GFX cards (`c-html-gfx` + HyperFrames)

Per card write `work/visuals/<id>/index.html` — 1920×1080, brand palette, grid + glow + vignette
background, GSAP eased + staggered elements loaded from a LOCAL copy of
`$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js`, content inside the safe zone and clear of the PIP
corner noted in `clear_zone` (`pip-left` / `pip-right`, alternating per beat; `none` when
`pip_mode = none`). Render: `npx hyperframes@0.7.5 render work/visuals/<id>/index.html --fps 25
--duration <seconds> --out work/visuals/<id>.mp4`. Verify 1920×1080 with `ffprobe`.

### 3. AI stills (`c-ai-media`, Kie) — `num_images` of them

For sections that need atmosphere rather than data (problem, agitation, overview), generate
`num_images` on-brand stills via `python3 "$SKILL_DIR/.hub/c-ai-media/scripts/generate.py"
--provider kie --aspect 16:9 --prompt "<brand-ref prompt>" --out work/visuals/img_NN.png`,
upscale / letterbox-fill to 1920×1080 (blurred-fill, no bars). Embed as `png_b64`.

### 4. Format-specific layer

- `vsl` — add one **offer banner** card for the `offer` section and the **CTA card** (`is_cta`).
- `demo` — add **callout overlays** (arrow + label, transparent background, `kind: "overlay"`) for
  each `walkthrough_*` section; they ride on top of the screen recording.
- `tutorial` (or `remotion = on`) — one HyperFrames / Remotion **concept composition** per
  `concept` section, full-length (`seconds` = section length), plus a **section title card**
  (3 s) at the start of every `step_*` section (chapter marker).

### 5. CTA card (always)

From `inputs/cta/cta.json` or `brief.json.brand`: offer line, brand name, handle only when
present; 8 s, brand palette, animated hero. `is_cta: true`, `section: "cta"`, `at: null` (the
composite pins it to the final 60 s).

### 6. Contact sheet and manifest

```bash
for d in work/visuals/*/; do ffmpeg -y -ss 2 -i "work/visuals/$(basename "$d").mp4" -frames:v 1 "work/visuals/$(basename "$d").png"; done
montage work/visuals/*.png -tile 4x -geometry 480x270+8+8 -background "#0F172A" work/sheet.png
convert work/sheet.png -resize 1920x1080 -background "#0F172A" -gravity center -extent 1920x1080 saves/gfx_contact_sheet.png
python3 -c "
import json; m=json.load(open('work/visuals_manifest.json')); a=m['assets']
assert any(x.get('is_cta') for x in a), 'CTA card missing'
assert sum(1 for x in a if x['kind']=='gfx') >= min(6, int((json.load(open('brief.json')).get('options') or {}).get('num_gfx') or 6)), 'too few gfx cards'
json.dump(m, open('saves/visuals_manifest.json','w')); print('OK', len(a), 'assets')"
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing CTA input falls back to the
brand; a missing Kie key downgrades stills to cards. A HyperFrames render that fails three times
is a failure — exit non-zero with the card id.

## Checks the harness runs

- `gfx_count_met` — `assets` has ≥ `num_gfx` entries of kind `gfx` (default 6).
- `gfx_dims` — every rendered `gfx` / `hyperframes` / `still` asset's embedded source renders to
  1920×1080 (`canvas` declared and the contact sheet is 1920×1080).
- `cta_card_present` — exactly one asset has `is_cta: true` with `section: "cta"`.
