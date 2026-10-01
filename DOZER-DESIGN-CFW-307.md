# DOZER-DESIGN-CFW-307 — [CARRIER] Land dozer/CFW-297 (73/74 pass, verify CFW-291+CFW-292 coexist)

## Why this is a CARRIER, and why it exists at all

`dozer/CFW-297` already did its job: it's a CARRIER that landed `dozer/CFW-291`
(resolved worker PATH + headless `claude` probe) on top of `dozer/CFW-292`
(kill-tree fix) via commit replay, then a FIX pass (`bcb5fc0`) ran the full
suite and got **73/74 PASS** — the one failure (Case Q4's first sub-case) is a
pre-existing CFW-291 test-fixture bug (`env -i` can't resolve `bash` for the
fake claude's shebang when the test bypasses `cr_resolve_worker_path`'s
fallback dirs), root-caused, reproduced against a pristine CFW-291 checkout in
isolation, and explicitly scoped out of that carrier's job (fail-fast: "a
carrier that starts editing the carried code stops being a carrier").

CFW-297 never got to actually merge into `develop`, though. While it did its
verification work, `develop` moved twice more: `dozer/CFW-286` (Director
background-work handling — `cr_kill_tree`-adjacent reaping, new
`outcome=orphaned`) and `cfw-fanout-native`/CFW-299 (native-Claude fan-out
routing) both merged in. CFW-297's own branch is based on `4c17f3c` (right
after CFW-289), so landing it now means rebasing/merging across two more
branches' worth of changes to the *same* handful of files — and CFW-297 hit
`releases=3/3 EXHAUSTED` on that rebase before it could finish. Hence CFW-307:
a fresh carrier, fresh release budget, whose only job is to actually get
CFW-297's content onto current `develop`.

**Non-negotiable constraint (same one CFW-297 inherited from CFW-292):** every
fix already on `develop` — CFW-292's `cr_kill_tree`, CFW-286's background-work
reaping, CFW-299's native fan-out routing — must survive the landing
untouched. This carrier adds CFW-291's content on top; it does not re-derive
or revert any of it.

## What I verified before designing this

- `git merge-base dozer/CFW-297 develop` → `4c17f3c` (right after CFW-289).
  `develop` has 5 commits CFW-297 lacks: CFW-286's design/wip/merge (`3353dd9`,
  `e7baaec`, `75ab76c`) and CFW-299's fix/merge (`5ca407c`, `005fef0`).
- **File-region overlap check.** CFW-297 (i.e. CFW-291's replayed content)
  touches: `bin/cfw-render-lib.sh`, `README.md`, `docs/deploy.md`,
  `install/install.sh`, `install/cfw-render.service`,
  `install/com.cfw.render.plist`, `install/byoa-installer-notes.md`,
  `test/run-tests.sh`, `test/fake-claude-env-dependent.sh`. CFW-286 and
  CFW-299 together touch `bin/cfw-render-lib.sh`, `bin/cfw-render-subagent.sh`,
  `bin/cfw-render.sh`, `config/cfw-render.env.example`,
  `lib/director-prompt.md`, `README.md`, `docs/deploy.md`,
  `test/run-tests.sh`. The overlap set is `bin/cfw-render-lib.sh`,
  `README.md`, `docs/deploy.md`, `test/run-tests.sh`.
- **Read-only merge simulation** (`git merge-tree --write-tree
  --merge-base=4c17f3c dozer/CFW-297 develop`, Git 2.50, no working-tree/index
  side effects) resolved with exactly **one conflict: `README.md`**.
  `bin/cfw-render-lib.sh`, `docs/deploy.md`, and `test/run-tests.sh` all
  auto-merged clean.
- **Why the code files auto-merge clean, confirmed by direct diff inspection,
  not just trusted from the conflict-free result:**
  - `bin/cfw-render-lib.sh`: CFW-292's `cr_kill_tree` sits at the
    `cr_heartbeat_start`/`cr_heartbeat_stop` region (~line 468-527, already a
    develop-side no-op for this merge since it predates CFW-297's base).
    CFW-299 adds `cr_is_native_claude_model` and `claude_fanout_run`
    immediately after `claude_ollama_failover` (~line 577+), disjoint from
    both. CFW-291's `cr_resolve_worker_path`/`cr_probe_claude_headless` land
    after `_CR_REQUIRED_BINS`, before `cr_preflight_hint()` (~line 691+,
    confirmed in CFW-297's own design doc). Three disjoint insertion points,
    no shared line ranges, no duplicate function names across any of them.
  - `test/run-tests.sh`: CFW-299 appends "Case F: fan-out routes a native
    Claude alias..." right before the final `PASS/FAILURES` summary block.
    CFW-291's Q1-Q7 (per CFW-297's design doc) append after Case P, before
    `=== Lint ===`. Different anchor points, no overlap.
  - `docs/deploy.md`: both sides add independent prose sections; `git
    merge-tree` confirms no line-range collision.
  - `README.md`: **one real conflict**, and it's purely textual/prose — see
    below.
- **The `README.md` conflict, read directly (`git cat-file -p` on all three
  merge-tree blob stages):** all three versions share one base sentence in
  the testing-coverage section: *"...watchdog timeout → block with a
  time-budget reason, empty queue, and tick-lock exclusion."* CFW-286's side
  edits it in place (*"...reason (and, per CFW-286, that a background process
  it spawned is reaped too...)..."*) and appends a new sentence describing its
  own `outcome=orphaned`/`outcome=complete` coverage. CFW-297's side leaves
  the base sentence alone and appends a different new sentence describing
  CFW-291's `cr_resolve_worker_path`/`cr_probe_claude_headless`/install.sh
  coverage. **These are two independent, purely-additive doc edits to the
  same paragraph — not a substantive disagreement.** No code, no test
  assertion, nothing executable is in this hunk.

## Approach

1. **Merge `dozer/CFW-297` into this worktree's branch (`dozer/CFW-307`,
   currently at `develop` tip `005fef0`).** Use a real `git merge
   dozer/CFW-297` (not a replay, not a rebase) — `develop` has moved forward
   from two other landed branches since CFW-297 did its work, so replaying
   CFW-297's own commits verbatim onto `dozer/CFW-307` would fight the same
   file regions CFW-286/CFW-299 already touch; a merge is the correct
   operation here (unlike CFW-297's own case, where CFW-291 was replayed
   because the Dev-Director's crash-recovery had already put it there before
   design even started — no equivalent has happened for CFW-297 itself).
2. **Resolve the one `README.md` conflict by hand, keeping both additions.**
   Take CFW-286's version of the base sentence (the parenthetical about
   reaping the spawned background process) as the line text, then keep
   *both* "Also covers..." paragraphs — CFW-286's `outcome=orphaned` blurb
   and CFW-297/291's `cr_resolve_worker_path`/`cr_probe_claude_headless`/
   install.sh blurb, in either order. This is additive prose merging, not a
   design decision — nothing to adjudicate.
