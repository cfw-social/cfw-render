# DOZER-FIX-CFW-307 — land dozer/CFW-297 (CFW-291+CFW-292) across CFW-286+CFW-299

## What happened

`git merge dozer/CFW-297` into `dozer/CFW-307` (then at `develop` tip
`005fef0`), exactly as designed. One conflict, `README.md`, matching the
design's prediction precisely — resolved by hand, keeping both additions
(CFW-286's `outcome=orphaned` blurb + CFW-291's `cr_resolve_worker_path`/
`cr_probe_claude_headless`/install.sh blurb). `bin/cfw-render-lib.sh`,
`docs/deploy.md`, and `test/run-tests.sh` auto-merged clean, zero conflict
markers anywhere in the tree (`grep -rn '^<<<<<<<\|^=======\|^>>>>>>>'`
confirmed empty post-merge).

Merge commit: `e836409` — "merge dozer/CFW-297 into dozer/CFW-307 — #CFW-307
land CFW-291+CFW-292 content across CFW-286+CFW-299".

## Insertion-point spot-check (design step 5)

```
485:cr_kill_tree()                  — CFW-292
585:cr_is_native_claude_model()     — CFW-299
599:claude_fanout_run()             — CFW-299
750:cr_resolve_worker_path()        — CFW-291
794:cr_probe_claude_headless()      — CFW-291
```

Five disjoint functions, no duplicate names — matches the design's
predicted insertion points exactly.

## Test results

`./test/run-tests.sh` (includes the trailing `scripts/lint.sh`):
**86 PASS / 1 FAIL.**

- The 1 failure is Case Q4's first sub-case (`cr_probe_claude_headless:
  success case — expected 0, got 1`) — the same pre-existing CFW-291
  test-fixture bug CFW-297's own FIX pass root-caused (`env -i` strips PATH
  to a `bash`-free temp dir because the test bypasses
  `cr_resolve_worker_path()`'s fallback dirs). Confirmed reproducing
  identically post-merge: same failure message, same isolated sub-case, no
  change in blast radius. Per the design doc's edge case, carried forward
  rather than fixed inline (carrier scope) or silently ignored.
- All of CFW-286's and CFW-299's own cases continue to pass.
- All of CFW-291's other 6 Q-cases (Q1, Q2, Q3, Q4's second sub-case, Q5,
  Q6, Q7) pass.
- New total: 87 cases (up from CFW-297's own 74), reflecting `develop`'s
  growth from CFW-286 (Case 4a/4b) and CFW-299 (Case F) landing since
  CFW-297's base.
- `scripts/lint.sh` clean — `bash -n` + `shellcheck -S warning` on every
  script, zero findings.
- One harmless pre-existing shell artifact noted during the run: `./test/
  run-tests.sh: line 522: needs: command not found` (an unquoted backtick
  inside an `echo` string in a section header, byte-identical on `develop`
  tip `005fef0` before this merge — not introduced here, doesn't affect any
  assertion).

## Orphan-process check

`pgrep -fl cfw-render` after the run returned only a pre-existing,
unrelated background log-tail watcher (`tail -n0 -F
~/.cfw-render/cfw-render.log | grep ...`) from an entirely separate
monitoring session — not a render worker, not spawned by this test run. No
`cfw-render-lib.sh`/`cfw-render-subagent.sh` process left running. This
merge concentrates four branches' worth of process-lifecycle code
(`cr_kill_tree`, background-work reaping, `claude_fanout_run`,
`cr_probe_claude_headless`) into one file with no observed interaction
between them, consistent with the design's disjoint-region analysis.

## Q4 follow-up issue — filed

The design's edge case asked to verify (not assume) a follow-up Linear
issue against CFW-291's Q4 fixture exists. It did not — CFW-297's FIX pass
only recommended one. Filed now: **CFW-308** — "[ENG] CFW-291 Q4 test
fixture: cr_probe_claude_headless success-case bypasses
cr_resolve_worker_path, env -i can't find bash" — laddered under the same
Project (`CFW: Paste-to-install`) and Milestone (`KR: brand key → probe
render completes with zero human steps`) as CFW-291 itself, labeled
`lane:dev` + `repo:cfw-render` + `Bug`. Left untriaged/un-greenlit —
triage and `dozer:ready` are the Dev-Director's call, not this pass's.

## Disposition

Green modulo the one documented, carried-forward, pre-existing failure —
matching the precedent CFW-297's own FIX pass already established. Ready
to serial-merge `dozer/CFW-307` into `develop`.
