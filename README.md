# cfw-render

Decoupled render fleet for CFW Social — the async worker that drains `RenderOrder` rows
(Postgres, cfw-social system of record), spawns a headless Claude Creative Director with
GLM/Kimi fan-out, renders un-timeboxed, and writes the dish back via the narrow render-worker
MCP credential.

**Design source of truth:** `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md`
**Worker auth/credential:** `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md`
**Implementation plan (this repo):** `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md`

Status: deployed to `hst` (15-min drainer timer, first deployed 2026-08-12).
The skills bundle is **self-contained** (the box carries no render toolchain).
The remaining step to make cfw-render the **sole** renderer is the gated,
per-brand `renderFleetEnabled` flip — an **operator action**, not a code
change; see `docs/deploy.md` §6 (fleet-enable rollout). The submit-vs-inline
"hard rule" and the fleet-enable admin endpoint are enforced/served in
**cfw-social** (`src/lib/render/submit-render-order.ts`, `CFW-V2-071`
doctrine), not in this repo.

## Layout

```
bin/            drainer, ctl, and the Director-facing helpers (report/subagent/upload)
lib/            director-prompt.md (the dispatch prompt template)
config/         cfw-render.env.example — every knob, commented; skills-version.json — pinned bundle manifest
skills/         BUNDLED recipes — self-contained, source-synced from ecosystem/skills, pinned (see "Bundled skills" below)
install/        launchd plist, systemd unit+timer, install.sh (--mode), provisioner snippet, byoa-installer-notes.md
docs/           deploy.md (supervised deploy runbook), PACKAGING-DESIGN.md (the design this implements)
test/           mock-server.py + fake-director.sh + run-tests.sh (no live services)
scripts/        lint.sh, verify-skills-bundle.sh (checksum gate), gen-skills-manifest.sh (regen the pin)
```

## Bundled skills (CFW-HST-BUNDLE → self-contained, VPS-simplification epic Phase 2)

The renderer ships **with** its recipes: `skills/` is a **self-contained**,
source-synced copy of the recipes listed in `config/recipes.json`, pinned to
the source commit recorded in `config/skills-version.json`. Installing this
repo (`install/install.sh`) installs both the worker and the exact skills
closure it renders with — no separate hourly pull, no shared-box directory, no
second moving part to drift out of sync. This is what makes the Hermes box
**stateless**: the render toolchain and its recipes live in this repo, not on
the box. Authoring still happens upstream in `~/ecosystem/skills`
(the `c-*`/`p-*`/`r-*` library); this repo vendors a pinned copy via
`scripts/sync-skills.sh` (git-subtree + the old `cfw-skills-pack` build were
retired 2026-09-01).

- **Default resolution:** `CFW_RENDER_SKILLS_DIR` unset/blank → bundled
  `skills/` in this repo (resolved relative to the repo/install root, not
  cwd). There is no shared-box fallback and no bundle-vs-fetch switch — the
  bundle is cfw-render's one and only skills source. Setting
  `CFW_RENDER_SKILLS_DIR` explicitly (env, `/etc/cfw-render.env`, or
  `~/.gsai/secrets/cfw-render.env`) overrides it — use this only to point at a
  local `~/ecosystem/skills` checkout for recipe-development iteration.
- **Version pin:** `config/skills-version.json` records the exact
  `ecosystem/skills` source commit (`sourceCommit`), per-recipe `version` +
  checksum, and `recipeCount`. The worker logs this on every config load
  (`cr_log_skills_version` in `bin/cfw-render-lib.sh`) — check
  `~/.cfw-render/cfw-render.log` (or `$CFW_RENDER_STATE_DIR`) to see which
  bundle a run served.
- **Bumping the pin / changing the recipe set:**
  ```bash
  # edit config/recipes.json to add/remove a bundled recipe, then:
  scripts/sync-skills.sh            # copy recipes from ~/ecosystem/skills into skills/,
                                    # regenerate skills/index.json + config/skills-version.json
  scripts/verify-skills-bundle.sh   # confirm the tree matches the manifest (checksum gate)
  ```
  `scripts/sync-skills.sh` reads `CFW_SKILLS_SRC` (default `~/ecosystem/skills`)
  as the source of truth; `config/skills-version.json` is regenerated, not
  hand-edited.
