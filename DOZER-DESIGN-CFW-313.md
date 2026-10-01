# DOZER-DESIGN-CFW-313

[ENG] HeyGen step must use the v1 remote MCP (OAuth → plan credits) and take provider
credentials from the brand's account settings, never the worker's vault

## Confirmed root cause

The HeyGen recipe (`c-heygen`, a sub-skill vendored into this repo's `.hub/` under
`p-reels-pip-heygen`, `p-reels-spotlight-heygen`, `p-reels-split-heygen`, `p-longform`, and
`p-clone-reel`) sources `HEYGEN_API_KEY` from **`~/ecosystem/vault/secrets.env`** — a flat
file on the render **worker's own disk** — on every path that actually calls HeyGen:

- Path 2 (MCP, the documented *default* render path): `mcp__heygen__generate_avatar_video`,
  a **stdio** MCP keyed by that same worker-vault API key. `SKILL.md`'s own table: "Stdio MCP
  + API key → `api_credits`" (i.e. it bills against whatever plan the worker-vault key happens
  to belong to, not the brand's).
- Path 4 (REST fallback): `curl … -H "X-Api-Key: $HEYGEN_API_KEY"` reading the same var.
- `LEARNINGS.md` ("1080p needs the REST API, not the MCP") reconfirms the key source
  explicitly: `~/ecosystem/vault/secrets.env` `HEYGEN_API_KEY`.

This is a **single shared key for every brand the render fleet serves**. Two problems follow
directly from the ticket title:

