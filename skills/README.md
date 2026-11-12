# cfw-render bundled skills

> **Retired as a recipe source (owner decision, 2026-11-10).**
> - Recipes are written only in `~/ecosystem/harness/skills` (owner, 2026-11-06 and 2026-11-10).
> - Customer bots get recipes from Social's recipe library, not from this folder.
> - `skills/` is frozen at its current bytes. It is never synced again.
> - `scripts/sync-skills.sh` is used only with `--recipes <file> --out-dir <scratch>`, to build a bundle for cfw-social's `scripts/recipe-library/publish.mjs`. It refuses to write into `skills/` (checked by file identity), and `--recipes` is required: name only the recipes you publish; `config/recipes.json` describes the frozen `skills/` copy.
> - Do not promote `develop` to `main` while cfw-social's `/install-bot.md` still clones this repo's `main`. `main` and `develop` differ in about 101 recipe files under the same version numbers, and old-guide bots claim by version with no hash check.
> - The CFW Render worker (`com.cfw.render`) stays off.

The renderer's **self-contained** recipe closure. Each top-level folder is one
ready-to-run recipe (`SKILL.md` + its vendored `.hub/` dependency closure) that
`bin/cfw-render.sh` renders from directly — the box carries no separate render
toolchain (this is what "make the box stateless", CFW-16, delivers).

**This is a frozen, pinned copy — do not hand-edit the recipe folders and do not
sync into it (WI28, owner decision 2026-11-10).** It was generated from the private
source library; `scripts/sync-skills.sh` no longer writes here or into
`../config/skills-version.json`, and refuses an `--out-dir` that is this folder.
Any hand edit to a `<recipe>/` folder fails the checksum gate.
`../config/recipes.json` describes this frozen copy. (The old `cfw-skills-pack`
build/publish and the `git subtree` of `cfw-social/cfw-skills` were retired 2026-09-01.)

---

## Layout

- `<recipe>/SKILL.md` — the recipe entrypoint.
- `<recipe>/.hub/<dep>/` — the recipe's transitive `dependsOn` closure, flattened
  and vendored so the recipe runs offline with no cross-repo lookups.
- `index.json` — the manifest: every recipe, its full file list, a per-file
  `sha256`, a per-recipe aggregate `checksum` + `fileCount`, and a bundle-wide
  `aggregateChecksum`. This is what the integrity gate reads.

## Changing the bundle

This copy is frozen: it is not changed here. To build a bundle of current recipes
for publishing, use a scratch folder and name only the recipes you publish:

```bash
CFW_SKILLS_SRC=~/ecosystem/harness/skills scripts/sync-skills.sh \
  --recipes <your-recipes.json> --out-dir <scratch>   # (run from the repo root)
```

To confirm this frozen tree still matches its manifest (checksum gate):
`scripts/verify-skills-bundle.sh`.

`../config/skills-version.json` records the exact source commit this copy was
synced from; it is no longer refreshed, and is never hand-edited.

_14 recipes in this bundle._
