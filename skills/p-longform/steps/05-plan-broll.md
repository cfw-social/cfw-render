# Plan the b-roll

Decide what is on screen at every second: avatar full-frame, avatar PIP over b-roll / GFX / stills,
full-screen footage, or side-by-side. The plan is the composite's shot list; every row uses
transcript timecodes and the quality guard (≥ 4 unique assets, coverage ≥ `broll_coverage` %)
is enforced here, not discovered after a 30-minute render.

## You receive

- `prior/transcripts.json` — `sections`, `words`, `duration`, `avatar_mode` (`supplied`, `avatar`
  or `voice`).
- `prior/visuals_manifest.json` — the rendered cards / stills / concept compositions with `at`.
- `prior/section_map.json` — section types (`talking-head`, `concept`, `demo-recording`, …).
- `inputs/broll/` — zero or more clips, stills or screen recordings (dir absent = none supplied).
- `brief.json` — `options.broll_coverage` (80), `options.pip_mode` (corner).

## You must produce

- `saves/broll_plan.json`:

```json
{ "duration": 736.4, "coverage_pct": 83.1, "pip_mode": "corner",
  "rows": [
    {"start": 0.0, "end": 28.4, "says": "Most agencies…", "layout": "AVATAR_FULL", "asset": null, "zoom": "none", "pip_side": null},
    {"start": 28.4, "end": 61.0, "says": "…", "layout": "PIP_CORNER", "asset": "broll/clinic-01.mp4", "zoom": "slow-in", "pip_side": "right"},
    {"start": 61.0, "end": 67.0, "says": "…", "layout": "FULLSCREEN_BROLL", "asset": "gfx:gfx_01_stat", "zoom": "none", "pip_side": null}
  ] }
```

Layouts: `AVATAR_FULL | PIP_CORNER | PIP_SIDE | FULLSCREEN_BROLL | SIDE_BY_SIDE`. `asset` is
`broll/<file>` (an input), `gfx:<id>` / `still:<id>` / `hf:<id>` (a visuals-manifest asset) or
`null`. `pip_side` alternates `left` / `right` on consecutive PIP rows.

## How

```bash
mkdir -p work saves
ls inputs/broll/ 2>/dev/null | sort > work/broll-files.txt || true
FMT=$(python3 -c "import json;print(json.load(open('prior/section_map.json'))['format'])")
NB=$(wc -l < work/broll-files.txt | tr -d ' ')
MODE=$(python3 -c "import json;print(json.load(open('prior/transcripts.json')).get('avatar_mode') or 'avatar')")
PIPM=$(python3 -c "import json;print((json.load(open('brief.json')).get('options') or {}).get('pip_mode') or 'corner')")
NOPIP=0; if [ "$MODE" = voice ] || [ "$PIPM" = none ]; then NOPIP=1; fi
echo "format=$FMT broll_files=$NB avatar_mode=$MODE pip_mode=$PIPM no_pip=$NOPIP"
```

`NOPIP=1` (a voice-only run, or the owner set `pip_mode = none`) means no presenter is shown
beside footage: the plan never uses `PIP_CORNER`, `PIP_SIDE` or `SIDE_BY_SIDE`; the footage or
card takes the whole frame (`FULLSCREEN_BROLL`) and the narration plays under it. With a supplied
clip, `AVATAR_FULL` shows the clip itself (the presenter) and is fine. On a voice-only run
(`avatar_mode = voice`) there is no presenter: the bed is one flat dark colour, which fails the
frame-0 and no-black-void checks, so plan **no `AVATAR_FULL` row at all** — the hook gets a card,
still or footage like every other beat. Write `"pip_mode": "none"` into the plan.

### 1. Catalogue the footage (`c-broll`)

