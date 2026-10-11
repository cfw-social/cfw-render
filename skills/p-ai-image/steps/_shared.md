# AI Image Post — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-ai-image` recipe
for the CFW render harness. You are given only this file, your step's file, the order brief and
the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What an AI image post is

One image, or a small batch (2–6), generated from a natural-language prompt with the kie.ai
text-to-image API — a photo-style scene, an illustration, a product shot, a character — at an
exact social canvas (`1080×1080` square by default; `1080×1920` portrait or `1920×1080`
landscape on request). Not an HTML/explainer graphic (that is `p-gfx-image`) and not video.
Every produced image is READ with vision and must pass the recipe's acceptance checks before
it is delivered.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/prompt/prompt.md` (the owner's description), `inputs/count/count.md` (one of `1`,`2`,`3`,`4`,`6`), `inputs/aspect_ratio/aspect_ratio.md` (`1:1`, `9:16` or `16:9`), `inputs/reference_image/<file>` (optional style/subject reference, any image format). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `recipe`, `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text, optional `imageStyle` prompt template) and any `options` the owner set. |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.png` image, `.json` json). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (image `.png`, json `.json`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe only `plan_prompts` may ask, and only for `prompt`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. Every step resolves `RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")` and `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"`; the recipe's `acceptance.json` lives there and vendored components at `$SKILL_DIR/.hub/<name>` (`c-ai-media`, `c-vision-qa`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path.

## Provider key

The provider key (`KIE_AI_API_KEY`) is exported by the harness from the order's brand provider
credentials; it is never read from a file and never printed. The `generate` step requires it
and fails (not asks) when it is unset — a missing key is an order problem the harness reports,
not an input.

## Asking for an input (`needs_input.json`)

When your step cannot proceed because an input your step may ask for (its manifest `canAsk`) is
missing or unusable, write this file in the workdir and STOP without writing any output:

```json
{ "inputId": "<manifest input id>", "reason": "<one short sentence the owner can act on>", "count": 1 }
```

`count` is optional. The reason is owner-facing: plain words, no paths, no stack traces. Do not
write `needs_input.json` for anything that is not an input (an API error is a failure, not an
ask). When the owner answers, the harness reruns the step from scratch.

## Brand rules (every step)

- **The brand's image style wins**: when `brief.json.brand.imageStyle` (or the brand `brief`)
  carries a style guide or prompt template, it is the BASE of every prompt and the owner's
  description is layered on top. Without one, write in a premium editorial-photography register
  (clean light, intentional palette, one focal subject).
- **Text in images** is a risk: only include text the owner asked for, keep it ≤ 4 words, and
  the QA step verifies it is legible and spelled correctly — garbled text is a FAIL.
- **Never ship generation failures**: distorted anatomy, duplicate limbs, watermarks, seams or
  a subject that does not match the prompt are defects to regenerate, not deliver.
- Kitchen words are banned in anything owner-facing (`reason` texts, notes).

## Canvas by aspect

| `aspect_ratio` | Canvas | kie.ai `aspect_ratio` |
|---|---|---|
| `1:1` (default) | 1080×1080 | `1:1` |
| `9:16` | 1080×1920 | `9:16` |
| `16:9` | 1920×1080 | `16:9` |

The provider returns its own native size; every image is scaled and centre-cropped to the
exact canvas with ffmpeg before it is saved (`scale=W:H:force_original_aspect_ratio=increase,
crop=W:H`). The acceptance `dims` gate is exact.

## Tool notes

- Generation protocol (create task → poll → download) is in `$SKILL_DIR/.hub/c-ai-media/SKILL.md`;
  the default model is `z-image`, `google/imagen4-fast` for brand/product photography,
  `gpt-image/1.5-text-to-image` for complex photoreal scenes. Image-to-image needs the reference
  as a base64 data URI.
- Read dimensions with `ffprobe -v error -select_streams v:0 -show_entries stream=width,height
  -of default=noprint_wrappers=1 FILE`.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Earlier steps'
  files are in `prior/`.
- Never print or write a secret anywhere, including logs and `reason` texts.
