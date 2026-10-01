# DOZER-DESIGN-CFW-308 — CFW-291 Q4 test fixture: `cr_probe_claude_headless` success-case bypasses `cr_resolve_worker_path`, `env -i` can't find bash

## Root cause (confirmed by reproduction)

`cr_probe_claude_headless` (CFW-291, `bin/cfw-render-lib.sh`) runs its probe in a
fully stripped environment:

```sh
out="$(env -i "${env_args[@]}" claude --version 2>&1)"
```

where `env_args` sets `PATH=$worker_path` and nothing else that isn't on an
explicit allow-list. `worker_path` defaults to a fresh `cr_resolve_worker_path`
call, which always appends four static fallback dirs
(`/usr/local/bin /usr/bin /bin /opt/homebrew/bin`) in addition to whatever dirs
it resolves real tools into.

Case Q4 in `test/run-tests.sh` (`cr_probe_claude_headless` success case) does
**not** go through that default — it builds a bare `mktemp -d`, copies
`test/fake-claude.sh` into it, and calls the function with that single
directory as an explicit `worker_path` argument:

```sh
q4_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$q4_tmp/claude"
chmod +x "$q4_tmp/claude"
( source "$REPO_DIR/bin/cfw-render-lib.sh"; cr_probe_claude_headless "$q4_tmp" ) >/dev/null 2>&1
```

`fake-claude.sh` (and the empty-output fixture built inline a few lines later)
is itself a bash script: `#!/usr/bin/env bash`. The kernel execs `/usr/bin/env`
directly (absolute path, no PATH lookup needed for that step), but `env` then
has to resolve the literal word `bash` **using the PATH it was just told to
use** — `$q4_tmp`, which contains nothing but `claude`. Reproduced directly:

```
$ env -i PATH=/tmp/q4test /tmp/q4test/claude --version
env: bash: No such file or directory      # rc=127
$ env -i PATH=/tmp/q4test:/bin /tmp/q4test/claude --version
fake-claude: ok (--version)               # rc=0
```

So the probe fails before `fake-claude.sh`'s own logic ever runs — not because
`cr_probe_claude_headless` is broken, but because the **fixture handed it an
unrealistic `worker_path`** that no real caller would ever construct (every
real caller either omits the argument, going through `cr_resolve_worker_path`,
or — as Case Q3 already does correctly — appends the system fallback dirs by
hand). This is a test-fixture bug, not a production bug; `DOZER-FIX-CFW-307.md`
and the CFW-297 FIX pass already root-caused it the same way and deliberately
left it for a dedicated follow-up, which is this issue.

