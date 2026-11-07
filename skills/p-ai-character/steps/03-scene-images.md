# Generate the scene images

One image-to-image call per scene, every call anchored on the reference. Audit each scene for
divergence before moving to the next; a diverged scene is regenerated, never carried forward.

## You receive

- `prior/char_ref.png` — the locked reference (1080×1920).
- `prior/character_lock.json` — `type`, `attributes`, `lock_prompt`.
- `prior/story_arc.json` — `num_scenes`, `scenes[]` (`n`, `act`, `visual`, `emotion`, `camera`, `motion`).
- `brief.json` — `brand` (`imageStyle` when present), `intent`.
- `KIE_AI_API_KEY` in the environment (exported by the harness).

## You must produce

- `saves/scene_1.png` — scene 1 (the cover) at exactly 1080×1920.
- `saves/scene_sheet.png` — every scene side by side in order (`count`·1080 × 1920), the
  owner's preview of the whole story.
- `saves/scenes.json` — `{ "width": 1080, "height": 1920, "count", "scenes": [ { "n",
  "task_id", "attempts", "sha256", "bytes", "divergence": "PASS" } ] }`. The full set travels
  inside `scene_sheet.png` (one row); the QA step re-splits it from this geometry.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
GEN="$SKILL_DIR/.hub/c-ai-media/scripts/generate.py"
[ -n "${KIE_AI_API_KEY:-}" ] || { echo "kie.ai provider key is not set for this brand"; exit 1; }
N=$(python3 -c "import json;print(json.load(open('prior/story_arc.json'))['num_scenes'])")
```

### 1. Per scene, in order

Prompt = `"<brand imageStyle base, if any>. <lock_prompt, verbatim>. <scene.visual>.
<scene.camera>. Mood: <scene.emotion>. <scene.motion>. Same character as the reference image,
identical face, outfit and <attribute 5>. No text."` — `plush` adds the toy-photography
phrase. Keep it under 4000 characters.

Generate with the vendored `generate.py` (one call = one paid image, about 10 Kie credits at
`2K`). It uploads `prior/char_ref.png` to Kie's free File Upload API and sends the hosted URL
in `input_urls` of `gpt-image-2-image-to-image` with `aspect_ratio: "9:16"` and
`resolution: "2K"`. Never put the reference in the request as a base64 `data:` URI: Kie's
image-to-image models take a hosted file URL, not file content (the data-URI request failed
with createTask code 500 in order TSW3). Do not hand-write the API calls; the script holds
the spend rules.

```bash
python3 "$GEN" --provider kie --model gpt-image-2-image-to-image --aspect 9:16 --resolution 2K \
  --ref prior/char_ref.png --prompt "$PROMPT" --out "work/raw-$i.png" --timeout 240 --poll 5 \
  > "work/gen-$i.log" 2>&1
RC=$?; tail -1 "work/gen-$i.log"
[ "$RC" -eq 0 ] || exit 1      # IMAGE_FAILED: the reason is on the last line; never repeat the call
TASK=$(sed -n 's/^KIE_TASK: //p' "work/gen-$i.log" | tail -1)   # record it in work/tasks.json
ffmpeg -y -v error -i "work/raw-$i.png" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -frames:v 1 "work/scene-$i.png"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "work/scene-$i.png"
```

Fail-fast rules (enforced by the script; do not work around them): the create call is made once
and never retried; status is polled every 5 s for at most 240 s (48 polls), then the step fails
naming the task id. Kie code `402` ("not enough Kie credits") stops the step at once — no
further scene is attempted. A refused reference upload stops it before anything is spent. If
Kie's recorded task input lost the reference (`input_urls`), the image is refused rather than
used, because it would not be anchored on the character. A divergence regeneration (below) is
a new, deliberate call, not a retry.

### 2. Divergence check (after EVERY scene, before the next)

READ `work/scene-N.png` next to `prior/char_ref.png`, attribute by attribute. Face, outfit or
distinctive feature changed → regenerate now (tighten the drifting attribute in the prompt;
up to 3 attempts per scene). Also reject: black/dark centre, text in frame, distorted anatomy,
the character tiny in the frame. Record `divergence` and `attempts` per scene in
`work/tasks.json`. Do not start scene N+1 until scene N passes.

### 3. Write the saves

```bash
cp work/scene-1.png saves/scene_1.png
# One row, scene 1..N in order, with plain appends that need no font. (`montage` always loads a
# font and exits 1, "unable to read font `'", where ImageMagick has no default font.)
SHEET=()
for ((i = 1; i <= N; i++)); do SHEET+=( "work/scene-$i.png" ); done
convert "${SHEET[@]}" +append saves/scene_sheet.png
python3 - <<'PY'
import glob, hashlib, json, os, re
arc = json.load(open('prior/story_arc.json')); tasks = json.load(open('work/tasks.json'))
files = sorted(glob.glob('work/scene-*.png'), key=lambda f: int(re.search(r'(\d+)\.png$', f).group(1)))
assert len(files) == int(arc["num_scenes"]), "scene count"
scenes = []
for i, f in enumerate(files):
    t = tasks[str(i+1)]; assert t.get("divergence") == "PASS", f"scene {i+1} diverged"
    scenes.append({"n": i+1, "task_id": t["task_id"], "attempts": t.get("attempts", 1), "divergence": "PASS",
                   "sha256": hashlib.sha256(open(f,'rb').read()).hexdigest(), "bytes": os.path.getsize(f)})
json.dump({"width": 1080, "height": 1920, "count": len(files), "scenes": scenes}, open('saves/scenes.json','w'), indent=1)
print(f"[character] {len(files)} scenes, {sum(s['attempts'] for s in scenes)} generations")
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing provider key, exhausted
credits, a refused upload or generation (`IMAGE_FAILED`), or a scene that still diverges after
3 attempts is a failure: exit non-zero with one plain line naming the scene and the drifting
attribute or the Kie reason.

## Checks the harness runs

- `scene_dims` — `saves/scene_1.png` is exactly 1080×1920; `saves/scene_sheet.png` is
  `count`·1080 × 1920.
- `scenes_not_dark` — the centre zone (y 480–1440) of `saves/scene_1.png` and of every tile of
  the sheet has luma ≥ 16.
- `no_diverged_scenes` — every entry in `saves/scenes.json` has `divergence: "PASS"`.
