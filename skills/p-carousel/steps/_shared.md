# Carousel — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-carousel` recipe
for the CFW render harness. You are given only this file, your step's file, the order brief and
the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a carousel is

A set of 3–10 **rich, premium HTML cards** rendered to PNG by headless Chromium: a cover slide
with a scroll-stopping hook, one insight per content slide, and a closing slide with the
brand's call to action. Slides are `1080×1350` (4:5, default) or `1080×1080` (1:1). Every slide
is authored as HTML from the recipe's `template.html` — real layout and depth (step lists, stat
callouts, window mocks, node diagrams), never a bare title on a flat background and never an
AI-generated background with text on top. Every slide is READ with vision and fixed until it
passes before anything is delivered. The deliverable is the ordered slide set plus a per-platform
caption.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/topic/topic.md` (the topic text), `inputs/num_slides/num_slides.md` (one of `3`,`5`,`7`,`10`), `inputs/aspect_ratio/aspect_ratio.md` (`4:5` or `1:1`), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `recipe`, `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text) and any `options` the owner set. |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.png` image, `.json` json, `.md` text). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe only `outline` may ask, and only for `topic`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. Every step resolves `RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")` and `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"`; the recipe's own `template.html`, `render.mjs` and `acceptance.json` live there, and vendored components at `$SKILL_DIR/.hub/<name>` (`c-script`, `c-vision-qa`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path. This recipe calls no external provider.

## Asking for an input (`needs_input.json`)

When your step cannot proceed because an input your step may ask for (its manifest `canAsk`) is
missing or unusable, write this file in the workdir and STOP without writing any output:

```json
{ "inputId": "<manifest input id>", "reason": "<one short sentence the owner can act on>", "count": 1 }
```

`count` is optional. The reason is owner-facing: plain words, no paths, no stack traces. Do not
write `needs_input.json` for anything that is not an input (a tool error is a failure, not an
ask). When the owner answers, the harness reruns the step from scratch.

## Brand rules (every step)

- **Palette / typography come from the brand**: brand brief → palette/typography in
  `brief.json.brand` → a named style the brief asks for → the dark-premium default `bg #0F172A`,
  `accent #F97316`, `fg #F1F5F9`. Hexes are 6-digit. Never ship generic stock colours
  (`#3b82f6`, `#333`, default greys) — off-brand colour is a QA failure.
- **Closing-slide copy is per-brand**: the CTA line, brand name and handle come from
  `inputs/cta/cta.json` (`text`, `brandName`, `handle`), never from a template default. A brand
  with no handle gets a closing slide with **no handle line** — never invent one.
- **Latin script only**; prefer HTML entities (`&rarr;`, `&mdash;`) over raw Unicode symbols, and
  every HTML head carries `<meta charset="UTF-8">`.
- **Fonts:** the brand's typography when known, else Inter for body and Oswald for display.
- Kitchen words are banned in anything owner-facing (`reason` texts, captions, slide copy).

## Style defaults

| Option (in `brief.json.options` or inputs) | Default | Meaning |
|---|---|---|
| `num_slides` | `5` | Cover + content + closing slide. |
| `aspect_ratio` | `4:5` | `4:5` = 1080×1350, `1:1` = 1080×1080. |
| `cta` | brand | Closing-slide call to action. |
| `max_fix_rounds` | `3` | Vision look-and-fix rounds before surfacing remaining issues. |

## Tool notes

- Rendering uses Playwright's bundled Chromium through `$SKILL_DIR/render.mjs`
  (`WIDTH=… HEIGHT=… SCALE=2 node "$SKILL_DIR/render.mjs" work/carousel.html`); install
  Playwright locally in `work/` (`npm i playwright`) if it is not resolvable. The 2× capture is
  lanczos-downscaled to exactly the canvas; `ffmpeg`/`ffprobe` are required for that.
- Read dimensions with `ffprobe -v error -select_streams v:0 -show_entries stream=width,height
  -of default=noprint_wrappers=1 FILE`.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Earlier steps'
  files are in `prior/`.
- Never print or write a secret anywhere, including logs and `reason` texts.
