# cfw-render

The CFW Social render worker — runs on the brand's own computer (a Mac), drains `RenderOrder` rows
(Postgres, cfw-social system of record), spawns a headless Claude Creative Director with
GLM/Kimi fan-out, renders un-timeboxed, and writes the dish back via the narrow render-worker
MCP credential.

**Design source of truth:** `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md`
**Worker auth/credential:** `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md`
**Implementation plan (this repo):** `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md`

Status: runs **only on the brand's own computers** (owner decision D118, 2026-10):
each person installs it on their Mac with a render-worker key issued from the
brand's settings in cfw-social, sent as the `cfw-render-key` header. CFW no longer
runs a render server; the old server install, its systemd units and the
master-key fleet-enable helper were removed. The submit-vs-inline "hard rule" is
enforced in **cfw-social** (`src/lib/render/submit-render-order.ts`), not here.

## Layout

```
bin/            drainer, ctl, and the Director-facing helpers (report/subagent/upload)
lib/            director-prompt.md (the dispatch prompt template)
config/         cfw-render.env.example — every knob, commented; skills-version.json — pinned bundle manifest
skills/         BUNDLED recipes — self-contained, source-synced from ecosystem/skills, pinned (see "Bundled skills" below)
install/        launchd plist, install.sh, byoa-installer-notes.md
docs/           deploy.md (running on an owner computer), PACKAGING-DESIGN.md (the design this implements)
test/           mock-server.py + fake-director.sh + run-tests.sh (no live services)
scripts/        lint.sh, verify-skills-bundle.sh (checksum gate), gen-skills-manifest.sh (regen the pin)
```

## Bundled skills (self-contained)

The renderer ships **with** its recipes: `skills/` is a **self-contained**,
source-synced copy of the recipes listed in `config/recipes.json`, pinned to
the source commit recorded in `config/skills-version.json`. Installing this
repo (`install/install.sh`) installs both the worker and the exact skills
closure it renders with — no separate pull, no shared directory, no second
moving part to drift out of sync. Authoring still happens upstream in `~/ecosystem/skills`
(the `c-*`/`p-*`/`r-*` library); this repo vendors a pinned copy via
`scripts/sync-skills.sh` (git-subtree + the old `cfw-skills-pack` build were
retired 2026-09-01).

- **Default resolution:** `CFW_RENDER_SKILLS_DIR` unset/blank → bundled
  `skills/` in this repo (resolved relative to the repo/install root, not
  cwd). There is no shared-directory fallback and no bundle-vs-fetch switch — the
  bundle is cfw-render's one and only skills source. Setting
  `CFW_RENDER_SKILLS_DIR` explicitly (env or `~/.cfw-render/cfw-render.env`) overrides it — use this only to point at a
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

