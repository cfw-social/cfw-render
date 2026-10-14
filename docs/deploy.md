# cfw-render — running it on an owner's computer

cfw-render runs **only on the brand's own computers** (owner decision D118):
each person installs it on their Mac with a render-worker key from the brand's
settings in cfw-social (sent as the `cfw-render-key` header). CFW runs no render
server; the old server runbook (systemd units, master-key fleet-enable, the
`hst` box) was removed with it. Install steps: README "Installing on an owner's
computer" and `install/byoa-installer-notes.md`; most owners use the desktop app.

## 1. Install and dry run

```bash
bin/cfw-render-preflight.sh          # every tool present → PREFLIGHT: PASS
install/install.sh --mode byoa       # copies the app, writes the LaunchAgent, runs --dry
"$HOME/CFW Render/app/bin/cfw-render.sh" --dry
```

`--dry` claims nothing. All rows must PASS before loading the LaunchAgent;
`install.sh` exits non-zero on FAIL rather than leaving a broken install.

## 2. Worker PATH is resolved, not guessed (CFW-291)

`install.sh` walks every binary a recipe needs (`curl python3 node npx ffmpeg
ffprobe magick claude`), resolves each with `command -v` **in the shell you run
it from**, and writes that `WORKER_PATH` into `com.cfw.render.plist`. Run it
from a normal login shell where `which claude` resolves. It also proves
`claude` actually runs under that PATH in a stripped environment (`env -i`, the
same narrow environment launchd hands a scheduled tick); a `claude` that only
works through shell functions/aliases/init hooks makes the install abort,
printing the PATH, the probe output and what to fix. If `--dry` later reports
`FAIL binary:claude not on PATH`, something moved — re-run `install/install.sh`.

## 3. Known gap — expired-lease requeue (do not paper over)

Neither worker MCP tool can reclaim an order stuck in `claimed`/`rendering`
with an expired lease, and there is no `requeue_render_order` tool yet
(`implementation-plan.md` §0.4). Consequences:

- **Director timeout/crash while the drainer is alive** → fully handled; the
  drainer holds a live lease and calls `block_render_order` itself. This is
  the dominant failure mode and works today.
- **Drainer death mid-render** (power loss, SIGKILL) → the order strands in
  `claimed` with an expired lease and nothing currently reclaims it.

**Reading `journal.tsv`'s `outcome` column (CFW-286):** `crashed` and
`orphaned` are NOT the same failure — don't treat them interchangeably when
triaging. `crashed` means the Director process itself exited with a nonzero
code (bad exit, uncaught exception, OOM) — a real toolchain/computer problem.
`orphaned` means the Director exited cleanly (rc=0) but never called
`complete`/`block` — it backgrounded a step (a trailing `&`, `run_in_background:
true`, a detached upload/encode) and ended its turn before that step
finished, which `lib/director-prompt.md` explicitly forbids. A nonzero
`orphaned` rate points at a Director-side prompt-adherence regression, not a
toolchain issue — spot-check that order's transcript
(`~/CFW Render/logs/runs/<orderId>-<ts>.out`) for a backgrounded tool call
before assuming it's an infra problem.

**Follow-up:** a ~5-line cfw-social change (extend the worker-claim CAS WHERE
to also take `status IN ('claimed','rendering','gating') AND
lease_expires_at < now()`), or a dedicated `requeue_render_order` tool. Filed
as `AB-RNDR-REQUEUE` (repo: cfw-social) — see that task file for the exact
scope. Until it lands, `cfw-render-ctl.sh unblock <orderId>` fails fast with
the admin SQL to run manually rather than silently no-opping.

## 4. Bundled skills

This repo carries its own pinned `skills/` (README "Bundled skills").
`install.sh` copies it into the app folder and the worker uses it when
`CFW_RENDER_SKILLS_DIR` is unset. To verify: `--dry` shows the `skills:pinned`
row with the expected `sourceSha` + recipe count, and
`scripts/verify-skills-bundle.sh` exits 0.

## 5. Key rotation

Issue a new render-worker key for the computer in the brand's settings in
cfw-social, put it in `~/.cfw-render/cfw-render.env` (`CFW_RENDER_WORKER_KEY`,
chmod 600) or re-enter it in the desktop app, then revoke the old key. The next
tick picks up the new value; no code change.
