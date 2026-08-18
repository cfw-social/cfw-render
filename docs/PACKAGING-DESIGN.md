# cfw-render ⊕ cfw-skills — Packaging & Distribution Design

> **Status:** design recommendation, not yet implemented. Read-only research doc for
> `CFW-HST-BUNDLE` (this repo, `backlog/queue/CFW-HST-BUNDLE.md`) and the cfw-social-side
> half `CFW-V2-073` (`cfw-social/backlog/blocked/CFW-V2-073.md`). Fulfils Phase 2 of
> `cfw-social/docs/v2-vps-simplification-epic.md`: *"Bundle cfw-render ⊕ cfw-skills as one
> deployable: the worker pins one skills version; kills 'skills drifted from the worker' bugs."*
>
> This doc does **not** contradict anything already decided in `BYOA-ONBOARDING-EPIC.md`
> (CFW-V2-062/066/067/068) — it packages the worker those stories assume exists, and it
> extends their design in two places (§5, §6.3) with a concrete, flagged gap.

---

## 0. Recommendation, up front

**Vendor a pinned copy of the built skill recipes into `cfw-render/skills/`, tracked as a
normal git directory, released as tagged commits.** Not a subtree, not a submodule, not an
npm/OCI package, not a container image (§2 walks through why each of those loses on at
least one hard requirement). A box (or a customer's desktop) installs cfw-render at a **git
tag**, and by construction gets the exact worker code *and* the exact skills closure that
were tested together — there is no second moving part to drift out of sync.

The same worker binary/scripts run in **two modes** — `server` (our hst fleet, global
`CFW_RENDER_WORKER_KEY`) and `byoa` (a customer's desktop, brand-scoped `RenderWorkerKey`,
per CFW-V2-062) — selected by **one new env var, `CFW_RENDER_MODE`**, set once at install
time. Mode only changes *which skills-sourcing code path runs* (§4); it is never
security-load-bearing — the server already enforces the real boundary (queue filtering by
credential type), matching this codebase's existing stance that `workerId` is "concurrency
hygiene, not a security boundary" (`render-key.ts`).

Claiming is **already** a correct, atomic, multi-worker-safe design server-side (transactional
CAS + 30-min lease + heartbeat + reaper + in-flight circuit breaker) — cfw-render does not
need, and should not build, any client-side locking (§6). The one real gap I found while
verifying that design against this repo's actual code: **`CFW_WORKER_ID` is recomputed every
tick** (`hostname:$$`, a fresh PID each systemd-timer firing), which will silently defeat
CFW-V2-068's planned per-`workerId` circuit breaker. §6.3 has the concrete fix.

---

## 1. Current state

### 1.1 cfw-render packaging today

cfw-render is **deliberately runtime-free**: `package.json` exists only to give `pnpm lint`
/ `pnpm test` a home — there is no `node_modules`, no build step, no compiled artifact. The
deployable *is* the repo: `bin/*.sh` (drainer, ctl, upload/report/subagent helpers),
`lib/director-prompt.md` (the one prompt template), `config/*.example`, `install/*` (systemd
unit + timer, launchd plist, `install.sh`).

- **Install:** `install/install.sh --prefix /opt/cfw-render --env-file /etc/cfw-render.env
  --user <svc-user>` copies `bin/*.sh` + `lib/*.md` into `$PREFIX`, renders the systemd
  unit/timer (Linux) or launchd plist (macOS) from templates, and runs `--dry` as a
  post-install gate. It is explicitly a **separate service pool** — must not share a unit
  name, tmux session, or working directory with any `cfw-gw@<slug>` Hermes gateway
  (`install/provisioner-snippet.md`).
- **Run:** `cfw-render.service` (oneshot) + `cfw-render.timer` (`OnCalendar=*:0/15`,
  `RandomizedDelaySec=60`) — every 15 minutes a **fresh process** boots, does one tick
  (claim → spawn Director → wait → reconcile), and exits. There is no long-lived daemon.
- **Status:** code-authored (`AB-RNDR-WORKER`), first deployed to `hst` 2026-08-12 per
  project memory, but `render_fleet_enabled=false` fleet-wide — the box has the binary, the
  fleet flip is a separate gated rollout (`CFW-V2-073`).
- **Config load order** (`cr_load_config` in `bin/cfw-render-lib.sh`): `/etc/cfw-render.env`
  → `$CFW_RENDER_ENV` (default `~/.gsai/secrets/cfw-render.env`) → process env wins over both.

### 1.2 How cfw-render gets skills today

`CFW_RENDER_SKILLS_DIR` (default `/data/shared/cfw-skills/cfw`) points at the **same shared
directory Hermes reads** via `skills.external_dirs`. That directory is:

```
Vasanth19/skills (private)   cfw-skills-pack (build tool)   cfw-social/cfw-skills (PUBLIC)
  author p-*/c-*/f-*/r-*  ──build:all──►  vendor .hub/ closure  ──publish:github --push──►  index.json + recipe folders
                                            + per-recipe checksum                             (flat files, raw-fetchable)
                                                                                                       │
                                                                     box: git clone (first) / git pull (hourly cron +
                                                                          provisioner installSharedPack) ──►
                                                                          /data/shared/cfw-skills/cfw
```

- **Build/publish** (`cfw-skills-pack`): `npm run build:all && npm run verify && npm run
  publish:github -- --push`. Manual today, automated by a **local launchd job**
  (`com.cfw.skills-daily-publish`, 9am) that publishes only when `Code/skills` HEAD moved.
- **Box side:** `git pull --ff-only` every hour (`/usr/local/bin/cfw-skills-pull.sh`) plus
  `cfw-provisioner installSharedPack` (clone on first provision, pull on refresh). The dir is
  made **immutable** (`chattr +i`) except during the brief window a pull is in flight
  (`cfw-provisioner/src/core/shared-skills.ts`).
- **cfw-render's role:** none. It never touches the pull cron, never toggles the immutability
  bit, never records what SHA it last saw. It reads whatever is on disk at the moment its
  Director subprocess calls `skill_view(...)`.

### 1.3 Concrete failure modes (why Phase 2 exists)

1. **No version pinning at the worker.** `CFW_RENDER_SKILLS_DIR` is a live directory, not a
   pinned artifact. `--dry` checks the dir *exists* (`bin/cfw-render.sh:61-65`) — it never
   checks *which* skills release is on disk, nor whether that matches what the worker's own
   code (`lib/director-prompt.md`, the gate-name-resolution logic in `spawn_director`)
   assumes. A worker built against skills-pack release N can silently run against release
   N+3 with no signal anywhere.
2. **Hourly-pull race, mid-render.** The pull cron and a running Director subprocess share
   the same directory with no coordination. `chattr +i` is dropped only for the pull's own
   duration — but Hermes scans "at cook time" by design (`ARCHITECTURE.md` §5c: "no gateway
   restart" is a *feature* for Hermes). For cfw-render this is a liability: a multi-minute
   video render (`CFW_RENDER_TIMEOUT_VIDEO=1800`) can start reading `SKILL.md` under one
   recipe version and finish reading `.hub/c-ffmpeg/SKILL.md` under a different one if a
   pull lands mid-tick. Nothing detects this; a bad render just... happens.
3. **Skills-drift-from-worker, structurally.** The worker's code (`spawn_director`'s default
   gate selection: `c-shorts-qa-gate` for video / `c-vision-qa` for image,
   `lib/director-prompt.md`'s `{{gate}}`/`{{failCap}}` substitutions) encodes assumptions
   about what a recipe's `acceptance.json` looks like. The skills tree evolves on the
   `cfw-skills-pack` publish cadence (daily, automatic); the worker evolves on its own git
   history (manual deploys). **Two independent clocks, one shared assumption surface, zero
   compatibility check.** This is the literal bug class the epic names.
4. **No BYOA fit.** The hourly `git clone`-the-whole-repo model is fine for *our* boxes (one
   shared dir, all brands read the union) but wrong for a BYOA render worker: a customer's
   machine should fetch only the recipes their brand is entitled to, pinned to a specific
   released SHA, checksum-verified per file — which is exactly what `CFW-V2-067` already
   designed (`byoa-fetch-plan.ts`, SHA-pinned `raw.githubusercontent.com/.../<pinnedSha>/...`
   fetch). cfw-render's packaging must accommodate **two legitimate skills-sourcing
   strategies**, not force BYOA through the fleet's git-clone path (§4).

---

## 2. Options evaluated

| | (a) git subtree | (b) vendored artifact + manifest | (c) git submodule | (d) npm/OCI package | (e) single container image |
|---|---|---|---|---|---|
| **Version pinning** | Strong (squash-merged commit = a point in time) | Strong (manifest records source SHA + per-recipe checksums; git commit = the pin) | Strongest (a 40-char SHA in the parent tree, unambiguous) | Strong (registry semver/digest) | Strongest (content-addressed image digest) |
| **Update propagation from `Code/skills`** | `git subtree pull --squash` from the *public* repo — an extra merge step on top of the existing build+publish pipeline | A small sync script copies `dist-public/` into `skills/` + writes `VERSION.json`, then a normal commit — reuses the pipeline as-is | `cd skills && git checkout <sha> && cd .. && git add skills && git commit` | Requires a registry publish step (npm publish / `oras push`) — new infra to operate | Requires a full image build (base OS + node/ffmpeg/claude CLI + skills) on every skills update |
| **Box deploy story (no hourly pull cron)** | `git pull` a tag — trivial | `git pull`/`git checkout` a tag — trivial | Needs `git submodule update --init --recursive` on every clone/pull — an extra step every operator and every install script must remember | Needs a package manager + auth to a registry on the box — new attack surface + new failure mode ("registry unreachable") | Needs Docker/Podman on the box, image pull, credential/volume wiring for the `claude` CLI's OAuth session |
| **Rollback** | `git revert` the subtree-pull commit | `git checkout <previous tag>` | `git checkout <previous commit>` (submodule pointer reverts with it) | `npm install <pkg>@<prev>` / re-pull previous digest | redeploy previous image tag |
| **Eval-gate integrity** | Preserved (files come from the same publish pipeline, gates already ran upstream) | Preserved, **plus** can re-run `c-eval-runner`'s golden tripwire against the vendored copy as a pre-tag CI gate (own repo, own CI) | Preserved | Preserved, but the registry becomes a second trust boundary to audit | Preserved, but baking `acceptance.json`/gates into an immutable image makes brand-override iteration (§7.3) awkward |
| **Dev ergonomics** | Full upstream history import is unnecessary noise (skills history isn't something cfw-render devs need to `git blame`) | Plain directory, `git clone` "just works," `CFW_RENDER_SKILLS_DIR` override still works for local dev pointing at `cfw-skills-pack/dist-public` | Classic submodule footguns: forgotten `--recurse-submodules`, detached HEAD confusion, box clones need extra creds/network to a second repo at clone time | Adds a Node/npm runtime dependency to a repo whose own `package.json` says "no JS runtime" — contradicts the design | Heaviest: requires Docker literacy from anyone debugging a stuck render; worst fit for the desktop/BYOA target (asking a customer to run Docker is much higher friction than "clone a folder of bash scripts") |
| **BYOA desktop fit** | Same as box — but a customer would need `git` + push access considerations for their own copy; fine but heavier than necessary | Fine — same tag-pull `install.sh` works verbatim on a laptop; §4 additionally lets BYOA skip vendoring entirely and use the SHA-pinned selective fetch (067) | Same friction as the box case, amplified for a non-technical customer | Poor — requires npm auth on a customer machine for a private/scoped package, or a public npm namespace nobody asked for | Poor — Docker Desktop as a hard prerequisite for a lightweight bash worker is disproportionate |
| **Verdict** | Workable but solves a problem (preserving history) nobody has | **Recommended** | Rejected — footgun class outweighs the marginal pinning-precision gain over (b) | Rejected — wrong runtime philosophy, disproportionate infra | Rejected for *this* phase — worth revisiting later purely for `hst`-side isolation, not as the BYOA answer |

**Why (b) over (c), specifically:** a git submodule is objectively the most explicit pin (one
SHA, one line in `.gitmodules`), but every operational surface here — `install.sh`, a fresh
`git clone` on a customer's laptop, a provisioner reprovision script, `hst`'s eventual systemd
unit — has to remember an extra flag or step, forever, or silently get a stale/empty `skills/`
dir. Option (b) makes the pin **exactly as explicit** (a `VERSION.json` with the source SHA
and per-file checksums, checked at `--dry` and tick-start, §5) while making "clone the repo"
the *entire* install story, with zero submodule-specific tooling anywhere. That trade — give
up nothing on pinning precision, remove a whole footgun class — is the deciding factor.

**Why not (e) container image, in more depth:** cfw-render's Director is a `claude` CLI
subprocess running under the operator's OAuth session (`bin/cfw-render.sh` spawns it with
`CFW_RENDER_DIRECTOR_MODEL`, `-p "$prompt" --dangerously-skip-permissions`), plus a GLM/Kimi
fan-out subprocess helper reading `~/.gsai/secrets/ollama-keys.env`. Containerizing that means
either baking long-lived credentials into an image (bad) or mounting host credential
directories into every container run (workable but adds real complexity for zero benefit over
plain process isolation on a box that's already dedicated to this one job). It also fights the
BYOA goal directly: the whole point of "the worker runs on the customer's own compute" is low
friction — `git clone && ./install.sh` beats "install Docker, authenticate a registry, `docker
run` with the right volume mounts" for a non-infra audience. Container packaging can be
revisited later as a **pure `hst`-side deployment optimization** (e.g. if the fleet grows past
what bare-metal + systemd comfortably manages) — it is an orthogonal decision, not this
phase's.

---

## 3. Recommended repo layout

```
cfw-render/
├── bin/                        # unchanged — drainer, ctl, report/subagent/upload helpers
├── lib/
│   └── director-prompt.md      # unchanged
├── skills/                     # NEW — vendored, pinned recipe closure (git-tracked)
│   ├── VERSION.json            # NEW — the pin: source SHA + per-recipe checksum + build metadata
│   ├── index.json              # copy of cfw-skills' own index.json (per-file sha256), for the
│   │                           #   same verify logic BYOA fetch-plan already uses (§4)
│   ├── p-reels-pip/            # ...one dir per enabled recipe, byte-identical to what
│   ├── p-reels-spotlight/      #    cfw-social/cfw-skills ships (SKILL.md, acceptance.json,
│   ├── p-carousel/             #    .hub/ vendored closure, templates/, scripts/)
│   └── ...
├── config/
│   └── cfw-render.env.example  # UPDATED — adds CFW_RENDER_MODE, CFW_RENDER_SKILLS_SOURCE,
│                               #   CFW_RENDER_WORKER_ID_FILE (§4, §6.3)
├── install/
│   ├── install.sh               # UPDATED — records CFW_RENDER_MODE at install, seeds a stable
│                                #   worker-id file (§6.3), runs the new skills-verify check
│   ├── cfw-render.service / .timer / com.cfw.render.plist   # unchanged shape
│   └── byoa-installer-notes.md  # NEW — thin doc: how the BYOA-mode skills-fetch step differs
├── scripts/
│   ├── lint.sh                  # unchanged
│   ├── sync-skills.sh           # NEW — pulls the latest published `dist-public/` from
│   │                            #   cfw-skills-pack (or the public repo) into skills/,
│   │                            #   regenerates VERSION.json, does NOT commit (review + commit
│   │                            #   is a human/CI step, same discipline as any dependency bump)
│   └── verify-skills-bundle.sh  # NEW — checksum-verifies skills/ against VERSION.json; the
│                                #   same check `--dry` runs; also runs c-eval-runner's golden
│                                #   tripwire against the vendored copy pre-tag (§7.3)
└── docs/
    └── PACKAGING-DESIGN.md      # this file
```

`skills/VERSION.json` shape (mirrors the public repo's own `index.json` fields so the same
checksum algorithm — `sha256:` + sha256 of the post-frontmatter body, per
`cfw-skills-pack/src/skill-checksum.mjs` — verifies both):

```json
{
  "bundledAt": "2026-08-18T00:00:00Z",
  "sourceSha": "<Code/skills commit the pack was built from>",
  "skillsRepoSha": "<cfw-social/cfw-skills commit this was synced from>",
  "aggregateChecksum": "sha256:...",
  "recipes": {
    "p-reels-pip": { "version": "1.4.0", "checksum": "sha256:...", "fileCount": 9 },
    "p-carousel":  { "version": "1.1.0", "checksum": "sha256:...", "fileCount": 6 }
  }
}
```

---

## 4. Same worker, two deploy targets — config-driven, not a fork

There is exactly **one** `cfw-render` codebase, cloned at exactly **one** git tag, on both
`hst` and a customer's desktop. The only per-install differences are: which credential is in
`cfw-render.env`, and one new mode flag that decides which skills-sourcing code path runs.

```bash
# config/cfw-render.env.example — additions
# ── Deploy mode (set ONCE at install time — never re-derived at runtime) ────
# server = our own fleet (hst); byoa = a customer's own machine.
# This is OPERATIONAL config only (which skills source + which setup flow to
# run) — it is NEVER the security boundary. The server enforces the real
# boundary via which credential family resolves (CFW_RENDER_WORKER_KEY vs a
# brand-scoped RenderWorkerKey, per cfw-social's render-key.ts) regardless of
# what this box thinks its own mode is.
CFW_RENDER_MODE=server            # server | byoa

# ── Skills sourcing strategy (derived default from CFW_RENDER_MODE, override
# only for local dev / testing the other path) ──────────────────────────────
# bundle = read the vendored, pinned skills/ shipped in THIS git tag (fast,
#          offline, byte-identical across every box — the fleet default).
# fetch  = pull only the entitled recipes via cfw-social's SHA-pinned
#          byoa-fetch-plan (CFW-V2-067) into a local cache — the BYOA default,
#          because a customer's brand is curated to a SUBSET of recipes and
#          the bundle's full closure would be wasted/unentitled bytes.
CFW_RENDER_SKILLS_SOURCE=bundle   # bundle | fetch
```

| | `server` (hst fleet) | `byoa` (customer desktop) |
|---|---|---|
| Credential | Global `CFW_RENDER_WORKER_KEY` (`cfw-render-key` header, sees ALL brands' queues) | Brand-scoped `RenderWorkerKey` (`cfw_render_<brandSlug>_…`, sees only its own brand — enforced server-side, CFW-V2-062) |
| Skills source | `CFW_RENDER_SKILLS_SOURCE=bundle` — the vendored `skills/` tree pinned in this git tag | `CFW_RENDER_SKILLS_SOURCE=fetch` — `bin/cfw-render-fetch-skills.sh` (NEW) calls the brand key's fetch-plan (067), raw-fetches only entitled recipes into `~/.cfw-render/skills-cache/<brandId>/`, writes the **same `VERSION.json` shape** so §5's verify logic is one code path regardless of source |
| Setup/bootstrap | None — the box is pre-provisioned by us; `--dry` is the only gate | Walks the `BrandRenderWorkerSetup` state machine (CFW-V2-066): `not_installed → deps → credential → recipe_fetch → provider_keys_needed → probe_render → ready`. `claim_render_order` self-redirects here until `ready` (066's poller redirect) |
| Provider keys | JIT-fetched from the vault into skill subprocesses (existing `project_hermes_jit_vault_keys` pattern) | 100% local — customer's own `.env`, never transits cfw-social (BYOA epic decision 2) |
| Probe render | N/A | `taskOrder.probe:true` order proves claim→render→upload→complete without minting a dish (CFW-V2-068) |
| Circuit breaker | N/A (trusted, ops-owned) | Per-`(brandId, workerId)` — see the gap flagged in §6.3 before this is trustworthy |
| Origin tag | `RenderOrder.origin="fleet"` | `RenderOrder.origin="byoa"` (CFW-V2-068, report-only, no metering effect) |

`install.sh` gets one new flag: `--mode server|byoa` (default `server`, matching today's only
real deploy target). It writes `CFW_RENDER_MODE` into the rendered env file and, when
`byoa`, prints the pointer to `install/byoa-installer-notes.md` instead of assuming
`skills/` needs anything — a BYOA install genuinely does not need the vendored `skills/`
directory present at all (it can be `git sparse-checkout`'d out, or just left on disk unused;
disk cost is small enough not to bother excluding it by default).

**Why not a server-computed/pushed "mode" the worker fetches every tick** (as opposed to a
local, install-time flag): the credential *is* the mode, already, at the only place that
matters for security (which queue rows the server hands back). A second, independently
mutable "mode" field in the DB that the worker polls would be a **second source of truth**
that can drift from the credential in the env file — exactly the class of bug this whole
epic exists to kill. cfw-social's control panel already gets everything a "mode" toggle would
give an operator, for free, by surfacing what CFW-V2-062/066/068 already ship: Settings →
API Keys shows whether a brand has a global (N/A, env-only) or brand-scoped render key minted;
`BrandRenderWorkerSetup.state` shows BYOA setup/readiness; `/admin/fleet/renders` shows
`origin` per completed order. That *is* the mode visibility surface — no new field needed.

### 4.1 Credential SCOPE — the mode is a *set of brands*, resolved from ownership (DECIDED 2026-08-18)

The BYOA credential is **not** brand-only. `Brand.ownerId → User` is one-to-many (one user owns
many brands — e.g. Sindhu Naidu owns *both* Earthy Table and her personal brand), so a desktop
worker running as a **user's** assistant must be able to render for **every brand that user
owns**, from one install, one key. There are therefore **three credential scopes, one
mechanism**, all resolved and enforced server-side — never trusting the worker:

| Scope | `claim_render_order` filter | "Mode" / deploy target | Credential |
|---|---|---|---|
| **global** | (none) — all brands | `server` — hst fleet | env-only `CFW_RENDER_WORKER_KEY` |
| **user** *(NEW — extends 062)* | `AND brand_id IN (SELECT id FROM brands WHERE owner_id = <keyUser>)` | `byoa` / **user-assistant** — a user's desktop | user-scoped `RenderWorkerKey` |
| **brand** | `AND brand_id = <boundBrand>` | narrow per-brand box | brand-scoped `RenderWorkerKey` (CFW-V2-062 as-is) |

- **The scope is the mode.** "server vs user-assistant" is a *label* for the credential's scope +
  deploy target, not an independent toggle. This is why an operator-flippable, worker-polled
  "mode" field is rejected (§4 above): the user scope — *the set of brands the user owns* — is a
  live query that changes as the user creates/deletes brands. Only a server-side ownership
  resolution stays correct; a static DB flag or an env value the worker self-asserts cannot.
- **Claim protocol unchanged.** The transactional CAS (§6.1) is untouched — user scope just adds an
  `IN (owned brand ids)` predicate to the same `WHERE status='queued'` guard, so the single-winner
  guarantee still holds when a user's desktop worker and the hst fleet both poll that user's brands
  (exactly one claims each order; the loser retries next tick).
- **v1 = ownership only.** The `@@unique([userId, brandId])` membership join means a user can be a
  *non-owner* member of a brand; v1 scopes the user key to `owner_id = user` (the entitlement/billing
  boundary) and defers membership-based scope.
- **Deferred (v2): render affinity.** "Prefer a user's own desktop worker over the fleet for that
  user's brands, to offload our compute" is a routing optimization on top of this — correctness does
  not depend on it (the CAS already makes double-claim impossible). Not in scope now.
- **Server-side work this implies (gated, not autonomous):** CFW-V2-062 currently mints brand-scoped
  keys only; this adds a **user-scoped `RenderWorkerKey`** (scope = user, resolved to owned brand ids
  at claim time) + the `IN (...)` predicate in `render-order-worker.ts`'s claim CAS + a schema field
  for key scope. That is cfw-social server-side + a migration — it runs through the normal supervised
  path, not a cfw-render branch edit.

---

## 5. Pinning + verification at worker start

Both `--dry` and the top of every real tick call a new `cr_verify_skills_bundle` (in
`bin/cfw-render-lib.sh`, backed by `scripts/verify-skills-bundle.sh`'s logic ported to the
existing bash+`sha256sum`/`shasum` pattern already used elsewhere in this repo — no new
runtime dependency):

1. Read `$CFW_RENDER_SKILLS_DIR/VERSION.json` (bundle mode) or the per-brand cache's
   equivalent manifest (fetch mode).
2. For each recipe the *current tick's claimed order* references (`taskOrder.recipe`),
   re-hash the on-disk `SKILL.md`/closure and compare against the manifest's `checksum`.
   Mismatch → **do not spawn the Director**; call `block_render_order` with an owner-safe
   reason ("this render's recipe files are out of sync — a redeploy is needed") and log the
   expected/actual checksum pair for an operator. This turns failure mode #2 (§1.3, a pull
   landing mid-tick) into a loud, attributable block instead of a silent bad render — and
   since bundle mode has no pull cron at all (skills only change when a new git tag is
   deployed), this check is normally a no-op fast-path, not a per-tick tax.
3. **Forward-looking, once CFW-V2-073 lands its half:** if the claimed order carries a
   `taskOrder.pinnedSkillsVersion` (the render-order-side pin CFW-V2-073 adds), compare it
   against this worker's own `VERSION.json.recipes[recipe].version`. A mismatch here is a
   **different** signal than a checksum mismatch — it means the order was queued expecting a
   skills release this worker hasn't been upgraded to yet (or vice versa) — same
   `block_render_order` treatment, distinct reason string, so `/admin/fleet/renders` can tell
   "corrupted bundle" apart from "worker needs a redeploy."

`--dry`'s existing PASS/FAIL row format (`bin/cfw-render.sh:36-43`) gets one new row:
`row "skills:pinned" ...` reporting the loaded `sourceSha` short-form and recipe count, so a
human running `--dry` after a deploy sees at a glance which skills release is live.

---

## 6. Multi-worker concurrency / row-locking

**This is already solved, correctly, server-side — cfw-render must not duplicate it.**
Verified by reading `src/lib/mcp/tools/render-order-worker.ts` and
`src/lib/jobs/runners/reap-render-orders.ts` directly (cfw-social):

### 6.1 The claim protocol (as it exists today)

- `claim_render_order` runs inside a Prisma `$transaction`: `findFirst` the oldest queued
  order (`priority DESC, createdAt ASC`), then `updateMany({ where: { id, status: "queued"
  }, data: { status: "claimed", claimedBy: workerId, leaseExpiresAt: now+30m, attempts:
  {increment:1} } })`. The `WHERE status: "queued"` on the `updateMany` **is** the
  compare-and-set — if two workers race, exactly one `updateMany` affects a row
  (`count===1`); the loser gets `count===0` → `null` → `{ order: null }`, and retries next
  tick. Brand-scoped keys add `AND brand_id = <bound>` to the same CAS (CFW-V2-062) — a BYOA
  worker's claim query is filtered before the race even starts.
- **Heartbeat = lease renewal.** `append_render_event` extends `leaseExpiresAt` by another 30
  minutes on every progress event, and flips `claimed → rendering` on the first `stage`
  event. cfw-render's `cr_event` helper (`bin/cfw-render-lib.sh`) already calls this at each
  pipeline stage — the heartbeat is a side effect of normal operation, nothing new to build.
- **Mutation authorization** (`append`/`complete`/`block`) all route through
  `requireClaimedOrder`, which returns an **identical 403** for missing / foreign-claimed /
  terminal / lease-expired orders — never leaks which case it was.
- **Reaper** (`reap-render-orders`, Vercel cron today, Trigger.dev-eligible): every run,
  scans non-terminal orders (`claimed|rendering|gating`) whose lease expired, requeues them
  (`status: "queued"`, clears claim/lease) if `attempts < MAX_ATTEMPTS=3`, else fails them
  terminally with an owner-safe reason. A `leaseExpiresAt: null` fallback (60-min stale-claim
  cutoff) covers the pathological "claimed but lease never written" case.

This covers exactly the scenarios asked for: atomic claim (yes, `FOR UPDATE`-equivalent CAS
via the transactional `updateMany` guard), crash-mid-render (yes, lease expiry + reaper
requeue), duplicate-delivery safety (yes — `complete_render_order`'s status guard makes a
reclaimed-then-late-arriving completion from the original worker a 403, since the order has
moved past the states `requireClaimedOrder` accepts), and visibility (`RenderOrderEvent` rows
+ the planned `origin` tag give `/admin/fleet/renders` everything needed to show which worker
holds which order).

### 6.2 What cfw-render's packaging must NOT do

Do not add a second locking layer (a local lockfile keyed by orderId, a Redis SETNX, a
"worker registry" table). The queue is already single-writer-safe at the database level
regardless of how many workers — hst fleet ticks and N customer desktops simultaneously —
are polling it. cfw-render's only job is to be a well-behaved client: claim, heartbeat via
`append_render_event`, and always terminate via `complete_render_order` or
`block_render_order` (never just exit silently — `spawn_director`'s existing timeout/crash
handling already does this correctly).

### 6.3 The gap: `workerId` is not stable across ticks — breaks the planned circuit breaker

`bin/cfw-render-lib.sh:83`: `CFW_WORKER_ID="${CFW_WORKER_ID:-$(hostname -s):$$}"`. Because
`cfw-render.service` is a **oneshot** unit fired fresh by the timer every 15 minutes, `$$` is
a **new PID every tick**. `workerId` today is explicitly documented as "concurrency hygiene,
not a security boundary" (correct, and fine for the CAS/lease/reaper mechanics in §6.1, which
never key anything long-lived off `workerId`).

CFW-V2-068 introduces a **per-`(brandId, workerId)` circuit breaker**
(`BrandRenderWorkerSetup.consecutiveFailures` / `suspendedUntil`) intended to degrade a
broken BYOA install gracefully after repeated lease-expiry failures. As specified, that
breaker will not accumulate: a BYOA install running under the same 15-minute-timer,
fresh-PID-per-tick pattern presents a **different `workerId` on every single tick**, so
`consecutiveFailures` for any one `workerId` value never exceeds 1 before a new one starts at
0 again. The breaker would only ever fire for a *long-lived* process that claims, fails, and
retries within one process lifetime — not for the dominant "timer fires, tick fails, timer
fires again 15 minutes later" pattern this whole repo is built around.

**Packaging-side fix (this repo, in scope for the CFW-HST-BUNDLE build):** stop deriving
`workerId` from `hostname:$$`. Seed a **stable, persisted install identity** once, at install
time:

```bash
# install.sh (new step) — seed once, never regenerate on a re-run
WORKER_ID_FILE="$CFW_RENDER_STATE_DIR/worker-id"
[[ -f "$WORKER_ID_FILE" ]] || uuidgen > "$WORKER_ID_FILE"   # or `hostname -s`-<random> if uuidgen absent
```

```bash
# cfw-render-lib.sh — read the persisted id; hostname:$$ becomes free-text
# forensic context in log/event MESSAGES only, never the claim identity
CFW_WORKER_ID="$(cat "${CFW_RENDER_WORKER_ID_FILE:-$CFW_RENDER_STATE_DIR/worker-id}")"
export CFW_WORKER_ID
```

This is a small, additive change (new file, one line of config, one line of lib code) that
makes `workerId` mean "this install," not "this process" — which is what CFW-V2-068's breaker
needs to key off in order to actually suspend a repeatedly-failing customer install rather
than resetting to a clean slate every 15 minutes. **Flag this to whoever implements
CFW-V2-068 server-side** — the alternative fix (key the breaker off the `RenderWorkerKey` id,
which is already stable, instead of the caller-supplied `workerId`) is also valid and may be
less invasive on the cfw-social side; either fix closes the gap, but *someone* needs to pick
one before 068 ships, or the breaker will look tested-and-green in isolated integration tests
(one process, one `workerId`, sustained failures) while doing nothing in the actual
15-minute-timer deployment topology.

---

## 7. Migration steps

Staged, non-breaking, exactly matching the discipline already written into
`CFW-HST-BUNDLE.md` and the epic's "cutover invariants" (parallel-run, brand-by-brand, never
big-bang):

1. **Build the bundle mechanism in this repo (additive, zero prod risk today).**
   `render_fleet_enabled=false` fleet-wide means cfw-render isn't serving live traffic yet —
   this is the ideal window to land §3-§6 without any parallel-run choreography. Add
   `scripts/sync-skills.sh`, `scripts/verify-skills-bundle.sh`, the `skills/` dir (first
   sync from the current `cfw-skills-pack/dist-public`), `CFW_RENDER_MODE` /
   `CFW_RENDER_SKILLS_SOURCE` config, the stable-`workerId` fix (§6.3), and the `--dry`
   verify row (§5). Tag a release once `pnpm lint && pnpm test` plus the new verify script
   are all green.
2. **Point `CFW_RENDER_SKILLS_DIR` at the bundled `skills/` for cfw-render specifically —
   this does NOT touch Hermes.** `Brand.renderFleetEnabled` is still `false`; this step only
   changes what a `--dry` run and (once flipped per-brand) a real tick would read. The
   existing shared dir + hourly `cfw-skills-pull.sh` cron **stay alive, untouched**, still
   serving all Hermes brands.
3. **Prove it on the box.** Re-run `docs/deploy.md`'s existing supervised runbook (§2-§6:
   scratch root check, probe upload, install as a separate service pool, `--dry`, enable
   the timer, Bujji-first cutover) — now with the bundled skills path active. Nothing in
   `deploy.md`'s steps changes; only what `CFW_RENDER_SKILLS_DIR` resolves to does.
4. **Wire BYOA fetch mode (`CFW_RENDER_SKILLS_SOURCE=fetch`)** once `CFW-V2-067`'s
   `byoa-fetch-plan.ts` is available to call against — add
   `bin/cfw-render-fetch-skills.sh` as a thin client of that plan (§4), verified by the same
   `verify-skills-bundle.sh` logic against the manifest it writes.
5. **Only after Phase 2's stated exit ("Hermes renders nothing")** — i.e. after the hard
   submit-vs-inline rule (`CFW-V2-073`) is live and verified fleet-wide — retire
   `/usr/local/bin/cfw-skills-pull.sh` and remove `/data/shared/cfw-skills/cfw` from the box.
   By that point cfw-render no longer reads it (step 2 already decoupled it); the only
   remaining reader was Hermes, and Hermes is the thing Phase 2 is removing skills access
   from. This is a **box-wide, ops-gated deletion** — not something this repo's build can
   or should force.

---

## 8. Risks

- **Eval-gate golden tripwire must run against the vendored copy, not just upstream.**
  `c-eval-runner/test/golden.sh` (source repo) locks the floor by asserting a known-bad
  render comes back FAIL. `scripts/verify-skills-bundle.sh` (§3) must invoke the vendored
  copy's `c-eval-runner` closure against that same golden fixture as a **pre-tag CI gate** in
  *this* repo — otherwise a vendoring bug (partial copy, stale `.hub/` closure, a checksum
  script drift between `cfw-skills-pack` and this repo's bash port) could ship a
  bundle whose gate silently passes bad renders, which is precisely the failure category
  this whole design exists to prevent. Do not treat "the source repo's tests are green" as
  sufficient — the vendored copy is a distinct artifact and needs its own gate.
- **`brand-overrides/<slug>/acceptance.json` has no home yet, and bundling must not
  foreclose one.** `c-eval-runner` already supports `--brand <slug>` (deep-merges
  `<recipe>/brand-overrides/<slug>/acceptance.json` over the base spec), but per the
  skills-pack audit (`cfw-skills-pack/docs/skills-audit.md` §4.4/§5 P6) this layer is **not
  built yet** — it's the last phase of that doc's rollout plan, and nothing in the current
  public `cfw-social/cfw-skills` repo or the shared box dir carries per-brand override
  content today (`brand-targets.json`/`link-brands.mjs` is a different, unrelated mechanism
  — Paperclip Creative Director workspace symlinks for marketing content brands, not CFW
  render-worker eval overrides). **Do not vendor `brand-overrides/` into the immutable,
  git-tracked `skills/` tree** when that layer lands — a brand's override content is
  per-tenant data (potentially per-brand-vault-scoped for BYOA), not a build artifact shared
  across every install. Reserve a **writable, non-git-tracked** mount point instead (e.g.
  `$CFW_RENDER_STATE_DIR/brand-overrides/<slug>/`, populated at claim time from the order's
  `brandId` via a small MCP fetch, or symlinked in for the fleet case) so the pinning
  guarantee in §5 stays meaningful — a checksum-verified recipe body with a
  dynamically-supplied brand override layered on top, not a bundle whose contents quietly
  vary per brand.
- **The existing hourly `cfw-skills-pull.sh` cron is live infrastructure serving 9 production
  brand gateways today — do not touch it as a side effect of this work.** §7 step 2 is
  written specifically to decouple cfw-render from that dir without modifying it. The cron's
  retirement (§7 step 5) is explicitly gated on Phase 2's stated exit criterion and is an
  `hst`-wide ops action, not a `cfw-render` repo change — flag it as a **separate, later,
  supervised step**, never bundle it into a cfw-render release.
- **`CFW_RENDER_MODE` is advisory, not enforced — a misconfigured box degrades safely but
  silently.** If someone deploys with `CFW_RENDER_MODE=byoa` but forgets to switch
  `CFW_RENDER_SKILLS_SOURCE` off `bundle`, the worker just uses the pinned bundle instead of
  a curated fetch (wasted disk, not a security issue — the server-side brand filter on the
  claim query is what actually protects tenant isolation, per §4's design note). Worth an
  operator-facing `--dry` WARN row (not FAIL) when `CFW_RENDER_MODE=byoa` and
  `CFW_RENDER_SKILLS_SOURCE=bundle` are both set, so a misconfiguration is visible without
  being treated as a hard failure it isn't.
- **CFW-V2-073's server-side pin (order-carries-its-expected-skills-version) isn't shipped
  yet** (status: blocked, merge-conflict note on the card). §5 step 3 of this doc's
  verification logic is written to activate automatically once that lands (it's a
  conditional check keyed on the field's presence) — this doc's recommendation does not
  block on it, but the full "kills skills-drift bugs" promise isn't complete until both
  halves (this repo's pinning + cfw-social's order-side pin) are live together.

---

## 9. Relationship to existing backlog

This doc is the detailed design the following cards were waiting on — align, don't re-litigate:

- **`CFW-HST-BUNDLE`** (this repo, `backlog/queue/`) — this doc *is* the design its
  acceptance criteria ask for. §3's layout satisfies AC1; §7 satisfies the staged/
  non-breaking transition ACs; the `install.sh`/fetch-plan combination in §4 satisfies "works
  identically on HST and a desktop."
- **`CFW-V2-073`** (cfw-social, blocked) — its AC3 ("a render order records the pinned
  skills/recipe version it must be rendered with") is the server-side counterpart §5 step 3
  is written to consume. Nothing here duplicates its scope (fleet-enable tooling, doctrine
  rule) — this doc only depends on its schema addition existing eventually.
- **`BYOA-ONBOARDING-EPIC.md` / CFW-V2-062/066/067/068** — fully read and reconciled: §4's
  mode split maps directly onto the credential-family split 062 already shipped; §4's
  `fetch` skills-sourcing path is a thin client of 067's fetch-plan (not a reimplementation);
  §6.3 flags a concrete gap in 068's breaker design that this repo's packaging can close on
  its side. `docs/byo-cfw-agent.md`'s "BYO CFW Agent" (full personas + brand DNA, via
  `@cfw-social/setup`) is a **different, broader** product than the narrow BYOA render
  worker this doc packages — the two should not be conflated; a BYOA render worker install
  never touches personas, brand DNA, or the full ~64-tool brand MCP surface.
