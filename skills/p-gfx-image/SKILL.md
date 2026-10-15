---
name: p-gfx-image
description: Generate one or many HTML-GFX explainer images (brand-styled, navy/green) from a topic or script via c-html-gfx — single cards, multi-image batches, or platform banners (c-banner; replaces p-banner). Trigger on "make explainer image", "graphic post", "GFX image", "infographic post", "make a banner", "channel art".
when-to-use: Use when the user wants ONE or a FEW brand-styled static images (not a video, not a multi-step carousel PDF). Each image is a self-contained HTML composition rendered to PNG/JPG.
version: 0.1.0
kind: pipeline
visibility: catalog
produces:
  dish: GFX Image Post
  format: image (single or multi)
  duration: n/a
inputs: [topic, count]
dependsOn: [c-html-gfx, c-ffmpeg, c-banner, c-eval-runner, c-vision-qa]
---

# p-gfx-image-posts — HTML-GFX Explainer Images

## Execution and reporting

Read [Recipe stage reporting](../../docs/RECIPE-STAGE-REPORTING.md) before a tracked
run. Managed work uses the installed worker/harness and the exact claimed manifest;
its stage IDs select `steps/_shared.md` plus the referenced step file. The harness
alone reports stages; step assistants must not call `complete_render_order` or
emit competing MCP events. Standalone use does not report to CFW Social.

Catalog presence and declared checks do not prove validator coverage or readiness.
Missing validators/evidence block gates. See
[reporting coverage](../../docs/RECIPE-REPORTING-COVERAGE.md) before claiming tracked
execution is ready; local checkpoint eligibility is independently restricted.

## Authored workflow and current limits

The authored instructions are split into four manifest stages. Read
[shared rules](steps/_shared.md) with each selected step:

1. [`plan_cards`](steps/01-plan-cards.md): turn `topic` and requested `count` into
   `saves/plan.json`, with one headline/layout entry per card.
2. [`author_html`](steps/02-author-html.md): use the chosen format and brand palette
   to author complete compositions in `saves/cards_html.json`.
3. [`render`](steps/03-render.md): render each composition, verify its canvas, and
   preserve the images in order. `image_1`, `contact_sheet` and `images` are the
   manifest's intermediate saves, not an ordered final-delivery contract.
4. [`qa_gate`](steps/04-qa-gate.md): inspect every card against its plan and
   acceptance criteria; failed or unresolved checks require correction.

These authored steps replace the former scaffold entry point; they do **not**
make tracked execution ready. The six declared checks still lack executable
harness validators, and the manifest has no `finalOutputs` mapping. For batches,
`final.png` is only a selected preview; neither it nor a contact sheet delivers
all requested cards. Tracked delivery remains blocked until validators and an
ordered individual-image contract are implemented and tested. In standalone use,
retain and deliver every passing full-resolution PNG in requested order, plus
its QA evidence; never substitute a sheet for the set.

## Inputs (intake)
1. `topic` — what the image is about
2. `count` — 1 by default; can request a small batch (e.g. 3 variants or a 4-pack)

## Output
- One or many 1080×1080 (or 1080×1920) brand-styled images (PNG), navy/green palette.

## QA Gate (run per produced image — MANDATORY before delivery)

```bash
SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-gfx-image"
bash .hub/c-eval-runner/scripts/eval-run.sh <OUTPUT_IMAGE.png> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
```

The runner writes `<image_dir>/eval/scorecard.json` and prints the verdict:
- **PASS** — image passes all hard checks; deliver.
- **NEEDS_VISION** — hard checks passed but `perceptual` checks are `PENDING`. Read
  `<image_dir>/eval/frame0.png` or run `c-vision-qa` with `--intent "..."` and
  `--aspect 1080x1080` to resolve every PENDING item before delivery.
- **FAIL** (exit 1) — a hard check failed (wrong dims, blank/black render). Fix and re-render; do not deliver.
