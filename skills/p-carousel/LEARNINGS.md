# p-linkedin-carousel Learnings

> This file is the self-learning loop for `p-linkedin-carousel`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

- **[ACTIVE] WI2.45 — ordered slides are the deliverables, never cover/sheet.** After
  `render_slides`, write `saves/slide_1.png`…`saves/slide_N.png` (N = outline count) plus
  pad `saves/slide_{N+1}.png`…`saves/slide_10.png` as copies of the last real slide so the
  manifest's fixed `slide_1`…`slide_10` saves all exist for harness upload/resume. Write
  `saves/slides.json` with `count` = N only (real slides). `cover.png` and `slide_sheet.png`
  are previews only — never deliver them. The worker selects `slide_1`…`slide_N` from
  `slides.json` for `complete_render_order`.

---

## Upstream source port (WI2.45 finding 3)

`scripts/sync-skills.py` rewrites `skills/` from the private source skills repo (`--src`,
outside this repository). Bundled edits here are overwritten on the next sync. **Chosen
approach for WI2.45:** do not patch `sync-skills.py` to preserve local diffs (fragile across
a full tree rewrite). Instead, the source-repo owner must carry the text below into
`p-carousel` before the next sync.

### `manifest.json` (render_slides.saves + recipeVersion)

- `recipeVersion`: `2026.10.3` (bumped from `2026.10.2` when slide saves landed).
- `render_slides.saves` must declare, in order:
  - `slide_1` … `slide_10` (`kind: image`, `preview: false`) — max matches `num_slides` choices
  - `cover` (`kind: image`, `preview: true`)
  - `slide_sheet` (`kind: image`, `preview: true`)
  - `slides` (`kind: json`, `preview: false`)
  - `qa_report` (`kind: json`, `preview: false`)

### `steps/03-render-slides.md` — required wording

- You must produce `saves/slide_1.png` … `saves/slide_N.png` as the carousel deliverables
  (N = `slides.json.count`).
- Pad `saves/slide_{N+1}.png` … `saves/slide_10.png` as copies of the last real slide so
  every declared manifest save exists for upload/resume; delivery still uses only
  `slides.json.count`.
- `cover.png` / `slide_sheet.png` are **preview only**; not deliverables.
- Save-writing Python must copy real slides, pad to 10, write `slides.json` with
  `count: len(real)`, then write cover + qa_report + contact sheet.

### `SKILL.md` — Step 8 Deliver

Must say: deliver individual slide PNGs in slide order (`slide_1.png` … `slide_N.png`);
never send `cover.png` or `slide_sheet.png` as a deliverable; managed runs select
`steps/render_slides/saves/slide_N.png` from `slides.json`.

### `steps/04-captions.md` — Delivery boundary

Must say: the worker delivers ordered `saves/slide_1.png` … `saves/slide_N.png` from
`render_slides` (via `prior/slides.json` order) plus captions; do not select `cover.png` or
`slide_sheet.png`.

---

## Feedback Log

### 2026-10-20 — WI2.45 resume + sync survival
- Manifest now declares `slide_1`…`slide_10` so per-slide PNGs are checked, uploaded and
  restored on resume. Recipe pads unused slots; selector still uses `slides.json.count`.
- Recipe delivery wording lives in this LEARNINGS upstream-port section so the next
  `sync-skills` does not silently drop WI2.43/WI2.45 contracts.

### 2026-05-08 — Initial template
- Skill created. No feedback yet.


### 2026-09-04 — CFW-128 headless certification (B-Vasanth Blueprint, 8 × 1080×1350 + PDF)
- `render.mjs` defaults to `SCALE=2` (2160×2700) but `acceptance.json` `canvas_1080x1350` is an EXACT dims check → every slide FAILs the gate until downscaled. Headless runs: render at 2× for sharpness, then `scale=1080:1350:flags=lanczos` into `slides/` (keep the 2× set in `slides-2x/`). **FIXED 2026-09-05 (CFW-131):** `render.mjs` now does exactly this itself — 2× capture → `slides-2x/`, lanczos downscale → `slides/` at exactly WIDTH×HEIGHT, ffprobe-verified, exit 1 on mismatch.
- `render.mjs` hard-launches Playwright's default headless-shell; on a box where that revision isn't installed it dies with "Executable doesn't exist". Pin `playwright` in the production dir (`npm i playwright@<ver>` + `npx playwright install chromium-headless-shell`) or point `node_modules/playwright` at an install whose revision is cached.
- Google Fonts are fetched over the network by both `template.html` and the Blueprint override — the fleet box blocks outbound fetches, so ship `@font-face` files (Inter, JetBrains Mono, Poppins) inside the recipe or accept system-font fallback.
- Both ⛔ CHECKPOINTs (outline, caption) must be pre-answered by the order: pass the full slide outline in `directives`/`intent` and `caption_autoapprove=true`; a headless Director cannot wait.
- Brand template: `brand-overrides/b-vasanth/template.html` (Blueprint exemplar) — use it instead of the recipe `template.html` for that brand.
