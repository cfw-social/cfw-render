---
name: p-carousel
description: Multi-slide carousel for any platform, built as RICH premium HTML cards. Writes slide copy, authors one HTML document (premium template — brand palette, depth, type hierarchy), renders each slide to PNG via headless Chromium, runs the c-vision-qa look-and-fix gate on every slide, assembles a PDF, and drafts the caption. Trigger on "make a carousel", "LinkedIn carousel", "Instagram carousel", "slide deck post", "multi-slide post".
disable-model-invocation: true
argument-hint: "[brand] [production-name] [topic]"
allowed-tools: Bash, Read, Write
kind: pipeline
visibility: catalog
produces:
  dish: LinkedIn Carousel
  format: PDF carousel
  duration: n/a
inputs: [topic]
dependsOn: [c-script, c-vision-qa, c-eval-runner]
requires: node, chromium
metadata:
  hermes:
    vendored:
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-script, load: ".hub/c-script/SKILL.md" }
      - { name: c-vision-qa, load: ".hub/c-vision-qa/SKILL.md" }
    progressive: true
---




> ## ⚡ PREMIUM HTML CARDS + VISION QA (MANDATORY — 2026-06-17)
> - **Slides are authored as RICH HTML and rendered to PNG via headless Chromium.** Use `template.html` in this skill as the quality floor — premium type hierarchy, depth (shadows, rounded cards), generous margins. **NOT** AI-generated background images with text drawn on top. **NOT** bare title-on-plain-background cards. A flat, templated-looking card is a defect.
> - **Inject the brand palette + fonts** (`get_brand_dna`) into the template's CSS vars. **Never** ship generic `#3b82f6` / `#333` / stock colors — off-brand color is a QA failure.
> - **EVERY rendered slide MUST pass `c-vision-qa` before assembly.** Render → look → fix the HTML → re-render → look again, until every slide PASSes. An unseen slide is a defect. The cover slide is the brightest, strongest beat; no black or blank first/last slide.

# pipeline-carousel — Premium HTML Carousel (PDF)


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

Produces a premium, on-brand carousel PDF (rich HTML cards) + caption copy. The agent
authors the HTML and renders it — exactly the workflow that produces hand-quality cards —
then proves quality with the `c-vision-qa` gate before anything is delivered.

## Arguments

| Arg | Required | Default | Description |
|-----|----------|---------|-------------|
| brand | Yes | — | Brand slug |
| production_name | Yes | — | Folder name |
| topic | Yes | — | Carousel topic / hook |
| num_slides | No | `5` | Number of slides (cover + content + CTA) |
| aspect_ratio | No | `4:5` | `4:5` (1080×1350) or `1:1` (1080×1080) |

## Steps

### Step 1 — Outline ⛔ CHECKPOINT

Write the carousel outline:
- Slide 1: Cover (hook headline)
- Slides 2 … N-1: Content (one insight per slide, progressive reveal)
- Slide N: CTA (follow + offer + handle/URL)

Headline copy: short, scroll-stopping, value-front.
**Gate: User approves outline.**

### Step 2 — Slide Copy

Write full copy per slide:
- Headline: ≤ 8 words
- Body: 2–3 sentences max
- Visual idea: the layout/illustration that supports this slide (a step list, a stat,
  a before→after, a code/window mock, a node diagram — NOT just a title)

### Step 3 — Author the premium HTML

→ Copy `template.html` (this skill folder) to `<production>/carousel.html`.
→ **Brand it:** read `get_brand_dna` and overwrite the `:root` CSS vars (`--accent`,
  `--ink`, `--bg`, `--card`, `--line`, `--muted`) + fonts with the brand's palette/type.
→ **One `<section class="slide" id="sN">` per slide** (N = 1…num_slides). Use the
  component classes in the template (`.window`, `.step`, `.pill`, `.callout`, `.cta-key`,
  `.node`) to give each slide real layout + depth — match the visual idea from Step 2.
→ Keep the set consistent: same fonts, accent, card style, margin rhythm across all slides.
→ Set the slide size for `$aspect_ratio` (the template's `--w`/`--h` vars: 1080×1350 for 4:5, 1080×1080 for 1:1).

### Step 4 — Render to PNG

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd 2>/dev/null)"
[ -d "$SKILL_DIR/.hub" ] || SKILL_DIR="$(find "$HOME/.hermes/skills" "$HOME/.claude/skills" \
   -type d -name p-carousel -print 2>/dev/null | head -1)"
cd <production>
[ -d node_modules/playwright ] || npm i playwright >/dev/null 2>&1
# render.mjs auto-discovers every <section class="slide" id="sN"> and shoots each at 2x.
WIDTH=1080 HEIGHT=1350 SCALE=2 node render.mjs        # HEIGHT=1080 for 1:1
```
→ Output: `slides/slide-<id>.png` (retina, sharp).

### Step 5 — Vision QA gate ⛔ (MANDATORY look-and-fix loop)

→ LOAD: skill_view("p-carousel", ".hub/c-vision-qa/SKILL.md") —— run it on the rendered slides:
```bash
bash .hub/c-vision-qa/scripts/precheck.sh slides/*.png --aspect 1080x1350
```
Then READ every slide PNG and score it against the c-vision-qa rubric (clipping, contrast,
margins, premium hierarchy, on-brand palette, charset, set consistency).
→ **Any FAIL → fix the HTML for that slide → re-render (Step 4) → re-run this gate.**
Loop until every slide PASSes (max 3 iterations, then surface remaining issues to the owner).
Do NOT proceed to assembly with a slide that has not passed.

→ **Eval-runner gate (MANDATORY — run per slide, after c-vision-qa PASSes):**
```bash
for SLIDE in slides/*.png; do
  bash .hub/c-eval-runner/scripts/eval-run.sh "$SLIDE" --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
done
```
- `FAIL` (exit 1) on any slide → fix and re-render before assembly.
- `NEEDS_VISION` → perceptual checks are still `PENDING`; resolve with a c-vision-qa pass before delivery.
- Do NOT proceed to Step 6 until every slide is `PASS` or all perceptual pending items are resolved.

### Step 6 — Assemble PDF

```bash
# stitch the approved slide PNGs in slide order (ls -v = natural sort) — NO text drawing
convert $(ls -v slides/slide-*.png) "final/carousel-<topic-slug>.pdf"
```
→ Output: `final/carousel-<topic-slug>.pdf` + the individual `slides/*.png` (for platforms that take images).

### Step 7 — Caption

→ LOAD: skill_view("p-carousel", ".hub/c-script/SKILL.md") —— write the post copy:
- Hook line (matches the cover slide)
- Tease slides 2–3 (don't give it all away)
- CTA: "Save this + follow for more"
- 3–5 relevant hashtags

### Step 8 — Deliver ⛔ CHECKPOINT

Deliver: PDF + slide PNGs + caption `.txt`.
**Gate: User approves caption before scheduling.**

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.
