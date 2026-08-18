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
  types: qa_gate, dims, duration_window, luma_floor, loudness, mean_volume,
  custom, perceptual. `p-reels-split` ported with zero custom code (all its
  checks are built-ins). Golden test locks the floor.
