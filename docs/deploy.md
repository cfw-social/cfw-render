# cfw-render — supervised deploy runbook

> **This runbook is for a human/attended session only.** AB-RNDR-WORKER (the
> unattended dev task that authored this repo) explicitly did NOT run any of
> these steps against the live box `hst` (31.97.140.100) — that box runs 9
> production brand gateways and must not be touched by an unattended agent.
> See the task's "SUPERVISED FOLLOW-UP GATE" for the authorization boundary.

## 0. Prerequisites

- SSH access to the render worker host (`hst` today; the worker is
  host-agnostic per `cfw-render-worker-plan.md` "Open items").
- `~/ecosystem/vault/cfw-render.env` populated (§5 of
  `cfw-social/docs/render-worker-auth.md`) with `CFW_RENDER_WORKER_KEY` +
  `CFW_API_BASE`.
- Vercel env `CFW_RENDER_WORKER_KEY` set on prod (matching value) and
  cfw-social redeployed.

## 1. Pre-flight (operator's machine, never unattended)

1. Mint/verify the render-worker key per `render-worker-auth.md` §5.1–5.2.
2. Confirm the Vercel env is live (`vercel env ls`) and cfw-social has been
   redeployed since the key was set.
3. Confirm `~/ecosystem/vault/cfw-render.env` has the matching key, chmod 600.

## 2. REQUIRED CHECKS — confirm scratch root + CFW Media path on the live box

These two checks are acceptance criteria for the deploy, not optional:

1. **Scratch root.** SSH to the box, run `df -h` and pick a volume with
   headroom for video intermediates. Set `CFW_RENDER_SCRATCH` in
   `/etc/cfw-render.env` to that path (default in the example is
   `$HOME/cfw-render-scratch` — override it).
2. **CFW Media render path.** Upload a probe file **larger than 5 MB** (e.g.
   `head -c 6000000 /dev/urandom > probe.mp4`) against a throwaway **claimed**
   order (create one via a test `submit_render_order` call from an attended
   Hermes session, claim it manually with `claim_render_order`, then run
   `cfw-render-upload.sh probe.mp4` with `CFW_ORDER_ID`/`CFW_WORKER_ID` set to
   that order). Confirm the returned `cdnUrl` resolves and contains
   `brands/<brandId>/renders/<orderId>/`. The helper defaults to the presigned
   direct-to-R2 path (`POST /api/v1/render/upload-url` → `PUT` →
   `POST /api/v1/render/upload-complete`, CFW-144) because Vercel rejects any
   function request body over 4.5 MB (`413 FUNCTION_PAYLOAD_TOO_LARGE`) — the
   legacy multipart `POST /api/v1/render/upload` only carries ≤ 4 MiB files.
   A > 5 MB probe therefore proves the path a real reel will take.

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

