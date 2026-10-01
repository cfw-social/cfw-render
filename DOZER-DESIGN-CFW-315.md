# DOZER-DESIGN-CFW-315

## Task

`test/run-tests.sh` Case 4d ("heartbeat + renderer identity", CFW-146) is red on a
clean `develop` checkout — not on any particular feature branch. Because the
green gate reruns the full suite on every candidate merge and this failure is
pre-existing and unrelated to whatever is actually being merged, the gate
auto-reverts whatever lands, regardless of its own correctness. CFW-312 and
CFW-313 are the visible symptom: `review(CFW-313): FAIL — branch is stale
against develop, silently reverts CFW-312 + GSAI-36` — two good branches
bouncing off a gate that was never green to begin with.

## Root cause (confirmed by live reproduction, not just code reading)

I ran the full suite on `develop` (this worktree's current `HEAD`, `005fef0`,
unmodified) three times. Every run is clean through Case 4b, then Case 4d
fails the same way every time:

```
=== Case 4d: heartbeat + renderer identity (CFW-146) ===
  FAIL  heartbeat — BAD a heartbeat was rejected by the server; 1 event(s) after the order went terminal
  PASS  heartbeat: the render still completed normally
```

(68 PASS / 4 FAIL overall — the other 3 are Case 4a, `orphan-just-in-time`,
which I'm treating as unrelated sandbox CPU-contention flakiness; see **Out of
scope** below. Case 4d failed 3/3 times, not intermittently in my runs.)

### The bug

`cr_heartbeat_start` (`bin/cfw-render-lib.sh:505-522`) forks an independent
background loop — `while :; do sleep "$secs"; cr_event ... heartbeat ...; done`
— that ticks on its own clock, decoupled from whatever the Director is doing.
`bin/cfw-render.sh`'s `spawn_director` starts it *before* backgrounding the
Director subprocess (`cfw-render.sh:246`) and stops it with
`cr_heartbeat_stop "$heartbeat_pid"` (`cfw-render.sh:317`) — but **only after
`wait "$director_pid"` returns**, i.e. only after the Director's entire
process tree has already exited.

That's too late. The terminal report (`complete_render_order` /
`block_render_order`) isn't sent by `cfw-render.sh` after the wait — it's sent
*from inside the Director's own process*, synchronously, via
`cfw-render-report.sh complete|block` (`bin/cfw-render-report.sh`), well
before the Director's process actually exits. `test/mock-server.py` itself
documents the assumption this was supposed to satisfy
(`test/mock-server.py:97-98`):

```python
# CFW-146: a heartbeat is a pulse, not progress — it may carry the
# renderer kind on `stage` but never a pct, and it never lands on a
# terminal order (the drainer stops the pulse before reporting).
```

"The drainer stops the pulse before reporting" was never actually wired up —
the heartbeat PID lives only in `spawn_director`'s local shell variable in
`cfw-render.sh`; `cfw-render-report.sh` runs in a *different* process (the
Director's) and has no way to reach it. So there is a real window — from the
moment the Director internally calls `complete`/`block` to the moment its
whole process tree finally exits and the drainer's `wait` returns — during
which the heartbeat loop is still alive and can fire.

`test/fake-director.sh`'s `heartbeat` mode (`fake-claude.sh` isn't involved
here) does `sleep 5; ...; sleep 3; ...complete` — ~8s of "work" before its own
`complete` call. Case 4d sets `CFW_RENDER_HEARTBEAT_SECS=2` specifically so
the 8s run produces `>=2` pulses — but that same tight cadence against that
same run length makes a tick landing in the post-complete window close to
certain: ticks land at roughly t≈2s, 4s, 6s, 8s, and t≈8s is exactly when the
Director calls `complete`. Whichever wins the race, the result trips the
test's "nothing after terminal" check (`run-tests.sh:497-507`) and often also
a hard `ok:false`/"order is terminal" rejection from the mock server
(`test/mock-server.py:100-102`) once `STATUS[order_id]` has already flipped to
`done`.

This is a genuine, deterministic-at-this-cadence bug in the CFW-146
heartbeat feature, not a test-authoring mistake — the test's own tight timing
is what reliably exposes it, which is exactly why it's red on every clean
`develop` run rather than only occasionally.

## Fix

Move the "stop the pulse" trigger from *"the Director's whole process tree
has exited"* to *"the Director is about to report a terminal outcome"* — the
earlier, correct point mock-server.py's comment already assumes. Thread the
heartbeat PID into the Director's own process tree the same way `.outcome` is
already threaded (`cfw-render-report.sh:168`: `echo "complete" > .outcome`,
relative to CWD, which is always the order's scratch dir — both the parent
drainer's subshell and the Director's own subprocess/background children
share that CWD).

