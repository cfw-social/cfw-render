# DOZER-DESIGN-CFW-291 — CFW-279 follow-up: resolved-binary worker PATH, headless `claude` probe, Linux coverage, tests

## Root cause (what CFW-279 left open)

CFW-279 fixed the *reported symptom* (`FAIL binary:claude not on PATH` on a
BYOA Mac) by hardcoding two more guessed directories into
`install/com.cfw.render.plist`:

```xml
<key>PATH</key>
<string>{{HOME}}/.local/bin:{{HOME}}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
```

Its own design doc (`DOZER-DESIGN-CFW-279.md`) and review
(`DOZER-REVIEW-CFW-279.md`) explicitly flagged three things it did **not**
fix, which is exactly this ticket's scope:

1. **Still a guessed, static list, not a resolved one.** If `claude` (or any
   binary a recipe/Director invocation needs — `node`, `npx`, `ffmpeg`,
   `ffprobe`, `magick`, `curl`, `python3`) is installed somewhere CFW-279
   didn't happen to guess — an nvm shim, a pyenv/pipx user install, a
   non-default Homebrew prefix, a Node installed via a `.pkg` to
   `/usr/local/opt/...` — the box repeats the exact CFW-279 incident with a
   different directory. A guessed list can never close this generally; a
   **resolved** one can.
2. **Never actually probed `claude` headless.** CFW-279's own review notes
   (point 5) that the only verification is `command -v claude` /
   `claude --version` run in **whatever shell invoked it** — the installer's
   full login shell at install time, or the drainer's inherited environment
   at tick time. Neither simulates the *exact*, minimal environment
   launchd/systemd hand a scheduled unit. A `claude` that resolves via
   `command -v` in a rich shell (because a shell function, alias, or an
   nvm/asdf init hook shadows or wraps the real binary) can still fail the
   moment it runs under a bare `PATH`-only environment — which is precisely
   the failure class CFW-279 was fixing, just not fully closed.
3. **Linux was explicitly out of scope.** CFW-279's design doc says outright:
   "the Linux path (`install/cfw-render.service`) has no explicit `PATH=`
   override in `[Service]`... a different (already-tracked-elsewhere)
   concern, out of scope here." `install/cfw-render.service` still has no
   `PATH=`/`Environment=` today (confirmed: `grep -n PATH
   install/cfw-render.service` → no match). systemd gives a oneshot unit its
   own minimal default search path, not the service user's login-shell PATH
   — so a Linux box with `claude`/`ffmpeg`/etc. under `~/.local/bin` or a
   user npm prefix hits the **identical** failure CFW-279 fixed for macOS
   only, and nothing currently protects it.
4. **No automated test covers any of this.** CFW-279's review (Notes,
   non-blocking) states plainly: "No automated test covers plist content...
   verification is manual/operational." Same for the Linux unit — it has
   never been exercised by `test/run-tests.sh` at all.

## Approach

### 1. One shared resolver + one shared headless probe, in `bin/cfw-render-lib.sh`

Add two new functions next to the existing `TOOLCHAIN PREFLIGHT (CFW-199)`
block (they read `_CR_REQUIRED_BINS`, already defined there, so they belong
beside it):

