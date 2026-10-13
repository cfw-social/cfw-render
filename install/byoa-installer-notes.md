# Render-worker install on an owner's computer (BYOA)

> Thin pointer doc (PACKAGING-DESIGN.md §4). cfw-render runs **only** on the brand's
> own computers (mode `byoa`); CFW-run server rendering was removed (owner decision
> D118). Mode is **operational only** — it is **never** the security boundary (the
> server enforces that by which credential resolves — see `cfw-social` `render-key.ts`).

## What `--mode byoa` changes

`install/install.sh --mode byoa …`:
- writes `CFW_RENDER_MODE=byoa` into the env file (or tells you the line to add),
- seeds the same **stable per-install `worker-id`** (PACKAGING-DESIGN.md §6.3),
- lays down the in-repo `skills/` bundle,
- uses the **owner folder layout** (defaults; every `--flag` / `CFW_RENDER_*` override
  still wins):

```
~/CFW Render/                 visible — what the owner looks at
  app/                        --prefix default: bin/, skills/, AGENTS.md, ...
  outputs/<brand>/<date>_<order>/   a copy of each finished render, kept once CFW
                              accepted the upload (CFW_RENDER_KEEP_OUTPUTS=0 turns it off)
  logs/                       cfw-render.log, runs/*.out, macOS cfw-render.{out,err}.log
~/.cfw-render/                hidden — private plumbing
  cfw-render.env              --env-file default, chmod 600 by the installer
  worker-id, journal.tsv, tick.lock, scratch/
```

`--mode server` was removed (D118); the installer refuses it.

**Existing installs keep working.** A settings file found only at the older
`~/ecosystem/vault/cfw-render.env` is still used (by the renderer and by the
installer when no `--env-file` is given). An install at an older prefix
(`~/.cfw-render/app`, `~/cfw-render`, `/opt/cfw-render`) keeps running from its
current schedule until `install.sh --mode byoa` is re-run; the re-run moves the
schedule to `~/CFW Render/app` and names the old copy so the owner can delete it.
An old schedule whose sandbox cannot write to `~/CFW Render` logs to `~/.cfw-render`
and keeps no local copies until re-installed.

## Skills: one source, git-pull to update (fetch mode retired)

There is **no bundle-vs-fetch switch anymore.** `cfw-render` carries its recipe closure
**in-repo** (`skills/`, pinned by `config/skills-version.json`, verified by
`scripts/verify-skills-bundle.sh`). The old
curated-fetch path (`CFW_RENDER_SKILLS_SOURCE=fetch`, cfw-social `byoa-fetch-plan` /
CFW-V2-067) and the `CFW_RENDER_SKILLS_SOURCE` variable were **removed 2026-09-01** —
never built, and the in-repo bundle makes them unnecessary.

**To update a computer's skills:**

```bash
git -C ~/.cfw-render/source pull        # the checkout CFW's install page clones; pulls new worker code AND the pinned skills/
# then re-run the installer so it re-copies skills/ into place:
install/install.sh --mode byoa
```

That's the whole update story: `git pull` + re-install. No separate skills download, no
public skills repo, no per-brand fetch client.

> Tenant isolation is **not** a client-side skills concern: a BYOA computer carries the full
> recipe closure, and the server's brand filter on the claim query is the real tenant
> boundary. Shipping all recipes to a customer computer is disk, not a data-leak.

## Credential scope (PACKAGING-DESIGN.md §4.1)

BYOA uses a brand- or user-scoped `RenderWorkerKey` (stored locally as
`CFW_RENDER_WORKER_KEY`, sent as the `cfw-render-key` header). The server resolves scope to the set of brands the key may
claim — this is server-side work (CFW-V2-062 + the user-scope extension) and is **not**
part of this cfw-render repo change. A BYOA worker install never touches personas,
brand DNA, or the full brand MCP surface — it is the narrow render worker only.

## Troubleshooting: `FAIL binary:claude not on PATH` (macOS)

See `docs/deploy.md` §2 for the full note. Short version: launchd never
inherits your login shell's PATH, so `com.cfw.render.plist`'s
`EnvironmentVariables.PATH` is the *only* PATH the scheduled tick sees.
`install.sh` (CFW-291) now writes a **resolved** `WORKER_PATH` there —
computed by walking every required binary with `command -v` in the shell
`install.sh` itself runs from, not a guessed static list — and refuses to
install at all unless it can also prove `claude` runs headless under that
exact PATH (`env -i`, mirroring what launchd actually hands a
scheduled tick). An already-installed computer needs `install.sh` re-run (or the
plist manually re-rendered + reloaded) to pick up a re-resolved
`WORKER_PATH`.