**Bonus finding:** the second Q4 sub-case (`q4_empty`, the "empty output is
still a FAIL" check) has the *same* defect — `cr_probe_claude_headless
"$q4_empty"` also hits `env: bash: No such file or directory` before the
empty-output logic ever executes. It currently reports PASS anyway, by
accident: the sub-case asserts `rc != 0`, and a 127-from-exec-failure
satisfies that assertion just as well as the intended "ran, printed nothing,
still fails" path would. It is not actually testing what its own name and
comment claim. This gets fixed in the same pass since it's the same root
cause in the same test case.

## Prerequisite — this code does not exist on this branch yet

`dozer/CFW-308` (this worktree) branches from `develop@005fef0`. `cr_resolve_worker_path`,
`cr_probe_claude_headless`, `test/fake-claude-env-dependent.sh`, and Case
Q1–Q7 all live on `dozer/CFW-307` (CFW-291's content, replayed/merged there
per `DOZER-FIX-CFW-307.md`), which has **not** been merged into `develop`.
Confirmed: `git merge-base --is-ancestor dozer/CFW-307 HEAD` → false; `git log
HEAD..dozer/CFW-307` lists the CFW-291/CFW-297/CFW-307 commits, none of which
are reachable from this branch.

**The FIX pass cannot write this patch against the current worktree tree —
`bin/cfw-render-lib.sh` and `test/run-tests.sh` here have zero occurrences of
either function name.** Before touching anything, the FIX pass must confirm
which of the following is true at run time and proceed accordingly (fail fast
if neither holds — do not silently fabricate the missing functions):

1. `dozer/CFW-307` has by then been merged into `develop` and this branch has
   been rebased/updated onto the new `develop` tip → the normal single-file
   edit below applies directly.
2. `dozer/CFW-307` is still unmerged → the FIX pass must first merge
   `dozer/CFW-307` into `dozer/CFW-308` (same mechanical, conflict-light merge
   `DOZER-FIX-CFW-307.md` already performed once: expect at most the same
   trivial `README.md` conflict it recorded, auto-merge elsewhere), *then*
   apply the Q4 fix on top. This must be called out explicitly in whatever
   fix/review doc follows — it is scope beyond "edit one test case" and
   should not be silently absorbed without a note.

The rest of this design assumes the code is present (either path above) and
describes the actual one-case patch.

## Approach

Make Case Q4's `worker_path` realistic, using the same fix shape Case Q3
already proves out successfully one case earlier in the same file: append the
system fallback dirs so a dir containing `bash` is always on the stripped
PATH, instead of handing the probe a single-binary directory in isolation.

Use the **full** four-dir fallback list from `cr_resolve_worker_path` itself
(`/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin`), not Q3's three-dir subset
— Q3's `/usr/local/bin:/usr/bin:/bin` happens to work on this machine because
`/bin/bash` exists, but a locked-down macOS box or a container image that only
ships Homebrew's bash would need `/opt/homebrew/bin` too. Matching the real
function's fallback list exactly also means if that list ever changes, the
two test cases keep failing (or passing) together instead of drifting apart.

### Patch (both Q4 sub-cases), once Case Q4 exists in this tree

```sh
echo "=== Case Q4: cr_probe_claude_headless — success case, and empty-output-is-still-a-failure ==="
q4_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$q4_tmp/claude"
chmod +x "$q4_tmp/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_tmp:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
) >/dev/null 2>&1
q4_rc=$?
...
q4_empty="$(mktemp -d)"
cat > "$q4_empty/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
exit 0
FAKECLAUDE
chmod +x "$q4_empty/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_empty:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
) >/dev/null 2>&1
q4_empty_rc=$?
```

Only the two `cr_probe_claude_headless "$q4_tmp"` / `"$q4_empty"` call sites
change — append the fallback-dir suffix. Everything else in Case Q4
(`pass`/`fail` assertions, comments, cleanup) stays as-is; the assertions
already encode the right expected outcome for each sub-case, they just
weren't being exercised correctly.

### Alternative considered, and rejected

Call `cr_probe_claude_headless` with **no** argument after prepending `q4_tmp`
to the real `$PATH` (mirroring how Case Q2 exercises `cr_resolve_worker_path`
by mutating `PATH` and calling the function bare), so the test runs through
the actual default `cr_resolve_worker_path` call end-to-end. This is arguably
*more* faithful to production (it exercises the real default-arg code path,
which the explicit-argument patch above does not), but it was rejected for
this fix:

- It makes Q4's pass/fail depend on whatever real `curl`/`python3`/`node`/
  `ffmpeg`/`magick` happen to resolve to **on the host running the suite** —
  nondeterministic across machines/CI images, where the hand-picked fallback
  list is not.
- It's a bigger behavioral change to a passing-by-coincidence test than the
  bug calls for. The minimal fix is the literal one CFW-297's FIX pass
  diagnosed and recommended: give the probe a realistic PATH, the same shape
  Q3 already uses successfully.

If a future issue wants a test that specifically exercises the *default-arg*
`cr_resolve_worker_path` branch of `cr_probe_claude_headless` end-to-end,
that's a new, additive Q-case — not a change to Q4.

## Files to touch

- `test/run-tests.sh` — Case Q4 only, two call sites (success case and
  empty-output case), once that case exists in this tree (see Prerequisite).
- No changes to `bin/cfw-render-lib.sh` — `cr_resolve_worker_path` and
  `cr_probe_claude_headless` are working as designed; this is purely a
  fixture defect.
- No changes to `test/fake-claude.sh` or the empty-output inline fixture —
  both are fine as-is; it's the PATH handed to the probe that's wrong, not
  the fake binaries.

## Edge cases

1. **Prerequisite branch gap (see above)** — the dominant risk for this
   issue. A FIX pass that doesn't check for `cr_probe_claude_headless`'s
   existence first and instead "helpfully" reimplements it from this design
   doc's quoted source would silently diverge from CFW-291's real
   implementation (and get overwritten/conflicted the moment CFW-307 actually
   merges). Fail fast and merge CFW-307 in first if needed — do not
   reconstruct the function from the quotes in this doc.
2. **Host without `/opt/homebrew/bin`** (Linux CI, Intel Mac without
   Homebrew) — harmless: `cr_resolve_worker_path`'s own loop silently skips
   fallback dirs that don't exist or don't contain a hit; appending a
   nonexistent dir to a `PATH` string is a no-op for lookup purposes, not an
   error.
3. **A host where `bash` isn't in any of the four fallback dirs at all**
   (e.g., bash installed only via `nvm`-style user-local shims) — would still
   fail Q4, but that's no longer a *fixture* bug, it's a real gap in
   `cr_resolve_worker_path`'s fallback list and out of scope for this issue
   (the function's existing fallback list is also what Case Q2 already
   asserts against, so widening it is a separate, deliberate change, not a
   side effect of a test fixture fix).
4. **Q3 keeps using its narrower 3-dir list** — intentionally left alone.
   Q3's point is the *env-dependent* failure (`FAKE_NVM_DIR` stripped), and
   it already passes; touching it is out of scope and would be an unrelated
   diff in a fix meant to be surgical.
5. **Don't accidentally make Q4 pass for the wrong reason again** — the fix
   must be verified by confirming the probe actually reaches `fake-claude.sh`'s
   own `exit 0` (success case) and the empty-output script's own `exit 0`
   with nothing printed (empty case), not just that the final `rc` matches.
   See Testing below for how to check that directly.

## How it gets tested

1. **Preconditions check** — `grep -n "cr_probe_claude_headless\|cr_resolve_worker_path" bin/cfw-render-lib.sh test/run-tests.sh` must return matches before editing anything (see Prerequisite). If empty, merge `dozer/CFW-307` into this branch first (or wait for it to land in `develop` and rebase), and note that extra step in the fix doc.
2. **Reproduce first** — run `./test/run-tests.sh` (or isolate with `grep -A5 "Case Q4"`) before the patch and confirm the first Q4 sub-case fails with `expected 0, got <nonzero>`, matching `DOZER-FIX-CFW-307.md`'s reported failure. This confirms the repro before claiming a fix.
3. **Isolated repro outside the suite** (fast signal, no need to run the full ~900-line file):
   ```sh
   tmp=$(mktemp -d); cp test/fake-claude.sh "$tmp/claude"; chmod +x "$tmp/claude"
   source bin/cfw-render-lib.sh
   cr_probe_claude_headless "$tmp"; echo "old-style rc=$?"             # expect nonzero (bug)
   cr_probe_claude_headless "$tmp:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"; echo "fixed rc=$?"  # expect 0
   rm -rf "$tmp"
   ```
4. **Apply the patch**, then rerun `./test/run-tests.sh` in full. Expect all previously-passing cases to stay green and Case Q4's both sub-cases to PASS (87/87, up from the 86/87 recorded in `DOZER-FIX-CFW-307.md` — assuming no other unrelated regressions have landed on `develop`/`CFW-307` in the meantime; the FIX pass should re-baseline the total count at run time rather than hardcoding 87).
5. **Confirm the empty-output sub-case tests what it claims**, not just that
   its `rc` happens to be nonzero: temporarily change the empty fixture's
   `exit 0` to `exit 1` and rerun just that sub-case — it should still report
   nonzero (trivially true either way), so that alone doesn't prove much;
   the real check is adding a temporary `echo "unexpected output"` before
   `exit 0` in the empty fixture and confirming Q4's success-case-style
   assertion (`rc == 0`) would now flip — i.e., prove the probe is actually
   executing the fixture's logic post-fix (reaching the exit code it returns)
   rather than failing at `env`'s bash lookup regardless of what the fixture
   does. Revert the temporary fixture edit before finishing.
6. **`scripts/lint.sh`** — `bash -n` + `shellcheck -S warning` on
   `test/run-tests.sh`, zero findings (per the project's existing test-gate
   convention, run at the end of `./test/run-tests.sh` already).
7. **No orphan processes** — `pgrep -fl cfw-render` after the run should show
   nothing new (standard check this repo's prior CFW-286/CFW-292/CFW-307
   passes already perform; this fix doesn't touch process lifecycle at all,
   but the convention is cheap to keep).
