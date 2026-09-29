# DOZER-DESIGN-CFW-297 — [CARRIER] Land dozer/CFW-291 without reverting CFW-292

## Why this is a CARRIER issue, not a normal fix

`dozer/CFW-291` (resolved worker PATH + headless `claude` probe + first Linux
test coverage, 497 lines) is stuck: it is `releases=3/3 EXHAUSTED`, and its
last automated pass died mid-rebase because `develop` had advanced out from
under it — specifically because **this branch's own promote** (`1bd7857`,
merging `dozer/CFW-292`'s kill-tree fix) is what moved `develop` forward. The
Dev-Director preserved CFW-291's uncommitted work verbatim as commit
`54b0a80` rather than lose it (`GSAI-157` data-loss mode), but that means
CFW-291 has never been merged against, tested with, or reviewed alongside
CFW-292. Because CFW-291 has no releases left, it cannot fix itself — a
CARRIER issue does the landing instead.

**Non-negotiable constraint:** `develop` currently has CFW-292's kill-tree
fix (`cr_kill_tree`, used by the watchdog and `cr_heartbeat_stop` in
`bin/cfw-render-lib.sh` / `bin/cfw-render.sh`) at `1bd7857`. That fix must
survive the landing untouched — CFW-297 adds CFW-291 on top of it, it does
not re-derive or revert it.

## What I verified before designing this

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

## Approach

1. **One merge, not a rebase.** From `develop` (currently `1bd7857`), run
   `git merge dozer/CFW-291` directly. Do not rebase CFW-291 onto develop
   first — rebasing would rewrite `54b0a80`'s "preserved verbatim" commit,
   which is exactly the history GSAI-157/GSAI-183 want kept intact as
   evidence of what happened. A merge commit is also the pattern every prior
   landing in this log already uses ("merge dozer/CFW-XXX into develop —
   #CFW-XXX ...").
   - Because `git merge` performs its own three-way merge against the same
     merge-base (`937e4e1`) regardless of merge direction, this produces the
     identical result already confirmed conflict-free by `git merge-tree`
     above. No intermediate "update CFW-291 with develop" step is needed.
   - Expect the merge to apply cleanly with zero conflict markers. If Git
     reports a conflict anywhere, that contradicts this design's
     `merge-tree` check — stop and re-diff `bin/cfw-render-lib.sh` between
     the two branches before resolving anything by hand, since an unexpected
     conflict means my file-region analysis above missed something.
   - Merge commit message: `merge dozer/CFW-291 into develop — #CFW-291
     [ENG] resolved-binary worker PATH, headless claude probe, Linux
     coverage, tests — carried by #CFW-297 (CFW-291 releases exhausted;
     rebased-equivalent merge onto CFW-292's kill-tree fix, no revert)`.

2. **Run the full suite post-merge**, exactly as CFW-292's review did
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

3. **No code changes.** This carrier's job is the merge + verification, not
   new implementation — CFW-291's 497 lines are taken as-is. If the test run
   surfaces an actual bug, that is out of scope for CFW-297 and should be
   spun out as its own issue rather than patched inline here (fail-fast: a
   carrier that starts editing the carried code stops being a carrier).

4. **Leave `develop` as the landing point.** This design does not promote
   `develop` → `main`; that stays the Dev-Director's call per the normal
   `dozer:merged-develop` → review → `director:merged-main` flow.

## Files touched by the FIX pass

- No new files beyond what CFW-291 already introduced (it comes along with
  the merge commit).
- The merge commit itself, touching: `bin/cfw-render-lib.sh`,
  `install/install.sh`, `install/cfw-render.service`,
  `install/com.cfw.render.plist`, `docs/deploy.md`, `README.md`,
  `install/byoa-installer-notes.md`, `test/run-tests.sh`,
  `test/fake-claude-env-dependent.sh`, plus `DOZER-DESIGN-CFW-291.md`
  arriving as a new file (it doesn't exist on `develop` yet, only the design
  doc from `44fc59e`).
- This design doc, `DOZER-DESIGN-CFW-297.md`, at the worktree root (this
  commit only).

## Edge cases

- **Merge direction sanity:** confirmed above via `merge-tree` — do not
  re-litigate by trying `dozer/CFW-291`-into-`develop` vs
  `develop`-into-`dozer/CFW-291`; they are equivalent here since there's
  only one merge base and no intermediate divergent history to preserve
  differently.
- **`install.sh`'s new hard gate changes behavior for every caller,
  including future test cases** — after this lands, any test or operator
  invoking `install/install.sh` will hit the `cr_probe_claude_headless`
  abort path if their fake/real `claude` doesn't survive `env -i`. Confirmed
  today there are zero other callers in the test suite to break; flag this
  in the merge commit body so a future PATH-related install failure is
  recognized as "the new CFW-291 gate doing its job," not a mystery
  regression.
- **`DOZER-DESIGN-CFW-291.md` reappearing:** `develop` never had it (CFW-291
  branched before merging, and CFW-292 doesn't have it either), so the merge
  introduces it fresh — not a conflict, just confirm it lands readable (it's
  a pure add).
- **Release-cap bookkeeping:** CFW-291 stays `EXHAUSTED`/however Linear
  reflects a carried-in branch — this design doesn't touch Linear state;
  that's the FIX/REVIEW pass's or the Director's job per
  `~/Code/dozers/directors/LINEAR.md`, not something to encode in the merge
  commit beyond the reference already in its message.
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

1. `git merge dozer/CFW-291` into `develop`, zero manual conflict
   resolution expected (verified via `git merge-tree` above; if any conflict
   appears, that itself falsifies part of this design and should stop the
   pass rather than be resolved blind).
2. Full `test/run-tests.sh` run against the merged tree — all pre-existing
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
