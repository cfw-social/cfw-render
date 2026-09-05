# c-eval-runner — LEARNINGS

## Active Feedback
<!-- Non-negotiable rules. Each must be applied on every run. -->

- The engine is plumbing — NEVER hardcode a recipe's threshold in `eval_run.py`.
  All thresholds live in the recipe's `acceptance.json`. A bespoke check goes
  through the `custom` escape hatch, not into the engine.
- Spec format is JSON, not YAML — do not add a PyYAML dependency (it may be
  absent on the Hermes box; a missing parser is a silent-fallback failure).
- An unknown check `type` returns `SKIP` (reported), never an implicit PASS.

## Log
<!-- date — what changed / was learned -->

- 2026-06-29 — Created. Generalized from `p-reels-split/scripts/eval-split.sh`
  (the pilot) into a shared engine + per-recipe `acceptance.json`. Built-in
  types: qa_gate, dims, duration_window, luma_floor, contrast_floor, loudness, mean_volume,
  custom, perceptual. `p-reels-split` ported with zero custom code (all its
  checks are built-ins). Golden test locks the floor.

- **2026-09-05 (CFW-131)** — added `contrast_floor` (perceptual cover rule) because a raw mean-luma
  floor can never pass a dark-palette brand card: MGG navy cards read ≈40 full-range with a bright
  headline on them. Rule: mean > 48 OR (mean ≥ 8 AND range ≥ 128 AND ≥ 2 % bright pixels).
  `test/golden.sh` now also proves a navy card WITH a headline passes and a flat navy frame fails.
  Same rule lives in `c-shorts-qa-gate` frame-0. Recipes: put `contrast_floor` at `samples:[0.0]`
  for the cover; keep `luma_floor` (floor 16) for "no black zone" sweeps.
