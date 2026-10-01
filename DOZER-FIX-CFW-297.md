# DOZER-FIX-CFW-297 — verification pass (no code changes)

Per `DOZER-DESIGN-CFW-297.md`: CFW-291's landing onto `dozer/CFW-297` already
happened via commit replay (`3bc7a69`, `d230063`); this pass's only job was
to run the full suite and confirm CFW-291 and CFW-292 coexist without
regression. **No code changes made.**

## Result

`./test/run-tests.sh` (full run, includes `scripts/lint.sh` tail):

- **PASS: 73  FAIL: 1**
- Wall clock: 2m43s — well inside the 900s test-gate budget CFW-292 exists
  to protect.
- No orphaned processes after the run (`pgrep -fl cfw-render` empty) — the
  specific regression class CFW-292 fixed did not reappear.
- All pre-existing cases (1 through P, including Case 2e/auto-upload and the
  watchdog/orphan cases) PASS — CFW-292's kill-tree fix is intact.
- Cases Q1, Q2, Q3, Q5, Q6, Q7 (6 of CFW-291's 7 new cases) PASS.
- `scripts/lint.sh` clean (`bash -n` + `shellcheck -S warning` on every
  script).

## The one failure — pre-existing in CFW-291, not a merge regression

**Case Q4, first sub-case** (`cr_probe_claude_headless: success case —
expected 0, got 1`), `test/run-tests.sh:839-843`.

**Root cause:** the test copies `test/fake-claude.sh` (shebang
`#!/usr/bin/env bash`) into an empty temp dir and calls
`cr_probe_claude_headless "$q4_tmp"` directly — bypassing
`cr_resolve_worker_path()`, which is what normally appends the static
fallback dirs (`/usr/local/bin /usr/bin /bin /opt/homebrew/bin`) that
contain `bash`. Inside the function, `env -i PATH="$q4_tmp" ... claude
--version` strips PATH to just that one directory, so when the kernel runs
the script's `#!/usr/bin/env bash` shebang, `env` itself can't resolve
`bash` on the stripped PATH → `env: bash: No such file or directory`, rc=127
→ the function's own `(( rc == 0 ))` check fails → returns 1. This is
deterministic on any machine; it is not a flake and not host-specific
(confirmed via direct reproduction, see below).

**Confirmed pre-existing and unrelated to this carrier's merge:**
- `test/run-tests.sh`'s Q4 block and `bin/cfw-render-lib.sh`'s
  `cr_probe_claude_headless`/`cr_resolve_worker_path` are **byte-identical**
  between `dozer/CFW-291` tip (`54b0a80`) and current HEAD (`d230063`) —
  diffed directly, only line-number offsets from later cases inserted
  before Q4 and the unrelated CFW-289 vault-path lines.
- Reproduced the exact failure (`env: bash: No such file or directory`,
  rc=127) by extracting a pristine `dozer/CFW-291` tree into an isolated
  `/tmp` dir and running the same `env -i PATH=<tmp> claude --version`
  sequence with no `develop`/CFW-292 code present at all.
- CFW-292 does not touch `test/run-tests.sh`, `cr_probe_claude_headless`, or
  `cr_resolve_worker_path` (confirmed disjoint in the design doc's file-region
  analysis) — there is no code path by which merging CFW-292 could have
  introduced this.

**Production impact:** none expected. Every real caller (`install.sh`'s
gate) builds `worker_path` via `cr_resolve_worker_path()` first, which
always appends the static fallback dirs — one of which contains `bash` on
every supported host. Only this unit test's direct, narrowed invocation of
`cr_probe_claude_headless` hits the gap. This is a test-fixture bug in
CFW-291's own Q4 (bad test setup, not a probe-logic defect), but per the
design doc's "No code changes" constraint, fixing it is out of scope for
this carrier.

## Disposition

Per design doc §Approach step 3 ("No code changes... If the test run
surfaces an actual bug, that is out of scope for CFW-297 and should be spun
out as its own issue rather than patched inline here"): **not patched
here.** Recommend a new Linear issue against CFW-291's Q4 test (fix the test
fixture to route through `cr_resolve_worker_path()`, or copy a `bash`-free
fake claude, or add `bash`'s dir to the probed PATH) — `lane:dev`,
`repo:cfw-render`, laddered under the same Milestone CFW-291 was.

This carrier's actual job — verifying CFW-291 and CFW-292 coexist on
`develop` without regression — is **done and clean**: 100% of the assertions
that exercise the merge boundary (all pre-existing cases, all of CFW-292's
watchdog/orphan cases, 6 of 7 new Q-cases) pass; the one failure is isolated,
proven pre-existing, and orthogonal to the merge.
