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
metadata:
  hermes:
    vendored:
      - { name: c-banner, load: ".hub/c-banner/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-html-gfx, load: ".hub/c-html-gfx/SKILL.md" }
      - { name: c-vision-qa, load: ".hub/c-vision-qa/SKILL.md" }
      - { name: f-remotion, load: ".hub/f-remotion/SKILL.md" }
    progressive: true
---


# p-gfx-image-posts — HTML-GFX Explainer Images

**SCAFFOLD — NOT YET AUTHORED.** Will be authored in the per-recipe review pass.

## Inputs (intake)
1. `topic` — what the image is about
2. `count` — 1 by default; can request a small batch (e.g. 3 variants or a 4-pack)

## Output
- One or many 1080×1080 (or 1080×1920) brand-styled images (PNG), navy/green palette.

## QA Gate (run per produced image — MANDATORY before delivery)

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-gfx-image 2>/dev/null | head -1)
bash .hub/c-eval-runner/scripts/eval-run.sh <OUTPUT_IMAGE.png> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
```

The runner writes `<image_dir>/eval/scorecard.json` and prints the verdict:
- **PASS** — image passes all hard checks; deliver.
- **NEEDS_VISION** — hard checks passed but `perceptual` checks are `PENDING`. Read
  `<image_dir>/eval/frame0.png` or run `c-vision-qa` with `--intent "..."` and
  `--aspect 1080x1080` to resolve every PENDING item before delivery.
- **FAIL** (exit 1) — a hard check failed (wrong dims, blank/black render). Fix and re-render; do not deliver.
