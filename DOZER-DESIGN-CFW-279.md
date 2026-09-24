# DOZER-DESIGN-CFW-279 — BYOA macOS: plist PATH omits `~/.local/bin`

## Root cause

`install/com.cfw.render.plist` hardcodes launchd's `EnvironmentVariables.PATH`:

```xml
<key>PATH</key>
<string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
```

launchd agents never source a login shell (`.zshrc`/`.zprofile`), so this string is
the *entire* PATH the drainer process sees — nothing a customer added on their own
machine leaks in. On a BYOA macOS box, the `claude` CLI is commonly installed via
the native installer or a user-level npm prefix, both of which land in
`~/.local/bin`, not in any of the four directories above.

Consequences, both already visible in `bin/cfw-render.sh`:

- `--dry`'s binary check (`cfw-render.sh:49`, `for b in curl python3 claude`) reports
  `FAIL binary:claude not on PATH`, so `install.sh`'s own post-install `--dry` gate
  (`install.sh:161`) refuses to leave the timer enabled — but if a box was installed
  before `claude` was on the hardcoded PATH and only later moved to `~/.local/bin`
  (or the installer ran interactively where PATH differed), the timer can already be
  loaded and every subsequent tick fails.
- The real tick's Director subshell (`cfw-render.sh:244`) does
  `export PATH="$SELF_DIR:$PATH"` — prepending the repo's own `bin/` but still
  inheriting whatever launchd handed it, so `claude` (invoked bare inside
  `claude_native_or_ollama_quota_fallback` / `claude_ollama_failover`,
  `cfw-render-lib.sh:536,568`) is never found. Every order fails at Director launch.

This is macOS-specific: the Linux path (`install/cfw-render.service`) has no
explicit `PATH=` override in `[Service]`, so it inherits systemd's own default
search path plus whatever `EnvironmentFile` sets — a different (already-tracked-
elsewhere) concern, out of scope here per the task title.

## Approach

Make the plist's PATH include the user's home-relative bin dirs, substituted the
same way `{{HOME}}` already is for the log paths — no new substitution mechanism
needed since `install.sh` already replaces `{{HOME}}` (`install.sh:136`).

1. **`install/com.cfw.render.plist`** — change the `PATH` value to prepend
   `{{HOME}}/.local/bin` (and, for the same reason, `{{HOME}}/bin` as a second
   common user-install location) ahead of the existing system dirs:
   ```xml
   <key>PATH</key>
   <string>{{HOME}}/.local/bin:{{HOME}}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
   ```
   `install.sh`'s existing `sed -e "s#{{HOME}}#$HOME#g"` (install.sh:136) already
   substitutes every `{{HOME}}` occurrence, so no script change is required to wire
   the value through — the plist is the only file whose *content* needs to change.
   Ordering matters: put the user-local dirs first so a customer's own `claude`
   install wins over any stray system copy, matching normal shell PATH convention
   (`$HOME/.local/bin` before system dirs).

2. **`install/install.sh`** — no functional change needed for the substitution
   itself, but add a one-line comment near the existing `sed` call (install.sh:136)
   noting that the plist's `PATH` now depends on `{{HOME}}` resolving to the
   *service user's* home, not the installer's, for parity with the worker-id
   resolution logic that already handles `RUN_USER != installer` (install.sh:118,
   `eval echo "~$RUN_USER"`). On macOS, `install.sh` never took a `--user` other
   than the running one for the LaunchAgent path (LaunchAgents are always
   per-logged-in-user, unlike the Linux `{{USER}}` systemd case), so `$HOME` at
   install time is already correct — this is a documentation-only addition to
   prevent a future regression if someone tries to add multi-user support here.

