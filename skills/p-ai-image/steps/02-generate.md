# Generate the images

Call kie.ai once per planned prompt, download every result, normalise it to the exact canvas
and write the batch plus a contact sheet. Regenerate anything that comes back broken.

## You receive

- `prior/prompts.json` — `count`, `aspect_ratio`, `model`, `negative`, `images[]`.
- `inputs/reference_image/<file>` — optional; when present every call is image-to-image with
  this file as the base64 reference.
- `brief.json` — `brand` (slug), `intent`.
- `KIE_AI_API_KEY` in the environment (exported by the harness).

## You must produce

- `saves/image_1.png` — the first image at the exact canvas (the owner's preview).
- `saves/contact_sheet.png` — all images tiled in order (single image: identical to `image_1`).
- `saves/images.json` — `{ "width", "height", "count", "cols", "model", "images": [ { "n",
  "task_id", "sha256", "bytes", "attempts" } ] }`. Only these three saves are uploaded: the
  full batch travels inside `contact_sheet.png` (`cols` tiles across, row-major) and the QA
  step re-splits it from this geometry.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
[ -n "${KIE_AI_API_KEY:-}" ] || { echo "kie.ai provider key is not set for this brand"; exit 1; }
AR=$(python3 -c "import json;print(json.load(open('prior/prompts.json'))['aspect_ratio'])")
case "$AR" in 9:16) W=1080; H=1920;; 16:9) W=1920; H=1080;; *) W=1080; H=1080;; esac
REF=$(ls inputs/reference_image/* 2>/dev/null | head -1)
```

### 1. Create and poll one task per image

Follow the protocol in `$SKILL_DIR/.hub/c-ai-media/SKILL.md` exactly (createTask → poll
`recordInfo` every 5 s, max 30 polls → `resultUrls[0]`). Text-to-image body:
`{"model": "<model>", "input": {"prompt": "<prompt>. Avoid: <negative>", "aspect_ratio": "<AR>"}}`.
With a reference: model `gpt-image/1.5-image-to-image`, `input_urls: ["data:image/png;base64,…"]`.
Record `task_id` per image in `work/tasks.json`. A `402` is "insufficient kie.ai credits" —
fail with that line. A task that fails or times out is retried once with the same prompt;
the second failure fails the step.

### 2. Download and normalise

```bash
# per image N with URL $URL
curl -sL --max-time 60 "$URL" -o "work/raw-$N"
ffmpeg -y -v error -i "work/raw-$N" -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H}" -frames:v 1 "work/img-$N.png"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "work/img-$N.png"
```

Then look at each `work/img-N.png`: a black/blank frame, an obvious generation failure
(distorted anatomy, duplicate limbs, watermark) or a subject missing from the prompt is
regenerated now (one extra attempt per image, counted in `attempts`). Mechanical precheck:

```bash
bash "$SKILL_DIR/.hub/c-vision-qa/scripts/precheck.sh" work/img-*.png --aspect "${W}x${H}" --outdir work/qa
```

### 3. Write the saves

```bash
cp work/img-1.png saves/image_1.png
N=$(python3 -c "import json;print(json.load(open('prior/prompts.json'))['count'])")
COLS=$(( N <= 1 ? 1 : (N <= 4 ? 2 : 3) ))
montage $(ls -v work/img-*.png) -tile "${COLS}x" -geometry "${W}x${H}+0+0" -background black saves/contact_sheet.png
python3 - "$W" "$H" "$COLS" <<'PY'
import glob, hashlib, json, os, re, sys
W, H, cols = map(int, sys.argv[1:4])
p = json.load(open('prior/prompts.json')); tasks = json.load(open('work/tasks.json'))
files = sorted(glob.glob('work/img-*.png'), key=lambda f: int(re.search(r'(\d+)\.png$', f).group(1)))
assert len(files) == int(p["count"]), "image count"
imgs = [{"n": i+1, "task_id": tasks[str(i+1)]["task_id"], "attempts": tasks[str(i+1)].get("attempts", 1),
         "sha256": hashlib.sha256(open(f,'rb').read()).hexdigest(), "bytes": os.path.getsize(f)} for i, f in enumerate(files)]
json.dump({"width": W, "height": H, "count": len(files), "cols": cols, "model": p["model"], "images": imgs},
          open('saves/images.json','w'), indent=1)
print(f"[ai-image] {len(files)} image(s) {W}x{H}, model {p['model']}")
PY
```

## If you cannot proceed

This step has no `canAsk` (`count`, `aspect_ratio` default; `reference_image` is optional).
Never write `needs_input.json`. A missing provider key, exhausted credits, or an image that
fails twice is a failure: exit non-zero with one plain line.

## Checks the harness runs

- `image_dims` — `saves/image_1.png` is exactly `width`×`height` from `saves/images.json`;
  `saves/contact_sheet.png` is `cols`·`width` wide and `ceil(count/cols)`·`height` tall.
- `not_black` — luma floor ≥ 16 at the centre of `saves/image_1.png` and of every tile of
  the contact sheet.
