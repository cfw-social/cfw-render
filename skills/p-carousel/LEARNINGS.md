# p-linkedin-carousel Learnings

> This file is the self-learning loop for `p-linkedin-carousel`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

*None yet — add feedback below and it becomes part of this skill's behavior.*

---

## Feedback Log

### 2026-05-08 — Initial template
- Skill created. No feedback yet.


### 2026-09-04 — CFW-128 headless certification (B-Vasanth Blueprint, 8 × 1080×1350 + PDF)
- `render.mjs` defaults to `SCALE=2` (2160×2700) but `acceptance.json` `canvas_1080x1350` is an EXACT dims check → every slide FAILs the gate until downscaled. Headless runs: render at 2× for sharpness, then `scale=1080:1350:flags=lanczos` into `slides/` (keep the 2× set in `slides-2x/`). **FIXED 2026-09-05 (CFW-131):** `render.mjs` now does exactly this itself — 2× capture → `slides-2x/`, lanczos downscale → `slides/` at exactly WIDTH×HEIGHT, ffprobe-verified, exit 1 on mismatch.
- `render.mjs` hard-launches Playwright's default headless-shell; on a box where that revision isn't installed it dies with "Executable doesn't exist". Pin `playwright` in the production dir (`npm i playwright@<ver>` + `npx playwright install chromium-headless-shell`) or point `node_modules/playwright` at an install whose revision is cached.
- Google Fonts are fetched over the network by both `template.html` and the Blueprint override — the fleet box blocks outbound fetches, so ship `@font-face` files (Inter, JetBrains Mono, Poppins) inside the recipe or accept system-font fallback.
- Both ⛔ CHECKPOINTs (outline, caption) must be pre-answered by the order: pass the full slide outline in `directives`/`intent` and `caption_autoapprove=true`; a headless Director cannot wait.
- Brand template: `brand-overrides/b-vasanth/template.html` (Blueprint exemplar) — use it instead of the recipe `template.html` for that brand.