### 1. `bin/cfw-render.sh` — write the heartbeat PID where the Director can see it

At `cfw-render.sh:246`, right after capturing `heartbeat_pid`:

```bash
local heartbeat_pid
heartbeat_pid="$(cr_heartbeat_start "$order_id")"
# [CFW-315] Let the Director's own process (cfw-render-report.sh, running
# inside it) stop the pulse itself, synchronously, right before it reports a
# terminal outcome — stopping it here, after wait, is too late: the Director
# already called complete/block from inside its own tree before it exits.
[[ -n "$heartbeat_pid" ]] && echo "$heartbeat_pid" > "$order_dir/.heartbeat.pid"
```

The existing `cr_heartbeat_stop "$heartbeat_pid"` after `wait` (`cfw-render.sh:317`)
stays as-is — it's the backstop for every path that never calls
`cfw-render-report.sh complete|block` at all (crash, watchdog kill, a Director
that just hangs). Stopping an already-dead PID is already a safe no-op
(`cr_kill_tree`/`kill` on a reaped pid fails silently, same pattern used
throughout this file).

### 2. `bin/cfw-render-lib.sh` — one small shared helper

Next to `cr_heartbeat_stop`, so both `complete)` and `block)` in
`cfw-render-report.sh` can share one implementation instead of duplicating it:

```bash
# ---------------------------------------------------------------------------
# cr_heartbeat_stop_if_pending — [CFW-315] stop a pulse (if one is running)
# BEFORE reporting a terminal outcome. Reads the pid dropped by spawn_director
# at $PWD/.heartbeat.pid (CWD is always the order's scratch dir, for both the
# Director's foreground run and any backgrounded straggler it forks — same
# assumption cfw-render-report.sh already makes for .outcome). Best-effort,
# idempotent, silent if no pidfile exists (heartbeat cadence 0, or already
# stopped).
# ---------------------------------------------------------------------------
cr_heartbeat_stop_if_pending() {
  [[ -f .heartbeat.pid ]] || return 0
  local pid; pid="$(cat .heartbeat.pid 2>/dev/null)"
  rm -f .heartbeat.pid
  cr_heartbeat_stop "$pid"
}
```

### 3. `bin/cfw-render-report.sh` — call it immediately before each terminal RPC

