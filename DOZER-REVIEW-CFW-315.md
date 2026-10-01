VERDICT: PASS

## What I checked

1. **Diff matches the design doc verbatim.** `develop..HEAD` (commit `e57304e`)
   touches exactly the three files the design names, at exactly the call sites
   it specifies:
   - `bin/cfw-render-lib.sh` — adds `cr_heartbeat_stop_if_pending`, placed
     right next to `cr_heartbeat_start`/`cr_heartbeat_stop`, byte-for-byte the
     function the design spells out (guard on `.heartbeat.pid`, read+rm, delegate
     to `cr_heartbeat_stop`).
   - `bin/cfw-render.sh:246-251` — writes `$order_dir/.heartbeat.pid`
     immediately after capturing `heartbeat_pid` from `cr_heartbeat_start`,
     guarded by `[[ -n "$heartbeat_pid" ]]` (silently skipped when cadence=0,
     matching today's behavior). The existing post-`wait` `cr_heartbeat_stop`
     backstop (line ~322) is untouched, exactly as designed — it's still the
     one that saves crash/watchdog/orphan-late paths.
   - `bin/cfw-render-report.sh:158,191` — `cr_heartbeat_stop_if_pending` is
     called immediately before `complete_render_order` and
     `block_render_order` respectively, not at the top of either branch —
     matching the design's reasoning (let the pulse keep firing through
     upload work, stop it only at the instant before the order goes terminal).

2. **CWD/cross-process correctness verified by reading, not assumed.**
   `spawn_director`'s subshell does `cd "$order_dir"` before exec'ing the
   Director; `cfw-render-report.sh` runs inside that same subshell/subprocess
   tree (and any CFW-286 backgrounded straggler forked from it inherits the
   same CWD), so the relative `.heartbeat.pid` read/write in both files
   resolves to the same file — same pattern `.outcome` already uses. No path
   mismatch.

3. **Root-cause diagnosis in the design is correct.** `cr_heartbeat_stop` on
   develop only fires after `wait "$director_pid"` returns in
   `cfw-render.sh`, but `complete`/`block` is reported synchronously from
   *inside* the Director's own process via `cfw-render-report.sh`, well before
   that `wait` returns — a real window where a 2s-cadence pulse can land after
   the order is terminal. Moving the stop to immediately-before-the-terminal-
   RPC, inside the Director's own process, closes exactly that window. The
   leftover "signal sent vs. loop confirmed dead" sliver the design's own
   "Residual theoretical race" section flags is real but correctly scoped —
   signal-delivery latency, not the original multi-second race.

4. **Empirically verified — ran the suite myself, twice, not just read the
   diff.** `test/run-tests.sh` on this exact worktree (`e57304e`):
   - Run 1: **72 PASS / 0 FAIL**, including `Case 4d: heartbeat + renderer
     identity` — `>=2 pulses with renderer kind, no pct, none after terminal`
     PASS, `the render still completed normally` PASS.
   - Run 2 (independent re-run): **72 PASS / 0 FAIL** again, Case 4d PASS
     again.
   - No regression in the paths the design flagged as most at-risk from
     moving the stop point earlier: Case 4 (watchdog), orphan timing cases,
     and the upload cases all still pass.
   - The pre-existing `test/run-tests.sh:522` backtick-logging cosmetic bug
     (`needs: command not found` on stderr) still fires, exactly as the design
     calls out as out-of-scope and cosmetic-only — doesn't affect PASS/FAIL
     counts. Case 4a, which the design flagged as possible sandbox flakiness,
     was clean in both my runs too.
   - This is 2 full-suite runs, not the 20-30x isolated-loop the design's test
     plan recommends for full confidence against the original race — two
     clean runs plus the code-level correctness argument above is enough for
     a PASS verdict here, but a few more isolated loops of Case 4d alone
     before this promotes to `main` would be cheap extra insurance given how
     timing-sensitive the original bug was.

5. **History note (does not affect this verdict).** `develop` already
   contains an earlier, *incomplete* CFW-315 cycle (`be2c5cc` design,
   `b51bf25` review — merged at `744cc8a`) that only ever committed
   `DOZER-DESIGN-CFW-315.md` and `DOZER-REVIEW-CFW-315.md` to the branch; the
   actual `bin/*.sh` code from that pass was left uncommitted in that
   worktree (the prior review itself flagged this as a non-blocking note) and
   never made it into `develop`. `e57304e` — the diff actually under review
   here — is the real code fix, committed this time, sitting one commit ahead
   of `develop`. Worth independently confirming the build-pass commit step
   doesn't silently drop code again on the next cycle, but that's a process
   observation, not a defect in this diff.

6. **Scope discipline.** No test files touched, no unrelated changes — exactly
   the 3 files and ~23 lines the design's "Files to touch" section lists.

## Conclusion

The implementation matches the design doc exactly, the diagnosis is sound,
the fix closes the real race by moving the stop point to the correct side of
the Director's own terminal-report call, and it's confirmed green (72/72,
twice, including Case 4d) rather than just read as correct. Satisfies the
spec for CFW-315.