**`cr_resolve_worker_path`** — walks `_CR_REQUIRED_BINS` (`curl python3 node
npx ffmpeg ffprobe magick`) plus `claude`, resolves each with `command -v` in
**the caller's current environment** (at install time that's the installer's
real, rich shell — the only place we can observe where things are actually
installed), takes the `dirname` of each hit, and dedupes into an ordered list
(first-seen wins, so if two tools live in the same custom dir it appears once).
It then appends today's static fallback dirs (`/usr/local/bin /usr/bin /bin
/opt/homebrew/bin`) **only if not already present**, at the **end** — so a
resolved real location always wins over a guess, but boxes that already work
via the old hardcoded dirs keep working unchanged (same ordering rationale
CFW-279 used for `~/.local/bin` vs. system dirs, generalized). A binary that
doesn't resolve is silently skipped here — `cr_preflight` is still the one
place that turns "missing" into a hard failure; this function's only job is
turning "found, and here's where" into a PATH string. Prints the colon-joined
result on stdout.

**`cr_probe_claude_headless [worker_path]`** — the actual new safety net.
Defaults `worker_path` to a fresh `cr_resolve_worker_path` call if not given.
Mirrors `cr_preflight`'s existing stub-Director skip
(`CFW_RENDER_DIRECTOR_CMD` set → SKIP, not FAIL — a test/dev box that
intentionally stubs out `claude` must not suddenly be required to install a
real one). Otherwise it runs the probe **exactly the way launchd/systemd will
run the real tick**: `env -i` (a fully stripped environment, not "inherit
everything minus a filter") with only `PATH=<worker_path>`, `HOME`, and a
short, explicit allow-list of vars a CLI can legitimately need to behave
correctly (`TMPDIR`, `LANG`, `LC_ALL`, `USER`) passed through — then
`claude --version`. Applies the same "exit 0 but empty output is still a
failure" rule `cr_preflight` already applies to its own `claude --version`
check, for consistency. Returns 0 and the version string on success; returns
1 and both the captured output and the `worker_path` that was tried on
failure, so a human (or `install.sh`) gets an actionable message instead of a
bare non-zero.

This is the piece that closes gap #2 above: it doesn't just ask "does
`claude` resolve," it asks "does `claude` actually run in the *narrowest*
environment a scheduled tick will ever get" — which is a strictly harder and
more honest bar than anything CFW-279 or `cr_preflight` checks today.

### 2. Wire both into `install/install.sh`, right after the existing preflight gate

Today's flow: `cr_preflight` (require every binary present) → copy files →
render the plist/unit → final `--dry`. Insert the new gate immediately after
`cr_preflight` succeeds and before anything is rendered:

```bash
WORKER_PATH="$(cr_resolve_worker_path)"
if ! cr_probe_claude_headless "$WORKER_PATH"; then
  echo "install.sh: ABORTING — claude resolves but does not run under the exact" >&2
  echo "  PATH a scheduled tick will get (see probe output above). Nothing was" >&2
  echo "  installed. Fix claude's install (or its wrapper/shim) and re-run." >&2
  exit 1
