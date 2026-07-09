# cfw-render

Decoupled render fleet for CFW Social — the async worker that drains `RenderOrder` rows
(Postgres, cfw-social system of record), spawns a headless Claude Creative Director with
GLM/Kimi fan-out, renders un-timeboxed, and writes the dish back via the narrow render-worker
MCP credential.

**Design source of truth:** `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md`
**Worker auth/credential:** `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md`
**Implementation plan (this repo):** `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md`

Status: code-authored (AB-RNDR-WORKER). **Not yet deployed to hst** — see
`docs/deploy.md` for the supervised follow-up gate. Nothing in this repo has
been run against the live box.

## Layout

```
bin/            drainer, ctl, and the Director-facing helpers (report/subagent/upload)
lib/            director-prompt.md (the dispatch prompt template)
config/         cfw-render.env.example — every knob, commented
install/        launchd plist, systemd unit+timer, install.sh, provisioner snippet
docs/           deploy.md — the supervised human-run deploy runbook
test/           mock-server.py + fake-director.sh + run-tests.sh (no live services)
scripts/        lint.sh
```

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
