---
name: c-broll-sync
description: Transcript-synced b-roll beat planner. Takes a word-level transcript + optional b-roll clips + coverage params and emits an ordered JSON beat list where each beat is tagged broll(clip,in,out) or graphics(scene). Used by p-reels-pip, p-reels-spotlight, and p-reels-faceless as the background layout planner — this component plans, it does NOT render. Engine-agnostic.
kind: component
visibility: internal
version: 1.0.0
dependsOn: []
requires: node
---


# c-broll-sync — Transcript-Matched B-Roll Beat Planner

Produces an **ordered beat list** from a word-level transcript + optional b-roll clips. Every beat
is tagged either `broll` (a specific clip window) or `graphics` (a scene spec for the calling core
to render). The calling skill (p-reels-pip, p-reels-spotlight, p-reels-faceless) maps each beat
into its layout-specific position — this component is **planner only, no ffmpeg/HyperFrames calls
here**.

**Degenerate case:** no b-roll supplied → every beat is `graphics`. This exactly reproduces old
fmt1 / fmt4 behavior (100% motion-graphics background).

---

## Inputs

| Var | Required | Default | Notes |
|---|---|---|---|
| `TRANSCRIPT_JSON` | Yes | — | Word-level transcript `[{text,start,end}]` from c-audio/whisper. |
| `BROLL_JSON` | No | `[]` | Array of b-roll clip descriptors (see schema below). |
| `BROLL_COVERAGE_PCT` | No | `30` | Target % of bed_duration covered by b-roll. |
| `BROLL_CLIP_SECONDS` | No | `4` | Default on-screen duration per b-roll window. |
| `BROLL_MIN_SECONDS` | No | `2` | Minimum clamped window duration. |
| `BROLL_MAX_SECONDS` | No | `6` | Maximum clamped window duration. |
| `BROLL_ORDER` | No | `transcript-match` | `transcript-match` · `as-given` · `even` — see below. |
| `BROLL_REUSE` | No | `false` | `true` → clips may be reused to hit the coverage target. |
| `BED_DURATION` | No | auto | Total reel duration (seconds). If omitted, derived from max word end time. |
| `BRAND_JSON` | No | `{}` | Brand identity blob forwarded into each `graphics` beat's `brand` field for the renderer. |
| `PLAN_MODEL` | No | opus | `opus` (via OAuth env-unset) or `kimi` (fallback). |

### `BROLL_JSON` element schema

```json
{
  "clip": "filename-or-label.mp4",
  "duration": 12.4,
  "cues": [
    { "start": 0.0, "end": 3.2, "text": "the coffee shop opens at eight" }
  ]
}
```

`cues` is the clip's own word-level transcription (produced in the calling skill's transcribe step).
Silent clips → `cues: []`; matching falls back to filename/label heuristic.

---

## Coverage Params

| Param | Default | Meaning |
|---|---|---|
| `broll_coverage_pct` | `30` | Target % of bed_duration covered by b-roll. |
| `broll_clip_seconds` | `4` | Default on-screen duration per b-roll window. |
| `broll_min_seconds` | `2` | Min per-window duration (clamp floor). |
| `broll_max_seconds` | `6` | Max per-window duration (clamp ceiling). |
| `broll_order` | `transcript-match` | Placement strategy (see below). |
| `broll_reuse` | `false` | Whether clips may appear more than once. |

### `broll_order` strategies

- **`transcript-match`** *(default)* — OPUS finds the b-roll windows whose clip cues best match the
  spoken words at each beat. The coverage budget is enforced mechanically (Node script); OPUS only
  chooses *which* transcript moments get b-roll and which clip/window fits best. Strongest matches
  kept if budget is exceeded.
- **`as-given`** — clips are assigned in the order they appear in `BROLL_JSON`, each trimmed to a
  `broll_clip_seconds` window at the start of the beat where it's placed. No LLM call needed.
- **`even`** — clips are spread evenly across the reel duration, spaced `bed_duration / n_clips`
  apart. No LLM call needed.

---

## Allocation Logic

```
budget_seconds = (broll_coverage_pct / 100) × bed_duration
max_windows    = floor(budget_seconds / broll_clip_seconds)   # initial slot count
window_seconds = clamp(broll_clip_seconds, min_seconds, max_seconds)
```

1. **Budget clips:** compute how many windows fit in the budget.
2. **Pick moments:** for `transcript-match`, OPUS maps each candidate clip to the best transcript
   cue (see Step S1 below). For `as-given`/`even`, the Node script assigns positions mechanically.
3. **Clamp:** each actual window = `clamp(clip_duration_available, min_seconds, max_seconds)`.
4. **Shortfall check:** if `available_clips < max_windows` (and `broll_reuse=false`), cap at
   `available_clips` windows and LOG: `"[c-broll-sync] shortfall: requested X%, achieved Y% — only
   N clips, no reuse"`.