fi
```

Same fail-fast shape as the existing `cr_preflight` abort a few lines above
it (`install.sh:57-61`) — consistent with this repo's "never claim work a
host can't finish" doctrine, extended to "never install a unit whose PATH
can't actually run its own Director."

`WORKER_PATH` then replaces the hardcoded `PATH` string in **both** rendered
templates via a new `{{WORKER_PATH}}` placeholder, substituted the same way
`{{PREFIX}}`/`{{ENV_FILE}}`/`{{HOME}}` already are (one more `-e
"s#{{WORKER_PATH}}#$WORKER_PATH#g"` added to each OS branch's existing `sed`
line).

### 3. `install/com.cfw.render.plist` (macOS) — replace the guessed list

```xml
<key>PATH</key>
<string>{{WORKER_PATH}}</string>
```

`{{HOME}}` stays exactly as-is for `StandardOutPath`/`StandardErrorPath` —
only the `PATH` value's *source* changes, from a hand-guessed string to the
resolved one computed in `install.sh`.

### 4. `install/cfw-render.service` (Linux) — give it the same protection for the first time

Add one line, placed **after** `EnvironmentFile={{ENV_FILE}}` (order matters:
systemd applies repeated `Environment=`/`EnvironmentFile=` directives for the
same key in file order, last one wins — placing ours after the env file
guarantees the resolved worker PATH always wins even if `{{ENV_FILE}}`
happens to also declare a `PATH=` line, rather than silently losing to it):

```ini
[Service]
Type=oneshot
User={{USER}}
EnvironmentFile={{ENV_FILE}}
# Deliberately AFTER EnvironmentFile — the resolved worker PATH must always
# win over anything {{ENV_FILE}} declares. See CFW-291.
Environment=PATH={{WORKER_PATH}}
ExecStart={{PREFIX}}/bin/cfw-render.sh --once
TimeoutStartSec=2100
```

This is the direct fix for gap #3: Linux gets the identical resolved-PATH
protection macOS is getting, using the same `WORKER_PATH` value computed
once in `install.sh` and fed into both templates — one resolver, two
renderers, no drift between the platforms.

### 5. Docs

- `docs/deploy.md` §4 — rewrite the CFW-279 troubleshooting note: it
  previously told a human to manually confirm `claude` resolves and re-run
  `install.sh`. Now `install.sh` itself proves this (both "resolves" and
  "runs headless") before it will finish, and prints the exact resolved
  `WORKER_PATH` plus the probe's captured output on failure — so the note
  becomes "if install.sh aborts here, this is what it checked and this is
  what to fix," not "go check this yourself." Also removes the "Linux is a
  different, already-tracked concern" framing (CFW-279 language) since Linux
  is now covered identically.
- `install/byoa-installer-notes.md` — update its cross-reference to match.
- `README.md`'s test-suite paragraph (~line 381) — add the new cases to the
  list of what `test/run-tests.sh` covers, keeping that doc accurate (it
  already itemizes every case category today).

## Files to touch

- `bin/cfw-render-lib.sh` — add `cr_resolve_worker_path`, `cr_probe_claude_headless`.
- `install/install.sh` — compute `WORKER_PATH`, run the new abort gate, add
  the `{{WORKER_PATH}}` substitution to both the Darwin and Linux `sed` calls.
- `install/com.cfw.render.plist` — `PATH` value becomes `{{WORKER_PATH}}`.
- `install/cfw-render.service` — add `Environment=PATH={{WORKER_PATH}}`.
- `docs/deploy.md`, `install/byoa-installer-notes.md`, `README.md` — doc updates described above.
- `test/run-tests.sh` — new cases (below). No new fixture files needed beyond
  one small additional fake binary described in "How it gets tested."

No changes to `bin/cfw-render.sh`'s runtime tick path or to `cr_preflight`
itself: `cr_preflight` keeps doing exactly what it does today (a live check
under whatever environment actually invoked it) — that check becomes
*trustworthy* as a side effect of the plist/unit now carrying the resolved
PATH, without needing to touch its code. `bin/cfw-render-preflight.sh` (the
human-run standalone preflight) is deliberately left alone too — it's a
live-tick-shaped check, not an install-time PATH constructor, and folding the
headless probe into it would run `env -i ... claude --version` on every
15-minute tick for no benefit (the real tick already spawns `claude` for the
whole Director session; a probe there would be redundant, not protective).

## Edge cases

- **`sudo install.sh --user <svc>` (root ≠ service user).** `command -v`
  inside `cr_resolve_worker_path` reflects *root's* PATH, not `<svc>`'s —
  the same caveat `install.sh` already documents for worker-id state-dir
  resolution (`eval echo "~$RUN_USER"`, install.sh:132). Document in
  `docs/deploy.md` that `install.sh` should be run as (or `sudo -u <svc> -i
  ...`) the actual service user so resolution reflects what that user will
  actually see — an operational note, not something the code can silently
  correct (guessing on the operator's behalf here would reintroduce exactly
  the "guessed, not resolved" problem this ticket fixes).
- **`claude` not installed at all on the authoring/dev box.** This repo's own
  `install.sh` is explicitly "AUTHORING ONLY... never executed against a real
  box" in this lane. `cr_resolve_worker_path` never fails on a missing
  binary (it just skips it) — only `cr_preflight` (unchanged, runs first) and
  the new probe (runs second, and only reached if `cr_preflight` already
  confirmed `claude` resolves) can fail the install. Ordering guarantees the
  probe's only *new* failure mode is "resolves but doesn't run," never
  "doesn't resolve" (already caught upstream).
- **Stub Director (`CFW_RENDER_DIRECTOR_CMD` set — tests/dev).**
  `cr_probe_claude_headless` mirrors `cr_preflight`'s existing SKIP for this
  case exactly, so `test/run-tests.sh` and any dev box using the stub never
  gets newly blocked by a missing real `claude`.
- **Chromium/fonts are NOT added to the PATH resolver.** `cr_preflight_chromium`
  already discovers Chromium by walking Playwright's cache dirs or a handful
  of named system binaries — Playwright launches it by absolute path, not by
  relying on shell `PATH` lookup, so it's a different resolution problem and
  intentionally out of scope here (documenting this explicitly to head off a
  future "why doesn't chromium show up in WORKER_PATH" question).
- **A required binary resolves into a dir already in the static fallback
  set** (e.g., `claude` really does live in `/opt/homebrew/bin`) — dedup by
  first-seen directory keeps the final PATH free of duplicates; this is also
  CFW-279's own regression case ("box where `claude` lives in
  `/opt/homebrew/bin`... fix is additive") and must still pass unchanged.
- **`env -i` over-stripping.** A bare `env -i PATH=... HOME=... claude
  --version` could produce a false FAIL if `claude`/Node needs `LANG` for
  UTF-8-safe output or `TMPDIR` for scratch files — allow-listing exactly
  `HOME TMPDIR LANG LC_ALL USER` (passed through only if already set in the
  caller's env) keeps the probe a faithful simulation of what launchd/systemd
  actually hand a unit (both set at least `HOME`; `TMPDIR` is standard on
  macOS launchd jobs) without being needlessly stricter than reality.
- **`PATH` value containing a literal `#`.** The substitution `sed` calls use
  `#` as the delimiter (matching the existing `{{PREFIX}}`/`{{ENV_FILE}}`
  substitutions). A resolved directory containing `#` would break it — an
  accepted, pre-existing class of limitation (identical risk already exists
  for `$PREFIX`/`$ENV_FILE` today), not a new problem introduced by this
  change.
