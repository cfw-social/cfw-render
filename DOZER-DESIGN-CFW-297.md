# DOZER-DESIGN-CFW-297 — [CARRIER] Land dozer/CFW-291 without reverting CFW-292

> **Amendment (attempt 2, architect pass):** between the first architect pass
> and this one, the Dev-Director's own crash-recovery step already replayed
> both of `dozer/CFW-291`'s commits directly onto this branch — `44fc59e` →
> `3bc7a69` ("design(CFW-291)") and `54b0a80` → `d230063` ("wip(CFW-291):
> preserve uncommitted crew output"), same messages and tree content, new
> hashes because they were committed as regular commits on `dozer/CFW-297`
> rather than via `git merge dozer/CFW-291`. **The landing already happened.**
> The "Approach" and "Files touched" sections below are updated to match:
> there is no merge left to perform, only verification. The original
> verification notes (file-region analysis, `merge-tree` check) are kept
> below because they explain *why* the replay was safe, and are now
> confirmed by direct inspection of the resulting tree (see "What I
> verified" — updated).

## Why this is a CARRIER issue, not a normal fix

`dozer/CFW-291` (resolved worker PATH + headless `claude` probe + first Linux
test coverage, 497 lines) got stuck: it was `releases=3/3 EXHAUSTED`, and its
last automated pass died mid-rebase because `develop` had advanced out from
under it — specifically because **this branch's own promote** (`1bd7857`,
merging `dozer/CFW-292`'s kill-tree fix) is what moved `develop` forward. The
Dev-Director preserved CFW-291's uncommitted work verbatim (`GSAI-157`
data-loss mode) and, in this branch's case, went further and replayed both of
CFW-291's commits directly onto `dozer/CFW-297` (`3bc7a69`, `d230063`) — so
the code is now physically present on this branch, sitting on top of develop
which already has CFW-292. What's still missing is the thing a normal
design→fix→review pipeline would have done: **verification that the two
branches' changes coexist correctly** (no regression of CFW-292's kill-tree
fix, CFW-291's new tests actually pass against current `develop`). Because
CFW-291 has no releases left to run that verification itself, this CARRIER
issue's remaining job is to do that verification pass, not to redo a landing
that already happened.

**Non-negotiable constraint:** `develop` currently has CFW-292's kill-tree
fix (`cr_kill_tree`, used by the watchdog and `cr_heartbeat_stop` in
`bin/cfw-render-lib.sh` / `bin/cfw-render.sh`) at `1bd7857`. That fix must
survive the landing untouched — CFW-297 adds CFW-291 on top of it, it does
not re-derive or revert it.

## What I verified before designing this

**Updated for attempt 2 — direct inspection of the current tree (`dozer/CFW-297`
at `d230063`), superseding the original merge-tree prediction below:**

- `git diff dozer/CFW-291 HEAD --stat` shows the only differences are files
  CFW-291 predates (`DOZER-DESIGN-CFW-289/292/297.md`, `DOZER-REVIEW-CFW-289/292.md`,
  and CFW-292's own code changes) — i.e. HEAD is exactly "CFW-291's tree plus
  everything that landed on develop after CFW-291 branched." No leftover diff
  in the files CFW-291 itself touches.
- `grep -n "cr_kill_tree\|cr_resolve_worker_path\|cr_probe_claude_headless"
  bin/cfw-render-lib.sh` on HEAD confirms both land in the same file at the
  disjoint locations predicted below: `cr_kill_tree` at lines 468–527 (CFW-292,
  used by the watchdog / `cr_heartbeat_stop`), `cr_resolve_worker_path` /
  `cr_probe_claude_headless` at lines 691–751+ (CFW-291). No overlap, no
  merge-marker residue, no duplicate function definitions.
- `test/run-tests.sh` on HEAD has `Case Q1` at line 754 through `Case Q7` at
  line 986 — CFW-291's 7 new cases are present and appended after the
  pre-existing case list, as designed.
- `git status --short` is clean — nothing uncommitted, nothing to lose.
- **Net effect:** the file-region and merge-cleanliness analysis from attempt
  1 (kept below) was correct, and the replay committed by the Dev-Director
  produced exactly the tree that analysis predicted a merge would produce.
  There is no residual merge step for the FIX pass to run.

<details>
<summary>Original attempt-1 analysis (git merge-tree prediction, now confirmed by direct inspection above)</summary>

- `dozer/CFW-291` branches from `937e4e1`, the exact commit `develop` was at
  right before CFW-292 landed (`git merge-base dozer/CFW-291 develop` →
  `937e4e1`). So the only commits `develop` has that CFW-291 lacks are
  CFW-292's four (`1f8e4d0` design → `990372d` fix → `a892488` review →
  `1bd7857` merge).
- CFW-291's two commits (`44fc59e` design-doc-only, `54b0a80` the preserved
  497-line implementation) touch: `bin/cfw-render-lib.sh` (+89),
  `install/install.sh` (+25), `install/cfw-render.service` (+11),
  `install/com.cfw.render.plist` (+5), `docs/deploy.md`, `README.md`,
  `install/byoa-installer-notes.md` (docs), `test/run-tests.sh` (+312, new
  Cases Q1–Q7), `test/fake-claude-env-dependent.sh` (new fixture, +14).
