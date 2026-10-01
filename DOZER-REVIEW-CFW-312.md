VERDICT: PASS

## Summary

The build faithfully implements DOZER-DESIGN-CFW-312.md: a sync-time rewrite pass in
`scripts/sync-skills.py` that replaces the host-path `find` sub-skill resolver idiom with
bundle-relative paths, a new `scripts/check-skills-portability.sh` gate wired into the sync
pipeline + test suite + lint, and a real regenerated bundle. Verified directly in this
worktree, not just read off the diff:

- `scripts/check-skills-portability.sh` (no args) → **PASS — no host-path sub-skill resolver
  in 14 recipe dir(s)**.
- Independent raw `grep -rn` for `$HOME/.claude`, `$HOME/.hermes`, `/Users/*/ecosystem/harness/skills`
  across `skills/` turns up only the exact set of out-of-scope exceptions the design calls out:
  `c-audio`'s SFX library doc paths, `c-kie-ai`/`c-replicate`'s `${SKILLS_DIR:-$HOME/.claude/skills}`
  author-tooling idiom (different shape, not the bug), `c-production`'s example, and
  `c-eval-runner/scripts/eval_run.py`'s already-correct `.hub/`-first-then-host-fallback. No
  resolver-shaped host-path reference survived anywhere in the bundle.
- `scripts/verify-skills-bundle.sh` → **PASS — 14 recipe(s), 1150 file(s) match index.json**
  (hashes cover the rewritten bytes, as designed).
- `test/run-tests.sh` → **PASS: 80  FAIL: 0**, including the new Case 10 (fixture-based unit
  coverage of the rewrite: own-dir anchors on `CFW_RENDER_SKILLS_DIR`, sub-skill-dir resolves
  to `.hub/`, dead fallback line dropped, nested dep's own-dir resolves to its actual on-disk
  `.hub/` location, gate passes clean on the fixture, clean recipe doesn't false-positive) and
  Case 11 (static guard against the real committed `skills/` tree).
- `scripts/lint.sh` → all scripts including the new one pass `bash -n` + shellcheck (no
  explicit glob edit needed — `scripts/*.sh` already covers it).

Spot-checked the trickiest edge cases the design flagged as risk:
- `p-reels-faceless/SKILL.md` Step-0 (most variables): `SKILL_DIR`/`BROLL_SYNC_DIR`/
  `TYPING_UI_DIR`/`PREMIUM_DIR`/`OVERLAY_FX_DIR` all rewritten correctly, no `find` left.
- Nested dependency flattening: `p-reels-pip-heygen/.hub/p-reels-pip/SKILL.md`'s own `SKILL_DIR`
  resolves to its actual on-disk path (`.../p-reels-pip-heygen/.hub/p-reels-pip`), and its
  sub-skill vars correctly use `$SKILL_DIR/../<dep>` (sibling, not `.hub/<dep>`) — matches where
  `copy_tree`'s flattened closure actually places `c-broll-sync` etc. under
  `p-reels-pip-heygen/.hub/`. Verified via `ls skills/p-reels-pip-heygen/.hub/`.
- Second-level fallback paths (`f-gsap/vendor` via `$SKILL_DIR/../f-gsap/vendor`) survived the
  rewrite untouched in both the top-level and nested copies, as required.
- `_find_skill()` helper in `verify-skill.sh` rewritten correctly in both the top-level
  (`.hub/$1`) and nested (`../$1`) variants.
- `CFW_RENDER_SKILLS_DIR` is confirmed actually exported into the Director's process env by
  `cr_load_config` (`bin/cfw-render-lib.sh:220-225`) — the rewrite's anchor is real, not
  aspirational.

## Scope note (not a defect)

The regenerated bundle's `sourceCommit` moved from `08ca722…` to `4c247e1…`, so this commit
also pulls in unrelated upstream changes that landed between those two source commits (most
visibly the GSAI-36 CTA alpha-channel/scrim fix touching several recipes' Step 8/9 blocks).
This is exactly what DOZER-DESIGN-CFW-312.md §3 anticipated and called "a normal 'pull in an
upstream skills change' commit, just with the new rewrite applied for the first time" — not a
scope deviation. All upstream content came through as a faithful copy plus the one intended
rewrite; checksum and portability gates both confirm this.

## Design fidelity

Every file the design's "Files to touch" section named was touched, and only those (plus the
expected regenerated `skills/**`, `skills/index.json`, `config/skills-version.json`). The
out-of-scope items (p-carousel's eval_run.py, c-kie-ai/c-audio/c-production host paths,
brand-overrides asset paths) were correctly left alone and are allowlisted in the gate with a
one-line reason each, matching the design's explicit instruction not to grow the allowlist
without re-examining the rewrite first.

## Independent re-verification (second review pass)

Re-ran every claim above from scratch in this worktree rather than trusting the committed
review text — all reproduced:

- `scripts/check-skills-portability.sh` → PASS (14 recipe dirs).
- `scripts/verify-skills-bundle.sh` → PASS (14 recipes, 1150 files).
- `test/run-tests.sh` → `PASS: 80  FAIL: 0`, Case 10 and Case 11 both present and green.
- Raw `grep -rl` sweep of `skills/` for the three forbidden host-root patterns turned up only
  `c-audio`/`c-production` doc paths, `c-kie-ai`/`c-replicate`'s `${SKILLS_DIR:-$HOME/.claude/skills}`
  default-value idiom (not a `find`, correctly untouched), `c-kie-ai/sync-models.sh`'s author-side
  output path, and `eval_run.py`'s allowlisted `.hub/`-first fallback — nothing else.
- `p-reels-pip-heygen/.hub/p-reels-pip/SKILL.md` confirmed on disk to resolve its own dir to its
  real nested path and its sub-skill vars to `$SKILL_DIR/../<dep>` siblings; `CFW_RENDER_SKILLS_DIR`
  confirmed exported at `bin/cfw-render-lib.sh:221-222`.
- Ran all four recipe-level `scripts/verify-skill.sh` copies touched by this diff
  (`p-reels-pip`, `p-reels-pip-heygen/.hub/p-reels-pip`, `p-reels-split`,
  `p-reels-split-heygen/.hub/p-reels-split`) directly: 33/33, 33/33, 48/48, 48/48 under a
  UTF-8 locale — the `_find_skill()` rewrite works in both the top-level (`.hub/$1`) and
  nested (`../$1`) forms.

**One pre-existing, out-of-scope flake found and ruled out as a blocker:** under a `C`
locale shell, `p-reels-split/scripts/verify-skill.sh`'s own "bottom zone 1080x960" check
(line 47, `grep -q "bottom.*1080.960\|..."`) fails, because its `.` assumes the `×` in
"1080×960" is one byte; in `C` locale it's two UTF-8 bytes, so the pattern doesn't match.
Confirmed this reproduces byte-for-byte on `develop`'s baseline copy of the same file under
the same locale — it predates this branch, CFW-312 never touched that check line, and
`test/run-tests.sh` (the actual gate `pnpm test` runs) never invokes any recipe's
`verify-skill.sh` at all, so this never reaches CI. Not a regression, not in scope, not
blocking — flagging only so it doesn't get mistaken for fallout from this change later.

No changes made to the repo other than this review file.