- **Already-installed boxes.** Same operational caveat CFW-279 already
  documented: a box's existing `~/Library/LaunchAgents/com.cfw.render.plist`
  or `/etc/systemd/system/cfw-render.service` is a static rendered copy and
  won't pick up the new resolved-PATH behavior until `install.sh` is
  re-run — carried forward unchanged into the updated `docs/deploy.md` note.

## How it gets tested

Everything below lands in `test/run-tests.sh` (the repo's one sanctioned
suite — `package.json`'s `test` script, ending in the existing
`scripts/lint.sh` call) as new `Case` blocks after the existing `Case P`
(toolchain preflight) and before the final `Lint` section. None of it needs
the mock server — these are pure bash-function and template-rendering
checks, matching the "no live services" rule already governing this file.

**New fixture:** one additional fake binary, `test/fake-claude-env-dependent.sh`
— exits 0 and prints `ok` only when a specific env var (e.g. `FAKE_NVM_DIR`)
is set; otherwise exits 127 and prints nothing. This is the fixture that
proves the headless probe actually catches the class of bug CFW-279 could
not: a `claude` that resolves via `command -v` in a rich test shell (because
the harness itself exports `FAKE_NVM_DIR`) but must fail under `env -i`,
which strips it.

1. **`cr_resolve_worker_path` finds a nonstandard binary location.** Build a
   temp dir with a fake `claude` (reuse `test/fake-claude.sh`) in
   `$tmp/weird/claude`, put `$tmp/weird` on `PATH` ahead of everything else,
   source `bin/cfw-render-lib.sh` in a subshell, call the function, and
   assert the output contains `$tmp/weird` — proving the PATH is *resolved*,
   not the CFW-279 guessed list.
