# cfw-render

Decoupled render fleet for CFW Social — the async worker that drains `RenderOrder` rows
(Postgres, cfw-social system of record), spawns a headless Claude Creative Director with
GLM/Kimi fan-out, renders un-timeboxed, and writes the dish back via the narrow render-worker
MCP credential.

**Design source of truth:** `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md`
**Worker auth/credential:** `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md`
**Implementation plan (this repo):** `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md`

Status: **DEPLOYED on `hst`** since 2026-08-18 (`/opt/cfw-render`, source copy
`/opt/cfw-render-src`, `/etc/cfw-render.env`, `cfw-render.timer` every 15 min →
`cfw-render.service --once`; state in `/root/.cfw-render/`). Refreshed to `main`
`b817a18` on 2026-09-05 (CFW-129) via `install/install.sh --prefix /opt/cfw-render
--env-file /etc/cfw-render.env --user root --yes-really` (`--dry` PASS, skills pin
`eb1996a`). It drains `render_orders` for every `render_fleet_enabled` brand and
posts a `render_done` pack task that the multi-tenant `cfw-hermes-mt` daemon
(cfw-provisioner) acks. `docs/deploy.md` is the supervised refresh runbook.

## Layout

```
bin/            drainer, ctl, and the Director-facing helpers (report/subagent/upload)
lib/            director-prompt.md (the dispatch prompt template)
config/         cfw-render.env.example — every knob, commented; skills-version.json — pinned bundle manifest
skills/         BUNDLED recipes — git subtree of cfw-social/cfw-skills, pinned (see "Bundled skills" below)
install/        launchd plist, systemd unit+timer, install.sh (--mode), provisioner snippet, byoa-installer-notes.md
docs/           deploy.md (supervised deploy runbook), PACKAGING-DESIGN.md (the design this implements)
test/           mock-server.py + fake-director.sh + run-tests.sh (no live services)
scripts/        lint.sh, verify-skills-bundle.sh (checksum gate), gen-skills-manifest.sh (regen the pin)
```

## Bundled skills (CFW-HST-BUNDLE, VPS-simplification epic Phase 2)

The renderer ships **with** its recipes: `skills/` is a `git subtree` checkout
of the public `cfw-social/cfw-skills` repo, pinned to the commit recorded in
`config/skills-version.json`. Installing this repo (`install/install.sh`)
installs both the worker and the exact skills closure it renders with — no
separate hourly pull required once a box is fully on the bundle. Authoring
still happens upstream (`Vasanth19/skills` → `cfw-skills-pack` build →
public `cfw-social/cfw-skills`); this repo only vendors a pinned copy.

- **Default resolution:** `CFW_RENDER_SKILLS_DIR` unset/blank → bundled
  `skills/` in this repo (resolved relative to the repo/install root, not
  cwd) → falls back to the legacy shared box path
  `/data/shared/cfw-skills/cfw` only if `skills/` isn't present (pre-bundle
  checkout). Setting `CFW_RENDER_SKILLS_DIR` explicitly (env, `/etc/cfw-render.env`,
  or `~/.gsai/secrets/cfw-render.env`) always overrides both — use this to
  point back at the legacy path for parallel-run/rollback during transition,
  or at a local `cfw-skills-pack` build for recipe-development iteration.
- **Version pin:** `config/skills-version.json` records the exact
  `cfw-social/cfw-skills` commit, the pack's `sourceSha`/`release`, and the
  `git subtree pull` command to bump it. The worker logs this on every
  config load (`cr_log_skills_version` in `bin/cfw-render-lib.sh`) — check
  `~/.cfw-render/cfw-render.log` (or `$CFW_RENDER_STATE_DIR`) to see which
  bundle a run served.
- **Bumping the pin:**
  ```bash
  git subtree pull --prefix skills https://github.com/cfw-social/cfw-skills.git main --squash
  scripts/gen-skills-manifest.sh   # refresh config/skills-version.json's recipe rollup + aggregate
  # then hand-update sourceCommit in config/skills-version.json to the new subtree commit
  ```
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

- **`CFW_RENDER_MODE=server|byoa`** (default `server`) and
  **`CFW_RENDER_SKILLS_SOURCE=bundle|fetch`** (default `bundle`) are
  **operational** config set once at install time — never the security
  boundary (the server enforces that by which credential family resolves).
  `install/install.sh --mode server|byoa` writes `CFW_RENDER_MODE` into the env
  file. The BYOA curated-`fetch` path (CFW-V2-067) is **not built yet**:
  `CFW_RENDER_SKILLS_SOURCE=fetch` makes the worker **refuse to run** (fail
  fast, no silent fallback), and `--dry` emits a non-fatal `WARN` when
  `mode=byoa` + `source=bundle`. See `install/byoa-installer-notes.md`.
- **Stable `workerId` (doc §6.3):** the claim identity is a **per-install**
  UUID persisted at `$CFW_RENDER_STATE_DIR/worker-id`
  (`CFW_RENDER_WORKER_ID_FILE`), seeded once by `install.sh` (and lazily by the
  worker if absent) — **not** `hostname:$$`, which changed every 15-min oneshot
  tick and would defeat CFW-V2-068's per-`workerId` circuit breaker. An
  explicitly exported `CFW_WORKER_ID` still wins (tests/ops); `hostname:$$`
  survives only as free-text log context. **Flagged for CFW-V2-068:** the
  server-side breaker must key off this stable id (or off the `RenderWorkerKey`
  id) — see PACKAGING-DESIGN.md §6.3.
- **Box hourly pull cron (`/usr/local/bin/cfw-skills-pull.sh`) — transition
  note:** the standalone `cfw-social/cfw-skills` repo + the box's hourly
  `git pull` into `/data/shared/cfw-skills/cfw` stay alive during the
  brand-by-brand cutover (CFW-HST-BUNDLE design note 3 — no break). Once a
  brand/worker is fully on this bundled model, that cron becomes
  unnecessary for it — but **retiring it on the live box `hst` is a human,
  supervised step** (not done by this repo change); see `docs/deploy.md`.

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

## Knobs

Every config var is documented inline in `config/cfw-render.env.example`
(concurrency, scratch/state/skills paths, watchdog timeouts per `kind`, gate
fail-cap, fan-out model allowlist, Ollama keys file, the `CFW_RENDER_DIRECTOR_CMD`
test seam). Load order: `/etc/cfw-render.env` → `$CFW_RENDER_ENV` (default
`~/.gsai/secrets/cfw-render.env`) → process env wins over both files.

## `workerId` semantics

Computed, not configured: `"$(hostname -s):$$"` (host+pid). Per
`render-worker-auth.md` §2, this is **concurrency hygiene, not a security
boundary** — the credential itself (`CFW_RENDER_WORKER_KEY`) is the auth
principal; `workerId` only stops two processes holding that same key from
stomping each other's claims.

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