3. **No other manual resolution expected.** `bin/cfw-render-lib.sh`,
   `docs/deploy.md`, and `test/run-tests.sh` should auto-merge with zero
   conflict markers per the simulation above — the FIX pass should still
   run `git diff --check` / grep for `<<<<<<<` across the whole tree after
   the merge to catch anything the simulation missed (e.g. if any of those
   branches were force-pushed/amended since this design was written).
4. **Run the full suite against the merged tree**, exactly as CFW-297's own
   FIX pass did: `./test/run-tests.sh` (includes the trailing
   `scripts/lint.sh` invocation). Compare against the union of what's
   already known:
   - All cases CFW-297's FIX pass already verified (73 PASS, Q4 sub-case
     FAIL) should still PASS/FAIL the same way — the code regions are
     disjoint from CFW-286/CFW-299, so this merge shouldn't change Q4's
     outcome in either direction.
   - CFW-286's and CFW-299's own cases (already passing on `develop` before
     this merge) should still PASS — CFW-291's additions don't touch their
     code paths either.
   - New total case count = old `develop` count + CFW-291's 7 Q-cases. Get
     the real number from this run; don't assume.
   - Wall clock should stay well inside the 900s test-gate budget — none of
     the three merged features spawn new long-running or real-render paths.
5. **Orphan-process check after the run** (`pgrep -fl cfw-render` /
   equivalent). This merge is unusually process-management-dense for one
   file: CFW-292's `cr_kill_tree` (watchdog), CFW-286's background-work
   reaping, CFW-299's fan-out subprocess spawning (`claude_fanout_run`), and
   CFW-291's headless probe (`cr_probe_claude_headless`, itself a subprocess
   call under `env -i`) all now coexist in `bin/cfw-render-lib.sh`. None of
   them call each other, per the disjoint-region analysis above, but this is
   exactly the kind of interaction a purely textual merge can't catch —
   worth the explicit eyeball CFW-292's own review already established as
   precedent for this file.
6. **Serial-merge `dozer/CFW-307` into `develop`** once the suite is green
   (or green-modulo-Q4, see Edge cases below), same as every prior landing
   in this chain (`4c17f3c`, `1bd7857`, `75ab76c`, `005fef0`).
7. **No new implementation.** Like CFW-297 before it, this carrier's job is
   landing + verification, not new code. If the full-tree merge surfaces an
   actual *new* bug (something that only appears in the merged combination,
   not attributable to any one branch alone), that's a real finding to
   report — but the fix belongs in a follow-up issue, not inline here,
   unless it's a trivial merge-conflict resolution itself (like the
   README.md hunk).

## Files touched by the BUILD/FIX pass

