# cfw-render — guide for coding assistants

This file is for any coding assistant (Codex, Claude Code, Cursor, Gemini CLI, …)
working in a cfw-render checkout **or** in an installed copy (on an owner's
computer: `~/CFW Render/app`). `CLAUDE.md` points here.

## What this is

cfw-render renders videos and graphics on the owner's own computer. It has two
halves, and they are independent:

1. **The CFW renderer.** A timer runs `bin/cfw-render.sh` every ~15 minutes. Each
   tick it asks CFW Social for queued render orders, renders them with the
   bundled recipes, and sends the finished files back. It only ever renders work
   CFW queued — there is no "render this one recipe" flag on it.
2. **The recipes (open box).** `skills/` is a plain folder of self-contained
   render recipes. Each one is a `SKILL.md` you can read and follow directly,
   with no CFW account, key or network call to CFW. Use these for local renders
   outside CFW.

## Layout

```
bin/cfw-render.sh             the CFW renderer tick (one tick per run; --dry = validate only, claims nothing)
bin/cfw-render-preflight.sh   checks this computer has the render toolchain (claims nothing, calls no API)
bin/cfw-render-*.sh           helpers the CFW renderer calls while rendering an order
skills/<recipe>/SKILL.md      one recipe — the entrypoint to read
skills/<recipe>/.hub/<dep>/   that recipe's dependencies, vendored so it works offline
skills/index.json             manifest: every recipe, file list, checksums
config/                       cfw-render.env.example, recipes.json, skills-version.json (pinned bundle)
install/install.sh            installs the CFW renderer + recipes into --prefix (owner's computer: ~/CFW Render/app)
```

In an installed copy the same files live under the prefix: recipes at
`<prefix>/skills`, this guide at `<prefix>/AGENTS.md`.

## Where things are on the owner's computer

`install/install.sh --mode byoa` sets up one visible folder the owner can open,
and one hidden folder for private plumbing. The folder name has a space —
**always quote these paths** (`"$HOME/CFW Render/app/skills"`).

| What | Where |
| --- | --- |
| The app (this guide, `bin/`, recipes) | `~/CFW Render/app/` — recipes in `~/CFW Render/app/skills/` |
| Finished renders | `~/CFW Render/outputs/<brand>/<YYYY-MM-DD>_<order>/` — a copy of every render CFW accepted |
| Logs | `~/CFW Render/logs/` — `cfw-render.log`, one transcript per render in `runs/`, and on a Mac `cfw-render.out.log` / `cfw-render.err.log` |
| Settings (keys — private, mode 600) | `~/.cfw-render/cfw-render.env` — never print, copy or commit it |
| Computer identity | `~/.cfw-render/worker-id` — keep it; deleting it makes CFW see a new computer |
| Temporary working folders | `~/.cfw-render/scratch/` — cleared after each render, leftovers after 48 h |
| Source checkout used for updates | `~/.cfw-render/source/` (when installed from CFW's install page) |

Every location can be changed in the settings file (`CFW_RENDER_HOME`,
`CFW_RENDER_LOG_DIR`, `CFW_RENDER_OUTPUTS`, `CFW_RENDER_KEEP_OUTPUTS`,
`CFW_RENDER_SCRATCH`, `CFW_RENDER_STATE_DIR`); `config/cfw-render.env.example`
documents each. An older install may still use `~/.cfw-render/app`,
`~/cfw-render` or `~/cfw-render-scratch` until it is reinstalled.

When you tell the owner where something is, use these plain words: "your
finished videos and images are in the CFW Render folder in your home folder,
under outputs, one folder per brand."

## Before rendering anything: preflight

```bash
bin/cfw-render-preflight.sh          # full report, exit 0 = ready
bin/cfw-render-preflight.sh --quiet  # failures only
```

It checks: `curl`, `python3`, `node`, `npx`, `ffmpeg`, `ffprobe`, ImageMagick 7
(`magick` — v6 `convert` alone is not enough), a Playwright/Chromium browser, a
usable system font, and a `claude` CLI that runs. Each failure prints the command
that installs it. **Ask the owner once before installing anything**; never
install silently.

## Local renders outside CFW (open box)

1. Pick a recipe: `ls skills/` (or `<prefix>/skills`). Read
   `skills/index.json` or each `SKILL.md`'s front matter (`description`,
   `inputs`, `requires`, `dependsOn`) to choose.
2. Read that recipe's `SKILL.md` top to bottom, then any `LEARNINGS.md` beside
   it — recipes treat its "Active Feedback" as rules.
3. Follow the steps yourself. Dependencies named in `dependsOn` are in that
   recipe's `.hub/<dep>/SKILL.md`; read them when a step refers to them.
4. Work in a folder **outside** `skills/`, and put the finished files where the
   owner already looks: `"$HOME/CFW Render/outputs/local/<name>/"`. Never write
   into `skills/`.

Things to know when running a recipe without CFW:

- Some steps call CFW tools (for example `get_brand_dna` for brand colours,
  fonts and voice). Without CFW, ask the owner for those facts once, or read
  them from a file they point you at, and carry on.
- Steps that upload results or report progress to CFW do not apply; keep the
  output files in `"$HOME/CFW Render/outputs/local/"` and tell the owner where they are.
- Recipes that use paid services (HeyGen, fal/kie, Replicate, Gemini) need the
  owner's own account and key for that service. Ask before spending money.
- `p-ai-image` and `p-gfx-image` are **scaffolds** — their `SKILL.md` says
  "SCAFFOLD — NOT YET AUTHORED". Do not try to follow them; tell the owner.

## Rules for editing this repo

- `skills/` is a **generated, pinned copy**. Do not hand-edit recipe folders —
  `scripts/sync-skills.sh` overwrites them and `scripts/verify-skills-bundle.sh`
  fails on any drift. Recipe changes are made upstream, then synced.
- Bash only, no JS toolchain in the renderer itself. Lint: `scripts/lint.sh`.
  Tests (no live services): `test/run-tests.sh`.
- Never put a CFW key, brand key or render pass in a file you commit or in a
  recipe folder. Keys live in the env file (`config/cfw-render.env.example`
  documents every setting).
- `bin/cfw-render.sh --dry` validates the CFW renderer's setup and claims
  nothing — safe to run any time.
