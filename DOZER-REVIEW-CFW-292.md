VERDICT: PASS

## What I checked

1. **Diff matches design.** `bin/cfw-render-lib.sh` adds `cr_kill_tree <pid> [sig]`
   exactly as specified (recursive `pgrep -P` walk, kill children before parent),
   and `cr_heartbeat_stop` and the three watchdog call sites in `bin/cfw-render.sh`
   (spawn TERM, spawn KILL, normal-path cleanup TERM) were switched from bare
   `kill "$pid"` to `cr_kill_tree` as planned. No extra files touched, no scope
   creep.

2. **Root cause diagnosis re-verified against the actual test file**, not just
   taken on faith: `test/run-tests.sh:661` (`pf_run "$REPO_DIR/bin:$FAKE_BIN:$PATH"`,
   the second Case P call) has no `CASE_TIMEOUT_VIDEO`/`CASE_TIMEOUT_IMAGE` in
   scope, so `cfw-render.sh` falls back to the 3600s default
   (`CFW_RENDER_TIMEOUT_VIDEO`), confirming the design's claim about where the
   long sleep comes from. `pf_run`'s `pf_out="$( ... )"` is a real command
   substitution, so it can't return until every writer of the pipe closes — the
   design's "orphaned sleep holds a caller's pipe open" mechanism is correct.

3. **`cr_kill_tree` is sourced before it's used in a background context** —
   `cfw-render.sh:17` sources `cfw-render-lib.sh` before the watchdog subshell
   at line 280, so the function is available inside `( sleep …; cr_kill_tree … ) &`.
   Bottom-up recursion (kill descendants, then the pid itself) is the right order
   — it can't orphan a grandchild by killing the parent first.

4. **Ran the real suite three times** (`test/run-tests.sh`, unmodified, as the
   design's own test plan specifies) on a heavily loaded shared box:
   - Two runs timed out mid-`Lint` (shellcheck across 17 files) under CPU
     contention from unrelated concurrent processes on this machine — but by
     then **Case P had already fully passed**, including the exact assertion
     (`preflight: a fully-provisioned host still runs`, run-tests.sh:663-667)
     that never used to execute because the run hung before reaching it. That's
     the smoking gun: the hang is gone even under load.
   - A clean third run finished in ~2 min wall-clock, exit 0, **`PASS: 55  FAIL: 0`**
     — comfortably inside the 900s gate.
   - Checked for leaked processes after each run: my worktree's runs left
     **zero** new orphaned `sleep 3600`/`sleep 60`. (One pre-existing orphaned
     `sleep 3600` was present throughout, traced via `lsof -p` to a *different*,
     unrelated concurrent `crew.sh CFW-292` process running against the plain
     checkout at `~/initiatives/cfw/cfw-render`, not this worktree — noted for
     awareness, not a defect in this branch.)

## Judgment

Implementation matches the design 1:1, the root-cause reasoning holds up against
the actual test file, and a live end-to-end run confirms the fix: Case P's
previously-unreachable assertion now runs and passes, the full suite completes
well under the CI budget, and no new orphaned processes are created. The
bonus fix (watchdog's TERM/KILL now actually reaching a hung render's real
process, not just its subshell wrapper) is a correct and low-risk side benefit
of the same helper, not scope creep — it's the watchdog's stated job.

No issues found. Ship it.