For each file in `inputs/broll/`: `ffprobe` duration / dims; one frame at 40 % to read what it
shows; a one-line description. Screen recordings (16:9, UI content) are tagged `demo`; everything
else `broll`. Stills become 5 s slow-zoom clips. A `demo` format with **no** `demo` footage
cannot be a walkthrough: ask for `broll` ("Please add the screen recordings of the product the
video walks through."). A `vsl` / `tutorial` with no footage proceeds on GFX + stills alone.

### 2. Lay the rows

Walk the transcript section by section:

- `hook` (first ≤ 30 s) and the final `cta` beat: `AVATAR_FULL` (hook; a card on a voice-only run) and the CTA card
  `FULLSCREEN_BROLL` pinned so it ends at `duration` — these are exempt from coverage.
- `talking-head` sections: `AVATAR_FULL`, broken every ≤ 25 s by a PIP row with the nearest
  matching footage so no bare-avatar stretch exceeds 25 s.
- `concept` sections: the section's HyperFrames composition as `FULLSCREEN_BROLL` with
  `pip_mode = corner` → `PIP_CORNER` over it instead (avatar stays visible; not when `NOPIP=1`).
- `demo-recording` sections: the matching screen recording `PIP_CORNER` (or `SIDE_BY_SIDE` when
  the recording is portrait / the section map says so).
- GFX cards and stills from `visuals_manifest` are placed at their `at` for `seconds` as
  `FULLSCREEN_BROLL` (or `PIP_CORNER` when the avatar must stay visible), overriding footage.

`says` is the transcript text of the row. Zoom: `slow-in` for stills and footage > 6 s, else
`none`. `pip_side` alternates on every consecutive PIP row.

### 3. Quality guard

```bash
NOPIP="$NOPIP" MODE="$MODE" python3 - <<'PY'
import json, os
p = json.load(open("work/broll_plan.json")); d = p["duration"]; rows = p["rows"]
if os.environ.get("MODE") == "voice":
    assert not any(r["layout"] == "AVATAR_FULL" for r in rows), "voice-only has no presenter: cover every row with a card, still or footage (a bare dark bed fails the frame-0 check)"
if os.environ.get("NOPIP") == "1":
    assert not any(r["layout"] in ("PIP_CORNER", "PIP_SIDE", "SIDE_BY_SIDE") for r in rows), "no presenter beside footage in this run: use FULLSCREEN_BROLL"
    p["pip_mode"] = "none"
assert abs(rows[0]["start"]) < 0.05 and abs(rows[-1]["end"] - d) < 0.5, "rows must span 0 → duration"
for a, b in zip(rows, rows[1:]): assert abs(a["end"] - b["start"]) < 0.05, f"gap/overlap at {a['end']}"
cov = sum(r["end"] - r["start"] for r in rows if r["layout"] != "AVATAR_FULL")
hook = min(30, rows[0]["end"]); cta = next(r for r in rows if r["asset"] == "gfx:cta")
eligible = d - hook - (cta["end"] - cta["start"])
pct = round(100 * cov / eligible, 1); p["coverage_pct"] = pct
want = (json.load(open("brief.json")).get("options") or {}).get("broll_coverage") or 80
uniq = {r["asset"] for r in rows if r["asset"]}
assert len(uniq) >= 4, f"only {len(uniq)} unique assets (need ≥ 4)"
assert pct >= want, f"coverage {pct}% below target {want}%"
json.dump(p, open("saves/broll_plan.json", "w"), indent=1); print(f"OK coverage {pct}%, {len(uniq)} assets, {len(rows)} rows")
PY
```

Coverage short with footage available → add rows; short with none → write `needs_input.json` for
`broll` with the measured percentage and the target in the reason, e.g.
`{ "inputId": "broll", "reason": "Only 54% of the video has footage or graphics over the speaker; the target is 80% — please add b-roll clips or screen recordings.", "count": 3 }`.
Supplied footage is the only lever left; do not pad with repeated cards. Cards and stills alone
cover only a few minutes of a long video, so a run with no `inputs/broll/` will usually stop
here unless the owner has lowered `options.broll_coverage`.

## Checks the harness runs

- `plan_covers_runtime` — rows are contiguous from 0 to `duration` with no gap or overlap, and
  the last `gfx:cta` row ends within the final 60 s.
- `coverage_target_met` — `coverage_pct` ≥ `options.broll_coverage` (default 80) and ≥ 4 unique
  assets are used.
