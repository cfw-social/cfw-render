# Render to PNG

Screenshot every card with headless Chromium, crop to the exact canvas, verify the dims, and
write the batch plus a contact sheet. Re-render anything that comes out blank.

## You receive

- `prior/cards_html.json` — `width`, `height`, `format`, `cards[]` (`n`, `html`).
- `brief.json` — `intent` (for the log line only).
- `$SKILL_DIR/.hub/c-vision-qa/scripts/precheck.sh`.

## You must produce

- `saves/image_1.png` — card 1 at the exact canvas (the owner's preview).
- `saves/contact_sheet.png` — all cards tiled in order (a single card: identical to `image_1`).
- `saves/images.json` — `{ "width", "height", "count", "cols", "images": [ { "n", "sha256",
  "bytes" } ] }`. The full batch travels inside `contact_sheet.png` (`cols` tiles across,
  row-major); the QA step re-splits it from this geometry.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
read -r W H N < <(python3 -c "import json;d=json.load(open('prior/cards_html.json'));print(d['width'],d['height'],len(d['cards']))")
python3 - <<'PY'
import json
for c in json.load(open('prior/cards_html.json'))["cards"]:
    open(f"work/card-{c['n']}.html", "w").write(c["html"])
PY
CHROME=${CHROMIUM_BIN:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}
```

### 1. Screenshot and crop each card

```bash
for i in $(seq 1 "$N"); do
  if [ -n "$CHROME" ]; then
    "$CHROME" --headless --screenshot="work/shot-$i.png" --window-size="$W,$((H+140))" \
      --hide-scrollbars --no-sandbox "file://$PWD/work/card-$i.html" 2>/dev/null
  else
    npx -y playwright screenshot --viewport-size="$W,$H" "file://$PWD/work/card-$i.html" "work/shot-$i.png"
  fi
  ffmpeg -y -v error -i "work/shot-$i.png" -vf "crop=${W}:${H}:0:0" "work/img-$i.png"
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "work/img-$i.png"
done
```

Every `work/img-N.png` must report exactly `W,H`. If a screenshot is smaller than the canvas
(the window was clamped), retry with `--force-device-scale-factor=1` and, failing that, the
Playwright path.

### 2. Look at each render

Open each `work/img-N.png`: fonts loaded (no system-serif fallback), entities rendered
(`&rarr;` is an arrow, not literal text), nothing clipped, nothing blank. A blank or
half-loaded card is re-rendered after adding a `<script>` that waits for `document.fonts.ready`
or a `--virtual-time-budget=5000` flag. Then the mechanical precheck:

```bash
bash "$SKILL_DIR/.hub/c-vision-qa/scripts/precheck.sh" work/img-*.png --aspect "${W}x${H}" --outdir work/qa
```

### 3. Write the saves

```bash
cp work/img-1.png saves/image_1.png
COLS=$(( N <= 1 ? 1 : 2 ))
montage $(ls -v work/img-*.png) -tile "${COLS}x" -geometry "${W}x${H}+0+0" -background black saves/contact_sheet.png
python3 - "$W" "$H" "$COLS" <<'PY'
import glob, hashlib, json, os, re, sys
W, H, cols = map(int, sys.argv[1:4])
files = sorted(glob.glob('work/img-*.png'), key=lambda f: int(re.search(r'(\d+)\.png$', f).group(1)))
n = len(json.load(open('prior/cards_html.json'))["cards"])
assert len(files) == n, "image count"
imgs = [{"n": i+1, "sha256": hashlib.sha256(open(f,'rb').read()).hexdigest(), "bytes": os.path.getsize(f)} for i, f in enumerate(files)]
json.dump({"width": W, "height": H, "count": n, "cols": cols, "images": imgs}, open('saves/images.json','w'), indent=1)
print(f"[gfx] {n} image(s) rendered at {W}x{H}")
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. No usable Chromium, a screenshot
that is not the exact canvas after the retries, or a card that renders blank twice is a
failure: exit non-zero with one plain line naming the card.

## Checks the harness runs

- `image_dims` — `saves/image_1.png` is exactly `width`×`height` from `saves/images.json`;
  `saves/contact_sheet.png` is `cols`·`width` wide and `ceil(count/cols)`·`height` tall.
- `not_black` — luma floor ≥ 16 at five sample points on `saves/image_1.png` and on every
  tile of the contact sheet.
