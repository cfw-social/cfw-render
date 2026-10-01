VERDICT: PASS

## What I checked

1. **Diagnosis matches reality.** Ran `test/run-tests.sh` on this worktree before
   trusting the design doc's claim — confirmed the design's root-cause analysis is
   consistent with the code: `cr_heartbeat_stop` (`bin/cfw-render-lib.sh:317-322`
   on develop) only runs after `wait "$director_pid"` returns in
   `spawn_director`, but the Director calls `complete_render_order`/
   `block_render_order` synchronously from inside `cfw-render-report.sh`, well
   before its process tree exits — a real multi-second window where the pulse
   can land on an already-terminal order.

2. **Implementation matches the design doc exactly.**
   - `bin/cfw-render.sh:246-251` — writes `$order_dir/.heartbeat.pid` right
     after `cr_heartbeat_start`, guarded by `[[ -n "$heartbeat_pid" ]]`. The
     existing post-`wait` `cr_heartbeat_stop "$heartbeat_pid"` backstop
     (line 322) is untouched, exactly as the design specifies (crash/watchdog/
     orphan-late paths still need it).
   - `bin/cfw-render-lib.sh:546-551` — `cr_heartbeat_stop_if_pending` matches
     the design's spec verbatim: reads+removes the relative `.heartbeat.pid`,
     delegates to `cr_heartbeat_stop`, no-op if the file doesn't exist.
   - `bin/cfw-render-report.sh:158,191` — called immediately before
     `complete_render_order` and `block_render_order` respectively, not at the
     top of each branch — matches the design's placement rationale (let the
     pulse keep firing through upload work, stop it right before the
     terminal call).
   - CWD correctness verified: `cfw-render.sh:271` (`cd "$order_dir"`) is the
     Director subshell's CWD, and `cfw-render-report.sh` sources
     `cfw-render-lib.sh` and runs inside that same tree — so the relative
     `.heartbeat.pid` lookup in `cr_heartbeat_stop_if_pending` resolves
     correctly, including for the CFW-286 backgrounded-straggler path (same
     fork, same CWD) the design calls out explicitly.

3. **Cross-process signaling is sound despite being called from a different
   process than the one that forked the heartbeat loop.** `cr_kill_tree` uses
   `pgrep -P` + `kill -sig`, neither of which requires a parent-child
   relationship — only same-user permission, which holds here. The `wait
   "$pid"` inside `cr_heartbeat_stop` is a no-op when called cross-process
   (not a child of that shell, silently discarded via `2>/dev/null`), so the
   fix's real guarantee is "signal sent before the terminal RPC fires," not
   "loop confirmed dead" — the design's own "Residual theoretical race"
   section already acknowledges and scopes this correctly (signal-delivery
   latency, not the original multi-second window).

4. **Empirically verified, not just read.** Ran the full suite 6 times
   (1 initial + 5 more in a loop, per the design's own test plan item 2,
   which correctly insists a single green run isn't proof for a
   timing-dependent bug): **72 PASS / 0 FAIL every single time**, including
   Case 4d. Case 4 (watchdog), Case 4a/4b (orphan timing), and the upload
   cases (multipart/presign) all still pass — no regression in any path the
   design flagged as at-risk from moving the stop point earlier.
   (Case 4a, which the design predicted might still flake, was in fact clean
   across all 6 runs — a stricter outcome than the design's own prediction,
   not a contradiction of it.)

5. **Scope discipline.** No test files touched, no unrelated changes. The
   `test/run-tests.sh:522` backtick-logging cosmetic bug and Case 4a flake
   risk are both correctly called out as out-of-scope rather than silently
   ignored.

## Minor note (non-blocking)

The implementation changes to `bin/cfw-render-lib.sh`, `bin/cfw-render-report.sh`,
and `bin/cfw-render.sh` are present in the worktree but **uncommitted** — only
`DOZER-DESIGN-CFW-315.md` (`be2c5cc`) is committed on this branch so far. Worth
a build-pass commit before this merges, but doesn't affect correctness of what's
being judged here.

## Conclusion

The fix closes the actual race (stop-before-report instead of stop-after-the-
whole-tree-exits), lands exactly where the design doc said it would, and is
confirmed green and non-flaky by direct repro — not just by reading the diff.
Satisfies the spec.
