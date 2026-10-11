# Render and vision-check every slide

Render the HTML to one PNG per slide at exactly the canvas size, then run the mandatory
look-and-fix loop: precheck → READ every slide → fix the HTML → re-render → look again, until
every slide passes. Only a slide set that passed leaves this step.

## You receive

- `prior/carousel_html.md` — the authored HTML document (copy it to `work/carousel.html`).
- `prior/slide_copy.json` — `aspect_ratio` and the per-slide copy (what each slide must show).
- `brief.json` — `brand` (palette, for the on-brand rubric line), `intent`.
- `$SKILL_DIR/render.mjs`, `$SKILL_DIR/acceptance.json`, `$SKILL_DIR/.hub/c-vision-qa`,
  `$SKILL_DIR/.hub/c-eval-runner`.

## You must produce

- `saves/cover.png` — slide 1 at the exact canvas.
- `saves/slide_sheet.png` — every slide stacked vertically in order (canvas width × N·height),
  the owner's preview of the whole set.
- `saves/slides.json` — `{ "width", "height", "count", "slides": [ { "n", "sha256", "bytes" } ] }`
  describing the final slide PNGs in order (the captions step and the delivery read it).
- `saves/qa_report.json` — `{ "rounds": 2, "slides": [ { "n", "verdict": "PASS", "notes": [] } ] }`;
  every verdict `PASS`.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
cp prior/carousel_html.md work/carousel.html
AR=$(python3 -c "import json;print(json.load(open('prior/slide_copy.json'))['aspect_ratio'])")
W=1080; H=1350; [ "$AR" = "1:1" ] && H=1080
cd work && { [ -d node_modules/playwright ] || npm i playwright >/dev/null 2>&1; } && cd ..
```

### 1. Render

```bash
(cd work && WIDTH=$W HEIGHT=$H SCALE=2 node "$SKILL_DIR/render.mjs" carousel.html)
ls -v work/slides/slide-*.png
for f in work/slides/slide-*.png; do
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 "$f" \
    | tr '\n' ' '; echo " $f"
done
```

Every slide must be exactly `${W}x${H}` — `render.mjs` downscales the 2× capture and verifies
this; a mismatch is a render failure, not something to fix with a later resize.

### 2. Mechanical precheck

```bash
bash "$SKILL_DIR/.hub/c-vision-qa/scripts/precheck.sh" work/slides/*.png --aspect "${W}x${H}" --outdir work/qa
```

### 3. Vision look-and-fix loop (max 3 rounds)

READ every slide PNG with vision and score it against the rubric: no clipped or overflowing
text, legible contrast, consistent margins, on-brand palette (compare with `brief.json.brand`),
genuinely premium hierarchy (real layout, not a bare title), Latin charset intact, set
consistency. The cover is the brightest, strongest beat; no black or blank first/last slide.

Any FAIL → edit `work/carousel.html` for that slide → re-run step 1 and 2 → read again. Stop
after 3 rounds: if a slide still fails, this step fails with the remaining issues listed in
plain words (the owner sees them). Then the eval gate, once per slide:

```bash
BRAND=$(python3 -c "import json;print(json.load(open('brief.json'))['brand']['slug'])")
for f in work/slides/slide-*.png; do
  bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" "$f" --recipe-dir "$SKILL_DIR" --brand "$BRAND" || exit 1
done
```

`NEEDS_VISION` is resolved by the vision pass you just did; `FAIL` (exit 1) means fix and
re-render.

### 4. Write the saves

```bash
cp "$(ls -v work/slides/slide-*.png | head -1)" saves/cover.png
convert $(ls -v work/slides/slide-*.png) -append saves/slide_sheet.png
python3 - "$W" "$H" <<'PY'
import glob, hashlib, json, os, re, sys
W, H = int(sys.argv[1]), int(sys.argv[2])
files = sorted(glob.glob('work/slides/slide-*.png'), key=lambda p: int(re.search(r'(\d+)\.png$', p).group(1)))
assert files, "no slides rendered"
slides = [{"n": i+1, "sha256": hashlib.sha256(open(f,'rb').read()).hexdigest(), "bytes": os.path.getsize(f)} for i, f in enumerate(files)]
json.dump({"width": W, "height": H, "count": len(files), "slides": slides}, open('saves/slides.json','w'), indent=1)
qa = json.load(open('work/qa_report.json'))
assert all(s["verdict"] == "PASS" for s in qa["slides"]) and len(qa["slides"]) == len(files), "a slide did not pass"
json.dump(qa, open('saves/qa_report.json','w'), indent=1)
print(f"[carousel] {len(files)} slides {W}x{H}, QA rounds={qa['rounds']}")
PY
```

Keep `work/qa_report.json` up to date during the loop (one entry per slide, `notes` = the
fixes applied) so the save is the true record.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A slide that still fails after 3
rounds, a render that is not the exact canvas, or a missing Chromium is a failure: exit
non-zero with one plain line naming the slide and the issue.

## Checks the harness runs

- `slide_dims` — every slide in `saves/slides.json` (and `saves/cover.png`) is exactly
  `width`×`height`; `saves/slide_sheet.png` is `width` × `count`·`height`.
- `slide_not_blank` — luma floor ≥ 16 at five sample points on every slide; the cover is not
  black.
- `vision_qa_pass` — `saves/qa_report.json` has one entry per slide, all `verdict: "PASS"`.
