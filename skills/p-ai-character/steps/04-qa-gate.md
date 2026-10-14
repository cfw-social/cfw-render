# Vision QA and final checks

READ the whole scene set against the reference and the recipe's perceptual rubric, run the
eval-runner gate on each scene, and confirm the cover. Only a set where every scene passes
leaves this step.

## You receive

- `prior/scenes.json` — `width`, `height`, `count`, `scenes[]` (`n`, `sha256`, `attempts`).
- `prior/scene_1.png` — the cover scene.
- `prior/scene_sheet.png` — all scenes in one row, in order.
- `prior/char_ref.png` — the locked reference.
- `prior/character_lock.json` — `attributes` (what to compare against).
- `prior/story_arc.json` — what each scene must show.
- `brief.json` — `brand` (slug), `intent`.
- `$SKILL_DIR/acceptance.json`, `$SKILL_DIR/.hub/c-eval-runner`.

## You must produce

- `saves/final.png` — the cover scene (scene 1), exact canvas, confirmed as the money shot.
- `saves/qa_report.json` — `{ "final_n": 1, "scenes": [ { "n", "verdict": "PASS",
  "scores": { "character_consistency": "PASS", "no_diverged_frames": "PASS",
  "character_fills_frame": "PASS", "cover_is_moneyshot": "PASS" }, "notes": [] } ] }`
  (`cover_is_moneyshot` scored on scene 1 only; other scenes carry `"n/a"`).

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
BRAND=$(python3 -c "import json;print(json.load(open('brief.json'))['brand']['slug'])")
N=$(python3 -c "import json;print(json.load(open('prior/scenes.json'))['count'])")
```

### 1. Re-split the set from the sheet

```bash
cp prior/scene_1.png work/scene-1.png
for i in $(seq 2 "$N"); do
  convert prior/scene_sheet.png -crop "1080x1920+$(( (i-1)*1080 ))+0" +repage "work/scene-$i.png"
done
python3 - <<'PY'
import hashlib, json
d = json.load(open('prior/scenes.json'))
assert hashlib.sha256(open('work/scene-1.png','rb').read()).hexdigest() == d["scenes"][0]["sha256"], "scene_1 changed in transit"
PY
```

### 2. Vision pass (the set as a whole)

READ `prior/char_ref.png`, then every `work/scene-N.png` in order, next to its arc entry, and
score the perceptual lines of `$SKILL_DIR/acceptance.json`: (a) all six attributes held in
every scene; (b) no diverged frame — face, outfit, distinctive feature identical to the
reference; (d) the character fills the frame; (e) scene 1 is a compelling, bright, clear
cover. Scenes also have to read as the story (act order visible, emotion matches). Record
`scores` and plain-word `notes` per scene in `work/qa_report.json`.

### 3. Eval-runner gate

```bash
for f in work/scene-*.png; do
  bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" "$f" --recipe-dir "$SKILL_DIR" --brand "$BRAND" || exit 1
done
```

The recipe's `acceptance.json` top-level gate targets the older video flow; for still scenes
the runner applies the geometry (`canvas_1080x1920`, `scenes_not_dark`) and perceptual lines
and skips video-only mechanical checks. `FAIL` (exit 1) blocks; `NEEDS_VISION` is satisfied
by the pass you just did.

### 4. Write the saves

```bash
python3 - <<'PY'
import json, shutil
qa = json.load(open('work/qa_report.json')); d = json.load(open('prior/scenes.json'))
assert len(qa["scenes"]) == d["count"], "one entry per scene"
assert int(qa["final_n"]) == 1, "the cover is scene 1"
for s in qa["scenes"]:
    assert s["verdict"] == "PASS" and all(v in ("PASS", "n/a") for v in s["scores"].values()), f"scene {s['n']} did not pass"
assert qa["scenes"][0]["scores"]["cover_is_moneyshot"] == "PASS", "cover is not the money shot"
shutil.copy('work/scene-1.png', 'saves/final.png')
json.dump(qa, open('saves/qa_report.json','w'), indent=1)
print(f"[character] {d['count']}/{d['count']} scenes passed; cover confirmed")
PY
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 saves/final.png
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A scene that fails the rubric or
the eval gate is a failure: exit non-zero with one plain line naming the scene and the defect
so the scene step can regenerate it.

## Checks the harness runs

- `vision_qa_pass` — `saves/qa_report.json` has one entry per scene, every `verdict: "PASS"`,
  and `cover_is_moneyshot: "PASS"` on scene 1.
- `final_dims` — `saves/final.png` is exactly 1080×1920 and its centre zone luma is ≥ 16.