- `README.md` — manual conflict resolution (prose only, see above).
- Everything else CFW-297 carries (`bin/cfw-render-lib.sh`, `docs/deploy.md`,
  `install/install.sh`, `install/cfw-render.service`,
  `install/com.cfw.render.plist`, `install/byoa-installer-notes.md`,
  `test/run-tests.sh`, `test/fake-claude-env-dependent.sh`,
  `DOZER-DESIGN-CFW-291.md`, `DOZER-DESIGN-CFW-297.md`,
  `DOZER-FIX-CFW-297.md`) arrives via the merge commit itself — **no manual
  edits expected**, per the auto-merge simulation.
- This design doc, `DOZER-DESIGN-CFW-307.md`, at the worktree root (this
  commit).
- Whatever process artifact the FIX pass produces (`DOZER-FIX-CFW-307.md` or
  equivalent) documenting the merge + test results.

## Edge cases

- **The Q4 pre-existing failure (73/74) — carry-forward, don't re-litigate,
  don't silently fix either.** CFW-297's FIX pass already root-caused this as
  a CFW-291 test-fixture bug, unrelated to any merge, and explicitly scoped
  fixing it out of that carrier. The dev-lane doctrine's fail-fast rule
  ("Red = not done... do not paper over a failure") is in real tension with
  "don't scope-creep a carrier into fixing carried code" — CFW-297 already
  resolved that tension once by documenting the failure in detail, proving
  it pre-existing and production-harmless, and recommending a follow-up
  issue. **This carrier should follow the same precedent rather than
  re-deciding it**: confirm Q4 fails the *same way* post-merge (same root
  cause, same isolated blast radius), and land with that one documented
  exception rather than either (a) blocking indefinitely on a bug this
  carrier didn't introduce and isn't scoped to fix, or (b) quietly patching
  the test fixture as a drive-by. If the FIX pass would rather escalate this
  tension instead of assuming the precedent applies, that's the judgment
  call to send to the Dev-Director — but it shouldn't silently do neither.
  Verify (don't assume) a follow-up Linear issue against CFW-291's Q4
  fixture actually exists yet; CFW-297's disposition only *recommended* one.
- **Merge direction sanity.** `git merge dozer/CFW-297` must be run from
  `dozer/CFW-307` (currently `develop` tip), merging CFW-297 *in* — not the
  reverse. Getting this backwards would fast-forward-losing-nothing in the
  best case or silently drop CFW-286/CFW-299 in the worst.
- **If the auto-merge simulation is stale.** This design's conflict
  prediction is only as good as `dozer/CFW-297`'s and `develop`'s tips at
  design time (`bcb5fc0` / `005fef0`). If either moved before the BUILD pass
  runs, re-run `git merge-tree --write-tree --merge-base=4c17f3c
  dozer/CFW-297 develop` fresh rather than trusting this doc's specific
  conflict list.
- **Release-cap bookkeeping.** CFW-297 stays however Linear reflects an
  EXHAUSTED-but-superseded carrier once CFW-307 actually lands its content —
  this design doesn't touch Linear state; that's the FIX/REVIEW pass's or
  the Director's job per `~/Code/dozers/directors/LINEAR.md`. Point anyone
  auditing the log at this merge commit (which will reference both
  `dozer/CFW-297` and `dozer/CFW-307`) rather than expecting CFW-297's own
  branch to show a landing.
- **No DB schema involved** — this is all bash/installer/test-harness code;
  the migration gate is not applicable.
- **Leave `develop` as the landing point.** Same as CFW-297's own design:
  this doesn't promote `develop` → `main`; that's the normal
  `dozer:merged-develop` → review → `director:merged-main` flow.

## How this gets tested

1. `git merge dozer/CFW-297` into `dozer/CFW-307`, resolve the single
   `README.md` conflict as described, confirm `grep -r '<<<<<<<'` across the
   tree comes back empty.
2. Full `test/run-tests.sh` run against the merged tree — expect the union of
   CFW-297's already-verified 73 PASS + Q4's known pre-existing FAIL, plus
   CFW-286's and CFW-299's cases (already passing on `develop`) continuing to
   pass. Get the real fresh count; don't assume arithmetic.
3. `scripts/lint.sh` (tail of `run-tests.sh`) clean.
4. Orphan-process check after the run — `pgrep -fl cfw-render` empty,
   specifically because this merge concentrates four different branches'
   process-lifecycle code into one file (`bin/cfw-render-lib.sh`).
5. Spot-check `bin/cfw-render-lib.sh` by eye for the three insertion points
   (`cr_kill_tree`, `cr_is_native_claude_model`/`claude_fanout_run`,
   `cr_resolve_worker_path`/`cr_probe_claude_headless`) landing disjointly
   with no duplicate function definitions — the automated suite exercises
   them but a direct grep is cheap insurance given how dense this file now
   is.
6. Serial-merge `dozer/CFW-307` into `develop` once green (modulo the
   documented Q4 exception), matching this repo's established merge-commit
   convention (`merge dozer/<id> into develop — #<id> ...`).
