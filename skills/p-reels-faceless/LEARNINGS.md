# p-reels-faceless Learnings

> This file is the self-learning loop for `p-reels-faceless`. Before executing this skill, the agent reads this file and applies all **Active Feedback**. After execution, the agent asks the user for feedback and appends it here.

> **Not yet certified.** Active Feedback is bootstrapped from `p-reels-fmt4`'s proven gates — every item that bit a live production is inherited here. Add certification entries below as rounds complete.

---

## Active Feedback (apply on every run — inherited from p-reels-fmt4 + cover rule)

- `[ACTIVE]` **Scene sequencing is mandatory — one text beat visible at a time.** One composition per beat, concatenated. NEVER lump all beats into one untimed composition. Within a beat, later elements start hidden and are revealed by their entrance tween. See Step 9 (concat) and the Visual doctrine.

- `[ACTIVE]` **All media must be downloaded local — never reference remote URLs inside a composition.** Remote `http(s)://` URLs silently fail to load in the headless render. `curl -L` + ffprobe every asset; reference only local relative paths. See the Local-media rule in the Visual doctrine.

- `[ACTIVE]` **Visual QA Gate is mandatory — actually LOOK at the frames AND prove motion.** After every render: extract 6 frames (5/20/40/60/80/95%), READ each with vision, AND run the per-beat two-frame PSNR motion proof on every graphics beat (finite dB = motion; `inf` or ≥ 50 dB = fail). NEVER upload without looking. See Step 14.

- `[ACTIVE]` **Always upload to R2 and print the URL as the final line.** The worker recovers the deliverable by scraping the reply for an R2/CDN URL. A perfect render left on local disk = job FAILS. See Step 15.

- `[ACTIVE]` **Visual identity comes from the BRAND, never from this skill.** Resolve via the Visual Identity Gate (Brand Brief → DESIGN.md → named style → dark-premium). Hard-coding `#333`, `#3b82f6`, or `Roboto` means you skipped it. See Step 6.

- `[ACTIVE]` **No unicode emoji / icon-font glyphs — they render as `□` tofu boxes.** Every icon is inline SVG / CSS. No exceptions. See the ICONS rule in the Visual doctrine.

- `[ACTIVE]` **Ghost glyph is a thematic number/letter, never a placeholder word.** Never "CTA", "TITLE", "HEADER". Use the beat index, listicle total, or a deliberate initial. See the GHOST GLYPH rule.

- `[ACTIVE]` **No beat may pop-in then freeze — continuous ambient motion for the whole window.** Slow yoyo/breathe/drift on glow/grid/ghost. Stagger entrances later. Step 14 motion proof FAILS at ≥ 50 dB. See AMBIENT MOTION rule.

- `[ACTIVE]` **The foreground content is the HERO — a beat that renders as only the ghost number is EMPTY.** Author every foreground element with `gsap.from()` (ends visible). NEVER `set(hidden)` + `.to(reveal)` pattern. A ghost-only frame is a hard failure. See the Visual doctrine HERO rule.

- `[ACTIVE]` **QA EVERY beat, never just beat 1.** The Step 14 motion + foreground proof runs on every graphics beat in the reel.

- `[ACTIVE]` **Every reel ends on a brand outro — never on a content beat.** Default is a GENERATED brand-card outro beat (brand name + tagline + Follow-for-more CTA). A supplied `$OUTRO` clip overrides it. QA check (h) samples ~97% and fails if it's a content beat. See Step 11.

- `[ACTIVE]` **First-frame cover rule — always prepend a 0.4s money-shot freeze.** Extract `cover.png` at `cover_at` (mid-content, never the hook), freeze to 0.4s clip, prepend via concat. Deliver `faceless-reel-with-cover.mp4` + `cover.png`. Never skip this. See Step 13.

- `[ACTIVE]` **c-typing-ui must use FULL variant for this format (never pip-safe).** There is no PIP in faceless layout. `pip-safe` would leave the bottom half blank. See Step 7 per-beat authoring spec.

- `[ACTIVE]` **No-broll path must be indistinguishable from fmt4.** When `$BROLL_CLIPS` is empty: skip Steps 4 and 8, call `c-broll-sync` without `--broll`, proceed with 100% graphics beats. Full Visual doctrine + QA gate + cover rule still apply. See the "Degenerate case" section.

---

## Feedback Log

### 2026-06-12 — Initial creation (bootstrapped from fmt4 + format-consolidation-plan §3c)

- Skill created as part of the reels-format-consolidation Phase 1 build. Based directly on
  `p-reels-fmt4` (inheriting all Active Feedback gates) + adds optional `c-broll-sync` b-roll
  integration, `c-typing-ui` FULL variant scene type, and the first-frame cover rule from §2d.
