# BYOA render-worker install — how it differs from the fleet install

> Thin pointer doc (PACKAGING-DESIGN.md §4). The **same** `cfw-render` codebase, at
> the **same** git tag, runs on both `hst` (mode `server`) and a customer's desktop
> (mode `byoa`). Only two things differ per install: which credential is in
> `cfw-render.env`, and `CFW_RENDER_MODE`. Mode is **operational only** — it is
> **never** the security boundary (the server enforces that by which credential family
> resolves — see `cfw-social` `render-key.ts`).

## What `--mode byoa` changes

`install/install.sh --mode byoa …`:
- writes `CFW_RENDER_MODE=byoa` into the env file (or tells you the line to add),
- seeds the same **stable per-install `worker-id`** (PACKAGING-DESIGN.md §6.3),
- lays down the same in-repo `skills/` bundle the server uses.

## Skills: one source, git-pull to update (fetch mode retired)

There is **no bundle-vs-fetch switch anymore.** `cfw-render` carries its recipe closure
**in-repo** (`skills/`, pinned by `config/skills-version.json`, verified by
`scripts/verify-skills-bundle.sh`). Server and BYOA use the **same** source. The old
curated-fetch path (`CFW_RENDER_SKILLS_SOURCE=fetch`, cfw-social `byoa-fetch-plan` /
CFW-V2-067) and the `CFW_RENDER_SKILLS_SOURCE` variable were **removed 2026-09-01** —
never built, and the in-repo bundle makes them unnecessary.

**To update a BYOA box's skills:**

```bash
git -C <cfw-render-checkout> pull        # pulls new worker code AND the pinned skills/
# then restart the skills-consuming service/cron so it re-copies skills/ into place:
systemctl --user restart cfw-render.timer   # or: re-run install/install.sh --mode byoa
```

That's the whole update story: `git pull` + restart. No separate skills download, no
public skills repo, no per-brand fetch client.

> Tenant isolation is **not** a client-side skills concern: a BYOA box carries the full
> recipe closure, and the server's brand filter on the claim query is the real tenant
> boundary. Shipping all recipes to a customer box is disk, not a data-leak.

## Credential scope (PACKAGING-DESIGN.md §4.1)

BYOA uses a brand- or user-scoped `RenderWorkerKey` (not the global fleet
`CFW_RENDER_WORKER_KEY`). The server resolves scope to the set of brands the key may
claim — this is server-side work (CFW-V2-062 + the user-scope extension) and is **not**
part of this cfw-render repo change. A BYOA worker install never touches personas,
brand DNA, or the full brand MCP surface — it is the narrow render worker only.
