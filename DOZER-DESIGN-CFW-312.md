# DOZER-DESIGN-CFW-312

[ENG] cfw-render recipes resolve sub-skills from host paths instead of their bundled `.hub/` — add a bundle gate so it cannot recur

## Root cause

`skills/<recipe>/SKILL.md`'s "Setup" bash block resolves its own directory and its
sub-skill directories with a `find` over **host** paths:

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" \
  /Users/vasanth/ecosystem/harness/skills -maxdepth 5 -type d -name p-reels-faceless 2>/dev/null | head -1)
BROLL_SYNC_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" \
  /Users/vasanth/ecosystem/harness/skills -maxdepth 5 -type d -name c-broll-sync 2>/dev/null | head -1)
[ -n "$BROLL_SYNC_DIR" ] || BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"
PREMIUM_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" \
  /Users/vasanth/ecosystem/harness/skills -maxdepth 5 -type d -name c-reel-premium 2>/dev/null | head -1)
```

This is correct for the **source** library (`~/ecosystem/harness/skills`), where Hermes/Claude
Code install skills as siblings under `~/.claude/skills` or `~/.hermes/skills` and a sub-skill
really does live at one of those host roots. It is **wrong for cfw-render's vendored bundle**:
the render box is "deliberately runtime-free" (`docs/PACKAGING-DESIGN.md`) — none of
`$HOME/.claude/skills`, `$HOME/.hermes/*`, or `/Users/vasanth/ecosystem/harness/skills` exist
there. On the box:

- `SKILL_DIR` has **no fallback at all** → resolves to `""`. Every downstream
  `"$SKILL_DIR/.hub/<dep>"` reference (including the fallbacks that *do* exist, e.g.
  `BROLL_SYNC_DIR`/`TYPING_UI_DIR`) becomes `/.hub/<dep>` — filesystem root, not the recipe.
- Some sub-skill vars (`PREMIUM_DIR`, `OVERLAY_FX_DIR`, `WOWX_DIR`, `TYPING_DIR` in the
  spotlight variant) have **no `.hub/` fallback at all** — they silently resolve to `""`.

`scripts/sync-skills.py` (called by `scripts/sync-skills.sh`) does a byte-for-byte
`copy_tree` from `CFW_SKILLS_SRC` into `skills/<recipe>/` + `skills/<recipe>/.hub/<dep>/`
(flattened) with **no body rewriting** — the module docstring and script header explicitly
(and incorrectly) assert "the source already uses `.hub/<dep>/...`-relative paths" for
everything. That assumption is false for the `SKILL_DIR`/sub-skill-dir resolver lines, and
nothing currently checks for it, so every future sync reintroduces the bug for any recipe
whose source `SKILL.md` still uses the dual-home resolver (which is most of them, since that
resolver is the *correct* pattern for the source library's other consumers).

Confirmed by grep across the vendored `skills/` tree (13 of 14 bundled recipes carry the
pattern somewhere in their own file or their `.hub/` closure; only `c-composio`, which has no
`dependsOn`, is clean):

```
c-composio:               0 files
p-ai-character:            3   p-ai-image:        4   p-carousel:   1 (different case, see below)
p-clone-reel:              2   p-gfx-image:       2   p-longform:   5 (all inside .hub/ deps)
p-reels-faceless:          5   p-reels-pip:       6   p-reels-pip-heygen:        6
p-reels-split:             6   p-reels-split-heygen:  7
p-reels-spotlight:         5   p-reels-spotlight-heygen: 5
```

9 recipes carry the bug in their **own top-level** `SKILL.md` Step-0 block (`p-ai-character`,
`p-ai-image`, `p-clone-reel`, `p-gfx-image`, `p-reels-faceless`, `p-reels-pip`,
`p-reels-split`, `p-reels-split-heygen`, `p-reels-spotlight`); the rest get it transitively
through a vendored dependency (`p-longform`, `p-carousel`'s `.hub/c-eval-runner`,
`p-reels-pip-heygen`/`p-reels-spotlight-heygen`'s `.hub/p-reels-pip`/`.hub/p-reels-spotlight`).
That reconciles with the ticket's "12 of 14" — the exact count depends on whether you count a
recipe once per closure or once per affected file; either way the fix has to walk the whole
vendored tree per recipe, not just the top-level `SKILL.md`.

One file is a **different, lower-severity** case and is deliberately left alone (see
"Out of scope" below): `p-carousel/.hub/c-eval-runner/scripts/eval_run.py` already checks
`.hub/c-shorts-qa-gate/...` **first** and only falls back to a host `find` if that's missing —
correct precedence, just belt-and-suspenders for non-bundled dev use.

## Why this hasn't been caught

- `scripts/verify-skills-bundle.sh` only checksums bytes against `index.json` — it verifies
  the bundle matches what was synced, not that what was synced is *correct*.
- `scripts/lint.sh` globs `bin/`, `install/`, `test/`, `scripts/` — it never looks at `skills/`.
- `test/run-tests.sh` has no case over the `skills/` tree at all today.
- The Director is explicitly told the resolved path already: `lib/director-prompt.md` /
  `bin/cfw-render.sh`'s `spawn_director` substitutes `{{skillsDir}}` = `$CFW_RENDER_SKILLS_DIR`
  and `{{recipe}}` into the prompt ("read ONLY `order.json` ... and recipe/skill files under
  `{{skillsDir}}`... Follow the recipe `{{recipe}}` under `{{skillsDir}}`"). The Director
  *knows* the right path — but when it then executes the Step-0 bash block verbatim out of
  `SKILL.md`, that block re-derives `SKILL_DIR` itself via the host `find` and clobbers the
  correct context with an empty string. `CFW_RENDER_SKILLS_DIR` is already exported into the
  Director's process env by `cr_load_config` (`bin/cfw-render-lib.sh`), so the fix can anchor
  on it directly instead of re-deriving anything at render time.

## Approach

Fix at the **sync** step, not by hand-editing `skills/` (which `skills/README.md` explicitly
forbids — "generated, pinned copy... any hand edit... is overwritten on the next sync and
will fail the checksum gate"), and not in the source library (`~/ecosystem/harness/skills` is
a different repo/owner outside this worktree's scope, and the dual-home resolver is *correct*
there for Hermes/Claude Code installs). cfw-render owns exactly one thing: `sync-skills.py`'s
copy step. Teach it to rewrite the known-bad lines as it copies, then add a gate that fails
loudly if any host-path reference survives — in the sync itself, in the test suite, and in
lint.

### 1. Rewrite pass in `scripts/sync-skills.py`

Add a `rewrite_host_path_resolvers(recipe_dest: Path, recipe_name: str)` step, run on
**every** copied tree (the recipe's own files at `recipe_dest`, and each dependency at
`hub_dir / dep` — same function, called once per directory with that directory's own "what
is my name" context) right after `copy_tree` and before `list_files`/hashing (so the hashes in
`index.json` are computed over the *rewritten* bytes, matching what actually ships).

Two deterministic, regex-anchored substitutions per file (text files only — skip binary):

- **The "what is my own dir" line** — matches
  `<VAR>=\$\(find ... -name <recipe_name> ...\)` for the directory's own name — rewritten to:
  ```bash
  SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/<recipe_name>"
  ```
  Fails loudly (`:?`) instead of silently resolving to `""` if the env var is somehow unset —
  consistent with the CLAUDE.md fail-fast rule, and a strict improvement over today's silent
  empty string. `<recipe_name>` is a literal baked in at sync time (known to the script), so
  no runtime `find` is needed at all.
- **Every "find a sub-skill dir" line** — matches
  `<VAR>=\$\(find "\$HOME/\.claude/skills" "\$HOME/\.hermes/skills"(?: "\$HOME/\.hermes/profiles")? (?:/Users/\S+/ecosystem/harness/skills )?-maxdepth \d+ -type d -name (\S+) ...\)`
  — rewritten to `<VAR>="$SKILL_DIR/.hub/\2"`. Any following
  `[ -n "$<VAR>" ] || <VAR>="$SKILL_DIR/.hub/<dep>"` fallback line becomes dead code with the
  same value, so drop it rather than leave a no-op — one line, same effect, easier to read.

  This fires for `BROLL_SYNC_DIR`, `TYPING_UI_DIR`, `PREMIUM_DIR`, `OVERLAY_FX_DIR`, `WOWX_DIR`,
  `TYPING_DIR`, and the nested copies of the same lines inside `.hub/p-reels-pip/SKILL.md` /
  `.hub/p-reels-spotlight/SKILL.md` (the `-heygen` variants' vendored dependency), and inside
  `.hub/c-typing-ui`, `.hub/c-broll-sync`, `.hub/c-reel-premium`'s **own** `SKILL_DIR=` lines
  (those files resolve *their own* dir the same broken way when read as a standalone
  `SKILL.md` — same fix, same two patterns, just a different `<recipe_name>` baked in: the
  dependency's own name, and its own `.hub/` is one level further down since it's itself
  vendored under the parent recipe's `.hub/<dep>/.hub/...` — confirm during implementation
  whether any dep has its own `dependsOn` closure nested two deep; `walk_closure` already
  flattens this to one `.hub/` per recipe, so the dep's `SKILL_DIR` fallback for further
  sub-deps should point at `$SKILL_DIR/../<sub-dep>` i.e. the *parent* recipe's `.hub/`, not a
  nested `.hub/`. Verify against `f-gsap`/`f-hyperframes` references inside
  `c-reel-premium`/`p-reels-faceless` which already use `"$SKILL_DIR/../f-gsap/vendor"` as a
  second fallback for exactly this reason — the rewrite must preserve that second path, not
  just the first).
- Apply the same two substitutions to non-`SKILL.md` vendored scripts that contain the
  identical `find`-over-host-paths idiom for *recipe/sub-skill* resolution (`verify-skill.sh`
  occurrences at `p-reels-pip/p-reels-split/p-reels-pip-heygen/scripts/verify-skill.sh`). Do
  **not** touch `eval_run.py`'s host-path fallback (different shape: `.hub/`-first, host-path
  only as a last resort) or the `c-kie-ai`/`c-audio` scripts' `/Users/vasanth/ecosystem/harness/skills`
  references — those are either correct-precedence already or author-side tooling not
  executed by the render worker (see "Out of scope").

### 2. Bundle gate — `scripts/check-skills-portability.sh` (new)

A standalone, dependency-free script (bash + grep, matching the repo's "runtime-free"
constraint) that scans `skills/` (or `--skills-dir DIR`) for the forbidden substrings and
exits non-zero with every offending `file:line` if it finds one:

```
$HOME/.claude    $HOME/.hermes    /Users/<anyone>/ecosystem/harness/skills
```

(the last one via a `/Users/[a-zA-Z0-9_-]+/ecosystem/harness/skills` pattern, not just the
literal `vasanth`, so a future BYOA customer's own home dir trips it too — this is a
portability gate, not a "don't say my name" gate). Carries a tiny, explicit, inline allowlist
(file + line, with a one-line reason) for the two known, intentionally-kept exceptions
(`eval_run.py`'s `.hub`-first fallback; none expected elsewhere after the rewrite — if the
allowlist ever needs a third entry that's a signal to re-examine the rewrite, not just add a
line). Mirrors `scripts/verify-skills-bundle.sh`'s CLI shape (`--skills-dir`, recipe-name
positional args) so it composes the same way in the sync pipeline and in tests.

Wire it in three places so it cannot silently regress:

1. **`scripts/sync-skills.sh`** — run it immediately after `sync-skills.py` and before the
   manifest refresh; a non-zero exit aborts the sync with the offending lines printed, so a
   future recipe added to `config/recipes.json` whose source `SKILL.md` uses some *new*
   resolver shape the rewrite doesn't yet handle fails the sync loudly instead of shipping a
   silently-broken recipe.
2. **`test/run-tests.sh`** — a new static-guard case, same shape as the existing
   `Case 9: static guard — no live reference to the retired ~/.gsai/secrets vault`:
   ```
   === Case <N>: static guard — bundled skills resolve sub-skills from .hub/, not host paths (CFW-312) ===
   ```
   runs `scripts/check-skills-portability.sh` against the real `skills/` dir and `pass`/`fail`
   accordingly. This is what makes the Dozer test gate (`pnpm test` = `test/run-tests.sh`)
   catch a regression even on a run that never touches sync-skills.py.
3. **`scripts/lint.sh`** — extend the `SCRIPTS` glob to include the new script itself
   (`scripts/check-skills-portability.sh`) so it gets `bash -n`/shellcheck coverage like every
   other script in the repo; the portability check itself is exercised via `test/run-tests.sh`,
   not lint (lint is shell-syntax, not content).

### 3. Regenerate the real bundle

Once the rewrite + gate land, re-run the sync for real and commit the result:

```bash
CFW_SKILLS_SRC=~/ecosystem/harness/skills scripts/sync-skills.sh
scripts/verify-skills-bundle.sh      # checksum gate — must still pass
scripts/check-skills-portability.sh  # new gate — must now pass clean
```

This regenerates `skills/<recipe>/**`, `skills/index.json`, and `config/skills-version.json`
from the live source — a normal "pull in an upstream skills change" commit, just with the new
rewrite applied for the first time. `skills/README.md`'s `_14 recipes in this bundle._` footer
is also regenerated by whatever currently writes it (confirm whether that's `sync-skills.sh`
or hand-maintained; if hand-maintained, leave it — out of scope for this ticket).

## Files to touch

- `scripts/sync-skills.py` — add the rewrite pass (`rewrite_host_path_resolvers`), call it
  for the recipe's own dir and each `.hub/<dep>` dir right after `copy_tree`, before hashing.
  Update the module docstring/header comment (currently claims "no body rewriting... the
  source already uses `.hub/<dep>/...`-relative paths" — false, per above) to describe what
  it now rewrites and why.
- `scripts/check-skills-portability.sh` — new script, the bundle gate.
- `scripts/sync-skills.sh` — invoke the new gate after the python sync, before the manifest
  refresh; abort (propagate exit code) on failure.
- `scripts/lint.sh` — add the new script to the `SCRIPTS` glob.
- `test/run-tests.sh` — new static-guard case (after Case 9, before Case P, matching the
  existing numbering style).
- `skills/**` + `skills/index.json` + `config/skills-version.json` — regenerated output, not
  hand-edited (committed as the result of step 3 above).
- Possibly `test/fixtures/skills-src/` (new, small) — see Testing below.

## Edge cases

- **`c-composio`** has no `dependsOn` — closure is empty, rewrite pass runs over just its own
  dir, finds nothing to rewrite (it never had the bug), gate stays green. Confirms the gate
  doesn't false-positive on a clean recipe.
- **Dep names that are substrings of other dep names** (e.g. none observed today, but
  `c-typing-ui` vs a hypothetical `c-typing-ui-v2`) — the regex must anchor on the `-name`
  argument's exact token (quoted or bare, up to the next whitespace/`2>`), not a loose
  substring match, so it can't mis-rewrite a sibling dep.
- **Second-level fallback paths** (`"$SKILL_DIR/../f-gsap/vendor"`) — must survive the
  rewrite untouched; they're relative to `$SKILL_DIR` which the rewrite fixes, so they become
  correct for free once `SKILL_DIR` is right. Verify explicitly for `p-reels-faceless` /
  `c-reel-premium` (both reference `f-gsap` this way) since this is the one place a dep's
  dep (`f-gsap` under a `.hub` sibling, not under the current file's own `.hub/`) is resolved
  by relative path rather than the `find`/`.hub/<dep>` pattern — nothing to rewrite there, just
  don't break it.
- **A future new recipe's source `SKILL.md` uses a resolver shape the regex doesn't
  recognize** (e.g. different flag order, an extra search root) — the sync-time gate (wired
  into `sync-skills.sh`, not just the test suite) catches this at sync time with the exact
  offending line printed, rather than shipping a recipe that passes CI (because nobody re-ran
  `test/run-tests.sh` against a bundle nobody regenerated) and breaks on the box. This is the
  main argument for running the gate in the sync pipeline itself, not only in tests.
- **BYOA / non-`vasanth` home dirs** — the portability gate's pattern
  (`/Users/[^/]+/ecosystem/harness/skills`) catches any user's home, not just
  `/Users/vasanth`, so a customer's own synced bundle (if BYOA ever syncs independently) is
  covered too.

## Out of scope (flagged, not fixed here)

- **`p-carousel/.hub/c-eval-runner/scripts/eval_run.py`** — already checks
  `.hub/c-shorts-qa-gate/scripts/qa-gate.sh` first; host `find` only runs if that file is
  missing. Correct precedence already; left alone and added to the gate's allowlist with a
  one-line reason rather than rewritten.
- **`c-kie-ai/sync-models.sh`, `c-audio`'s SFX library paths, `c-production`'s
  `{brand_local_path}` example** — author/maintainer-side tooling and documentation examples,
  not code the render worker executes for a customer render. Hardcoded to
  `/Users/vasanth/ecosystem/harness/skills` because that's genuinely where the *source*
  library lives for the one person who runs them. Not part of "sub-skill resolution" and not
  touched by `sync-skills.py`'s copy of the *bundled* tree's execution path.
- **`brand-overrides/vasanth-sek8tv/brand.json`'s hardcoded `/Users/vasanth/initiatives/...`
  asset paths** (`p-reels-faceless`, `p-reels-split`, `p-carousel`, `p-reels-split-heygen`) —
  a real portability smell (a brand override baked to one person's home dir), but it's data,
  not the sub-skill-resolution bug this ticket names, and fixing it means deciding where brand
  asset paths *should* resolve from (ecosystem.yaml? a brand-relative path?) which is a
  product decision, not a mechanical rewrite. Worth a follow-up CFW ticket; not blocking this
  one and not covered by this gate.

## Testing

1. **Fixture-based unit coverage, no dependency on `~/ecosystem/harness/skills` existing on
   every runner.** Add `test/fixtures/skills-src/` with 2-3 minimal synthetic recipes that
   reproduce the exact bug shape (a recipe with the broken `SKILL_DIR=$(find ...)` line, a dep
   with the broken sub-skill-dir line plus an existing `.hub/`-fallback line, one clean recipe
   with no deps). Point `scripts/sync-skills.sh --out-dir <scratch>` at it via
   `CFW_SKILLS_SRC=test/fixtures/skills-src` in a new test case, then assert on the rewritten
   output: `SKILL_DIR` line matches the `${CFW_RENDER_SKILLS_DIR:?...}` form, sub-skill lines
   match `"$SKILL_DIR/.hub/<dep>"`, and `scripts/check-skills-portability.sh --skills-dir
   <scratch>` exits 0.
2. **New `test/run-tests.sh` static-guard case** (real `skills/` dir, see §2 above) — this is
   the one the Dozer test gate actually runs on every build, and the one that would have
   caught today's bug immediately had it existed.
3. **Checksum gate still passes**: after regenerating the real bundle,
   `scripts/verify-skills-bundle.sh` (no args = full sweep) must exit 0 — proves the rewrite
   didn't desync `index.json`'s `fileHashes` from what's on disk (it can't, since hashing runs
   after the rewrite in the same script, but this is the cheap end-to-end confirmation).
4. **Manual spot-check** of one rewritten recipe's Step-0 block (`p-reels-faceless`, since it
   has the most variables — `SKILL_DIR`, `BROLL_SYNC_DIR`, `TYPING_UI_DIR`, `PREMIUM_DIR`) by
   eye after the real sync: confirm every `*_DIR` assignment now reads as a plain
   `"$SKILL_DIR/.hub/<dep>"` or the `${CFW_RENDER_SKILLS_DIR:?}/<recipe>` form, no `find`, no
   `$HOME/.claude`/`$HOME/.hermes` left anywhere in that recipe's closure.
5. **Full `pnpm test`** (`test/run-tests.sh`) must stay green — the new case is additive, not a
   replacement for the existing 20-ish cases (fan-out, heartbeat, orphan-grace, preflight,
   etc.), none of which this change touches.

No live render smoke-test against the real worker is planned (fleet is
`render_fleet_enabled=false` per `docs/PACKAGING-DESIGN.md`, and standing up ffmpeg/hyperframes
/ a live order to exercise an actual recipe end-to-end is far outside this ticket's bundle-
resolution scope) — the acceptance bar per the ticket is the static gate existing and passing,
which is what prevents recurrence.