1. **Wrong credential source.** Every brand's avatar render draws against one worker-owned
   HeyGen account/key instead of the brand's own HeyGen account — a brand with no HeyGen
   relationship at all still renders (against someone else's wallet), and a brand that pays
   for its own HeyGen plan never uses it.
2. **Wrong MCP tier.** `mcp__heygen__generate_avatar_video` is a **stdio** MCP authenticated by
   API key, billing `api_credits`. The ticket asks for the **v1 remote MCP** — HeyGen's own
   hosted MCP server, authenticated by **OAuth**, billing against the connected account's
   **plan credits**. This session's own MCP config actually proves the remote server exists
   today as a connector (`heygen-remote`, listed "requires authentication… via `claude mcp` or
   `/mcp`") — but nothing in `~/ecosystem/harness/skills` or this repo references it by name;
   `grep -rn "heygen-remote" ~/ecosystem` returns nothing. It is a live capability with zero
   integration.

## What "the brand's account settings" already means in this system

cfw-social (the control-plane app this worker drains `RenderOrder` rows from) already has a
**brand-scoped provider-key vault** — this is not new territory, it already covers HeyGen:

- `BrandSecret` (`prisma/schema.prisma`) — one encrypted row per `(brandId, provider)`.
  `brand-vault-providers.ts`'s `KNOWN_PROVIDERS.heygen = { envVar: "HEYGEN_API_KEY", label:
  "HeyGen", powers: "Avatar videos" }` — i.e. cfw-social already has a brand-settings surface
  (`/[brandSlug]/settings/vault`) where an owner pastes their **own** HeyGen API key, and a
  `get_brand_secrets` MCP tool that returns it decrypted for injection into a skill
  subprocess.
- This is **API-key** credentials, though — not OAuth, not "plan credits". The ticket's "v1
  remote MCP (OAuth → plan credits)" needs a *different* connection shape: an OAuth grant,
  stored the way `PlatformConnection` already stores social-platform OAuth
  (`accessTokenEnc`/`refreshTokenEnc`/`tokenExpiry`/`scopes`) — HeyGen has no row in that
  table today (`platform` values there are social platforms only).
- Critically, **`get_brand_secrets` is not reachable from this worker at all.** The
  render-worker credential (`cfw-render-key` → `CFW_RENDER_WORKER_KEY`) mounts
  `createRenderWorkerMcpServer()`, which registers **exactly four tools** — `claim_render_order`
  / `append_render_event` / `complete_render_order` / `block_render_order` — by deliberate
  design (`docs/render-worker-auth.md` §3: "a render key never constructs the brand server…
  structurally absent… zero risk of a forgotten per-tool check"). There is no fifth tool today
  for "give me this order's brand's HeyGen credential," OAuth or API-key.

## Scope boundary — this is a three-repo fix; only one piece lives here

Following the same boundary CFW-312 drew (`~/ecosystem/harness/skills` is "a different
repo/owner outside this worktree's scope"), this ticket spans three ownership domains and
**this worktree can design and implement only one of them**:

| Piece | Owner | What it needs to do | In scope here? |
|---|---|---|---|
| A. Brand HeyGen OAuth connection + embedding a live, scoped credential into the claimed order | `cfw-social` (`/Users/vasanth/initiatives/cfw/cfw-social/`) | New "connect HeyGen" OAuth flow in brand account settings (alongside the existing API-key vault page); resolve + refresh the brand's token server-side; embed a short-lived scoped credential into `taskOrder` at claim time | **No** — separate repo, separate Dozer `repo:` label |
| B. The recipe content itself — call the v1 remote MCP instead of the stdio MCP/REST, read the credential from env instead of hardcoding a vault path | `~/ecosystem/harness/skills/c-heygen` | Rewrite `SKILL.md` Path 2 (and the `LEARNINGS.md` 1080p note) to target `heygen-remote` / OAuth, drop the `~/ecosystem/vault/secrets.env` reference | **No** — out-of-worktree skill source, synced in via `scripts/sync-skills.sh`, never hand-edited here (`skills/README.md`) |
| C. The render worker's job: get the brand-scoped credential cfw-social embedded in the order into the Director's process, and refuse to render (fail fast) rather than fall back to any worker-local key if it's absent | `cfw-render` (this repo) | `bin/cfw-render.sh` / `bin/cfw-render-lib.sh` plumbing + a portability-style gate | **Yes — this is the piece this design covers** |

This design doc proposes a complete plan for C, specifies the exact contract C needs from A
(so A can be scoped as a precise, independent companion issue), and flags B as a second
companion issue. **Recommendation: file two companion Linear issues** — one `repo:cfw-social`
for the OAuth connection + order-embedding, one against the skills library (no `repo:` label
fits today; route through whichever lane owns `~/ecosystem/harness/skills` content changes) —
both `blocked-by`/`blocks` CFW-313, since C alone cannot produce a working render (it will
simply block every HeyGen order with a clear reason until A ships, and the recipe still calls
the old path until B ships). This mirrors Fail Fast: no silently inventing cfw-social's API
surface in this doc, and no silently leaving the worker vault as an unstated fallback.

## Approach — piece C (this repo)

### Why "order-embedded credential," not a new broad MCP tool

Two existing hard constraints point at the same answer:

1. **The render-worker MCP surface is deliberately narrow** (`docs/render-worker-auth.md`
   §3) — "Adding a tool here is the single review surface for the renderer-only-touches-
   render_orders invariant." A new `get_order_brand_credential`-shaped tool would need to be
   reviewed against that invariant on the cfw-social side; it is not this repo's call to make,
   but the pattern I'm recommending for piece A avoids needing one at all.
2. **The Director is explicitly forbidden from looking anything up live**
   (`lib/director-prompt.md`: "read ONLY `order.json`… NEVER query any brand database, NEVER
   make a network call except to fetch ingredient URLs that appear inside `order.json`"). A
   live "fetch my brand's HeyGen token" call from inside the Director's turn is categorically
   the kind of call this mandate exists to prevent.

Both constraints are satisfied by the pattern **already in use** for other brand-specific
render inputs: `AVATAR_ID` / `VOICE_ID` are documented in `c-heygen/SKILL.md`'s own Caller
Variables table as `Source: Caller / brand config` — i.e. cfw-social, which already has full
brand context at order-creation time, bakes them into `taskOrder` (`RenderOrder.taskOrder`,
"the self-contained task order JSON"). A brand-scoped HeyGen credential should flow exactly
the same way: cfw-social resolves/refreshes the brand's OAuth token server-side and embeds a
**short-lived, scoped** credential object into `taskOrder` when the order is created or
claimed — never a standing broad "read this brand's secrets" tool on the render-worker
surface, never a live lookup mid-render.

Proposed shape for piece A to target (stated here so C's contract is concrete, not because C
implements it):

```json
"taskOrder": {
  "...": "existing fields (brand, avatar_id, voice_id, ...)",
  "credentials": {
    "heygen": {
      "mode": "oauth",
      "accessToken": "<short-lived bearer, scoped to this brand's HeyGen account>",
      "expiresAt": "2026-10-01T13:00:00Z",
      "creditPool": "plan_credits"
    }
  }
}
```

Absent entirely (no `taskOrder.credentials.heygen`) means "this brand has no HeyGen account
connected" — the worker's job is to recognize that and block cleanly, not substitute anything.

### Changes in this repo

1. **`bin/cfw-render.sh` — `spawn_director()`** (currently lines ~161-280): after the existing
   `taskOrder.brand` / gate extraction block and before the integrity-gate check, add a
   recipe-aware credential check:
   - If `recipe` is one that depends on `c-heygen` (the three `*-heygen` recipes, plus
     `p-longform` / `p-clone-reel` when their own `taskOrder` indicates a HeyGen scene is
     actually used — confirm at implementation time whether that's recipe-level or
     scene-level; the gate below is the honest fallback either way), require
     `taskOrder.credentials.heygen` to be present and `mode == "oauth"`.
   - **Missing or wrong-shaped → `block_render_order`** immediately (same pattern as the
     existing "malformed/missing taskOrder.brand" block a few lines above), reason
     `"this brand's HeyGen account isn't connected — connect it in brand settings"`, `needs:
     "decision"` (the owner has to go do something in the product, same semantics as
     `cfw-render-report.sh block`'s `needs` doc). **Never** fall through to any
     worker-local key — there is no fallback path by design.
   - Present and well-shaped → export it into the Director's subprocess env alongside the
     existing `export CFW_ORDER_ID` / `CFW_WORKER_ID` / … block (~line 272-280):
     `export HEYGEN_API_KEY="<token>"` is the wrong name to reuse (it implies API-key auth to
     anyone reading the env later) — export `HEYGEN_OAUTH_TOKEN` and `HEYGEN_CREDIT_POOL` so
     the updated recipe (piece B) can assert it got an OAuth token, not an API key, and so a
     future `--dry` check or log line can say *which* brand's credential mode was used without
     printing the token itself (never log the value — same discipline as every other secret in
     this repo).
   - Also write `expiresAt` through; a render that runs long enough to cross token expiry is a
     real edge case (see below) and the Director/skill needs to know the budget, not just the
     token.

2. **`bin/cfw-render-lib.sh`** — no change to `cr_load_config`/`--dry` is needed: today's `--dry`
   preflight checks worker-owned credentials only (render-worker key, Ollama keys) and never
   checked HeyGen, so there's nothing to remove. Add one small helper,
   `cr_recipe_needs_heygen "$recipe"` (a simple name-list check mirroring `cr_verify_skills_bundle`'s
   existing recipe-name pattern), used by `spawn_director` so the gate logic isn't inlined
   Python in the middle of the function.

3. **`config/cfw-render.env.example`** — add a short comment block near the existing
   `CFW_RENDER_WORKER_KEY` documentation stating explicitly: *HeyGen (and any other
   brand-owned provider) credentials are never configured here — they arrive per-order,
   embedded in `taskOrder` by cfw-social, scoped to that order's brand. Do not add
   `HEYGEN_API_KEY` to this file or to any vault env file the worker reads.* This is the
   doc-level guard that keeps a future "just add the key to the worker's vault, it's faster"
   shortcut from quietly reintroducing exactly this bug.

4. **`README.md`** — one paragraph under the existing credential-scoping discussion
   (`CFW_RENDER_WORKER_KEY` vs brand/user-scoped `RenderWorkerKey`) describing the same
   brand/order-scoped pattern for provider credentials, cross-referencing
   `docs/render-worker-auth.md` conceptually (that doc lives in cfw-social; link by path +
   note it's the companion doc, same as this repo already does for
   `cfw-social/docs/cfw-render-worker-plan.md`).

5. **New gate — `scripts/check-no-worker-heygen-credential.sh`** (mirrors
   `scripts/check-skills-portability.sh`'s shape from CFW-312: standalone, dependency-free
   bash+grep, non-zero exit with offending `file:line`). Scans `bin/`, `lib/`, `config/`
   (**not** `skills/` — that tree is vendored from a different repo per the scope table above,
   not this gate's concern) for the forbidden pattern: any line that combines a HeyGen env var
   name (`HEYGEN_API_KEY`, case-insensitive `heygen`) with a worker-vault path
   (`ecosystem/vault`, `.gsai/secrets`). Wired into `test/run-tests.sh` as a new numbered
   static-guard case (after the existing Case 11 from CFW-312), same style as Case 9/Case 11:
   ```
   === Case <N>: static guard — no worker-vault HeyGen credential in bin/lib/config (CFW-313) ===
   ```
   Unlike CFW-312's gate this one does **not** need wiring into `scripts/sync-skills.sh` (it's
   not a sync-time concern — `skills/` content isn't in its scan scope) — just into
   `test/run-tests.sh` so `pnpm test` catches a regression, and `scripts/lint.sh`'s `SCRIPTS`
   glob for shellcheck coverage of the new script itself.

### Files to touch

- `bin/cfw-render.sh` — credential-presence gate + env export in `spawn_director()`.
- `bin/cfw-render-lib.sh` — `cr_recipe_needs_heygen` helper.
- `config/cfw-render.env.example` — doc-only guard comment.
- `README.md` — one paragraph, brand/order-scoped provider credentials.
- `scripts/check-no-worker-heygen-credential.sh` — new gate script.
- `scripts/lint.sh` — add the new script to `SCRIPTS`.
- `test/run-tests.sh` — new static-guard case; also a behavioral case against
  `spawn_director` (see Testing).
- `test/fixtures/` — a `taskOrder` fixture with `credentials.heygen` present (happy path) and
  one without it (block path), for the behavioral test.

No change to `skills/**`, `config/recipes.json`, or `config/skills-version.json` — the
vendored bundle is out of this ticket's scope per the table above, and its content is
currently an exact, unmodified copy of the upstream source (`diff -rq` against
`~/ecosystem/harness/skills/c-heygen` is empty) — this is a content bug inherited faithfully
from upstream, not a sync-mechanism bug like CFW-312.

## Edge cases

- **Brand has no HeyGen account connected** (piece A hasn't shipped yet, or the brand simply
  never connected one) — `taskOrder.credentials.heygen` absent → block with `needs: "decision"`
  and an owner-safe reason, every time, no retry-into-success. This is also the behavior for
  **every** HeyGen order the moment piece C ships, until piece A ships — an explicit,
  intentional regression from "silently renders against the shared key" to "blocks with a
  clear reason," which is the point of the ticket (no more silent cross-brand billing).
- **Token present but already expired by claim time** (order sat queued a while, or the lease
  was lost and re-claimed later) — treat identically to absent: block, don't attempt the
  render and let HeyGen's own 401 surface as a confusing mid-render failure instead.
- **Token expires mid-render** (long VSL render, 15-20 min per existing `LEARNINGS.md` timing)
  — out of this repo's control once the Director has the token; piece B's recipe should prefer
  short calls and the v1 remote MCP's own token-refresh semantics (if any) over anything this
  worker can do mid-flight. Worth noting in piece B's companion issue, not solvable here.
- **A recipe that only *sometimes* touches HeyGen** (`p-longform`, `p-clone-reel` — c-heygen
  is one of several possible scene sources) — gating at the recipe-name level would
  over-block orders that never actually invoke a HeyGen scene. Confirm at implementation
  time whether `taskOrder` already signals "this order uses a HeyGen avatar scene" at a
  finer grain than recipe name (e.g. a `scenes[].type` field); if so, gate on that instead of
  the recipe allowlist. Flagged here rather than guessed at, since getting this wrong either
  direction (over-block vs under-block) both cost real orders.
- **BYOA / brand-scoped `RenderWorkerKey` mode** (`docs/render-worker-auth.md` §2's `scope:
  {brandId}`) — the credential-embedding approach is scope-agnostic (it rides inside
  `taskOrder`, which exists identically in fleet and BYOA mode), so no special-casing needed
  here; worth a one-line confirmation in piece A that the embedding logic doesn't assume fleet
  mode.
- **A recipe gets added to `config/recipes.json` later that also depends on `c-heygen`
  transitively** (same shape as CFW-312's "12 of 14" discovery) — `cr_recipe_needs_heygen`
  should walk `config/skills-version.json`'s per-recipe dependency closure (if it records one)
  rather than hand-maintaining a name list that silently goes stale; confirm at implementation
  time whether that closure data exists today or needs adding.

## Testing

- **Static guard** (`scripts/check-no-worker-heygen-credential.sh` via `test/run-tests.sh`,
  new Case) — exercised against the real `bin/`/`lib/`/`config/` trees; must start red against
  current `main` if run manually against this repo state... actually it's currently green
  today (no such reference exists in `bin/lib/config` — the bug lives entirely in the vendored
  `skills/` tree, which this gate deliberately excludes). Its job is to **keep it green**
  going forward, catching any future "just read the vault key here, it's faster" shortcut in
  the worker scripts themselves.
- **Behavioral test** (new case in `test/run-tests.sh`, using the existing `mock-server.py` +
  `fake-director.sh` harness the other cases already drive): two fixtures —
  1. `taskOrder.credentials.heygen` present + unexpired → `spawn_director` exports
     `HEYGEN_OAUTH_TOKEN` into the Director's env (assert via `fake-director.sh` echoing its
     env, same technique existing cases likely use to assert `CFW_ORDER_ID` etc. land
     correctly — confirm exact assertion mechanism against an existing passing case before
     writing this one).
  2. `taskOrder.credentials.heygen` absent → `spawn_director` calls `block_render_order` with
     the expected reason/needs, **never** spawns a Director process at all (assert no
     `fake-director.sh` invocation happened).
- **`scripts/lint.sh`** — covers the new gate script's own shell syntax.
- No changes needed to `test/mock-server.py`'s MCP tool surface (`claim_render_order` etc.) —
  the credential lives inside the `taskOrder` JSON blob the mock server already returns
  verbatim from its fixture, so a fixture update is sufficient, no mock behavior change.

## Open questions (for the companion issues, not blocking this design)

1. Piece A: does HeyGen's OAuth app support machine-to-machine refresh without a user present
   (needed for unattended fleet renders), or does token lifetime bound how long an order can
   sit queued before the embedded credential goes stale? Shapes whether cfw-social embeds the
   token at *creation* time or re-resolves it at *claim* time (claim time is safer — shorter
   gap, and matches the "fetched when the worker actually needs it" ethos elsewhere).
2. Piece B: does the v1 remote MCP support a 1080p dimension override (`LEARNINGS.md`'s
   documented reason for falling back to REST at all), or does piece B also need a parallel
   OAuth-based REST path for that case?
3. Whether `p-longform` / `p-clone-reel` need the fine-grained "does this *specific* order use
   a HeyGen scene" signal called out in Edge cases, or recipe-level gating is an acceptable
   (if slightly conservative) first cut.
