# Plan the background beats

Compute the **beat list** that tiles the whole voice bed: every second of the background is either
a `graphics` beat (HyperFrames motion card restating what is said) or, when b-roll was supplied, a
`broll` beat where the transcript matches a clip. `c-broll-sync` is the planner; this step always
runs — with no b-roll the result is 100 % graphics beats.

## You receive

- `prior/voice_track.mp4` — probe for `BED_DUR`.
- `prior/transcripts.json` — `.words` for transcript matching, `.broll_cues` per clip.
- `inputs/broll/` — the b-roll clips when supplied (dir absent = none).
- `brief.json` — `brand` (palette), `options.broll_coverage_pct` (30), `broll_clip_seconds` (5),
  `broll_min_seconds` (5), `broll_max_seconds` (5) — the locked 5 s beat grid, `broll_order` (`transcript-match`),
  `broll_reuse` (`false`), `cta_duration` (3).

## You must produce

- `saves/beat_list.json` — the `c-broll-sync` output: `{ beats: [ {index, kind: "broll"|"graphics",
  start, end, broll?: {clip, in, out}, scene?, slug?} ], achieved_broll_pct, shortfall_note?,
  cover_at }`. Beats are contiguous from 0 to `BED_DUR`. `broll.clip` paths are workdir-relative
  `inputs/broll/...`. `cover_at` is the money-shot timestamp (a graphics beat ~40 % in).

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"; BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
python3 - <<'PY'
import json
t = json.load(open('prior/transcripts.json')); b = json.load(open('brief.json'))
json.dump(t['words'], open('work/words.json','w'))
json.dump(t.get('broll_cues') or [], open('work/broll_cues.json','w'))
json.dump(b.get('brand') or {}, open('work/brand.json','w'))
PY
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
BROLL_COVERAGE=$(opt broll_coverage_pct 30); BROLL_CLIP_SECS=$(opt broll_clip_seconds 5)
BROLL_MIN_SECS=$(opt broll_min_seconds 5);   BROLL_MAX_SECS=$(opt broll_max_seconds 5)
BROLL_ORDER=$(opt broll_order transcript-match); BROLL_REUSE=$(opt broll_reuse false)
[ -d inputs/broll ] || BROLL_COVERAGE=0
```

If `work/broll_cues.json` is `[]` but clips exist in `inputs/broll/`, rebuild it with one entry
per clip (`{"clip", "duration" via ffprobe, "cues": []}`) so ordered placement still works.

### 1. Author `scene_plan.json` (mandatory)

`plan.js` exits 1 rather than hand a blank graphics card downstream, so write
`work/scene_plan.json` first (contract: `$BROLL_SYNC_DIR/SCENE-PLAN.md`): one `graphic` scene per
4–6 s idea with `headline` / `eyebrow` / `ghost` / `type` restating what is said in that window
(split: the card fills the whole 1080×960 top zone — eyebrow + title up top, illustration enlarged and centred below), optional `broll` scenes to pin a clip to a
window, and `cover: true` on the scene that is the money shot. Keep b-roll windows clear of the
first 2 s and of the final `cta_duration` seconds. Validate:

```bash
node "$BROLL_SYNC_DIR/scripts/validate-scene-plan.js" work/scene_plan.json \
  --bed-dur "$BED_DUR" --transcript work/words.json
```

### 2. Run the planner

```bash
node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript work/words.json --broll work/broll_cues.json \
  --coverage "$BROLL_COVERAGE" --clip-secs "$BROLL_CLIP_SECS" \
  --min-secs "$BROLL_MIN_SECS" --max-secs "$BROLL_MAX_SECS" \
  --order "$BROLL_ORDER" --reuse "$BROLL_REUSE" --bed-dur "$BED_DUR" \
  --brand work/brand.json --scene-plan work/scene_plan.json --out work/beat_list.json

python3 - "$BED_DUR" <<'PY'
import json, sys
bed = float(sys.argv[1]); bl = json.load(open('work/beat_list.json')); sp = json.load(open('work/scene_plan.json'))
beats = sorted(bl['beats'], key=lambda b: b['start'])
assert abs(beats[0]['start']) < 0.05 and abs(beats[-1]['end'] - bed) < 0.1, "beats do not tile the bed"
for a, b in zip(beats, beats[1:]): assert abs(a['end'] - b['start']) < 0.05, f"gap at {a['end']}"
cov = next((s for s in sp.get('scenes', []) if s.get('cover')), None)
bl['cover_at'] = round((cov['start'] + cov['end']) / 2, 2) if cov else round(bed * 0.4, 2)
if bl.get('shortfall_note'): print('[split] c-broll-sync:', bl['shortfall_note'])
json.dump(bl, open('saves/beat_list.json', 'w'), indent=1)
print(f"[split] {len(beats)} beats, {sum(1 for b in beats if b['kind']=='broll')} broll, cover_at={bl['cover_at']}")
PY
```

## If you cannot proceed

This step may ask for **`broll` only**, and only when b-roll WAS supplied but is unusable: every
clip fails ffprobe, or every clip is shorter than `broll_min_seconds` so zero b-roll windows can be
placed. Write `needs_input.json` and stop (no save):

```json
{ "inputId": "broll", "reason": "The b-roll clips could not be used — please add a few more clips of at least 2 seconds each.", "count": 2 }
```

No b-roll at all is NOT an ask (graphics-only is a valid reel). A shortfall that still yields ≥ 1
window is not an ask. Tool errors (node missing, planner crash) are failures, not asks.

## Checks the harness runs

- `beats_cover_bed` — `saves/beat_list.json` parses; `beats` are contiguous from 0 to `BED_DUR`
  (±0.1 s); every `broll` beat has `broll.clip` pointing at an existing input clip with
  `0 ≤ in < out ≤ clip duration`; `cover_at` lies inside the bed.
