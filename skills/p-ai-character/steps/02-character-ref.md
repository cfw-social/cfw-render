# Generate the character reference

Produce the single reference image every scene call will be anchored to: full body, clean
studio background, all six attributes visible. Audit it against the lock before saving.

## You receive

- `prior/character_lock.json` — `type`, `attributes`, `lock_prompt`.
- `inputs/reference_image/<file>` — optional; an existing character image the owner wants
  kept. When present, the reference is an image-to-image pass that keeps that character and
  places it in the studio setup; the audit still applies.
- `brief.json` — `brand` (`imageStyle` when present), `intent`.
- `KIE_AI_API_KEY` in the environment (exported by the harness).

## You must produce

- `saves/char_ref.png` — the reference at exactly `1080×1920`.
- `saves/ref_audit.json` — `{ "task_id": "...", "model": "...", "attempts": 1, "audit": {
  "1": "PASS", "2": "PASS", "3": "PASS", "4": "PASS", "5": "PASS", "6": "PASS" }, "notes": [] }`.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
[ -n "${KIE_AI_API_KEY:-}" ] || { echo "kie.ai provider key is not set for this brand"; exit 1; }
LOCK=$(python3 -c "import json;print(json.load(open('prior/character_lock.json'))['lock_prompt'])")
TYPE=$(python3 -c "import json;print(json.load(open('prior/character_lock.json'))['type'])")
REF=$(ls inputs/reference_image/* 2>/dev/null | head -1)
```

### 1. The prompt

`"<brand imageStyle base, if any>. <LOCK>. Full body, standing, facing camera, product
photography, plain white studio background, clean soft studio lighting, no text."` — for
`plush` append `", plush toy, soft fabric texture, photorealistic toy photography"`. The lock
sentence is included verbatim — never paraphrased.

### 2. Create, poll, download

Use the vendored `$SKILL_DIR/.hub/c-ai-media/scripts/generate.py` (one call = one paid image;
it makes the create call once, polls every 5 s up to `--timeout`, and stops on Kie code `402`
with "not enough Kie credits"). Without `$REF`: text-to-image, `google/imagen4-fast`,
`aspect_ratio: "9:16"`, 150 s (30 polls). With `$REF`: image-to-image,
`gpt-image-2-image-to-image`, `aspect_ratio: "9:16"`, `resolution: "2K"` (about 10 Kie
credits); the script uploads the reference to Kie's free File Upload API and sends the hosted
URL in `input_urls`. Never send the reference as a base64 `data:` URI — Kie's image-to-image
models read `input_urls` as a hosted file URL, not file content (the data-URI request failed
with createTask code 500 in order TSW3). First copy the owner's file to a JPEG of at most
2048 px a side (well under Kie's 10 MB limit, any input format).

```bash
GEN="$SKILL_DIR/.hub/c-ai-media/scripts/generate.py"
if [ -n "$REF" ]; then
  ffmpeg -y -v error -i "$REF" -vf "scale='min(2048,iw)':'min(2048,ih)':force_original_aspect_ratio=decrease" -frames:v 1 -q:v 2 work/ref-in.jpg
  python3 "$GEN" --provider kie --model gpt-image-2-image-to-image --aspect 9:16 --resolution 2K \
    --ref work/ref-in.jpg --prompt "$PROMPT" --out work/raw-ref.png --timeout 240 --poll 5 > work/gen.log 2>&1
else
  python3 "$GEN" --provider kie --model google/imagen4-fast --aspect 9:16 \
    --prompt "$PROMPT" --out work/raw-ref.png --timeout 150 --poll 5 > work/gen.log 2>&1
fi
RC=$?; tail -1 work/gen.log
[ "$RC" -eq 0 ] || exit 1      # IMAGE_FAILED: the reason is on the last line; never repeat the call
TASK=$(sed -n 's/^KIE_TASK: //p' work/gen.log | tail -1)   # the task_id for ref_audit.json
ffmpeg -y -v error -i work/raw-ref.png -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -frames:v 1 work/char-ref.png
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 work/char-ref.png
```

### 3. Audit against the lock

READ `work/char-ref.png` and check each of the six attributes from `prior/character_lock.json`
is visibly present and correct; also: full body in frame, plain background, no text, no
distorted anatomy. Any attribute that fails → regenerate (tighten the wording of the failing
attribute in the prompt; up to 3 attempts total). Record the per-attribute verdicts in
`work/ref_audit.json`.

### 4. Write the saves

```bash
python3 - <<'PY'
import json, shutil
a = json.load(open('work/ref_audit.json'))
assert set(a["audit"]) == {"1","2","3","4","5","6"} and all(v == "PASS" for v in a["audit"].values()), "reference failed the six-attribute audit"
shutil.copy('work/char-ref.png', 'saves/char_ref.png')
json.dump(a, open('saves/ref_audit.json','w'), indent=1)
print(f"[character] reference locked after {a.get('attempts',1)} attempt(s), model {a['model']}")
PY
```

## If you cannot proceed

This step has no `canAsk` (`reference_image` is optional). Never write `needs_input.json`. A
missing provider key, exhausted credits, a refused upload or generation (`IMAGE_FAILED`), or a
reference that fails the audit three times is a failure: exit non-zero with one plain line
naming the failing attribute or the Kie reason.

## Checks the harness runs

- `ref_dims` — `saves/char_ref.png` is exactly 1080×1920.
- `not_black` — centre luma of `saves/char_ref.png` ≥ 16.
- `ref_matches_lock` — `saves/ref_audit.json` has six `PASS` verdicts.
