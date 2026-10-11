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
[ -n "${KIE_AI_API_KEY:-}" ] || { echo "kie.ai provider key is not set for this brand"; exit 1; }
REF_B64=$(python3 -c "import base64;print('data:image/png;base64,'+base64.b64encode(open('prior/char_ref.png','rb').read()).decode())")
N=$(python3 -c "import json;print(json.load(open('prior/story_arc.json'))['num_scenes'])")
```

### 1. Per scene, in order

Prompt = `"<brand imageStyle base, if any>. <lock_prompt, verbatim>. <scene.visual>.
<scene.camera>. Mood: <scene.emotion>. <scene.motion>. Same character as the reference image,
identical face, outfit and <attribute 5>. No text."` — `plush` adds the toy-photography
phrase. Body: `{"model": "gpt-image/1.5-image-to-image", "input": {"prompt": "...",
"input_urls": ["<REF_B64>"], "aspect_ratio": "9:16"}}`. Poll per the protocol in
`$SKILL_DIR/.hub/c-ai-media/SKILL.md`; record `task_id` in `work/tasks.json`.

```bash
curl -sL --max-time 60 "$URL" -o "work/raw-$i"
ffmpeg -y -v error -i "work/raw-$i" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -frames:v 1 "work/scene-$i.png"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "work/scene-$i.png"
```

### 2. Divergence check (after EVERY scene, before the next)

READ `work/scene-N.png` next to `prior/char_ref.png`, attribute by attribute. Face, outfit or
distinctive feature changed → regenerate now (tighten the drifting attribute in the prompt;
up to 3 attempts per scene). Also reject: black/dark centre, text in frame, distorted anatomy,
the character tiny in the frame. Record `divergence` and `attempts` per scene in
`work/tasks.json`. Do not start scene N+1 until scene N passes.

### 3. Write the saves

```bash
cp work/scene-1.png saves/scene_1.png
montage $(ls -v work/scene-*.png) -tile "${N}x1" -geometry "1080x1920+0+0" -background black saves/scene_sheet.png
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
credits, or a scene that still diverges after 3 attempts is a failure: exit non-zero with one
plain line naming the scene and the drifting attribute.

## Checks the harness runs

- `scene_dims` — `saves/scene_1.png` is exactly 1080×1920; `saves/scene_sheet.png` is
  `count`·1080 × 1920.
- `scenes_not_dark` — the centre zone (y 480–1440) of `saves/scene_1.png` and of every tile of
  the sheet has luma ≥ 16.
- `no_diverged_scenes` — every entry in `saves/scenes.json` has `divergence: "PASS"`.
