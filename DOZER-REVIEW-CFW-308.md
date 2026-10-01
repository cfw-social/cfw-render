VERDICT: FAIL

## Why

The actual fix is correct in shape but was never committed to this branch. `HEAD`
(`92c1c64`, "Merge branch 'dozer/CFW-307' into dozer/CFW-308") still contains Case
Q4 in its original, buggy form:

```
$ git show HEAD:test/run-tests.sh | grep -n cr_probe_claude_headless
...
1104:  cr_probe_claude_headless "$q4_tmp"
...
1123:  cr_probe_claude_headless "$q4_empty"
```

Both calls are missing the `:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin` suffix
that `DOZER-DESIGN-CFW-308.md` specifies as the fix. The only place that suffix
exists is an **uncommitted** working-tree edit to `test/run-tests.sh` (`git status`
shows `M test/run-tests.sh`; `git diff` shows exactly the two-line patch the design
doc describes). There is no `DOZER-FIX-CFW-308.md` and no fix commit on this branch.

If `dozer/CFW-308` were serial-merged into `develop` right now, Case Q4 would still
fail with the exact root cause this ticket exists to fix — confirmed by direct
reproduction:

```
$ bash -c '
tmp=$(mktemp -d); cp test/fake-claude.sh "$tmp/claude"; chmod +x "$tmp/claude"
source bin/cfw-render-lib.sh
cr_probe_claude_headless "$tmp"                                                  # committed (unfixed) call shape
echo rc=$?
cr_probe_claude_headless "$tmp:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"   # the fix, currently only uncommitted
echo rc=$?
'
claude --version failed under a headless probe (env -i, rc=127)
captured output: env: bash: No such file or directory
rc=1
fake-claude: ok (--version)
rc=0
```

So: the design's root-cause analysis is correct, the prescribed patch is correct and
does fix the bug when applied — but the build/fix pass never actually committed it.
The committed diff this review was handed (`develop..HEAD`) must have been generated
against a working tree that included this uncommitted edit, which does not reflect
what's actually on the branch. Reviewing committed state only (the only thing that
can be merged), the ticket's one deliverable is missing.

## Secondary note (not independently blocking, but worth flagging for the fix pass)

The merge commit `92c1c64` correctly brought in `dozer/CFW-307`'s content (CFW-291 +
CFW-292 + CFW-286 + CFW-299), matching `DOZER-DESIGN-CFW-308.md`'s "Prerequisite"
section — `cr_resolve_worker_path`/`cr_probe_claude_headless` and Cases Q1-Q7 are
present and otherwise intact (Q1, Q2, Q3, Q5 unaffected; Q4's two sub-cases are the
only gap). So the only outstanding work is: commit the already-correct two-line
`test/run-tests.sh` edit (and add whatever `DOZER-FIX-CFW-308.md` this repo's
pipeline expects), then re-run the suite to confirm Q4 now passes with no
regressions elsewhere.