- CFW-292 touches only `bin/cfw-render-lib.sh` and `bin/cfw-render.sh`.
  **`bin/cfw-render-lib.sh` is the one file both branches edit**, but at
  disjoint locations: CFW-292 adds `cr_kill_tree()` right after line ~464
  (near `cr_heartbeat_start`/`cr_heartbeat_stop`) and changes
  `cr_heartbeat_stop`'s body; CFW-291 adds `cr_resolve_worker_path()` and
  `cr_probe_claude_headless()` after line ~666, right after the
  `_CR_REQUIRED_BINS` array and before `cr_preflight_hint()`. No line
  ranges overlap.
- CFW-292 does **not** touch `test/run-tests.sh` at all — its fix lives
  entirely in `bin/cfw-render-lib.sh`/`bin/cfw-render.sh`; the hang it fixed
  was a pre-existing bug in code the existing (pre-CFW-291) test suite
  already exercised, not new test cases. CFW-291's Q1–Q7 append to the end
  of the case list (after `Case P`, before the `=== Lint ===` section) with
  no shared context lines.
- Read-only confirmation: `git merge-tree --write-tree
  --merge-base=937e4e1 dozer/CFW-291 develop` (Git 2.50, no working-tree or
  index side effects) resolved to a single tree with **no conflict output**.
  This is strong evidence the merge is textually clean; the FIX pass should
  still do a real `git merge` (not trust this alone) since `merge-tree`
  doesn't run hooks, tests, or catch semantic conflicts.
- `test/run-tests.sh` on the current `develop` (i.e. the branch this
  worktree is on) has **zero** existing calls into `install/install.sh`
  before CFW-291 — Q6/Q7 are the first. So CFW-291's new preflight gate in
  `install.sh` (`cr_probe_claude_headless`, which now runs — and can now
  `exit 1` — before anything is copied) has no other pre-existing test case
  to regress.
- `test/fake-claude.sh`, `test/fake-claude-env-dependent.sh`,
  `test/fake-director.sh`, and the harness vars `$TEST_DIR`/`$REPO_DIR`/
  `$FAKE_BIN` that Q1–Q7 rely on all already exist / are already defined at
  the top of `test/run-tests.sh` — no missing fixture.
- CFW-291's implementation commit (`54b0a80`) reads as **complete**, not
  partial: every new function (`cr_resolve_worker_path`,
  `cr_probe_claude_headless`) is fully bodied with header comments matching
  the design doc, `install.sh`'s new gate has both the resolve step and the
  abort-with-actionable-message path, both templates (`plist`, `service`)
  got the `{{WORKER_PATH}}` placeholder consistently, and the 7 new test
  cases assert both the happy path and the failure/edge paths (empty
  output, stub-Director skip, dedup, fallback preservation, XML
  well-formedness, env-var ordering vs `EnvironmentFile=`). There is no
  `DOZER-FIX-CFW-291.md` or `DOZER-REVIEW-CFW-291.md` — the branch never
  reached those pipeline stages — so this carrier is also standing in for
  the missing fix/review structure, not just the merge.

