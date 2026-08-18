---
name: c-vision-qa
description: Reusable perceptual QA gate for STILL images — carousel slides, single graphics, banners, thumbnails, AI images, extracted video frames. Runs cheap mechanical prechecks (dimensions, aspect, not-black, not-blank) then a vision pass — READ each image and score it against a rubric (no clipped/overflowing text, legible contrast, consistent margins, on-brand palette, genuinely premium hierarchy), returning a PASS/FAIL verdict plus concrete per-image fixes the caller applies and re-renders. Use as the look-and-fix gate in any image-producing recipe.
when_to_use: Trigger on c-vision-qa, vision QA, image QA gate, "check the render", "does this card look right", premium / quality gate for images, carousel slide review, banner / thumbnail review, AI image review, before-deliver image verification, render-and-critique loop.
allowed-tools: Read, Bash
kind: component
visibility: internal
requires: ffmpeg
---


# c-vision-qa — Perceptual QA Gate for Still Images


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as a non-negotiable rule.
> 3. Only then proceed.
> 4. After completing the task, append any correction/improvement to `LEARNINGS.md` with today's date; if it affects correctness, add it under **Active Feedback**.

The perceptual counterpart to `c-shorts-qa-gate` (which is the *mechanical, video* gate).
This gate is the executable arm of one rule: **never ship an image you have not looked at.**
A render that was never seen is a defect waiting to publish — clipped headlines, illegible
contrast, generic non-brand colors, a flat "templated" card. This skill makes the agent
**look, judge, and demand a fix** before a still leaves the kitchen.

It is engine-agnostic: it does not author or render anything. The caller produces PNG(s)
by whatever means (static HTML + Playwright, HyperFrames frame, AI image, ffmpeg frame
extract); this gate inspects them and returns a verdict the caller acts on.

## Caller Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `<image...>` | yes | One or more PNG/JPG paths to inspect (slides, a single card, a sweep of frames) |
| `--intent "..."` | yes | One line: what this image is meant to be/say (e.g. "Slide 3 — '3 steps to X', premium whiteboard card"). Vision needs the brief to judge correctness, not just aesthetics. |
| `--aspect WxH` | no | Expected pixel dims or ratio (e.g. `1080x1350`, `4:5`). Enables the mechanical aspect check. |
| `--palette "#hex,#hex,..."` | no | Brand palette (from `get_brand_dna`). The vision pass flags off-brand color as a failure. |
| `--rubric "..."` | no | Extra caller-specific checks appended to the universal rubric (e.g. "logo bottom-right", "code font is monospace"). |
| `--outdir <dir>` | no | Where the precheck writes its report (default `<first_image_dir>/qa/`). |

## How to run it (caller protocol — the LOOP is the point)

```
1. Author + render the image(s).
2. Mechanical precheck (cheap, scripted — kills obviously-broken renders before spending vision):
     bash scripts/precheck.sh <image...> --aspect 1080x1350
   # from inside a built recipe:
     bash .hub/c-vision-qa/scripts/precheck.sh slides/*.png --aspect 1080x1350
3. VISION PASS — Read EVERY image and score it against the rubric below.
4. Emit the verdict (per image): PASS, or FAIL + the specific, actionable fixes.
5. If any image FAILS → apply the fixes to its source, RE-RENDER that image, GOTO 2 for it.
   Repeat until every image PASSes or you hit --max-iter (default 3) → then surface the
   remaining issues to the owner rather than shipping a known-bad still.
```

Vision is near-free here — always run it. The expensive thing is publishing a broken card.

## Mechanical precheck (scripted — exit-coded)

`scripts/precheck.sh` catches the defects you should never waste a vision call on:

**HARD (exit 1 → re-render before looking):**
1. File exists and is a decodable image.
2. Resolution matches `--aspect` (exact dims) or ratio (±1%) when provided.
3. Not black — mean luma `YAVG > 0x18` (catches blank/black/failed renders).
4. Not flat/blank — luma spread `YHIGH-YLOW > 0x10` (catches a single-color card where text/layout never rendered).

**ADVISORY (reported, never blocks):** very large/small file size, extreme aspect, near-uniform edges.

Exit codes: `0` all hard checks pass · `1` a hard check failed (name the image + reason) · `2` usage/IO error.

## The Vision Rubric (READ each image, score every line)

Score PASS only if ALL apply. Any ✗ → FAIL with the concrete fix.

**Legibility & containment**
- No text is clipped, cut at an edge, or overflowing its container/card.
- No element collides with or overlaps another; nothing bleeds past the safe margin.
- Every line of copy is comfortably readable at thumbnail size (squint test) — adequate size + weight.
- Text↔background contrast is strong (no light-grey-on-cream, no color-on-busy-photo).

**Layout & polish (the "premium" bar)**
- Consistent, generous margins/padding; content is not crammed to an edge or floating in dead space.
- Clear visual hierarchy — one obvious focal point (headline/number), supporting copy subordinate.
- Depth and craft present, not flat: shadows/elevation, rounded cards, deliberate spacing — NOT a bare title on a plain background.
- Alignment is intentional (shared grid/baseline); no accidental ragged offsets.

**Brand & correctness**
- Palette matches `--palette` (or the brand) — NOT generic `#3b82f6`/`#333`/stock template colors.
- Content matches `--intent` — right headline, right point, no Lorem/placeholder, no wrong/garbled text.
- Charset intact — no `□`/`�`/missing-glyph boxes for emoji, arrows, em-dashes, or non-Latin script.
- No black/blank first or last slide in a set; the cover slide is the strongest, brightest beat.

**Set consistency (when inspecting multiple slides)**
- Shared system across slides — same fonts, accent color, card style, margin rhythm. A carousel must read as ONE deck, not N unrelated images.

## Verdict format (what the caller acts on)

For each image, emit exactly:

```
<image>: PASS
```
or
```
<image>: FAIL
  - <issue> → <specific fix> (e.g. "headline clipped on right → reduce font-size 64→52px or shorten copy")
  - <issue> → <specific fix>
```

Fixes must be **actionable on the source** (a CSS value, a copy edit, a layout change) — never vague ("make it nicer"). The whole point is that the caller can apply them and re-render without re-thinking.

## Scope (v1)

Perceptual judgment is done by the model's own vision via `Read` (the proven pattern from
`c-reel-premium` Step P4). The mechanical floor is scripted and dependency-light (ffmpeg only).
OCR/auto-contrast-measurement are deliberately deferred — the vision pass already catches them,
and adding tesseract/opencv would bloat the gate. Keep this gate fast and reusable.

## Self-Learnings

| Date | What went wrong | Fix |
|------|-----------------|-----|
| _seed_ | Carousels shipped as AI-image + ImageMagick text overlay, never looked at → clipped/off-brand cards | Author premium HTML, render to PNG, then run THIS gate's look-and-fix loop before deliver |