3. **`docs/deploy.md` / `install/byoa-installer-notes.md`** — add a short note
   under the BYOA install section: if `cfw-render.sh --dry` reports
   `FAIL binary:claude not on PATH` on a customer Mac, the fix is to confirm
   `claude` actually resolves at `~/.local/bin/claude` (or wherever `which claude`
   points when run in the customer's normal shell) and that the box has been
   reinstalled/re-bootstrapped since this fix (regenerating
   `~/Library/LaunchAgents/com.cfw.render.plist` from the updated template — an
   already-installed plist on a box is a static copy and won't pick up a template
   change until `install.sh` is re-run).

## Files to touch

- `install/com.cfw.render.plist` — the actual fix (PATH string).
- `install/install.sh` — one-line comment near the `{{HOME}}` sed (no behavior
  change).
- `docs/deploy.md` — troubleshooting note in the BYOA/macOS section.
- `install/byoa-installer-notes.md` — cross-reference to the same note (thin
  pointer doc, per its existing style).

No changes to `bin/cfw-render.sh` or `bin/cfw-render-lib.sh` — their PATH-dependent
binary checks and `claude` invocations are already correct; they only fail today
because of what launchd hands them.

## Edge cases

- **Box has no `~/.local/bin` at all** (customer never installed anything there):
  harmless — `command -v claude` still falls through to the system dirs exactly as
  before; adding a nonexistent directory to `PATH` is a no-op in bash's lookup.
- **Fleet (`hst`) install, `--mode server`**: `hst` is Linux (systemd), not macOS —
  this plist path is never rendered for it, so the fix is BYOA/macOS-only by
  construction, matching the ticket title. No risk of touching the production
  fleet path.
- **Already-installed BYOA boxes**: changing the template does not retroactively
  fix a box whose `~/Library/LaunchAgents/com.cfw.render.plist` was already
  written by an older `install.sh` run. That's why the docs note (§3 above) calls
  out re-running `install.sh` (or manually re-rendering + `launchctl bootout` +
  `bootstrap` to reload) as part of the fix rollout — this is an operational step,
  not something the code change can do on its own.
- **`claude` installed via multiple methods** (e.g. both an old Homebrew formula
  and a newer native `~/.local/bin` install): putting `{{HOME}}/.local/bin` first
  means the native/user install always wins, which matches how a customer's own
  interactive shell would resolve `claude` (assuming their shell's PATH also
  prefers `~/.local/bin` first, which is the native installer's own convention).
- **`{{HOME}}/bin` doesn't exist for most users**: included defensively since it's
  a common alternate convention (e.g. some pipx/pyenv setups); zero cost if unused.

## How it gets tested

No unit-test harness exists for the plist itself (`test/run-tests.sh` covers
`cfw-render.sh`/`cfw-render-lib.sh` shell logic against `test/fake-*.sh` stubs, not
launchd XML). Verification is manual/operational, consistent with how this repo
already gates deploys (`docs/deploy.md` §4 "Dry-run validation" is human-run):

1. **Template substitution sanity** — run the existing
   `sed -e "s#{{PREFIX}}#...#g" -e "s#{{ENV_FILE}}#...#g" -e "s#{{HOME}}#$HOME#g"`
   line from `install.sh` against the edited plist and `plutil -lint -` the result,
   confirming `{{HOME}}` resolves in the new `PATH` value exactly as it already does
   in `StandardOutPath`/`StandardErrorPath` — no new placeholder syntax introduced,
   so this is a low-risk mechanical check.
2. **Fresh macOS BYOA install** (the realistic repro): on a Mac where `claude`
   only resolves via `~/.local/bin` (verify with `which claude` in a plain, non-
   login-shell context, e.g. `env -i PATH=/usr/bin:/bin claude` should fail, but
   `env -i PATH=$HOME/.local/bin:/usr/bin:/bin claude` should succeed), run
   `install/install.sh --mode byoa --prefix <tmp> --env-file <tmp env>` and confirm
   the final `--dry` step (install.sh:161) reports `PASS binary:claude found`
   instead of today's `FAIL`.
3. **launchd-exact repro** — load the rendered plist with
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cfw.render.plist`
   and `launchctl kickstart -k` a single tick, then check
   `~/Library/Logs/cfw-render.out.log`/`.err.log` for a clean `claude` invocation
   rather than a `command not found`/PATH-related error — this is the actual
   failure mode the ticket reports ("every scheduled render Director fails
   headless"), so this is the check that proves the fix addresses the real
   symptom, not just the `--dry` proxy.
4. **Regression check on existing dirs** — confirm `--dry` still PASSes on a box
   where `claude` lives in `/opt/homebrew/bin` (Homebrew-installed, the other
   common case) to prove the fix is additive and doesn't reorder existing
   resolution for boxes that already worked.
