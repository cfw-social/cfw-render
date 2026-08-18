---
task-id: "CFW-HST-BUNDLE"
epic: "CFW-HST-SIMPLIFY"
status: backlog
priority: high
tags: [render, skills, bundle, distribution]
---
# cfw-render ⊕ cfw-skills → one installable bundle (pull → install on HST or desktop)

## Context (locked target — see cfw-social `docs/ARCHITECTURE.md` §1 law 6)
The renderer and its recipes must ship as **ONE repo/bundle**: pull it, install it, and you have the
render worker *plus* the exact recipe set it renders with — on **HST** (server) or a **user's desktop**
(BYOA). This kills the "skills drifted from the worker" class of bugs and makes the renderer a single
portable component keyed by an API key.

**Today (two repos):** `cfw-render` (this repo, the worker) + the **separate** public
`cfw-social/cfw-skills` repo (boxes `git pull` hourly into `/data/shared/cfw-skills/cfw`; external BYO
agents raw-fetch from it). **Do NOT break that live hourly pull on the 9 boxes** — stage the migration.

## Design (binding) — staged, non-breaking
1. **Combine (additive first):** bring the skills into this repo as a vendored/pinned set — either a
   `skills/` directory synced from `cfw-skills-pack`'s build, or a submodule pinned to a release SHA.
   The worker deploy now carries a **pinned recipe closure + its `index.json`**. Keep `cfw-skills-pack`
   as the *source* build (authoring stays where it is); this repo is the *bundled deployable*.
2. **One install path, two targets:** an installer/script (`install.sh` / `npx`) that, given an API key,
   fetches+installs the bundle and verifies checksums — works identically on HST and a desktop. On HST it
   lands where the box reads recipes; on desktop it lands in the user's local agent dir.
3. **Transition (no break):** keep the standalone public `cfw-social/cfw-skills` repo + the box hourly
   pull ALIVE until the bundle install is proven. Add the bundle path in parallel; cut the box pull over
   to the bundle **brand-by-brand**; retire the standalone skills-pull cron only after all boxes are on
   the bundle.
4. **Version pinning:** the bundle records the exact skills release it carries; a render order references
   that pinned version (aligns with CFW-V2-073 / the render-order pinned-version contract).

## Acceptance criteria
- [ ] This repo builds a self-contained bundle = worker + pinned skills closure + `index.json` (checksum-verified).
- [ ] `install.sh`/`npx` installs the bundle from an API key on a clean machine (scratch test), verifying checksums.
- [ ] The standalone `cfw-skills` pull path still works during transition (no regression) — asserted/ documented.
- [ ] Docs: distribution doc updated to the bundle model; the retire-the-standalone-pull step is written as a gated, brand-by-brand rollout.

## Rollout (GATED — not part of build/merge)
Prove the bundle install on a scratch box → cut one live box's recipe source to the bundle → verify a cook
renders → repeat brand-by-brand → retire the standalone skills-pull cron last.

## Out of scope
Authoring recipes (stays in `cfw-skills-pack` → public repo). The desktop BYOA agent runtime (Grok spike).
