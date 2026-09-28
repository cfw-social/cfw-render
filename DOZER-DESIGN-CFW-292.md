# DOZER-DESIGN-CFW-292

## Task

`test/run-tests.sh` (the cfw-render behavioral suite) hangs forever, pre-existing,
eating the 900s CI test-gate budget.

## Root cause (confirmed by live reproduction, not just code reading)

I ran the full suite three times, twice instrumented with a `ps` sampler polling
every 2-3s. Every run sails cleanly through every case — including "Case 2e: auto
mode" named in the ticket title, which passes in all runs — and then hangs
**after Case P's four ImageMagick-preflight assertions**, specifically inside the
*second* `pf_run` call at `test/run-tests.sh:661` ("Same host, full PATH restored:
the drainer runs normally"). Confirmed hung for 3+ minutes with zero stdout and
zero live `cfw-render`/`fake-director` processes — only one orphaned process
remained:

```
86627     1   02:54   sleep 3600
```

PPID `1` = reparented to launchd. `3600` = the default `CFW_RENDER_TIMEOUT_VIDEO`
(`cfw-render-lib.sh:184`) — `pf_run` never overrides it, unlike every `run_case`
call elsewhere in the suite (`CASE_TIMEOUT_VIDEO`/`CASE_TIMEOUT_IMAGE`, defaulting
to 30s). That single orphaned `sleep 3600` is what blocks everything: `pf_run`
captures the drainer's output via `pf_out="$( ... "$REPO_DIR/bin/cfw-render.sh"
... )"` (`run-tests.sh:616-627`) — a real pipe. `$( )` only returns once every
process holding the *write end* of that pipe has closed it. As long as that
`sleep 3600` is alive and still holds an inherited copy of the pipe fd, the
substitution cannot see EOF — so it blocks for up to ~3630s (timeout + the
watchdog's own 30s KILL grace), comfortably blowing the 900s gate. Ticket title
names Case 2e; empirically the hang is in Case P. I'd guess whoever filed it saw
the suite die around wherever output had last flushed in an earlier run and
mis-attributed the case — this repro is deterministic and lands at the same spot
every time.

### Why that `sleep 3600` exists and why it's orphaned

`bin/cfw-render.sh:280`:

```bash
( sleep "$timeout_secs"; kill -TERM "$director_pid" 2>/dev/null; sleep 30; kill -KILL "$director_pid" 2>/dev/null ) &
local watchdog_pid=$!
...
wait "$director_pid"
local director_exit=$?
kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null   # line 285
```

In this Case P run the director (`fake-director.sh`, "happy" mode — `FAKE_DIRECTOR_MODE`
isn't set by `pf_run` so it defaults to `happy`) completes normally in a couple of
seconds. Line 285 then tries to clean up the watchdog by `kill $watchdog_pid`. But
`$watchdog_pid` is the **wrapper subshell**, which at that moment is blocked
*inside its own foreground child*, `sleep "$timeout_secs"`. Bash has no trap on
SIGTERM here, so the wrapper dies immediately on receipt — but that only reaps the
wrapper. `sleep 3600`, its child, is never signaled; it's orphaned and reparented
to PID 1, and keeps running (and keeps holding the inherited pipe fd) for the rest
of its 3600s.

This is the **same failure class already documented and fixed once** in this repo,
just not everywhere. `cr_heartbeat_start` (`cfw-render-lib.sh:479-496`) has this
comment:

> NOTE: the loop's stdout/stderr MUST be redirected away from the caller's
> pipe. Callers take the PID via `$(cr_heartbeat_start …)`; a background child
> that keeps the command substitution's pipe open means the substitution never
> sees EOF and the caller hangs forever (same trap as test/run-tests.sh's
> start_mock).

That fix (`>/dev/null 2>&1 &`) stops the heartbeat's own `sleep 60` loop from
holding a caller's pipe open — but it doesn't stop the loop from being *orphaned*.
`cr_heartbeat_stop` (`cfw-render-lib.sh:503-509`) has the identical
`kill "$pid"` (wrapper-only) bug. I watched it leak a fresh orphaned `sleep 60`
after **every single case** in the full run (12+ of them accumulated over the run)
— harmless today only because its own output already goes to `/dev/null`, so it
doesn't block anything, but it's the same defect and a real, unbounded process
leak on a long-running render host.

The watchdog spawn at `cfw-render.sh:280` predates the CFW-146 heartbeat work and
never got the same treatment — and unlike the heartbeat loop, its own stdout/stderr
were never redirected at all, so it doesn't just leak, it can genuinely block a
caller.

**The deeper problem, beyond the test hang:** `kill -TERM "$director_pid"` /
`kill -KILL "$director_pid"` (the watchdog's actual *purpose* — killing a hung
render) have this exact same bug. If a real render genuinely hangs in production —
a stuck `claude` CLI call, a stuck `curl` inside `cfw-render-upload.sh` — the
watchdog's TERM/KILL only ever reaches the outer subshell wrapper. The actual hung
process is orphaned and keeps running (and keeps holding whatever claim/lease it
had) instead of being killed. The watchdog does not currently do the one thing it
exists to do.

## Fix

### 1. `bin/cfw-render-lib.sh` — add a process-tree kill helper

```bash
# ---------------------------------------------------------------------------
# cr_kill_tree <pid> [signal=TERM] — signal <pid> AND every live descendant.
# A backgrounded subshell (`cmd &`) gets no process group of its own — bash job
# control is off by default in a non-interactive script — so `kill $pid` only
# ever reaches that one wrapper. If it dies (e.g. SIGTERM, no trap) while
# blocked on ITS OWN foreground child, that child is orphaned: reparented to
# PID 1, left running, still holding whatever fds it inherited (this is how the
# render watchdog's own `sleep $timeout_secs` outlives a normal-path completion
# and wedges any caller that captures cfw-render.sh's output via `$( )` — see
# CFW-292). Worse: it means a genuinely hung render is never actually killed by
# the watchdog. Walk the tree with pgrep -P (present on both hst/Linux and
# macOS — no new dependency) so every descendant gets the signal.
# ---------------------------------------------------------------------------
cr_kill_tree() {
  local pid="$1" sig="${2:-TERM}" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    cr_kill_tree "$kid" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null
}
```

Placed near `cr_heartbeat_start`/`cr_heartbeat_stop` (both callers live in the
same file's heartbeat/watchdog neighborhood).

### 2. `bin/cfw-render-lib.sh` — `cr_heartbeat_stop` uses it

```bash
cr_heartbeat_stop() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  cr_kill_tree "$pid" TERM
  wait "$pid" 2>/dev/null
  return 0
}
```

(One-line change: `kill "$pid"` → `cr_kill_tree "$pid" TERM`.)

### 3. `bin/cfw-render.sh` — watchdog spawn + cleanup use it

```bash
( sleep "$timeout_secs"; cr_kill_tree "$director_pid" TERM; sleep 30; cr_kill_tree "$director_pid" KILL ) &
local watchdog_pid=$!

wait "$director_pid"
local director_exit=$?
cr_kill_tree "$watchdog_pid" TERM; wait "$watchdog_pid" 2>/dev/null
```

Three call sites change: the watchdog's own TERM, its fallback KILL, and the
normal-path cleanup kill at line 285. This closes the hang (nothing is ever left
holding a caller's pipe open) **and** fixes the watchdog's actual job (a hung
render's real process — `claude`, `curl`, whatever it's stuck in — now gets
signaled, not just its wrapper).

### 4. `test/run-tests.sh` — no code change required, but the fix unblocks an
existing assertion

`run-tests.sh:663-667` already asserts `pf_ok_exit == 0` for exactly this second
`pf_run` call — it just never got a chance to run because the process before it
hung. Once (1)-(3) land, that assertion starts executing and passing on every
run, so it doubles as regression coverage: if `cr_kill_tree` (or the watchdog
call sites) ever regress, this call goes back to hanging and the suite fails the
budget again, loudly.

## Files to touch

- `bin/cfw-render-lib.sh` — add `cr_kill_tree`; change `cr_heartbeat_stop`
- `bin/cfw-render.sh` — change the three watchdog `kill` call sites (~line 280,
  ~line 285)

No other files need code changes. `test/run-tests.sh` needs no edit — the fix
itself is the regression guard for the assertion already sitting at line 663-667.

## Edge cases

- **`pgrep` availability.** Both hst (Linux) and macOS dev boxes ship `pgrep`
  (procps on Linux, BSD userland on macOS) — no new dependency, matches the
  existing "no jq, portable bash" constraint in `cfw-render-lib.sh`'s header. If
  it were ever missing, `cr_kill_tree` degrades to killing just the root pid
  (today's existing, already-broken behavior) — not a regression.
- **`pid` already reaped.** `pgrep -P` on a dead pid returns nothing; the final
  `kill` fails silently (`2>/dev/null`, matching the existing pattern at both
  call sites) — no behavior change from today for the "director exited cleanly
  before the watchdog fires" path.
- **Race between `pgrep -P` snapshot and a child re-parenting mid-walk.** Vanishingly
  unlikely at this shallow depth (subshell → `fake-director.sh`/`claude` →
  at most one more level), and even in the worst case it just means that one
  grandchild is missed and orphaned exactly as before — never worse than current
  behavior.
- **Recursion depth/cost.** Tree here is 2-3 levels deep, one `pgrep` call per
  level — negligible, called at most twice per rendered order (watchdog cleanup
  + heartbeat stop).
- **`set -m` was considered and rejected.** Job-control process groups
  (`kill -TERM -- "-$pid"`) would also isolate the tree, but enabling monitor
  mode in a non-interactive script risks bash printing job-status
  ("Terminated: 15") lines to stderr when a backgrounded job dies — which
  `pf_run` and other callers capture and `grep` against. `cr_kill_tree` gets the
  same guarantee without touching job-control semantics anywhere in the script.
- **Does NOT touch the multipart/presign upload logic, mock server, or any of
  Case 2e's actual assertions** — those were already passing in every
  reproduction; nothing there needs to change.

## How it gets tested

1. `test/run-tests.sh` end-to-end, unmodified (per Fix §4): today it hangs and
   is killed by CI at 900s. After the fix it should run to completion in well
   under a minute (matches the ~80-90s wall-clock I measured for every case
   *except* the current Case P hang) and print `PASS: N   FAIL: 0`.
2. Manual live-process verification (same method I used to find the bug):
   run the suite with a `ps` sampler in parallel and confirm **zero** orphaned
   `sleep 3600` / `sleep 60` (PPID `1`) processes remain once the run finishes —
   today's run leaks one `sleep 3600` (from the watchdog) plus one fresh orphaned
   `sleep 60` after *every* case (from the heartbeat). After the fix, both should
   be zero.
3. Re-run the isolated repro I used to nail this down: `CFW_RENDER_DIRECTOR_CMD`
   pointed at `test/fake-director.sh` in `watchdog` mode with
   `CFW_RENDER_TIMEOUT_VIDEO=3`, drainer invoked directly (not through `--once`,
   which is a no-op flag per `cfw-render.sh:8`) — confirm `wait "$director_pid"`
   still returns promptly on the timeout path (unchanged: `director_exit` should
   still come back 143, journal row `outcome=timeout` still gets written) and that
   the orphaned `sleep 60` from the fake director no longer survives past the
   watchdog's TERM.
4. Lint (`scripts/lint.sh`, already the suite's last step at `run-tests.sh:674`)
   continues to run and pass — no shellcheck-relevant pattern changes beyond the
   new function and the three call-site edits.