- **Integrity verification (doc §5):** `config/skills-version.json` records, per
  recipe, `version` + aggregate `checksum` + `fileCount`, plus an
  `aggregateChecksum` over the whole bundle. `scripts/verify-skills-bundle.sh`
  recomputes per-file sha256 for the on-disk recipes and compares them to the
  per-file hashes shipped in `skills/index.json` (same raw-bytes sha256 the
  publish pipeline writes) — pure bash + `shasum`/`sha256sum`, no runtime dep:
  ```bash
  scripts/verify-skills-bundle.sh                # verify the whole tree (pre-tag / CI)
  scripts/verify-skills-bundle.sh p-carousel     # verify one recipe
  ```
  The worker calls this (`cr_verify_skills_bundle` in `bin/cfw-render-lib.sh`)
  for **only the claimed order's recipe** at the top of each real tick and in
  `--dry` (the `skills:pinned` row shows the live `sourceSha` + recipe count).
  A genuine checksum **mismatch** (a pinned file changed under the worker, e.g.
  a pull landing mid-tick) does **not** spawn the Director — it blocks the
  order with an owner-safe reason and logs the expected/actual pair. A missing
  `index.json` / an unpinned recipe is *unverifiable → proceed* (logged), never
  a false block, so a legacy/dev `CFW_RENDER_SKILLS_DIR` still works.

## Deploy mode + stable worker identity (PACKAGING-DESIGN.md §4, §6.3)

- **`CFW_RENDER_MODE=server|byoa`** (default `server`) is **operational**
  config set once at install time — never the security boundary (the server
  enforces that by which credential family resolves).
  `install/install.sh --mode server|byoa` writes `CFW_RENDER_MODE` into the env
  file. Both modes render from the same self-contained `skills/` bundle — the
  old `CFW_RENDER_SKILLS_SOURCE=bundle|fetch` switch and the curated-`fetch`
  path were **removed 2026-09-01** (there is only the bundle now). See
  `install/byoa-installer-notes.md`.
- **Stable `workerId` (doc §6.3):** the claim identity is a **per-install**
  UUID persisted at `$CFW_RENDER_STATE_DIR/worker-id`
  (`CFW_RENDER_WORKER_ID_FILE`), seeded once by `install.sh` (and lazily by the
  worker if absent) — **not** `hostname:$$`, which changed every 15-min oneshot
  tick and would defeat CFW-V2-068's per-`workerId` circuit breaker. An
  explicitly exported `CFW_WORKER_ID` still wins (tests/ops); `hostname:$$`
  survives only as free-text log context. **Flagged for CFW-V2-068:** the
  server-side breaker must key off this stable id (or off the `RenderWorkerKey`
  id) — see PACKAGING-DESIGN.md §6.3.
- **Box hourly pull cron (`/usr/local/bin/cfw-skills-pull.sh`) — retirement
  note:** cfw-render no longer reads the shared `/data/shared/cfw-skills/cfw`
  directory at all (self-contain refactor) — it renders only from its own
  bundled `skills/`. The box's hourly skills-pull cron was for the *Hermes*
  assistant bundle, never cfw-render; once every render on a box is on
  cfw-render (fleet-enabled — see `docs/deploy.md` §6), nothing cfw-render runs
  needs that cron. **Retiring it on the live box `hst` is a human, supervised
  step** (not done by this repo change); see `docs/deploy.md`.

## Usage

```bash
cp config/cfw-render.env.example ~/.gsai/secrets/cfw-render.env   # fill in CFW_API_BASE + CFW_RENDER_WORKER_KEY, chmod 600
bin/cfw-render.sh --dry      # validate config + credential + live tools/list; claims nothing
bin/cfw-render.sh --once     # one real tick — claims + renders (what the timer calls every 15 min)
bin/cfw-render-ctl.sh status # tick-lock state, journal tail, timer status, --dry summary
bin/cfw-render-ctl.sh run-now
bin/cfw-render-ctl.sh logs [n]
bin/cfw-render-ctl.sh unblock <orderId>   # forward-compatible; fails fast today, see below
```

**Operator fleet-enable (CFW-16) — run from an operator machine, NOT a box:**

```bash
# Uses the MASTER key (CFW_MASTER_API_KEY), not the box's cfw_render_ worker key.
# Read it from ~/.gsai/secrets/cfw-render-admin.env ($CFW_RENDER_ADMIN_ENV) or the env.
bin/cfw-render-fleet.sh status  <brandId>          # read renderFleetEnabled
bin/cfw-render-fleet.sh enable  <brandId>          # opt brand IN  (per-brand, reversible)
bin/cfw-render-fleet.sh disable <brandId>          # opt brand OUT (instant rollback)
bin/cfw-render-ctl.sh   fleet   status <brandId>   # same thing, via ctl
```

