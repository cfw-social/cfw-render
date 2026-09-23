VERDICT: PASS

## Summary

The build matches the design doc exactly: one functional line changed
(`install/com.cfw.render.plist`'s `PATH`), plus a comment and two docs notes.
No changes to `bin/cfw-render.sh` / `bin/cfw-render-lib.sh`, as the design
doc said were unnecessary.

## Verification performed

1. **Diff matches design.** `git diff develop..HEAD --stat` shows exactly the
   5 files the design doc's "Files to touch" section named (plus the design
   doc itself). Working tree is clean — nothing outside `DOZER-DESIGN-*.md`
   / the intended files was touched.

2. **The fix is correct.** `install/com.cfw.render.plist`'s `PATH` is now
   `{{HOME}}/.local/bin:{{HOME}}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin`
   — user-local dirs prepended ahead of system dirs, matching normal shell
   PATH convention and the design's stated ordering rationale.

3. **Substitution wiring needs no code change, confirmed.** `install.sh`'s
   existing `sed -e "s#{{PREFIX}}#$PREFIX#g" -e "s#{{ENV_FILE}}#$ENV_FILE#g"
   -e "s#{{HOME}}#$HOME#g"` (install.sh:136) already replaces every
   `{{HOME}}` occurrence in the plist, so the new PATH value is substituted
   for free. Verified by rendering the plist with a test `$HOME` and running
   `plutil -lint` on the result: `OK`, and the `{{HOME}}` tokens correctly
   became the substituted path.

4. **Linux out-of-scope claim verified.** `grep -n "PATH" install/cfw-render.service` — no match, confirming the systemd unit has no explicit PATH override, so this fix is correctly scoped to the Darwin/BYOA case only, per the ticket title.

5. **`--dry` binary-check claim verified.** `bin/cfw-render.sh:49` does
   `for b in curl python3 claude; do ... command -v "$b"` — a bare `command
   -v claude` lookup that depends entirely on inherited `PATH`, confirming
   the root-cause chain the design doc describes (launchd's literal PATH →
   `--dry` FAIL / real tick failure) is accurate.

6. **install.sh comment is correct and honest** — it documents that `$HOME`
   at install time already resolves correctly for the LaunchAgent case
   (no `RUN_USER` mismatch like the Linux `{{USER}}` path), and makes no
   functional claim beyond that.

7. **Docs additions are consistent** — `docs/deploy.md` and
   `install/byoa-installer-notes.md` both correctly note that an
   already-installed plist is a static copy and needs `install.sh` re-run
   (or manual re-render + reload) to pick up the fix — an important
   operational caveat that keeps the fix from being silently incomplete in
   the field.

## Notes (non-blocking)

- No automated test covers plist content (confirmed: `test/run-tests.sh`
  targets shell logic only) — the design doc is upfront about this and
  proposes manual verification steps instead, which is consistent with how
  this repo already gates deploys (`docs/deploy.md` dry-run step is
  human-run). Acceptable for a template-only change.
- The design doc's step 2 (install.sh comment) and step 3 (docs) were both
  followed faithfully in content and placement.

No correctness, security, or scope issues found. Fix is minimal, additive,
backward-compatible (nonexistent `~/.local/bin`/`~/bin` dirs are harmless
no-ops in PATH lookup), and directly addresses the reported symptom.