- **`CFW_RENDER_MODE=byoa`** is the only mode (the owner's own computer); it is
  **operational** config, never the security boundary (the server enforces
  that by which credential resolves). `install/install.sh` writes it; an older
  settings file that still says `server` is treated as `byoa`. See
  `install/byoa-installer-notes.md`.
- **Stable `workerId` (doc §6.3):** the claim identity is a **per-install**
  UUID persisted at `$CFW_RENDER_STATE_DIR/worker-id`
  (`CFW_RENDER_WORKER_ID_FILE`), seeded once by `install.sh` (and lazily by the
  worker if absent) — **not** `hostname:$$`, which changed every tick and would defeat CFW-V2-068's per-`workerId` circuit breaker. An
  explicitly exported `CFW_WORKER_ID` still wins (tests/ops); `hostname:$$`
  survives only as free-text log context. **Flagged for CFW-V2-068:** the
  server-side breaker must key off this stable id (or off the `RenderWorkerKey`
  id) — see PACKAGING-DESIGN.md §6.3.
## Provider credentials are brand-scoped, never the worker's (CFW-313)

Same principle as the brand/user-scoped render-worker key — applied to the *provider* credentials a recipe
calls out to (today: HeyGen). A HeyGen recipe (the `*-heygen` reel variants)
needs a brand-scoped OAuth credential billing that brand's own HeyGen plan
credits, never one shared worker-local key covering every brand. cfw-social resolves/refreshes the brand's connected HeyGen
account server-side and embeds a short-lived, scoped credential into
`taskOrder.credentials.heygen` when the order is claimed — the same pattern
already used for `AVATAR_ID`/`VOICE_ID` (`Source: Caller / brand config`).
`spawn_director()` in `bin/cfw-render.sh` (`cr_recipe_needs_heygen` in
`bin/cfw-render-lib.sh`) requires that field for any recipe that needs it and
**blocks cleanly** (`needs: "decision"`) if it's absent or malformed —
**never** a fallback to a worker-local/vault key. When present, it's exported
into the Director's subprocess env as `HEYGEN_OAUTH_TOKEN` /
`HEYGEN_CREDIT_POOL` / `HEYGEN_TOKEN_EXPIRES_AT` (deliberately not
`HEYGEN_API_KEY` — that name implies api-key auth, not OAuth). See
`config/cfw-render.env.example`'s "Provider credentials" note and
`scripts/check-no-worker-heygen-credential.sh`, the static guard that keeps a
future "just read the vault key here, it's faster" shortcut from
reintroducing this bug. This repo's own piece of CFW-313 cannot alone
produce a working HeyGen render — it depends on a companion cfw-social
change (the OAuth connection + order-embedding) and a companion
`c-heygen` skill change (call the v1 remote MCP instead of the stdio
MCP/REST); see `DOZER-DESIGN-CFW-313.md` for the full three-repo scope.

## Toolchain preflight (CFW-199)

`cfw-render` shells out to a real toolchain — ffmpeg, ImageMagick 7, headless
Chromium, node/npx (hyperframes), python3 and the `claude` CLI. **If any of it
is missing, the drainer must not start.** `claim_render_order` claims
**oldest-first across every brand the key covers**, so a half-provisioned
computer does not fail quietly: it takes the owner's real orders and burns them
into failures.

This is not hypothetical. **CFW-188 found a render computer with no ImageMagick
at all**, installed and one schedule load away from doing exactly that. Nothing in the install path or the drainer's startup
checked; `--dry` validated config, credentials and a live `tools/list`, but
never the tools the recipes actually run.

```bash
bin/cfw-render-preflight.sh            # full report
bin/cfw-render-preflight.sh --quiet    # only failures
```

Exit **0** = every required tool is present. Exit **1** = at least one is
missing, and the failure block names each one **and the command that installs
it on this OS**. It claims nothing, calls no API, costs nothing.

The same gate runs automatically in three places:

| where | when |
|---|---|
| `install/install.sh` | **first**, before anything is copied or the LaunchAgent is written — a failed preflight aborts the install |
| `bin/cfw-render.sh` (real tick) | before the tick lock and before the claim loop — a failed preflight logs and exits **1** having claimed nothing |
| `bin/cfw-render.sh --dry` | as part of the validation report |

**What is checked, and why that list:**

- `curl` · `python3` · `node` · `npx` · `ffmpeg` · `ffprobe` — every recipe path
  needs all six (no `jq` assumed, so every JSON hop is `python3`).
- **`magick`** — ImageMagick **7** verb form. The recipes call `magick`, not
  `convert`. A computer with only IM6 fails at render time; the preflight says so
  explicitly and prints the shim.
- **`claude`** — the render Director. Skipped when `CFW_RENDER_DIRECTOR_CMD` is
  set (tests / a stub Director). Note the binary being present is **not** proof
  it is authenticated — after installing, run `claude auth login` on that computer
  and confirm with `claude auth status` (this was the whole CFW-188 gate).
- **Chromium** — resolved from `PLAYWRIGHT_BROWSERS_PATH`, the per-OS
  `ms-playwright` cache, or a system Chrome/Chromium. HTML compositions cannot
  render without it.
- **Fonts** — deliberately the *generic* families (`sans-serif`, `serif`,
  `monospace`) must resolve to real, readable font files, **not** the brand
  families the recipes name (Inter, Oswald, JetBrains Mono, Poppins…). The
  HyperFrames compiler embeds those itself, and the Mac renderer — which has
  cooked real dishes — has none of them installed system-wide, so requiring
  them would be a false FAIL. What genuinely breaks a render is a computer with
  **no usable font at all**: Chromium and ImageMagick then draw blank/tofu text
  and every QA gate fails.

## Installing on an owner's computer

Get a render-worker key (`cfw_render_…`) from the brand's settings in cfw-social,
then on the Mac:

```bash
bin/cfw-render-preflight.sh                 # fix whatever it names, re-run until PASS
claude auth login && claude auth status
install -m 600 config/cfw-render.env.example ~/.cfw-render/cfw-render.env
#   set CFW_API_BASE=https://app.cfw.social and CFW_RENDER_WORKER_KEY=<this computer's key>
install/install.sh --mode byoa              # copies to "~/CFW Render/app", writes the LaunchAgent, runs --dry
```

The worker id is a fresh per-install UUID at `~/.cfw-render/worker-id`; never
copy another computer's file. Most owners use the desktop app (`desktop/`)
instead, which does the same thing. Folder layout: `AGENTS.md` ("Where things
are"); more detail: `install/byoa-installer-notes.md`.

## Usage

```bash
cp config/cfw-render.env.example ~/.cfw-render/cfw-render.env   # fill in CFW_API_BASE + CFW_RENDER_WORKER_KEY, chmod 600
bin/cfw-render.sh --dry      # validate config + credential + live tools/list; claims nothing
bin/cfw-render.sh --once     # one real tick — claims + renders
bin/cfw-render-ctl.sh status # tick-lock state, journal tail, timer status, --dry summary
bin/cfw-render-ctl.sh run-now
bin/cfw-render-ctl.sh logs [n]
bin/cfw-render-ctl.sh unblock <orderId>   # forward-compatible; fails fast today, see below
```

## Knobs

Every config var is documented inline in `config/cfw-render.env.example`
(concurrency, scratch/state/skills paths, watchdog timeouts per `kind` —
`CFW_RENDER_TIMEOUT_VIDEO` defaults to **3600 s** since CFW-131: local reels
certify at ≈6 min, slower computers run 2–3× slower and a gate-fail re-render
doubles it; stage reports heartbeat the 30-min claim lease so the hour is safe — gate
fail-cap, fan-out model allowlist, Ollama keys file, the `CFW_RENDER_DIRECTOR_CMD`
test seam). Load order: `$CFW_RENDER_ENV` (default
`~/.cfw-render/cfw-render.env`) → process env wins over the file.

## `workerId` semantics

**Stable per install, not per process** (doc §6.3 — see "Deploy mode + stable
worker identity" above). The claim identity is a per-install UUID persisted at
`$CFW_RENDER_STATE_DIR/worker-id` (`CFW_RENDER_WORKER_ID_FILE`), seeded once by
`install.sh` and reused by every tick — **not** the old
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
`~/ecosystem/vault/ollama-keys.env` (`OLLAMA_KEY_GOOFY_HUGLE_463_B`,
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
`docs/deploy.md` §3, `implementation-plan.md` §0.4.

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
block with a time-budget reason (and, per CFW-286, that a background process
it spawned is reaped too, not just the watchdog-killed subshell), empty
queue, and tick-lock exclusion. Also covers CFW-286's orphaned-background
race directly: a Director that backgrounds a step finishing just inside the
grace window still lands `outcome=complete`, while one that backgrounds a
step past the grace window is reaped and lands the distinct `outcome=orphaned`
(never `crashed`, and never a stray `complete_render_order` call racing the
block). Also covers (CFW-291): `cr_resolve_worker_path` finding a binary in a
nonstandard location and deduping/preserving the static fallback dirs;
`cr_probe_claude_headless` catching a `claude` that only "works" via an
ambient env var a rich shell would supply but `env -i` strips (the exact
CFW-279 gap), its empty-output-is-still-a-failure rule, and its
stub-Director skip; and `install/install.sh` rendering the resolved
`WORKER_PATH` into the macOS plist.