</details>

## Approach

**Updated for attempt 2:** step 1 below (the merge) is **already done** — the
Dev-Director's crash-recovery replay (`3bc7a69`, `d230063`) put CFW-291's
tree directly on `dozer/CFW-297`, on top of develop's CFW-292/CFW-289. It is
kept here, struck through in spirit, only so the FIX pass understands why
there is no merge commit in this branch's log even though the task title
says "merge develop in": the content landed by commit-replay instead of
`git merge`, which is equivalent in tree content (confirmed above) and
still preserves `54b0a80`'s "preserved verbatim" history intact (it's an
ancestor-equivalent commit, not a rewrite) — it just isn't *labeled* as a
merge commit. The FIX pass's real job is now only step 2.

1. ~~**One merge, not a rebase.** From `develop`, run `git merge
   dozer/CFW-291`.~~ **Not needed — do not run this.** HEAD already contains
   CFW-291's tree (verified above via `git diff dozer/CFW-291 HEAD --stat`
   and the `cr_kill_tree`/`cr_resolve_worker_path` grep). Running `git merge
   dozer/CFW-291` now would attempt to merge an already-contained ancestor
   history into HEAD; since the trees match it should be a content no-op,
   but it adds a pointless merge commit and risks Git treating `54b0a80` vs
   its replayed twin `d230063` as unrelated changes if any metadata differs.
   **If the FIX pass needs the commit history to visibly say "CFW-291
   landed,"** the correct move is a `git merge --strategy=ours
   dozer/CFW-291` style no-op merge (records the ancestry link without
   touching the already-correct tree) or simply noting the replay commits'
   hashes in the eventual `dozer:merged-develop` commit/PR body — pick
   whichever the FIX pass finds Linear/the Director actually needs; do not
   spend effort re-merging content that is already there.

2. **Run the full suite now**, exactly as CFW-292's review did
   (`a892488` — "suite completes in ~2min with 0 orphans"), before trusting
   the merge:
   - `./test/run-tests.sh` (or whatever the repo's documented entry point
     is — confirm against `README.md`'s test section, already updated by
     CFW-291's own diff to describe the new Q-cases).
   - Confirm: (a) all pre-existing cases still PASS, including the
     watchdog/orphan cases CFW-292 fixed (no regression from CFW-291
     touching an adjacent function in the same file); (b) all 7 new Q1–Q7
     cases PASS; (c) the suite finishes well inside the 900s test-gate
     budget (CFW-292's whole point) — CFW-291 adds 7 new cases, none of
     which spawn a real long-running render or touch the watchdog path, so
     there's no expected new hang surface, but confirm wall-clock time
     directly rather than assume it; (d) the trailing `scripts/lint.sh`
     invocation at the end of `run-tests.sh` still passes.
   - Watch specifically for orphaned processes after the run (CFW-292's
     regression class) — Q6/Q7 background `install.sh` itself
     (`... >"$q6_home/install.log" 2>&1` / a backgrounded `&` for Q7)
     and could theoretically leak a subprocess if `install.sh`'s new
     `cr_probe_claude_headless` step hangs; it shouldn't (it runs a fake
     `claude --version` under `env -i` — no long-lived process), but this
     is a new code path worth a specific eyeball rather than assuming
     CFW-292's fix covers it.

3. **No code changes.** This carrier's job is verification, not new
   implementation — CFW-291's 497 lines are taken as-is (they're already on
   the branch). If the test run surfaces an actual bug, that is out of scope
   for CFW-297 and should be spun out as its own issue rather than patched
   inline here (fail-fast: a carrier that starts editing the carried code
   stops being a carrier).

4. **Leave `develop` as the landing point.** This design does not promote
   `develop` → `main`; that stays the Dev-Director's call per the normal
   `dozer:merged-develop` → review → `director:merged-main` flow.

## Files touched by the FIX pass

**Updated for attempt 2: none, expected.** Every file CFW-291 touches
(`bin/cfw-render-lib.sh`, `install/install.sh`, `install/cfw-render.service`,
`install/com.cfw.render.plist`, `docs/deploy.md`, `README.md`,
`install/byoa-installer-notes.md`, `test/run-tests.sh`,
`test/fake-claude-env-dependent.sh`) plus `DOZER-DESIGN-CFW-291.md` are
already present on `dozer/CFW-297` as of `3bc7a69`/`d230063`. The FIX pass
runs the test suite (§Approach step 2) and, if everything is green, produces
no code diff at all — only whatever process artifact records the
verification (a `DOZER-FIX-CFW-297.md` noting "verified, no changes needed,"
or directly flipping the issue to `dozer:merged-develop` / handing to
review, per whatever this repo's pipeline expects when a carrier's checks
pass with zero code changes). If the suite finds a real regression, that's a
finding to report per "No code changes" above, not a diff to land here.
- This design doc, `DOZER-DESIGN-CFW-297.md`, at the worktree root (this
  commit, amended).

## Edge cases

- **Merge direction sanity:** no longer applicable — there is no merge to
  direct; the tree is already assembled (confirmed above via direct
  inspection, which supersedes the original `merge-tree` prediction).
- **`install.sh`'s new hard gate changes behavior for every caller,
  including future test cases** — this is already true on HEAD today, not
  something the FIX pass introduces. Any test or operator invoking
  `install/install.sh` will hit the `cr_probe_claude_headless` abort path if
  their fake/real `claude` doesn't survive `env -i`. Confirmed there are
  zero other callers in the test suite to break; flag this in whatever
  commit/PR body eventually documents the landing, so a future PATH-related
  install failure is recognized as "the CFW-291 gate doing its job," not a
  mystery regression.
- **`DOZER-DESIGN-CFW-291.md` presence:** already landed fresh via the
  replay (`3bc7a69`) — confirm it reads correctly (it's a pure add, no
  merge-marker artifacts possible since there was no merge).
- **Release-cap bookkeeping:** CFW-291 stays `EXHAUSTED`/however Linear
  reflects a carried-in branch — this design doesn't touch Linear state;
  that's the FIX/REVIEW pass's or the Director's job per
  `~/Code/dozers/directors/LINEAR.md`.
- **No merge commit in the log referencing `#CFW-291` by hash-pair.** Since
  the landing was a commit replay rather than `git merge`, this branch's
  history won't show a "merge dozer/CFW-291 into develop" commit the way
  CFW-289/CFW-292 do. If the Director or a human later audits the log
  expecting that pattern, point them at `3bc7a69`/`d230063` and this design
  doc's amendment note rather than treating the missing merge commit as a
  sign the landing didn't happen.