In `complete)`, immediately before `resp="$(cr_mcp_call complete_render_order
"$complete_args")"` — **not** at the top of the `complete)` branch, so the
pulse keeps firing during whatever upload work precedes it (useful "still
working" signal for a large multipart/presign upload) and only stops right at
the instant the order is about to go terminal:

```bash
cr_heartbeat_stop_if_pending
resp="$(cr_mcp_call complete_render_order "$complete_args")" || { echo "cfw-render-report: complete_render_order failed" >&2; exit 1; }
```

In `block)`, same placement, immediately before its `cr_mcp_call
block_render_order ...` call.

## Files to touch

- `bin/cfw-render.sh` — write `.heartbeat.pid` after `cr_heartbeat_start` in
  `spawn_director` (~line 246). No change to the existing post-`wait`
  `cr_heartbeat_stop` backstop.
- `bin/cfw-render-lib.sh` — add `cr_heartbeat_stop_if_pending`, placed next to
  `cr_heartbeat_start`/`cr_heartbeat_stop`.
- `bin/cfw-render-report.sh` — call `cr_heartbeat_stop_if_pending` immediately
  before the `complete_render_order` call in `complete)` and immediately
  before the `block_render_order` call in `block)`.

No test file changes. Case 4d's assertions (`run-tests.sh:478-519`) already
express the correct invariant ("nothing after terminal", no rejected
heartbeats) — they don't need editing, they need the implementation to
actually satisfy what `test/mock-server.py`'s own comment already assumed.

## Edge cases

- **Heartbeat cadence 0 (disabled).** `cr_heartbeat_start` echoes nothing;
  `spawn_director` guards the pidfile write (`[[ -n "$heartbeat_pid" ]]`), so
  no `.heartbeat.pid` is ever created; `cr_heartbeat_stop_if_pending` is a
  no-op. Matches today's behavior.
- **Crash / watchdog kill / Director that never calls `complete`/`block`.**
  `cfw-render-report.sh` never runs that branch, so
  `cr_heartbeat_stop_if_pending` never fires — the existing post-`wait`
  backstop in `cfw-render.sh` is unchanged and still the one that stops the
  pulse. No regression for Case 4 (watchdog) or any crash path.
- **`orphan-just-in-time` / `orphan-late` (CFW-286): a backgrounded straggler
  calls `complete` after the Director's own process has already exited 0.**
  That background subshell is a fork of the Director's process tree and
  inherits the same CWD (`order_dir`), so `cr_heartbeat_stop_if_pending`'s
  relative `.heartbeat.pid` lookup resolves correctly there too — the fix
  covers the delayed-completion path, not just the synchronous happy path.
  For `orphan-late` (the straggler is reaped before it ever calls `complete`),
  nothing calls `cr_heartbeat_stop_if_pending` and the existing post-`wait`
  backstop in `cfw-render.sh` still does the job, same as today.
- **Double-stop.** `cfw-render-report.sh`'s stop (new) and `cfw-render.sh`'s
  post-`wait` stop (existing) can both fire for the normal happy path — the
  second one finds no `.heartbeat.pid` (already removed) and nothing to kill
  (already dead); both `cr_heartbeat_stop` and `cr_kill_tree` are already
  written as idempotent/best-effort against a dead or already-signaled pid.
- **Concurrency (`CFW_RENDER_CONCURRENCY` > 1).** `.heartbeat.pid` lives under
  each order's own `order_dir`, so parallel orders never share or race on the
  same pidfile.
- **Scratch wipe after complete.** The pidfile is removed by
  `cr_heartbeat_stop_if_pending` itself before the terminal call even goes
  out; even if it weren't, `rm -rf "$order_dir"` on successful completion
  (`cfw-render.sh`, the existing "scratch dir wiped after complete" path)
  already wipes everything in the order dir regardless.
- **Residual theoretical race.** `cr_heartbeat_stop` sends `TERM` down the
  process tree and `wait`s for it — if the loop is mid-`sleep`, `TERM` kills
  it before the next `cr_event`/`curl` ever starts, which is the entire
  window this fix closes (seconds, today). The only remaining sliver is a
  heartbeat `curl` whose bytes are already on the wire in the same instant
  `cr_heartbeat_stop_if_pending` runs — a single local-loopback syscall racing
  a local signal, not a multi-second window. Closing that completely would
  need a cross-process flock around every pulse *and* every terminal send;
  given the real window drops from "~8s, same order as the whole fixture
  runtime" to "sub-millisecond, same order as signal delivery latency," that
  additional complexity isn't justified by what Case 4d actually needs to go
  reliably green.

## Out of scope (observed, not fixed here)

- **Case 4a (`orphan-just-in-time`) failed in my diagnostic runs** (`journal
  row`, `complete call`, `scratch` all FAIL). `CFW_RENDER_ORPHAN_GRACE_SECS=3`
  vs `FAKE_DIRECTOR_ORPHAN_SLEEP=1` is a comfortable margin on paper; this
  reads like CPU-contention flakiness in this sandboxed worktree (several
  concurrent python3/bash test processes competing for scheduling) rather
  than a logic bug, and the ticket names only Case 4d. Worth a human rerun on
  the actual gate machine before concluding it's part of the same ping-pong —
  not touched by this design.
- **`test/run-tests.sh:522`** — `echo "=== Case 4e: block carries `needs`
  (CFW-146) ==="` has literal backticks inside a double-quoted string, which
  bash treats as command substitution (`needs: command not found` printed to
  stderr every run). Cosmetic logging bug only, doesn't affect PASS/FAIL
  counts or gate outcome — not touched by this design.

## How it gets tested

1. `test/run-tests.sh` end-to-end, unmodified: today Case 4d fails 3/3 on a
   clean checkout; after the fix it should pass every time.
2. Because this was a timing-dependent bug, one green run isn't proof —
   **loop Case 4d's exact repro in isolation ~20-30x** (same
   `CFW_RENDER_HEARTBEAT_SECS=2` against `fake-director.sh`'s `heartbeat`
   mode, via `run_case` directly or by wrapping the whole suite in a shell
   loop) and confirm zero failures, not just the first one. The original bug
   was "almost certain to lose the race under this cadence," not "sometimes
   loses it" — the fix should make it "never loses it," which a single run
   can't distinguish from "got lucky."
3. Confirm no regression elsewhere: full suite PASS count should go from
   `68 PASS / 4 FAIL` to `69 PASS / 3 FAIL` (the 3 remaining being the
   out-of-scope Case 4a flake) — specifically re-check Case 4 (watchdog),
   Case 4b (`orphan-late`), and Case 2d/2e (large uploads, where the pulse
   legitimately needs to keep firing throughout a slow upload and must NOT
   stop early) still pass, since those are the paths most likely to be
   affected by moving the stop point earlier in `complete)`/`block)`.
4. `scripts/lint.sh` (the suite's last step) continues to pass — no new
   shellcheck-relevant patterns beyond one small function and two call sites.
5. Once Case 4d is reliably green, re-check the CFW-312/CFW-313 situation:
   either branch should now be able to merge without the gate reverting it
   for a reason that was never theirs — that's the actual acceptance signal
   for this ticket, not just the isolated test case.
