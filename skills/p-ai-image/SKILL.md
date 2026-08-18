---
name: p-ai-image
description: Generate one or many AI images for social posts via Gemini/Nanobanana (c-ai-media), fal.ai/kie.ai FLUX (c-kie-ai), or Replicate (c-replicate) — and optionally render a YouTube/social thumbnail from a generated frame (c-thumbnail). Trigger on "make an AI image", "generate image", "AI image post", "single image", "image batch", "thumbnail from an AI image".
when-to-use: Use when the user wants ONE or a small batch of generated/AI images (a photo-style scene, an illustration, a character). Not for HTML/explainer graphics (use p-gfx-image-posts) and not for video.
version: 0.1.0
kind: pipeline
visibility: catalog
providers: kie, fal, replicate
produces:
  dish: AI Image Post
  format: image (single or multi)
  duration: n/a
inputs: [prompt, count, provider]
dependsOn: [c-ai-media, c-kie-ai, c-replicate, c-ffmpeg, c-thumbnail, c-eval-runner, c-vision-qa]
metadata:
  hermes:
    vendored:
      - { name: c-ai-media, load: ".hub/c-ai-media/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-html-gfx, load: ".hub/c-html-gfx/SKILL.md" }
      - { name: c-kie-ai, load: ".hub/c-kie-ai/SKILL.md" }
      - { name: c-replicate, load: ".hub/c-replicate/SKILL.md" }
      - { name: c-thumbnail, load: ".hub/c-thumbnail/SKILL.md" }
      - { name: c-vision-qa, load: ".hub/c-vision-qa/SKILL.md" }
      - { name: f-remotion, load: ".hub/f-remotion/SKILL.md" }
    progressive: true
---


# p-ai-image-posts — AI Image Post(s)

**SCAFFOLD — NOT YET AUTHORED.** Will be authored in the per-recipe review pass.

## Inputs (intake)
1. `prompt` — natural-language image description
2. `count` — 1 by default; or a small batch (2–6)
3. `provider` (optional) — `gemini` (default, c-ai-media) | `fal` / `kie` (c-kie-ai) | `replicate` (c-replicate)

## Output
- One or many AI-generated images, brand-aspect (square / portrait / landscape per request).

## QA Gate (run per produced image — MANDATORY before delivery)

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-ai-image 2>/dev/null | head -1)
bash .hub/c-eval-runner/scripts/eval-run.sh <OUTPUT_IMAGE.png> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
```

The runner writes `<image_dir>/eval/scorecard.json` and prints the verdict:
- **PASS** — image passes all hard checks; deliver.
- **NEEDS_VISION** — hard checks passed but `perceptual` checks are `PENDING`. Read
  `<image_dir>/eval/frame0.png` or run `c-vision-qa` with `--intent "..."` and
  `--aspect 1080x1080` to resolve every PENDING item before delivery.
- **FAIL** (exit 1) — a hard check failed (wrong dims, black frame). Fix and re-render; do not deliver.
