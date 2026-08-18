# BYOA render-worker install — how it differs from the fleet install

> Thin pointer doc (PACKAGING-DESIGN.md §4). The **same** `cfw-render` codebase, at
> the **same** git tag, runs on both `hst` (mode `server`) and a customer's desktop
> (mode `byoa`). Only two things differ per install: which credential is in
> `cfw-render.env`, and `CFW_RENDER_MODE`. Mode is **operational only** — it selects
> which skills-sourcing path runs; it is **never** the security boundary (the server
> enforces that by which credential family resolves — see `cfw-social` `render-key.ts`).

## What `--mode byoa` changes today

`install/install.sh --mode byoa …`:
- writes `CFW_RENDER_MODE=byoa` into the env file (or tells you the line to add),
- seeds the same **stable per-install `worker-id`** (PACKAGING-DESIGN.md §6.3),
- still lays down the bundled `skills/` (a BYOA box can use it; see the caveat below).

## The curated-fetch path is NOT built yet

The intended BYOA skills source is `CFW_RENDER_SKILLS_SOURCE=fetch` — pull only the
recipes the brand/user is entitled to, SHA-pinned, via cfw-social's `byoa-fetch-plan`
(**CFW-V2-067**). That client (`bin/cfw-render-fetch-skills.sh`) is **not implemented
yet**. Until it lands:

- Leave `CFW_RENDER_SKILLS_SOURCE=bundle` (the shipped default). The worker uses the
  pinned bundled `skills/` — the full closure, not a curated subset. That is **wasted
  disk on a customer box, not a security issue** (the server's brand filter on the
  claim query is the real tenant boundary).
- Setting `CFW_RENDER_SKILLS_SOURCE=fetch` before 067 ships makes the worker **refuse
  to run** (`cr_guard_skills_source` in `bin/cfw-render-lib.sh`) rather than silently
  fall back to the bundle — fail fast, no silent fallback.
- `bin/cfw-render.sh --dry` emits a non-fatal `WARN mode:skills-source` row when
  `mode=byoa` and `skills-source=bundle`, so the misconfiguration is visible.

## Credential scope (PACKAGING-DESIGN.md §4.1)

BYOA uses a brand- or user-scoped `RenderWorkerKey` (not the global fleet
`CFW_RENDER_WORKER_KEY`). The server resolves scope to the set of brands the key may
claim — this is server-side work (CFW-V2-062 + the user-scope extension) and is **not**
part of this cfw-render repo change. A BYOA worker install never touches personas,
brand DNA, or the full brand MCP surface — it is the narrow render worker only.

## When `fetch` lands (CFW-V2-067)

Add `bin/cfw-render-fetch-skills.sh` as a thin client of the fetch-plan; it must write
the **same `VERSION.json`/manifest shape** into its per-brand cache so the one
`scripts/verify-skills-bundle.sh` checksum path verifies both bundle and fetch sources
identically. Then flip `CFW_RENDER_SKILLS_SOURCE=fetch` for BYOA boxes.
