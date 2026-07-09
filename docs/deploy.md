# cfw-render — supervised deploy runbook

> **This runbook is for a human/attended session only.** AB-RNDR-WORKER (the
> unattended dev task that authored this repo) explicitly did NOT run any of
> these steps against the live box `hst` (31.97.140.100) — that box runs 9
> production brand gateways and must not be touched by an unattended agent.
> See the task's "SUPERVISED FOLLOW-UP GATE" for the authorization boundary.

## 0. Prerequisites

- SSH access to the render worker host (`hst` today; the worker is
  host-agnostic per `cfw-render-worker-plan.md` "Open items").
- `~/.gsai/secrets/cfw-render.env` populated (§5 of
  `cfw-social/docs/render-worker-auth.md`) with `CFW_RENDER_WORKER_KEY` +
  `CFW_API_BASE`.
- Vercel env `CFW_RENDER_WORKER_KEY` set on prod (matching value) and
  cfw-social redeployed.

## 1. Pre-flight (operator's machine, never unattended)

1. Mint/verify the render-worker key per `render-worker-auth.md` §5.1–5.2.
2. Confirm the Vercel env is live (`vercel env ls`) and cfw-social has been
   redeployed since the key was set.
3. Confirm `~/.gsai/secrets/cfw-render.env` has the matching key, chmod 600.

## 2. REQUIRED CHECKS — confirm scratch root + CFW Media path on the live box

These two checks are acceptance criteria for the deploy, not optional:

1. **Scratch root.** SSH to the box, run `df -h` and pick a volume with
   headroom for video intermediates. Set `CFW_RENDER_SCRATCH` in
   `/etc/cfw-render.env` to that path (default in the example is
   `$HOME/cfw-render-scratch` — override it).
2. **CFW Media render path.** Upload a small probe file through
   `POST /api/v1/render/upload` against a throwaway **claimed** order (create
   one via a test `submit_render_order` call from an attended Hermes session,
   claim it manually with `claim_render_order`, then run
   `cfw-render-upload.sh <probe-file>` with `CFW_ORDER_ID`/`CFW_WORKER_ID` set
   to that order). Confirm the returned `cdnUrl` resolves and contains
   `brands/<brandId>/renders/<orderId>/`.

Do not proceed to §3 until both checks pass.

## 3. Install as a separate service pool

Run `install/install.sh` on the box (NOT run by this task):

```bash
./install/install.sh --prefix /opt/cfw-render --env-file /etc/cfw-render.env --user <svc-user>
```

This must NOT share unit names, tmux sessions, or a working directory with
any `cfw-gw@<slug>` gateway unit — cfw-render is a decoupled service pool
(plan §11 "Cutover"). See `install/provisioner-snippet.md` for wiring it into
reprovision.

## 4. Dry-run validation

```bash
/opt/cfw-render/bin/cfw-render.sh --dry
```

All rows must PASS before enabling the timer. `install.sh` already runs this
at the end of installation and refuses to leave you in a broken state
silently (it exits non-zero on FAIL).

## 5. Enable the timer

- Linux (systemd): `systemctl enable --now cfw-render.timer`
- macOS (launchd): `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cfw.render.plist`

## 6. Cutover — Bujji first

1. Flip `render_fleet_enabled=true` on **Bujji only** (not fleet-wide).
2. Submit one real reel via Hermes (`p-reels-spotlight` or similar).
3. Watch `cfw-render-ctl.sh status` + the brand UI event stream end-to-end:
   `queued → claimed → rendering → gating → done` (or `blocked` with a
   readable reason).
4. Confirm the dish lands in the Bujji Inbox and Hermes pings the owner.

Only after one clean end-to-end run should other brands be flipped on.

## 7. Rollback

```bash
systemctl disable --now cfw-render.timer   # or: launchctl bootout on macOS
```

In-flight orders re-strand as `claimed`/`rendering` with an expiring lease;
nothing else is touched. See §8 (known gap) for what happens next.

## 8. Known gap — expired-lease requeue (do not paper over)

Neither worker MCP tool can reclaim an order stuck in `claimed`/`rendering`
with an expired lease, and there is no `requeue_render_order` tool yet
(`implementation-plan.md` §0.4). Consequences:

- **Director timeout/crash while the drainer is alive** → fully handled; the
  drainer holds a live lease and calls `block_render_order` itself. This is
  the dominant failure mode and works today.
- **Drainer death mid-render** (power loss, SIGKILL) → the order strands in
  `claimed` with an expired lease and nothing currently reclaims it.

**Follow-up:** a ~5-line cfw-social change (extend the worker-claim CAS WHERE
to also take `status IN ('claimed','rendering','gating') AND
lease_expires_at < now()`), or a dedicated `requeue_render_order` tool. Filed
as `AB-RNDR-REQUEUE` (repo: cfw-social) — see that task file for the exact
scope. Until it lands, `cfw-render-ctl.sh unblock <orderId>` fails fast with
the admin SQL to run manually rather than silently no-opping.

## 9. Rotation

Follow `render-worker-auth.md` §5.3 verbatim: mint → update Vercel env →
redeploy cfw-social → update `~/.gsai/secrets/cfw-render.env` + the box
`/etc/cfw-render.env` → restart the worker pool (`systemctl restart
cfw-render.timer` picks up the new env on the next tick; no code change).