This is the per-brand, reversible replacement for the raw-SQL `render_fleet_enabled`
flip. It never bulk-flips (name each brand id) and reads the value back to confirm.
The live rollout stays gated + brand-by-brand — see `docs/deploy.md` §6. It depends
on a small cfw-social route extension (documented in that section); until that lands
the helper reports the gap and you use the break-glass SQL.

## Knobs

Every config var is documented inline in `config/cfw-render.env.example`
(concurrency, scratch/state/skills paths, watchdog timeouts per `kind`, gate
fail-cap, fan-out model allowlist, Ollama keys file, the `CFW_RENDER_DIRECTOR_CMD`
test seam). Load order: `/etc/cfw-render.env` → `$CFW_RENDER_ENV` (default
`~/.gsai/secrets/cfw-render.env`) → process env wins over both files.

## `workerId` semantics

**Stable per install, not per process** (doc §6.3 — see "Deploy mode + stable
worker identity" above). The claim identity is a per-install UUID persisted at
`$CFW_RENDER_STATE_DIR/worker-id` (`CFW_RENDER_WORKER_ID_FILE`), seeded once by
`install.sh` and reused by every 15-min oneshot tick — **not** the old
`"$(hostname -s):$$"` (host+pid), which changed every tick and would defeat
CFW-V2-068's per-`workerId` circuit breaker. Resolution order (`cr_load_config`
in `bin/cfw-render-lib.sh`, seeded by `cr_seed_worker_id`): an explicitly
exported `CFW_WORKER_ID` wins (tests / special ops) → else the `worker-id` file
(lazily seeded here too, so a hand-run/dev worker is also stable) → else, only
if that file is empty/unreadable, an unstable `hostname:$$` fallback (logged as
a WARN, since the breaker won't accumulate against it).

Per `render-worker-auth.md` §2, `workerId` is **concurrency hygiene, not a
security boundary** — the credential itself (`CFW_RENDER_WORKER_KEY`) is the
auth principal; `workerId` only stops two processes holding that same key from
stomping each other's claims (and now gives CFW-V2-068's breaker a stable key
to accumulate against).

## Ollama keys vs `zai.env` (read before chasing a "missing key")

The task text originally said `~/.gsai/secrets/zai.env` for the GLM/Kimi
fan-out + Sonnet quota-failover keys. That file holds unrelated z.ai creds
(`ZAI_API_KEY`) — **not** what `claude_ollama_failover` needs. The proven
production recipe (same one `ab-hustler` uses) is
`~/.gsai/secrets/ollama-keys.env` (`OLLAMA_KEY_GOOFY_HUGLE_463_B`,
`OLLAMA_KEY_RECURSING_PIKE_357`), configured via
`CFW_RENDER_OLLAMA_KEYS_FILE` (default already points there — see
`implementation-plan.md` §0.7).

## Known gap — `unblock` / expired-lease requeue

Neither worker MCP tool can reclaim an order stuck in `claimed`/`rendering`
with an expired lease, and there's no `requeue_render_order` tool yet. The
dominant failure mode (Director timeout/crash while the drainer is alive) is
fully handled — the drainer calls `block_render_order` itself. The
narrower gap (drainer process death mid-render) needs a small server-side
fix, tracked as `AB-RNDR-REQUEUE` (repo: cfw-social — see that task file).
Until it lands, `cfw-render-ctl.sh unblock <orderId>` fails fast with the
exact admin SQL rather than silently no-opping. Full detail:
`docs/deploy.md` §8, `implementation-plan.md` §0.4.

## ⚠️ Supervised deploy gate

Installing on `hst`, confirming the scratch root + CFW Media path, and
flipping `render_fleet_enabled` are **human/attended-session** steps —
never run unattended. See `docs/deploy.md`.

## Testing

```bash
pnpm lint    # bash -n + shellcheck (scripts/lint.sh)
pnpm test    # behavioral suite against a stdlib-only mock server (test/run-tests.sh)
```

`test/run-tests.sh` boots a fresh `test/mock-server.py` per case and drives
`bin/cfw-render.sh` with `CFW_RENDER_DIRECTOR_CMD=test/fake-director.sh` (the
test seam) so no real `claude` spawn, real Ollama call, or live cfw-social
endpoint is ever hit. Covers: `--dry` makes zero `tools/call`s, the happy
path (claim → stage events → subagent fan-out → upload → complete, scratch
wiped, journal row), gate-fail block (scratch retained), watchdog timeout →
block with a time-budget reason, empty queue, and tick-lock exclusion.
