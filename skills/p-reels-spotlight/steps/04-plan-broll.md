# Plan b-roll

Runs only when `broll` was supplied. Computes the b-roll takeover **beat list** with `c-broll-sync`.
Its beats are **merged** with the graphics takeovers from the edit plan — b-roll beats become
additional full-frame picture takeovers; they never replace the planned graphics and never touch
the voice bed.

## You receive

- `inputs/broll/` — the b-roll clips (one or more video files).
- `prior/voice_track.mp4` — probe for `BED_DUR`.
- `prior/transcripts.json` — `.words` for transcript matching, `.broll_cues` per clip.
- `prior/edit_plan.json` — `brand`, `takeovers` (so b-roll beats avoid them), `cover_at`.
- `brief.json` — `options.broll_coverage_pct` (30), `broll_clip_seconds` (4), `broll_min_seconds`
  (2), `broll_max_seconds` (6), `broll_order` (`transcript-match`), `broll_reuse` (`false`).

## You must produce

- `saves/beat_list.json` — the `c-broll-sync` output: `{ beats: [ {index, kind: "broll"|"graphics"|
  "avatar", start, end, broll?: {clip, in, out}, scene?, slug?} ], achieved_broll_pct, shortfall_note? }`.
  `broll.clip` paths are workdir-relative `inputs/broll/...`.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-spotlight"
BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
python3 - <<'PY'
import json
t = json.load(open('prior/transcripts.json')); p = json.load(open('prior/edit_plan.json'))
json.dump(t['words'], open('work/words.json','w'))
json.dump(t.get('broll_cues') or [], open('work/broll_cues.json','w'))
json.dump(p['brand'], open('work/brand.json','w'))
PY
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
BROLL_COVERAGE=$(opt broll_coverage_pct 30); BROLL_CLIP_SECS=$(opt broll_clip_seconds 4)
BROLL_MIN_SECS=$(opt broll_min_seconds 2);   BROLL_MAX_SECS=$(opt broll_max_seconds 6)
BROLL_ORDER=$(opt broll_order transcript-match); BROLL_REUSE=$(opt broll_reuse false)
```

If `work/broll_cues.json` is `[]` but clips exist in `inputs/broll/`, rebuild it with one entry
per clip (`{"clip", "duration" via ffprobe, "cues": []}`) so ordered placement still works.

### 1. Author `scene_plan.json` (mandatory — CFW-131)

`plan.js` exits 1 rather than hand a blank graphics card downstream, so write
`work/scene_plan.json` first (contract: `$BROLL_SYNC_DIR/SCENE-PLAN.md`): one `graphic` scene per
4–6 s idea with `headline` / `eyebrow` / `ghost` / `type` (restating what is said in that window —
mirror the edit plan's takeovers), `avatar` scenes for talking-head windows, optional `broll`
scenes to pin a clip to a window, and `cover: true` on the scene containing `cover_at`. Keep
b-roll windows clear of the graphics takeovers in `prior/edit_plan.json`, of the first 2 s, and of
the final `cta_duration` (default 3) seconds. Validate:

```bash
node "$BROLL_SYNC_DIR/scripts/validate-scene-plan.js" work/scene_plan.json \
  --bed-dur "$BED_DUR" --transcript work/words.json
```

### 2. Run the planner

```bash
node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript work/words.json \
  --broll      work/broll_cues.json \
  --coverage   "$BROLL_COVERAGE" \
  --clip-secs  "$BROLL_CLIP_SECS" \
  --min-secs   "$BROLL_MIN_SECS" \
  --max-secs   "$BROLL_MAX_SECS" \
  --order      "$BROLL_ORDER" \
  --reuse      "$BROLL_REUSE" \
  --bed-dur    "$BED_DUR" \
  --brand      work/brand.json \
  --scene-plan work/scene_plan.json \
  --out        saves/beat_list.json

python3 - <<'PY'
import json
bl = json.load(open('saves/beat_list.json')); p = json.load(open('prior/edit_plan.json'))
if bl.get('shortfall_note'): print('[spotlight] c-broll-sync:', bl['shortfall_note'])
broll = [b for b in bl['beats'] if b['kind'] == 'broll']
for b in broll:
    for tk in p.get('takeovers', []):
        assert b['end'] <= tk['start'] or b['start'] >= tk['end'], f"broll beat {b['index']} overlaps graphics takeover {tk['start']}-{tk['end']}"
print(f"[spotlight] beat_list: {len(bl['beats'])} beats, {len(broll)} broll windows, {bl['achieved_broll_pct']:.1f}% coverage")
PY
```

If a b-roll beat overlaps a graphics takeover, pin the b-roll elsewhere in `scene_plan.json`
(or shorten it) and rerun — the graphics takeovers from the edit plan are fixed.

## If you cannot proceed

This step may ask for **`broll` only**. Write `needs_input.json` and stop (no save) when:

- `inputs/broll/` has no decodable video (every ffprobe fails), or
- the usable clips cannot reach the requested coverage even with reuse and the shortfall leaves
  zero b-roll windows (e.g. all clips are shorter than `broll_min_seconds`).

```json
{ "inputId": "broll", "reason": "The b-roll clips could not be used — please add a few more clips of at least 2 seconds each.", "count": 2 }
```

A shortfall that still yields ≥ 1 b-roll window is NOT an ask: keep the beats, log the
`shortfall_note`, and finish. Tool errors (node missing, planner crash) are failures, not asks.

## Checks the harness runs

- `beats_covered` — `saves/beat_list.json` parses, `beats` contains ≥ 1 `kind: "broll"` beat, every
  b-roll beat has `broll.clip` pointing at an existing input clip with `0 ≤ in < out ≤ clip
  duration`, windows lie within `[2, BED_DUR − 2]`, and no b-roll beat overlaps a graphics takeover
  from the edit plan.
