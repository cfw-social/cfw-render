# p-reels-split Learnings

> Read before executing. Apply every item under **Active Feedback** as a rule.

## Active Feedback (apply on every run)

- [ACTIVE] **Reused HeyGen renders are valid input** (`talking_head_video`), but `known_transcript` means WORD-TIMED JSON, not the script text — transcribe (mlx_whisper large-v3-turbo, ~8 s for 54 s) and only use the script to correct ASR slips.
- [ACTIVE] With **zero b-roll**, `c-broll-sync/plan.js` returns ONE beat spanning the whole bed. Post-rewrite `beat_list.json` onto a fixed 5 s grid and author every card's `eyebrow/ghost/title_html` yourself — plan.js emits them empty.
- [ACTIVE] `bottom_cutzoom=true` keys zoom off beat *kind*; with no b-roll beats every segment is 1.4× — alternate by beat parity instead (`cutzoom_pattern=alternate`).
- [ACTIVE] Append a supplied `outro` AFTER the c-reel-premium pass, not before (Step 9 order): captions must not run over a static outro card and the premium plan assert (`last caption end within 3 s of duration`) trips on a 3 s outro. Give the outro a silent AAC track before concat.

## Feedback Log

### 2026-09-07 — GSAI-36 CTA end card: alpha dropped at render + copy top-anchored (every brand)
- Every reel from every brand ended on a flat opaque navy slate with the CTA jammed against the top edge. Two defects, one cause: the card was rendered to **mp4 (`yuv420p`, no alpha channel)** so the `rgba(...,0.85)` scrim was discarded at encode; and the copy was top-anchored despite `justify-content:center` on `body` and the root — HyperFrames' render capture does not honour flex centering on `body`/root (verified: the same compiled HTML centres correctly in plain Chrome; the worker's captured frames put the copy in rows 40–531 of 1920).
- Fix (Step 9): render with `--format mov` (ProRes 4444, `yuva444p12le`) and overlay `cta-card.mov`; move the scrim and the copy to **inner `position:absolute` layers** (the alpha capture forces `html`/`body`/root transparent); `padding-bottom:288px` keeps the copy above the bottom 15%. Two fail-fast gates: card `pix_fmt` must be `yuva*`, and the bottom 55% of the final frame must be >1 distinct colour.
- Proof on the same source reel (`05.15-day16-automate-instagram-postforme`): before = 1 distinct colour in the bottom 55%, after = 19 708; card alpha 218/255 (= 0.85); copy rows 594–1080 (centre 837, safe-zone centre 816). Reel duration unchanged (55.893 s).
- Merge gate: `scripts/tests/p-reels-cta-card.test.sh` checks both templates statically and proves the ffmpeg alpha path with a synthetic card (no Chrome needed); `CTA_RENDER=1` adds a real HyperFrames render.

### 2026-09-04 — CFW-128 headless certification (MGG, reused 1920×1080 `05.15-day14-week2-recap-top3-tools` raw avatar, $0)
- End-to-end on the Mac in ≈6 min: 11 top cards (26 s, 4-way parallel), cut-zoom bottom, vstack, CTA takeover, outro PNG, premium (Opus planner, 40 groups / 9 SFX, 3.5 min render), cover freeze. c-shorts-qa-gate PASS (-14.6 LUFS, frame-0 YAVG 55), c-eval-runner PASS after the `luma_floor` engine fix (it point-sampled navy frames as 4–13; true mean 33).
- The split-motion-card template is title-only; put chips/bignum HTML inside `TITLE_HTML` to satisfy the "illustrative, not just titles" rule.
- Fleet blockers found: outro/reused-avatar must be `media.cfw.social` ingredients (no MCP upload tool — brand-key `GET /api/v1/media/upload-url` presign), `claude --print` planners need the CLI + auth on the box, hyperframes via `npx` needs the 0.7.5 tarball cached offline.