- Not yet certified — no live cook run completed. All Active Feedback items are inherited from
  proven fmt4 gates, not from live failures in this skill. First certification round pending.
- Key design decisions: (1) `c-broll-sync` is the planner — it is always called, even for
  no-broll runs; (2) `c-typing-ui` FULL variant is the correct choice (no PIP safe zone);
  (3) `c-reel-premium` captions are ON by default for this format (TTS+graphics reel needs
  captions — different from fmt4 where the graphics carry the text themselves); (4) cover rule
  is the last pre-upload step, not folded into `c-reel-premium`.

### 2026-09-04 — CFW-128 headless certification (MGG, Day 17 MCP script, 1 ElevenLabs call $0.16)
- **Loudness contradiction:** Step 2 loudnorms the VO to **-16 LUFS** but `acceptance.json` `qa_gate` (c-shorts-qa-gate) expects **-14 ± 1.5** → the final reads -17.3 and FAILs. Master to -14 (or change Step 2 to -14) before the cover freeze.
- **Frame-0 floor vs navy palette:** every MGG graphics card measures YAVG≈42, below c-shorts-qa-gate's `>0x30` (48) frame-0 floor, so a card can never be the cover on this brand. Pick a b-roll frame or brighten the cover treatment; the planner's `cover_at` (a graphics beat) will fail here.
- **Step 8 b-roll filter is invalid:** it passes a labelled `[0:v]split…[bv]` graph to `-vf` → ffmpeg "Output with label 'bv' does not exist". Use `-filter_complex`.
- `c-broll-sync/plan.js` emits graphics beats with EMPTY `eyebrow/ghost/title_html` and windows of 10–17 s. The Director must split them into 4–6 s sub-beats and author every card's copy (`scene_plan`) — nothing in the chain writes card text.
- `repeat: -1` is rejected by `hyperframes lint` — compute a finite repeat from the beat duration.
- `voice_id` must be passed explicitly: the vault `ELEVENLABS_DEFAULT_VOICE_ID` is the superseded clone; the pin lives in `brand-overrides/<slug>/brand.json` (`qfNHzU5pVyzMLm53FhzY`, `eleven_v3`).
- MGG has **no video b-roll on disk** (`creatives/brolls/recordings/` is gone) — Ken-Burns clips from `brolls/images/*.png` (`zoompan`) work as on-brand b-roll.

### 2026-09-05 — CFW-131 fleet-blocker fixes (applied to this SKILL.md)
- **Loudness contradiction FIXED**: Step 2 now normalises to **-14 LUFS** and Step 13 re-masters the premium output to -14 (two-pass loudnorm) before the cover freeze; `acceptance.json` `vo_loudness` = -14 and a new `final_loudness` check on the delivered file. One truth: **-14 LUFS for reels.**
- **Step 8 `-vf` FIXED** → `-filter_complex` (labelled graph).
- **Frame-0 floor → perceptual**: `c-shorts-qa-gate` + new `c-eval-runner` `contrast_floor` (`cover_has_contrast` at t=0) accept a dark card with a bright headline; flat dark frames still fail. Prefer `cover: true` on a footage/bright scene in `scene_plan.json`.
- **Card copy is the Director's job**: Step 5a authors `scene_plan.json` (`.hub/c-broll-sync/SCENE-PLAN.md`); `plan.js --scene-plan` splits windows into 4–6 s cards and exits 1 if any graphics beat would be blank. Beats carry `slug` = `beat<N>-<id>` for Steps 7/9.
- **c-reel-premium P2 needs the vendored GSAP in the polish comp dir** (`cp .hub/f-gsap/vendor/gsap.min.js "$PW/comp/"` before `hyperframes validate/render`) — the template loads `gsap.min.js` locally and `validate` dies with `404 loading gsap.min.js` otherwise (CFW-131 re-run; same rule as Step 7 cards and the Step 11 outro).
- **The premium pass drifts the level (CFW-131 re-run: VO bed −14.0 → `premium.mp4` measured −16.1 LUFS)** — the caption comp re-encode + `amix normalize=0` with SFX under is not level-neutral. Step 13's two-pass master is therefore load-bearing, not cosmetic: the delivered file read −14.0 only after it.
- **scene_plan certified 2026-09-05 (CFW-131):** 9 scenes (7 graphic + 2 pinned broll with `cover:true` on the first) authored with `start_phrase`/`end_phrase` anchors → `plan.js --scene-plan` → 7 cards, every one with copy (luma range ≥ 215, ≥ 2.1 % bright pixels at mid-beat); gates PASS (−14.0 LUFS, cover YAVG 208, contrast_floor). Output: `mr-growth-guide/creatives/productions/2026-09-04-cfw131-p-reels-faceless/`.
