# GFX Image Post — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-gfx-image` recipe
for the CFW render harness. You are given only this file, your step's file, the order brief and
the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a GFX image post is

One brand-styled explainer graphic, or a small set (2–4), each a **self-contained HTML
composition rendered to PNG by headless Chromium**: a numbered-step grid, a stat callout, a
quote card, a before→after, a mini diagram, or a platform banner. Square `1080×1080` by
default; portrait `1080×1920` or a `1920×1080` banner on request. It is a designed card with
real type hierarchy and depth — not an AI-generated picture (that is `p-ai-image`) and not a
multi-slide carousel. Every image is READ with vision and must pass the recipe's acceptance
checks before it is delivered.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/topic/topic.md` (the topic text), `inputs/count/count.md` (one of `1`,`2`,`3`,`4`), `inputs/format/format.md` (`square`, `portrait` or `banner`), `inputs/logo/<file>` (optional brand logo image). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `recipe`, `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text) and any `options` the owner set. |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.png` image, `.json` json). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (image `.png`, json `.json`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe only `plan_cards` may ask, and only for `topic`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. Every step resolves `RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")` and `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"`; the recipe's `acceptance.json` lives there and vendored components at `$SKILL_DIR/.hub/<name>` (`c-html-gfx`, `c-banner`, `c-vision-qa`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path. This recipe calls no external provider.

## Asking for an input (`needs_input.json`)

When your step cannot proceed because an input your step may ask for (its manifest `canAsk`) is
missing or unusable, write this file in the workdir and STOP without writing any output:

```json
{ "inputId": "<manifest input id>", "reason": "<one short sentence the owner can act on>", "count": 1 }
```

`count` is optional. The reason is owner-facing: plain words, no paths, no stack traces. Do not
write `needs_input.json` for anything that is not an input (a render error is a failure, not an
ask). When the owner answers, the harness reruns the step from scratch.

## Brand rules (every step)

- **Palette / typography come from the brand**: `brief.json.brand` palette and fonts are the
  CSS vars of every card. Without a brand palette use the dark studio default: navy
  `#0B1220` background, card `#131C2E`, ink `#F4F6FA`, muted `#9AA6B8`, accent green
  `#22C55E`. Never ship stock defaults (`#3b82f6`, `#333`); off-brand colour is a QA fail.
- **Latin script only**; prefer HTML entities (`&rarr;`, `&mdash;`) over raw Unicode symbols;
  every HTML head carries `<meta charset="UTF-8">`. Emoji break without it — avoid them.
- **Fonts:** the brand's typography when known, else Inter for body and Oswald for display.
- **Logo** only when `inputs/logo/` is supplied — bottom corner, ≤ 10% of the card width; never
  invent a handle or logo.
- Kitchen words are banned in anything owner-facing (`reason` texts, headlines, notes).

## Canvas by format

| `format` | Canvas | Chromium `--window-size` |
|---|---|---|
| `square` (default) | 1080×1080 | `1080,1220` then crop |
| `portrait` | 1080×1920 | `1080,2060` then crop |
| `banner` | 1920×1080 | `1920,1220` then crop |

Chromium's `--window-size` is the outer window and reserves ~140 px; every screenshot is
cropped to the exact canvas with ffmpeg (`crop=W:H:0:0`) and the dims verified — the
acceptance `dims` gate is exact.

## Tool notes

- Screenshot: `chromium --headless --screenshot="work/shot-N.png" --window-size=W,H+140
  --hide-scrollbars --no-sandbox "file://$PWD/work/card-N.html"`; resolve the binary as
  `${CHROMIUM_BIN:-$(command -v chromium || command -v chromium-browser || command -v google-chrome)}`,
  falling back to Playwright's bundled Chromium (`npx playwright screenshot`) when none is on
  PATH. Detail in `$SKILL_DIR/.hub/c-html-gfx/SKILL.md`.
- Read dimensions with `ffprobe -v error -select_streams v:0 -show_entries stream=width,height
  -of default=noprint_wrappers=1 FILE`.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Earlier steps'
  files are in `prior/`.
- Never print or write a secret anywhere, including logs and `reason` texts.
