# Plan the scenes

Author the **scene plan** (what each beat says and shows — the card copy is YOUR job, nothing
else writes it) and then let `c-broll-sync` turn it into the timed **beat list** that
`render_graphics` and `assemble` follow. No rendering happens here.

## You receive

- `prior/voice_bed.mp4` — for the bed duration.
- `prior/transcripts.json` — `words` (ground truth for `start_phrase` / `end_phrase`).
- `inputs/broll/` — zero or more clips when the owner supplied b-roll (dir absent = none).
- `brief.json` — `brand` (palette, name, brief), `options.broll_*`, `intent`.

## You must produce

- `saves/scene_plan.json` — the contract in `$SKILL_DIR/.hub/c-broll-sync/SCENE-PLAN.md`: one
  `graphic` scene per 4–6 s idea (hook · each claim · each step · the CTA), `kind: "broll"` only
  where a specific clip is pinned, `cover: true` on the scene whose frame is the feed cover
  (b-roll or the brightest card). Every graphic scene has `headline` (≤ 90 chars, `<span
  class="accent">` on the key word), `eyebrow`, `ghost`, `type`
  (`hook|terminal|chips|flow|checklist|stat|cta|standard`) and that type's passthrough fields
  (`lines`, `chips`, `items`, `flow`, `stat`+`unit`, `sub`). Timing uses `start_phrase` /
  `end_phrase` (verbatim transcript words), never guessed seconds. The LAST scene is `type: cta`.
- `saves/beat_list.json` — `c-broll-sync` output: `{"bed_duration", "cover_at", "achieved_broll_pct",
  "beats": [{"index","kind":"graphic|broll","slug","start","end","clip"?, ...scene fields}]}`.
  Beats are contiguous from 0 to the bed duration (gaps < 0.1 s).

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-faceless"
BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_bed.mp4)
python3 -c "import json;t=json.load(open('prior/transcripts.json'));json.dump(t['words'],open('work/vo-words.json','w'))"
python3 -c "import json;b=json.load(open('brief.json'));json.dump(b.get('brand') or {},open('work/brand.json','w'))"
```

### 1. B-roll cues (only when `inputs/broll/` has clips)

If the owner supplied clips, check they decode (`ffprobe` each; a clip that fails to decode or is
under 2 s is unusable). If `inputs/broll/` exists but every clip is unusable, write
`needs_input.json` for `broll` ("The b-roll clips could not be read — please upload MP4/MOV clips
of at least 2 seconds.") and stop. Do NOT ask when the dir is simply absent — no b-roll is a valid
all-graphics reel.

For usable clips, transcribe their speech/on-screen context the same way `transcribe` did and
write `work/broll_cues.json`: `[{"clip": "<path>", "duration": 7.2, "cues": [{"text","start","end"}]}]`
(empty `cues` for silent footage — the planner then uses order / even spacing).

### 2. Author `scene_plan.json`

Read the script via the transcript and write 6–14 scenes (~4–6 s each for a 30–90 s bed). Each
graphic scene must say what the hero animation depicts (`type` + fields); the ghost glyph is the
beat number or a thematic letter. Pick the cover scene deliberately (bright, mid-content, never
the hook). Validate:

```bash
node "$BROLL_SYNC_DIR/scripts/validate-scene-plan.js" work/scene_plan.json \
  --bed-dur "$BED_DUR" --transcript work/vo-words.json || { echo "scene_plan invalid — fix it; never render blank cards"; exit 1; }
cp work/scene_plan.json saves/scene_plan.json
```

### 3. Plan the beats

```bash
OPT() { python3 -c "import json;print((json.load(open('brief.json')).get('options') or {}).get('$1', '$2'))"; }
BROLL_ARG=""; [ -s work/broll_cues.json ] && BROLL_ARG=work/broll_cues.json
node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript work/vo-words.json --broll "$BROLL_ARG" \
  --coverage "$(OPT broll_coverage_pct 30)" --clip-secs "$(OPT broll_clip_seconds 4)" \
  --min-secs "$(OPT broll_min_seconds 2)" --max-secs "$(OPT broll_max_seconds 6)" \
  --order "$(OPT broll_order transcript-match)" --reuse "$(OPT broll_reuse false)" \
  --bed-dur "$BED_DUR" --brand work/brand.json --scene-plan saves/scene_plan.json \
  --out saves/beat_list.json
python3 - <<'PY'
import json
bl = json.load(open("saves/beat_list.json")); beats = sorted(bl["beats"], key=lambda b: b["index"])
assert beats[0]["start"] <= 0.1 and abs(beats[-1]["end"] - bl["bed_duration"]) < 0.5, "beats do not span the bed"
for a, b in zip(beats, beats[1:]): assert abs(a["end"] - b["start"]) < 0.1, f"gap between beat {a['index']} and {b['index']}"
assert beats[-1].get("type") == "cta", "last beat must be the CTA card"
print(f"{len(beats)} beats, broll={bl.get('achieved_broll_pct', 0):.0f}%, cover_at={bl.get('cover_at')}")
PY
```

## Checks the harness runs

- `beats_cover_bed` — `saves/beat_list.json` beats are contiguous from 0 to the bed duration,
  every beat has a `slug`, and the last beat is `type: cta`.