**Worker PATH is resolved, not guessed (CFW-291).** `install.sh` no longer
bakes a hand-guessed list of directories into the plist/unit. It walks every
binary a recipe needs (`curl python3 node npx ffmpeg ffprobe magick claude`),
resolves each one with `command -v` **in the shell you run `install.sh`
from**, and writes that resolved `WORKER_PATH` into both
`com.cfw.render.plist` (macOS) and `cfw-render.service` (Linux) — so run
`install.sh` from the same normal login shell where `which claude` (and the
rest of the toolchain) actually resolves, not from a restricted/CI-shaped
shell. Before it will write anything, `install.sh` also **proves `claude`
actually runs** under that exact resolved PATH, in a fully stripped
environment (`env -i` — the same narrow environment launchd/systemd hand a
scheduled tick, not this installer's rich shell): if `claude` resolves via
`command -v` but is really a shell function/alias/nvm-or-asdf-init-hook
wrapper that only works with ambient shell state, the probe fails and
`install.sh` **aborts and installs nothing**, printing the resolved
`WORKER_PATH`, the probe's captured output, and what to fix — so you get an
actionable message here instead of the `FAIL binary:claude not on PATH` this
note used to send you chasing manually. If you still hit that FAIL from
`--dry` after `install.sh` succeeded, `claude` (or a dependency) moved since
install — re-run `install/install.sh` to re-resolve and re-render both
templates; an already-installed plist/unit is a static copy and won't pick
up a re-resolved `WORKER_PATH` until the installer is re-run (or you
`launchctl bootout` + `bootstrap` / `systemctl daemon-reload` after manually
re-rendering it). This applies identically on Linux now — the systemd unit
carries the same resolved `WORKER_PATH` as the plist, closing the gap
CFW-279 left open there (systemd gives a oneshot unit its own minimal
default search path, not the service user's login-shell PATH).

## 5. Enable the timer

- Linux (systemd): `systemctl enable --now cfw-render.timer`
- macOS (launchd): `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cfw.render.plist`

## 6. Fleet-enable rollout — all renders → cfw-render (CFW-16 / CFW-V2-073)

**Goal:** make cfw-render the *sole* renderer so the Hermes box carries no render
toolchain (skills already bundled — §8b). Two independent parts, one gated
rollout:

- **Code (already shipped):** cfw-render bundles its own skills (self-contained);
  cfw-social's `submitRenderOrderForBrand` gates on `Brand.renderFleetEnabled`
  and Hermes's **hard submit rule** routes *every* engine/`p-*`/HTML/ffmpeg job
  to `submit_render_order` instead of rendering inline
  (`cfw-social/docs/cfw-render-worker-plan.md` §1b(2); doctrine via CFW-V2-071).
- **The flip is an OPERATOR ACTION, per-brand and reversible** — never a
  bulk code flip. `renderFleetEnabled` defaults `false`; the whole flip is one
  per-brand toggle via the fleet helper (below), and reverting to `false` is an
  instant rollback with zero box changes.

### 6.1 The operator fleet-enable helper (CFW-16)

`bin/cfw-render-fleet.sh` (also reachable as `cfw-render-ctl.sh fleet …`) is the
per-brand, reversible, auditable way to opt a brand in/out of the render fleet
and read current state. It uses the **master key** (`cfw-api-key`), NOT the
box's narrow `cfw_render_` worker key — so **run it from an operator machine,
never a render box.** Point it at the master key via `CFW_MASTER_API_KEY` (in
`$CFW_RENDER_ADMIN_ENV`, default `~/ecosystem/vault/cfw-render-admin.env`, or the
process env) plus `CFW_API_BASE`:

```bash
cfw-render-fleet.sh status  <brandId> [<brandId>...]   # read renderFleetEnabled
cfw-render-fleet.sh enable  <brandId>                   # opt brand IN  (reversible)
cfw-render-fleet.sh disable <brandId>                   # opt brand OUT (instant rollback)
```

It flips one named brand at a time and reads the value back to confirm — it
**never bulk-flips**. Brands are addressed by **id**; map a slug to its id with
`SELECT id FROM brands WHERE slug = '<brand>';`.

> **SERVER-SIDE FOLLOW-UP (cfw-social) — required before the live flip.** The
> helper talks to `PATCH`/`GET /api/v1/admin/brands/:id`. That route today only
> curates `isShowcase`; extend it to carry `renderFleetEnabled`:
> add `renderFleetEnabled: z.boolean().optional()` to `PatchSchema` (write it
> through `prisma.brand.update`) and add a `GET` returning
> `{ id, renderFleetEnabled }`, both behind the existing `assertMasterOrAdmin()`
> gate (`src/app/api/v1/admin/brands/[id]/route.ts`). Until it lands, the helper
> reports the gap loudly and you fall back to the break-glass SQL below.

**Break-glass (only until the route ships, or if the API is down):**
```sql
-- read current fleet state:
SELECT id, slug, render_fleet_enabled FROM brands ORDER BY render_fleet_enabled DESC, slug;
-- flip one brand:
UPDATE brands SET render_fleet_enabled = true WHERE slug = 'bujji';
```

Fleet-wide drain health (master-key context, NOT the box's narrow worker key):
`GET /api/v1/admin/fleet/renders` returns every RenderOrder with model
attribution — use it to confirm orders are flowing `queued → done` after a flip.

### 6.2 Cutover — Bujji first (parallel-run)

1. Flip **Bujji only** (not fleet-wide):
   ```bash
   cfw-render-fleet.sh enable "$(psql ... -tAc "SELECT id FROM brands WHERE slug='bujji'")"
   # break-glass equivalent: UPDATE brands SET render_fleet_enabled = true WHERE slug = 'bujji';
   ```
2. Submit one real reel via Hermes (`p-reels-spotlight` or similar). With the
   hard submit rule live, Hermes must **submit** it, not render inline.
3. Watch `cfw-render-ctl.sh status` + the brand UI event stream end-to-end:
   `queued → claimed → rendering → gating → done` (or `blocked` with a
   readable reason).
4. Confirm the dish lands in the Bujji Inbox and Hermes pings the owner, and
   that **no inline render** happened on the gateway (check the box: the Hermes
   turn should have called `submit_render_order`, not run ffmpeg/HTML locally).

### 6.3 Widen brand-by-brand

Only after one clean end-to-end run, flip the next brand and repeat 6.2. Keep
going until every brand has `render_fleet_enabled = true` and
`GET /api/v1/admin/fleet/renders` shows cfw-render draining 100% of render work.

**Rollback (any brand, any time):** `cfw-render-fleet.sh disable <brandId>`
(break-glass: `UPDATE brands SET render_fleet_enabled = false WHERE slug =
'<brand>';`) — the brand's Hermes falls back to its previous behavior instantly;
already-queued orders still drain (the worker + list surfaces ignore the flag
for in-flight orders by design).

**Exit criteria (Phase 2):** zero inline renders on any gateway, cfw-render is
the sole renderer, the box carries no skills (§8b).

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

**Reading `journal.tsv`'s `outcome` column (CFW-286):** `crashed` and
`orphaned` are NOT the same failure — don't treat them interchangeably when
triaging. `crashed` means the Director process itself exited with a nonzero
code (bad exit, uncaught exception, OOM) — a real toolchain/host problem.
`orphaned` means the Director exited cleanly (rc=0) but never called
`complete`/`block` — it backgrounded a step (a trailing `&`, `run_in_background:
true`, a detached upload/encode) and ended its turn before that step
finished, which `lib/director-prompt.md` explicitly forbids. A nonzero
`orphaned` rate points at a Director-side prompt-adherence regression, not a
host/toolchain issue — spot-check that order's transcript
(`$CFW_RENDER_STATE_DIR/runs/<orderId>-<ts>.out`) for a backgrounded tool call
before assuming it's an infra problem.

**Follow-up:** a ~5-line cfw-social change (extend the worker-claim CAS WHERE
to also take `status IN ('claimed','rendering','gating') AND
lease_expires_at < now()`), or a dedicated `requeue_render_order` tool. Filed
as `AB-RNDR-REQUEUE` (repo: cfw-social) — see that task file for the exact
scope. Until it lands, `cfw-render-ctl.sh unblock <orderId>` fails fast with
the admin SQL to run manually rather than silently no-opping.

## 8b. Bundled skills — self-contained (CFW-HST-BUNDLE → self-contain refactor)

This repo carries its own pinned `skills/` — a source-synced copy of the
recipes in `config/recipes.json`, produced by `scripts/sync-skills.sh` from
`~/ecosystem/skills` and pinned via `config/skills-version.json` (see README
"Bundled skills"). `install.sh` copies `skills/` into `$PREFIX/skills`
alongside `bin/`/`lib/`, and the worker defaults `CFW_RENDER_SKILLS_DIR` to
that bundled path when the var is left unset. **cfw-render no longer reads the
shared `/data/shared/cfw-skills/cfw` directory at all** — the git-subtree /
`cfw-skills-pack` / bundle-vs-fetch switch were retired 2026-09-01. This is
what lets the Hermes box be stateless: the render toolchain lives here, not on
the box.

**The box's hourly skills-pull cron (`/usr/local/bin/cfw-skills-pull.sh`) and
the `/data/shared/cfw-skills/cfw` checkout are NOT cfw-render's** — they fed
the *Hermes assistant* bundle. Do NOT touch them as part of a cfw-render
deploy. Once every render on a box has moved to cfw-render (fleet-enabled, §6),
nothing cfw-render runs needs that cron; retiring it is a **separate,
supervised step** a human runs later, and leaves `/data/shared/cfw-skills/cfw`
in place for any external BYO agents that still read it.

To verify the bundle on a box: `install.sh` + `cfw-render.sh --dry` must PASS
with the `skills:pinned` row showing the expected `sourceSha` + recipe count,
and `scripts/verify-skills-bundle.sh` (checksum gate) exiting 0.

## 9. Rotation

Follow `render-worker-auth.md` §5.3 verbatim: mint → update Vercel env →
redeploy cfw-social → update `~/ecosystem/vault/cfw-render.env` + the box
`/etc/cfw-render.env` → restart the worker pool (`systemctl restart
cfw-render.timer` picks up the new env on the next tick; no code change).