5. **Excess check:** if matchable clips exceed budget, keep the `max_windows` strongest matches and
   drop the rest.
6. **Fill remaining time with `graphics` beats** (the full transcript time not covered by b-roll).

---

## Output — Beat List JSON Schema

The script writes `beat_list.json`:

```json
{
  "bed_duration": 42.3,
  "achieved_broll_pct": 28.4,
  "cover_at": 9.5,
  "shortfall_note": "requested 30%, achieved 28.4% — only 3 clips, no reuse",
  "beats": [
    {
      "index": 0,
      "start": 0.0,
      "end": 4.2,
      "kind": "graphics",
      "scene": {
        "eyebrow": "THE HOOK",
        "ghost": "OPEN",
        "title_html": "This <span class=\"accent\">changes</span> everything",
        "brand": {}
      }
    },
    {
      "index": 1,
      "start": 4.2,
      "end": 8.4,
      "kind": "broll",
      "broll": {
        "clip": "morning-routine.mp4",
        "in": 2.1,
        "out": 6.1,
        "match_score": 0.87,
        "match_reason": "clip cue 'coffee shop' matches transcript 'morning coffee'"
      }
    }
  ]
}
```

### `kind: "graphics"` beat fields

| Field | Type | Notes |
|---|---|---|
| `scene.eyebrow` | string | Short UPPERCASE mono label (2–4 words). |
| `scene.ghost` | string | ONE huge faint background word. |
| `scene.title_html` | string | Punchy headline; key word in `<span class="accent">WORD</span>`. |
| `scene.brand` | object | Brand identity forwarded from `BRAND_JSON`. |
| `scene.type` | string | Optional — `"typing-ui"`, `"chart"`, `"stat"`, `"checklist"`. Default omitted = standard motion card. |

### `kind: "broll"` beat fields

| Field | Type | Notes |
|---|---|---|
| `broll.clip` | string | Filename matching an entry in `BROLL_JSON`. |
| `broll.in` | number | Trim start (seconds into the source clip). |
| `broll.out` | number | Trim end (seconds into the source clip). Always `out - in ∈ [min, max]`. |
| `broll.match_score` | number | 0–1 confidence (transcript-match only; 1.0 for as-given/even). |
| `broll.match_reason` | string | Human-readable match rationale (transcript-match only). |

---

## Usage — calling pattern

```bash
BROLL_SYNC_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" -maxdepth 4 -type d -name c-broll-sync 2>/dev/null | head -1)
[ -n "$BROLL_SYNC_DIR" ] || BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"

node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript "$W/transcript.json" \
  --broll      "$W/broll_cues.json" \
  --coverage   30 \
  --clip-secs  4 \
  --min-secs   2 \
  --max-secs   6 \
  --order      transcript-match \
  --reuse      false \
  --bed-dur    "$BED_DUR" \
  --brand      "$W/brand.json" \
  --out        "$W/beat_list.json"
```

For `transcript-match` the script spawns an OPUS sub-call (env-unset pattern; kimi fallback).
For `as-given` and `even` the plan is entirely mechanical — no LLM call.

---

## Step S1 — OPUS planning call (transcript-match only)

The Node script builds the prompt, unsets the Ollama routing, and spawns `claude --print`:

```
Prompt: word transcript + broll cues + budget constraints
Output: JSON array of beat specs (strict, no prose)
```

OPUS decides **which transcript moments** receive b-roll and **which clip window** best matches.
The Node script then:
1. Verifies the plan honors the budget (`broll_seconds ≤ budget_seconds`).
2. Clamps every `broll.out - broll.in` to `[min_seconds, max_seconds]`.
3. Verifies beat coverage is gapless and sums to `bed_duration` (±0.1s tolerance).
4. Logs any shortfall.

The LLM **never** decides the budget number — that is computed mechanically from params.

---

## Gotchas

- **No b-roll supplied → 100% graphics — this is valid, not degraded.** Reproduces fmt1/fmt4 behavior.
- **`broll_reuse=false` (default) + too few clips → shortfall log, not an error.** The plan completes with fewer b-roll windows than the budget allows.
- **`transcript-match` with silent clips:** OPUS falls back to filename/label heuristic (the clip's filename words are matched against the transcript). Works for descriptive filenames like `coffee-shop-morning.mp4`.
- **Beat boundaries are gapless:** every second of `bed_duration` belongs to exactly one beat (`graphics` or `broll`). No gaps, no overlaps.
- **The planner is engine-agnostic:** it emits a JSON plan, it does not call ffmpeg or HyperFrames. The calling core renders each beat into its layout.
