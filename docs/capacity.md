# Capacity: how many requests a computer runs at once (M2-04)

The worker measures the Mac once at start and tells the server on every claim
how busy it is. The server hands out at most `max - running` requests, or one
urgent request when the computer is full.

## The table

`cr_capacity_table` in `bin/cfw-render-lib.sh`. Memory sets a ceiling, then
performance cores halve it, then the hard cap of 6 applies.

| Memory      | By memory | Example (perf cores) | Result |
|-------------|-----------|----------------------|--------|
| under 16 GB | 1         | any                  | 1      |
| 16–23 GB    | 2         | 4 cores → 2          | 2      |
| 24–31 GB    | 3         | 4 cores → 2          | 2      |
| 32–47 GB    | 4         | 8 cores → 4          | 4      |
| 48–63 GB    | 5         | 8 cores → 4          | 4      |
| 64 GB+      | 6         | 12 cores → 6         | 6      |

`CFW_RENDER_CONCURRENCY=<n>` (the owner's `.env`) overrides the table, capped
at 6. Empty or unset = measure.

## Live floor

Before each normal claim the worker checks free memory (`vm_stat` free +
inactive pages; `MemAvailable` on Linux) against a 3 GB floor and the 1-minute
load average against the CPU count. Under the floor it skips normal claims and
only asks for urgent work (once the server has shown it honours capacity, see
below). One log line each time it skips.

## Old servers

A server that ignores capacity answers with a single `order` and never with
`orders[]`. The worker only makes the "I am full, anything urgent?" ask after
a reply carried `orders[]`; otherwise an old server would hand a normal request
to a full computer. Against an old server the worker behaves exactly as M1:
one request per claim, up to `max`.

## Setup summary line (D78)

When the measured `max` is 1 the installer and the setup summary print:

> This computer runs one request at a time. It still serves your brands; bigger jobs just take turns.

M2-12 mirrors this sentence in cfw-social `src/lib/labels.ts` so the Runs page
can show the same words. Keep both in step.

## Kept-alive loop (manual checks)

`install/com.cfw.render.plist` runs `cfw-render.sh --loop` with `RunAtLoad`
and `KeepAlive` (`ThrottleInterval` between restarts). `install/install.sh`
re-run on an installed computer does `launchctl bootout` then `bootstrap`, so
a terminal-installed computer moves to the loop by pasting the setup message
again.

These need real launchd and are checked by hand, not in `test/run-tests.sh`:

1. `kill -9` the worker's PID → `launchctl list | grep com.cfw.render` shows a
   new PID within `ThrottleInterval` seconds; the log says `loop: started`.
2. Queue one request with the worker idle → it is claimed within 60 s
   (the idle claim cadence), without the Mac's timer firing.
3. Re-run `install.sh` on an installed Mac → the log shows one `bootout`
   and one `bootstrap`; the old loop is gone (`pgrep -f 'cfw-render.sh --loop'`
   shows exactly one PID).

The automated cases cover the rest: 22 (table + setup line), 23 (full +
urgent), 24 (floor), 25 (`stop_after_step`), 26/27 (resume), 28 (old server),
29 (back-off growth, one log line per step).
