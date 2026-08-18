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
