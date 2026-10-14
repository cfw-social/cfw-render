# Vision QA and final checks

READ every generated image with vision, score it against the recipe's acceptance rubric, run
the eval-runner gate, and pick the final. Only images that pass leave this step; an image that
fails is a regeneration job for the previous step, not something to deliver.

## You receive

- `prior/images.json` — `width`, `height`, `count`, `cols`, `images[]` (`n`, `task_id`, `sha256`).
- `prior/image_1.png` — the first image at the exact canvas.
- `prior/contact_sheet.png` — all images tiled `cols` across in order.
- `prior/prompts.json` — the prompt each image was generated from (what the subject must be).
- `brief.json` — `brand` (slug, palette), `intent`.
- `$SKILL_DIR/acceptance.json`, `$SKILL_DIR/.hub/c-vision-qa`, `$SKILL_DIR/.hub/c-eval-runner`.

## You must produce

- `saves/final.png` — the delivered image (the best-scoring one; with a batch of 1 it is
  `image_1`), exact canvas.
- `saves/qa_report.json` — `{ "final_n": 1, "images": [ { "n", "verdict": "PASS",
  "scores": { "subject_rendered": "PASS", "no_artifacts": "PASS", "legible_text": "PASS",
  "palette_premium": "PASS", "composition_quality": "PASS" }, "notes": [] } ] }`.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
BRAND=$(python3 -c "import json;print(json.load(open('brief.json'))['brand']['slug'])")
read -r W H N COLS < <(python3 -c "import json;d=json.load(open('prior/images.json'));print(d['width'],d['height'],d['count'],d['cols'])")
```

### 1. Re-split the batch from the contact sheet

```bash
cp prior/image_1.png work/img-1.png
for i in $(seq 2 "$N"); do
  r=$(( (i-1) / COLS )); c=$(( (i-1) % COLS ))
  convert prior/contact_sheet.png -crop "${W}x${H}+$((c*W))+$((r*H))" +repage "work/img-$i.png"
done
python3 - <<'PY'
import hashlib, json
d = json.load(open('prior/images.json'))
assert hashlib.sha256(open('work/img-1.png','rb').read()).hexdigest() == d["images"][0]["sha256"], "image_1 changed in transit"
PY
```

### 2. Vision pass (every image)

READ each `work/img-N.png` next to its prompt from `prior/prompts.json` and score the five
perceptual lines of `$SKILL_DIR/acceptance.json`: (a) subject rendered as prompted, no
generation failures; (b) no AI artifacts, watermarks, seams; (c) any text legible and spelled
right; (d) palette premium and on-brand; (e) composition strong with a clear focal point.
Record a line-by-line `scores` map and plain-word `notes` per image in `work/qa_report.json`.

### 3. Eval-runner gate

```bash
for f in work/img-*.png; do
  bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" "$f" --recipe-dir "$SKILL_DIR" --brand "$BRAND" || exit 1
done
```

`FAIL` (exit 1) blocks; `NEEDS_VISION` is satisfied by the pass you just did — mark the
pending items from your scores.

### 4. Pick the final and write the saves

With a batch, `final_n` is the image with every line PASS and the strongest composition; with
one image it is 1. An image that fails any line is marked `verdict: "FAIL"` with the reason in
`notes` — if the chosen final (or the only image) fails, this step fails and names the defect.

```bash
python3 - <<'PY'
import json, shutil
qa = json.load(open('work/qa_report.json')); d = json.load(open('prior/images.json'))
assert len(qa["images"]) == d["count"], "one entry per image"
fin = int(qa["final_n"]); entry = next(i for i in qa["images"] if i["n"] == fin)
assert entry["verdict"] == "PASS" and all(v == "PASS" for v in entry["scores"].values()), f"image {fin} did not pass"
shutil.copy(f"work/img-{fin}.png", "saves/final.png")
json.dump(qa, open('saves/qa_report.json','w'), indent=1)
print(f"[ai-image] final = image {fin}; {sum(i['verdict']=='PASS' for i in qa['images'])}/{d['count']} passed")
PY
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 saves/final.png
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A final that fails the rubric or
the eval gate is a failure: exit non-zero with one plain line naming the defect so the
previous step can regenerate.

## Checks the harness runs

- `vision_qa_pass` — `saves/qa_report.json` has one entry per image; the `final_n` entry is
  `verdict: "PASS"` with every score PASS.
- `final_dims` — `saves/final.png` is exactly `width`×`height` from `prior/images.json` and
  its centre luma is ≥ 16.
