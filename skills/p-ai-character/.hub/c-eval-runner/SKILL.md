---
name: c-eval-runner
description: Generic eval ENGINE for any rendering recipe. Reads a per-recipe acceptance.json (the strict, recipe-owned spec of "what done means"), runs the declared checks — mechanical (delegated to c-shorts-qa-gate), geometry, audio, and perceptual — optionally deep-merges a per-brand override, and writes a structured scorecard.json with a PASS / NEEDS_VISION / FAIL verdict. A FAIL exits non-zero and blocks delivery. Exotic checks a recipe needs are handled by a `custom` escape-hatch type that runs a recipe-local script. The engine is plumbing only: all thresholds live in the spec, so reusing one engine across recipes does not relax any recipe's bar.
when-to-use: Trigger on c-eval-runner, eval runner, acceptance spec, scorecard, "gate this render", per-recipe eval, interim/step gate, brand acceptance override, "run the eval", before-deliver verdict, replace a hand-rolled QA step with the shared engine.
version: 1.0.0
kind: component
visibility: internal
requires: ffmpeg, python3
---


# c-eval-runner — Generic Eval Engine


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as a non-negotiable rule.
> 3. Only then proceed.
> 4. After completing the task, append any correction/improvement to `LEARNINGS.md` with today's date; if it affects correctness, add it under **Active Feedback**.

The engine behind "every render runs a checklist." A recipe ships an
`acceptance.json` next to its `SKILL.md`; the recipe's final step calls this
engine on the rendered file; a **HARD** failure (`verdict: FAIL`, exit 1) blocks
upload. Perceptual checks come back `PENDING` with a frame sweep for a vision pass.

**Why one engine doesn't relax anyone's bar:** the rigor lives entirely in each
recipe's `acceptance.json`. The engine only executes what the spec declares.
Sharing the engine removes 18 copy-pasted runners that would otherwise rot and
drift — which is where standards actually slip. The **golden test** (`test/golden.sh`)
locks the floor: a known-bad render MUST come back FAIL, or the test goes red.

## Call it

```bash
# final gate (recipe's last step before upload)
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_FILE> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"

# interim fail-fast gate (mid-pipeline, named in the spec's "steps")
bash .hub/c-eval-runner/scripts/eval-run.sh <ARTIFACT> --recipe-dir "$SKILL_DIR" --step voicebed
```

- `--recipe-dir` — the calling recipe's `$SKILL_DIR` (where `acceptance.json` and
  the vendored `.hub/c-shorts-qa-gate/` live). Required.
- `--brand` — if `<recipe>/brand-overrides/<slug>/acceptance.json` exists, its
  checks deep-merge over the base (same `id` ⇒ brand wins; new ids appended).
- Outputs `scorecard.json` + a frame sweep to `<file_dir>/eval/`.

## The spec — `acceptance.json`

JSON (not YAML) on purpose: the engine parses the spec at render time with the
python3 stdlib — no PyYAML dependency to be missing on the box (no silent
fallback). Shape:

```json
{
  "recipe": "p-reels-split",
  "spec_version": 1,
  "checks": [
    { "id": "qa_gate",          "kind": "mechanical", "type": "qa_gate", "format": "reel" },
    { "id": "canvas",           "kind": "geometry",   "type": "dims", "w": 1080, "h": 1920 },
    { "id": "top_zone_not_black","kind": "geometry",  "type": "luma_floor",
      "crop": "1080:960:0:0", "floor": 16, "samples": [0.05,0.4,0.95] },
    { "id": "hard_split_line",  "kind": "perceptual", "type": "perceptual",
      "desc": "Clean seam at y=960 — zones do not bleed." }
  ],
  "steps": {
    "voicebed": { "artifact": "voice-bed.aac", "checks": [
      { "id": "bed_loudness", "type": "loudness", "target": -14, "tol": 1.5 }
    ]}
  }
}
```

## Built-in check types

| type | HARD by default | params | what it does |
|---|:--:|---|---|
| `qa_gate` | yes | `format` | delegates to `c-shorts-qa-gate` (loudness/res/fps/frame0/audio) |
| `dims` | yes | `w`, `h` | exact resolution |
| `duration_window` | yes | `min_s`, `max_s` | duration band |
| `luma_floor` | yes | `crop` (`W:H:X:Y`), `floor`, `samples[]` | a region is not black/dark on any sample |
| `loudness` | yes | `target`, `tol` | integrated LUFS (ebur128) |
| `mean_volume` | yes | `min_db`, `max_db` | speech present / not clipping / not silent |
| `custom` | yes | `script` (recipe-relative), `args[]` | **escape hatch** — run a recipe-local check; exit 0 = PASS |
| `perceptual` | no | `desc` | emits `PENDING` + frame sweep for a vision pass |

Any check may set `"hard": false` to make it advisory. Unknown types → `SKIP`
(reported, never silently passed).

## Escape hatch (the exotic 20%)

When a recipe needs a check the engine doesn't ship, add a `custom` check pointing
at a recipe-local script — the rigor stays recipe-owned, the engine stays generic:

```json
{ "id": "seam_continuity", "kind": "geometry", "type": "custom",
  "script": "scripts/checks/seam-continuity.sh", "args": ["960"] }
```

The script receives `<file>` then the `args`; exit 0 = PASS, non-zero = FAIL (its
last stdout/stderr line becomes the scorecard detail).

## Verdict

- `PASS` — every HARD check passed, nothing pending.
- `NEEDS_VISION` — HARD passed, perceptual checks still `PENDING` (resolve with a
  vision pass / `c-vision-qa`, set each, then deliver).
- `FAIL` — a HARD check failed → exit 1 → **do not deliver**.

See `cfw-skills-pack/docs/skills-audit.md` §4 for the architecture and rollout.
