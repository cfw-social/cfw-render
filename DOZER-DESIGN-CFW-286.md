# DOZER-DESIGN-CFW-286

**Title:** Director ends its turn with background work still running → ~50% of renders fail as "render failed unexpectedly"

## 1. Problem

`bin/cfw-render.sh`'s `spawn_director()` runs the headless Claude Creative
Director (`claude -p ... --dangerously-skip-permissions --output-format
text`) as a subshell, `wait`s for it, then classifies the outcome
(`bin/cfw-render.sh:283-309`):

```bash
wait "$director_pid"
local director_exit=$?
...
if [[ -f "$outcome_file" ]]; then
  outcome="$(cat "$outcome_file")"        # "complete" or "block", written by
                                           # cfw-render-report.sh
elif (( director_exit == 143 || director_exit == 137 )); then
  outcome="timeout"                       # watchdog TERM/KILL
else
  outcome="crashed"                       # ← everything else lands here
  cr_mcp_call block_render_order ... "render failed unexpectedly" ...
fi
```

`cfw-render-report.sh complete|block` is the **only** thing that writes
`.outcome`, and per `lib/director-prompt.md` step 8 it must be the Director's
last tool call. The Bash tool available to the Director (same harness as this
session — see its own docs: "You can use the `run_in_background` parameter to
run the command in the background... you do not need to check the result
right away — you'll be notified when it completes") supports firing a shell
command **asynchronously** and returning control immediately. Nothing in
`director-prompt.md` forbids this, and nothing in the recipes under
`skills/` enforces synchronous execution end-to-end (`cfw-render-subagent.sh`
and `cfw-render-report.sh` themselves are synchronous, but that doesn't stop
the Director from directly backgrounding a slow step — a long `ffmpeg` pass,
a parallel per-clip loop, a `curl` upload — with a trailing `&` or
`run_in_background: true`, intending to "check back on it").

`claude -p` (headless print mode) is a **single, non-interactive turn**: once
the model stops emitting tool calls, the process exits. It does not block on
outstanding backgrounded children, and there is no second turn in which the
Director can be "notified when it completes" the way an interactive session
would. So the sequence that produces this bug is:

1. Director backgrounds a step (e.g. a slow encode) and, believing it can
   move on, either finishes its stage reporting and stops, or runs out of
   things to do before the background step finishes.
2. `claude` exits — cleanly, `rc=0` — because from the CLI's point of view
   the turn ended normally. Nothing crashed.
3. `.outcome` was never written (`complete`/`block` never ran — the
   background step, not the Director's foreground path, was supposed to lead
   there).
4. The wrapping subshell's `exit $?` propagates that `rc=0` immediately —
   bash does **not** wait for a subshell's own backgrounded children on
   exit — so `wait "$director_pid"` in `spawn_director` also returns right
   away, while the backgrounded child is still writing to the order's
   scratch dir.
5. `spawn_director` sees: no `.outcome`, `director_exit=0` (not 143/137) →
   falls into the `else` branch → `outcome="crashed"` →
   `block_render_order(reason="render failed unexpectedly")`. The order is
   reported failed to the owner even though the render may well finish
   moments later, now orphaned and writing into a scratch dir the drainer
   has already given up on (and which the 48h janitor will eventually
   `rm -rf`).

This is a **race**, not a deterministic bug, which is exactly why it presents
as "~50% of renders fail" rather than "always fails": whether it triggers
depends on whether the Director chooses to background a step at all (more
tempting on slower `kind=video` renders — 3600s budget — than `kind=image` —
900s), and whether that background step happens to finish before or after
the Director's own turn ends.

Two things are broken here, and both need fixing:

- **Root cause (behavioral):** the Director is allowed to background work
  and end its turn without having actually reached a terminal action. This
  is the literal "Director ends its turn with background work still
  running."
- **Symptom amplifier (diagnostic):** even once that's fixed at the source,
  the wrapper still lumps "Director exited cleanly but never called
  complete/block" into the same bucket as a genuine crash
  (`director_exit` nonzero, an unhandled exception, OOM, etc.), reporting
  the same opaque "render failed unexpectedly" for both. Per this repo's
  fail-fast doctrine (no silent misclassification — report the exact
  failure), these are different failures with different fixes and should
  not share one label.

## 2. Approach

Two independent, complementary changes — a behavioral fix at the source, and
a structural safety net in the wrapper that (a) closes the narrow timing race
for genuinely-near-finished work and (b) makes any residual occurrence loud
and distinguishable instead of silently mislabeled.

### 2a. Prompt-level fix (primary — removes the root cause)

Add an explicit, unambiguous rule to `lib/director-prompt.md`: the Director
must never background a command (no trailing `&`, no `nohup`, no
`run_in_background: true`) and must never end its turn while any command it
started is still running. Every tool call finishes before the next one
starts; the terminal action (`complete`/`block`) is only ever the *next*
thing after the last piece of real work is confirmed on disk — not raced
against it. Slow steps are fine (the timeout budget already accounts for
long video renders); *unsupervised* slow steps are the bug.

This directly targets the named root cause and is fully within this repo's
control (unlike the `claude` CLI's own internals around backgrounded
processes, which we can't verify or rely on).

### 2b. Wrapper-level safety net (defense in depth — bounds the blast radius)

In `bin/cfw-render.sh`'s `spawn_director()`:

1. **Give the director subshell an addressable process group.** Enable job
   control (`set -m`) inside the subshell before it launches `claude`/
   `$CFW_RENDER_DIRECTOR_CMD`, and capture the resulting PGID
   (`ps -o pgid= -p "$director_pid"`) right after backgrounding it — before
   anything can exit. This groups the Director process and its *ordinary*
   (non-detached) children together so they can be signaled as a unit. This
   is a best-effort mitigation, not a guarantee: a child process that
   explicitly detaches into its own session (e.g. via `setsid`) will not be
   reachable this way — which is exactly why 2a (removing the behavior at
   the source) is the primary fix and this is the backstop.

2. **Bounded grace-poll before declaring failure.** After `wait
   "$director_pid"` returns with no `.outcome` present and `director_exit`
   is not 143/137, poll for `.outcome` to appear for a short, fixed window
   (`CFW_RENDER_ORPHAN_GRACE_SECS`, default 5s, checked every 0.5s) before
   giving up. This absorbs the genuinely-near-finish case (a background
   write that lands a few hundred ms after the parent exits) without
   masking real failures — if `.outcome` never appears, we still fail, just
   a few seconds later and with better information.

3. **Reap stragglers, then classify precisely.** If the grace window expires
   with still no `.outcome`: best-effort `kill -TERM -"$pgid"`, a short
   pause, `kill -KILL -"$pgid"` for anything left in that process group —
   so no orphan keeps mutating (or re-reporting to) an order the drainer has
   already decided about. Then split what was previously one `else` branch
   into two distinct, separately-logged outcomes:
   - `director_exit == 0` (clean exit, no terminal action) → new outcome
     `orphaned`, reason `"render ended without finishing — a background
     step was still running when the Director's turn ended"`. This is the
     bug this task is about, made visible instead of hidden behind a generic
     label.
   - `director_exit != 0` (and not 143/137) → outcome stays `crashed`,
     reason stays `"render failed unexpectedly"` — a genuine crash (bad
     exit code, exception, etc.), unchanged behavior.
   Both still call `block_render_order` and still write a journal row (the
   journal's `outcome` column carries the new value, so `journal.tsv`
   becomes queryable for how often each actually happens — this task's own
   "did we fix it" signal for CFW-286).

4. **Apply the same group-kill on watchdog timeout**, not just on the
   post-`wait` cleanup path. Today `kill -TERM "$director_pid"` (then
   `-KILL`) only signals the wrapping subshell — a stray `ffmpeg` the
   Director backgrounded survives a watchdog-triggered "timeout" block just
   as easily as it survives a clean exit, and keeps burning CPU/writing
   into a scratch dir the drainer already reported as timed out. Point the
   watchdog's kill at `-"$pgid"` once the PGID is known (falling back to the
   bare PID if the PGID lookup ever fails — never worse than today).

### Why not just wait forever for backgrounded work?

Rejected: the whole point of the watchdog + per-`kind` timeout budget
(`CFW_RENDER_TIMEOUT_VIDEO`/`IMAGE`) is an upper bound on how long one order
may hold a claim; indefinitely awaiting an unsupervised background process
defeats that and can wedge `CFW_RENDER_CONCURRENCY` slots. A bounded grace
window (seconds, not minutes) plus removing the behavior at the source (2a)
is the correct trade-off — long legitimate work stays inside the Director's
foreground turn where the existing timeout budget already governs it.

## 3. Files to touch

- `lib/director-prompt.md` — add the no-backgrounding / terminal-action rule
  (near step 8, and a short callout near step 4's subagent delegation so it's
  visible right where fan-out is introduced).
- `bin/cfw-render.sh` — `spawn_director()`:
  - `set -m` + PGID capture around the director subshell launch.
  - grace-poll loop before the outcome `if/elif/else`.
  - process-group kill in both the watchdog line and the post-grace reap.
  - split `crashed` into `crashed` (nonzero exit) vs `orphaned` (clean exit,
    no terminal action), with distinct `cr_log` lines and distinct
    `block_render_order` reasons.
  - journal row keeps its existing 7-column shape; `outcome` column now can
    read `orphaned` in addition to `complete`/`blocked`/`timeout`/`crashed`.
- `test/fake-director.sh` — new `FAKE_DIRECTOR_MODE`:
  - `orphan-late` — backgrounds a `sleep` past the grace window before
    writing `final/out.mp4` + calling `complete`, then exits 0 immediately
    (reproduces the bug deterministically: exercises the new `orphaned`
    path).
  - `orphan-just-in-time` — backgrounds a short `sleep` (inside the grace
    window) before completing, then exits 0 immediately (exercises the
    grace-poll catching a near-miss and still landing `outcome=complete`).
- `test/run-tests.sh` — new cases driving both fake-director modes above,
  asserting: (a) `orphan-just-in-time` → journal outcome `complete`, dish
  delivered, scratch wiped; (b) `orphan-late` → journal outcome `orphaned`,
  `block_render_order` called with the new reason, and — where feasible in
  the test harness — that the backgrounded process is no longer alive after
  the tick (process-group reap worked, no straggler left running past the
  test).
- `README.md` — "Testing" section already narrates the covered cases
  (`watchdog timeout → block with a time-budget reason`, etc.); add a line
  for the new orphaned-background case so the doc stays truthful.
- `docs/deploy.md` — the known-failure-modes section (`§` near line 192,
  "Director timeout/crash while the drainer is alive") gets a line
  distinguishing `orphaned` from `crashed` so on-call reading
  `cfw-render.log`/`journal.tsv` knows what the new value means and that it
  points at a Director-side backgrounding regression, not a host/toolchain
  problem.
- `config/cfw-render.env.example` — document the new
  `CFW_RENDER_ORPHAN_GRACE_SECS` knob (optional override, default 5)
  alongside the existing `TIMEOUT_*`/`HEARTBEAT_SECS` knobs.

No changes to `cfw-render-report.sh`, `cfw-render-subagent.sh`,
`cfw-render-upload.sh`, `cfw-render-lib.sh`'s MCP/event plumbing, or any
`skills/` recipe — all of those are already synchronous end-to-end; the gap
is specifically in the Director's own tool-use discipline and in how the
drainer classifies what happens when that discipline is violated.

## 4. Edge cases

- **Legitimate long-running foreground work (a real 50-minute 4K encode
  within budget).** Unaffected — it's still a normal foreground `wait`, no
  backgrounding involved, `.outcome` lands the instant `complete` runs, long
  before any grace/reap logic is reached.
- **Watchdog-killed order that *also* backgrounded work.** Previously: the
  stray process could keep running past the "timeout" block indefinitely.
  After: the group-kill on the watchdog path reaps it (best-effort — see the
  detached-session caveat in 2b.1). Journal outcome stays `timeout` (the
  watchdog path is unchanged in classification, only in cleanup thoroughness).
- **`.outcome` appears mid-grace-poll.** Treated as success exactly as if it
  had been there at `wait`-return time — no special-casing needed, the poll
  loop just breaks and falls into the normal `[[ -f "$outcome_file" ]]`
  branch.
- **PGID capture races the child's own exit (very short-lived director
  process, e.g. a config error that exits in milliseconds).** `ps -o pgid=
  -p "$director_pid"` returning empty is handled by falling back to
  signaling the bare PID (today's behavior) — never a hard failure of the
  drainer itself.
- **`CFW_RENDER_DIRECTOR_CMD` override (test/dev seam).** `set -m` and the
  PGID capture wrap *whatever* is launched in the subshell (real `claude` or
  the override), so `test/fake-director.sh` is exercised through the exact
  same code path as production — no test-only branching in the drainer.
- **A Director that backgrounds work AND still (correctly) calls
  `complete`/`block` as its literal last foreground action, but the
  background job is pure side work it never depended on (e.g., a fire-and-
  forget cache warm).** Still flagged as a prompt violation under 2a (the
  rule is "never background," full stop, not "never background things you
  depend on") — the safest bar someone reviewing Director transcripts can
  check mechanically. `.outcome` would already exist in this case, though,
  so the wrapper-level classification (2b) is unaffected either way — this
  case only matters for prompt-adherence auditing, not for the failure
  reported to the owner.
- **`CFW_RENDER_CONCURRENCY > 1` (multiple orders per tick).** Each claimed
  order gets its own `spawn_director` subshell and thus its own PGID; the
  grace/reap logic is entirely local to one order and doesn't cross-signal
  a sibling order's process group.
- **macOS (BYOA) vs Linux (`hst`) portability.** `set -m`, `ps -o pgid=`,
  and `kill -TERM -PGID` (negative PID = process-group signal) are all
  portable POSIX-ish bash/ps/kill behavior available on both platforms
  used today (macOS BYOA per `install/byoa-installer-notes.md`, Linux `hst`
  server per `docs/deploy.md`) — no `setsid`(1) dependency, which is not
  guaranteed present on macOS.

## 5. How it gets tested

- `pnpm lint` — `scripts/lint.sh` (bash -n + shellcheck) over the modified
  `bin/cfw-render.sh`, `test/fake-director.sh`.
- `pnpm test` — `test/run-tests.sh` against `test/mock-server.py`, no live
  services, exactly the existing pattern:
  - New case using `FAKE_DIRECTOR_MODE=orphan-just-in-time`: assert
    `journal.tsv`'s outcome column reads `complete`, the mock server recorded
    a `complete_render_order` call, and scratch was wiped — proves the
    grace-poll absorbs a near-miss instead of false-failing it (this is the
    regression test for "don't make the fix worse than the bug" — a naive
    zero-grace implementation would turn every legitimate late-finishing
    write into a hard failure).
  - New case using `FAKE_DIRECTOR_MODE=orphan-late`: assert `journal.tsv`'s
    outcome column reads `orphaned` (not `crashed`), the mock server
    recorded a `block_render_order` call whose reason matches the new
    orphaned-specific message, and — this is the direct regression test for
    the bug itself — that no `complete_render_order` call landed after the
    block (i.e., the reaped background process didn't get a chance to race
    the drainer's own decision and post a stale/conflicting completion).
  - Existing `watchdog` case (`FAKE_DIRECTOR_MODE=watchdog`, already covers
    the `sleep 60` timeout-kill path) extended to also background a
    marker-writing process, asserting the marker process is no longer alive
    (e.g., its pidfile's PID fails `kill -0`) once the tick completes —
    proves the group-kill applies to the watchdog path too, not just the
    clean-exit path.
  - Existing happy-path/gate-fail/large/carousel/no-captions/
    needs-ingredient cases are unaffected (all reach `.outcome` well within
    the grace window — effectively immediately) and continue to assert
    exactly as today; re-running the full suite is the regression check that
    2b's changes are additive, not disruptive, to the synchronous path.
- **Manual/deploy-time verification (not part of `pnpm test`):** after
  landing 2a, spot-check a handful of real Director transcripts
  (`$CFW_RENDER_STATE_DIR/runs/<orderId>-<ts>.out`) on `hst` for any
  remaining `&`/backgrounding tool calls, and watch `journal.tsv` for the
  `orphaned` outcome rate over the following few days — it should trend to
  zero if 2a alone was sufficient, or stay non-zero-but-now-visible (instead
  of hidden inside `crashed`) if the model still occasionally backgrounds
  despite the prompt rule, which would itself be useful signal for a
  follow-up task.
