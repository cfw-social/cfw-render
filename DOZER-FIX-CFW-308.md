# DOZER-FIX-CFW-308 — commit the Q4 fixture fix (prior build pass left it uncommitted)

## What happened

This is a second BUILD attempt. The first attempt produced the correct
two-line patch to `test/run-tests.sh` (exactly matching
`DOZER-DESIGN-CFW-308.md`'s prescribed patch) but left it as an **uncommitted**
working-tree edit — `HEAD` (`92c1c64`) still had Case Q4 in its original,
buggy form. The REVIEW pass caught this and failed the branch for it.

Prerequisite check from the design doc: `dozer/CFW-307`'s content
(`cr_resolve_worker_path`, `cr_probe_claude_headless`, Cases Q1–Q7) is already
present on this branch via merge commit `92c1c64` — confirmed by `grep -n
cr_probe_claude_headless test/run-tests.sh` finding both call sites before
this fix. No re-merge needed; this pass is purely the one-case patch plus
committing it.

## The fix

Both `cr_probe_claude_headless` call sites in Case Q4 (`test/run-tests.sh`,
success case and empty-output case) now pass the fallback-dir suffix
`:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin`, matching
`cr_resolve_worker_path`'s own fallback list and the shape Case Q3 already
uses successfully. This gives the stripped `env -i` probe a PATH that
actually contains `bash`, so `fake-claude.sh`'s `#!/usr/bin/env bash` shebang
resolves instead of failing with `env: bash: No such file or directory`
(rc=127) before the fixture's own logic ever runs.

No changes to `bin/cfw-render-lib.sh` or `test/fake-claude.sh` — this is a
fixture-only defect, as the design doc establishes.

## Test results

`./test/run-tests.sh` (includes the trailing `scripts/lint.sh`):
**105 PASS / 0 FAIL.**

- Case Q4 (both sub-cases) now passes — previously the lone failure
  (`cr_probe_claude_headless: success case — expected 0, got 1`), carried
  forward from CFW-307/CFW-297's FIX passes as a known, documented gap.
- No regressions: all other Q-cases (Q1, Q2, Q3, Q5, Q6, Q7), Case F, and
  the install.sh/Linux-unit cases (Q6/Q7 area) all pass.
- `scripts/lint.sh` clean — `bash -n` + `shellcheck -S warning`, zero
  findings across all scripts.

## Disposition

Green, zero failures, fix committed this time. Ready to serial-merge
`dozer/CFW-308` into `develop`.