- **If the suite is slow or hangs:** given CFW-292 is already in place, a
  hang would indicate CFW-291's own code has a problem (e.g.
  `cr_probe_claude_headless`'s `env -i claude --version` blocking on stdin,
  or the backgrounded `install.sh &` in Q7 not being reaped) — not a
  reappearance of the Case-2e/Case-P bug CFW-292 already fixed. Treat any
  new hang as a CFW-291 defect to report, not something to patch under this
  carrier (see "No code changes" above) — kill the suite, capture which
  case it stalled on, and hand that back rather than silently extending the
  gate budget or skipping the case.

## How this gets tested

1. ~~`git merge dozer/CFW-291` into `develop`~~ — not needed; already landed
   on HEAD (verified above by direct tree inspection, superseding the
   original `merge-tree` prediction).
2. Full `test/run-tests.sh` run against HEAD as-is — all pre-existing
   cases PASS (proves CFW-292's fix is intact), all new Q1–Q7 cases PASS
   (proves CFW-291 works against current `develop`), suite completes well
   under the 900s gate with no orphaned processes (proves the two branches'
   process-management code doesn't interact badly).
3. `scripts/lint.sh` (already invoked at the tail of `run-tests.sh`) clean.
4. Spot-check the rendered templates once by hand if convenient: run
   `install/install.sh --mode byoa ...` in a scratch prefix and confirm
   `com.cfw.render.plist` and (via `CFW_RENDER_TEST_OS=Linux`)
   `cfw-render.service` both get a real, non-placeholder `PATH` — this is
   exactly what Q6/Q7 already automate, so it's a redundant human sanity
   check, not a new requirement.