2. **Dedup + fallback-preserving.** Two required bins resolved into the same
   temp dir must produce that dir exactly once in the output; the standard
   fallback dirs (`/usr/local/bin`, `/opt/homebrew/bin`, etc.) must still
   appear (at the end) so a box that only ever worked via those dirs (the
   pre-CFW-279, pre-CFW-291 "boring" case) keeps working — direct regression
   coverage for CFW-279's own "Homebrew case" edge case, now automated for
   the first time.
3. **Headless probe: the money test.** With `FAKE_NVM_DIR` exported in the
   *test harness's own shell* and `test/fake-claude-env-dependent.sh` on
   `PATH` as `claude`: (a) show a naive `command -v claude && claude
   --version` in the harness's own environment reports success (demonstrating
   the exact old gap: it "resolves"), then (b) call
   `cr_probe_claude_headless` with that same PATH and assert it **fails** —
   proving the probe genuinely runs under a stripped `env -i`, not the
   harness's ambient environment, and would have caught the CFW-279 failure
   mode at install time instead of at the first real scheduled tick.
4. **Headless probe: success case + empty-output-is-still-a-failure.** Same
   probe against `test/fake-claude.sh` (always prints `ok`, exit 0) →  PASS;
   then against a fixture that exits 0 but prints nothing → FAIL, mirroring
   `cr_preflight`'s existing rule for its own `claude --version` check.
5. **Headless probe respects the stub-Director skip.** With
   `CFW_RENDER_DIRECTOR_CMD` exported and no `claude` anywhere on `PATH`,
   `cr_probe_claude_headless` must return 0 (SKIP), proving it won't newly
   block the test/dev flow that already relies on the stub seam.
6. **`install.sh` renders `WORKER_PATH` into the macOS plist.** Run
   `install/install.sh --mode byoa --prefix <tmp> --env-file <tmp-env>` with
   `HOME` overridden to a scratch dir (install.sh never calls `launchctl`
   itself, only prints the command — safe to run for real, hermetically, in
   a test) and a `PATH` built the same way `Case P`'s shim already does,
   plus one required bin relocated into a custom temp dir. Assert the
   rendered `$HOME/Library/LaunchAgents/com.cfw.render.plist`'s `PATH` value
   equals the exact string `cr_resolve_worker_path` would have produced for
   that same `PATH` (no leftover `{{WORKER_PATH}}` token), and that it
   parses as well-formed XML (`plutil -lint` where available, else a
   `python3 -c "import xml.dom.minidom; ..."` fallback so the assertion also
   runs on a Linux CI runner without `plutil`).
7. **Cover Linux from a macOS dev box: a small, explicit test seam.** Since
   this worktree runs on Darwin and `install.sh` picks its branch from `uname
   -s` directly, add one narrow override — `CFW_RENDER_TEST_OS` — checked
   only if set, in the same spirit as the existing `CFW_RENDER_DIRECTOR_CMD`
   test seam (a variable that only ever matters to `test/run-tests.sh`).
   With `CFW_RENDER_TEST_OS=Linux`, run the same install invocation as case 6
   and assert the rendered `/tmp/cfw-render.service.$$` contains
   `Environment=PATH=<same resolved value>`, positioned **after** the
   `EnvironmentFile=` line (ordering assertion — this is what guarantees the
   env file can't silently clobber it). This is the first automated coverage
   the Linux unit has ever had, closing CFW-279's explicitly-stated gap, and
   it runs on any host (mac dev box today, a real Linux CI runner later)
   without needing an actual Linux machine to exercise the *template
   rendering* logic (no `systemctl` call is ever made by this branch either
   way).
8. **Shellcheck-clean.** No new case needed — `scripts/lint.sh` already runs
   `shellcheck -S warning` over every file under `bin/`, `install/`, `test/`,
   `scripts/` as the last step of `test/run-tests.sh`; the new functions and
   any new test code must pass it same as everything else in the repo.
