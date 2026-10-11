# AI Character Scenes — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-ai-character`
recipe for the CFW render harness. You are given only this file, your step's file, the order
brief and the files listed below. Do not look for the rest of the recipe and do not run other
steps.

## What an AI character scene set is

A character-consistent **set of 9:16 scene images** (`1080×1920`) telling a short visual story
in 3–6 acts, for any character type — human, plush toy / mascot, fantasy. One locked character
reference is generated first and passed to every scene call; every scene is audited against
the six locked attributes and regenerated on any divergence. No dialogue, no text in frame —
pure visual storytelling. The deliverable is the ordered scene set with the cover (scene 1) as
the money shot. (The animation / music assembly of the older short-video flow is not part of
this recipe; the image set is what ships.)

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/story_concept/story_concept.md`, `inputs/character_description/character_description.md`, `inputs/character_type/character_type.md` (`human` or `plush`), `inputs/num_scenes/num_scenes.md` (one of `3`,`4`,`5`,`6`), `inputs/reference_image/<file>` (optional existing character reference). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `recipe`, `intent`, `targets` (platform list), `brand` (slug, name, palette when known, `brief` text, optional `imageStyle` prompt template) and any `options` the owner set. |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.png` image, `.json` json). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (image `.png`, json `.json`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe only `character_lock` may ask, for `story_concept` or `character_description`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. Every step resolves `RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")` and `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"`; the recipe's `acceptance.json` lives there and vendored components at `$SKILL_DIR/.hub/<name>` (`c-ai-media`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path.

## Provider key

The provider key (`KIE_AI_API_KEY`) is exported by the harness from the order's brand provider
credentials; it is never read from a file and never printed. The generation steps require it
and fail (not ask) when it is unset — a missing key is an order problem the harness reports,
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

## The six-attribute character lock (every step)

| # | `human` | `plush` (toy / mascot) |
|---|---|---|
| 1 | Face shape | Body type / plush material |
| 2 | Hair: colour, length, style | Face: eye shape, eye colour, nose/mouth style |
| 3 | Eyes: colour, shape, expression | Ear / head shape |
| 4 | Clothing: colour, pattern, texture | Outfit: colour, pattern, texture |
| 5 | Distinctive feature (scar, glasses, accessory) | Accessories / distinctive feature |
| 6 | Colour palette (primary + accent) | Colour palette (primary + accent) |

All six must be specific and visual; vague = fail. **Divergence protocol:** after every
generated image, compare it with the reference attribute by attribute. Any divergence in face,
outfit or distinctive feature = regenerate immediately; a diverged image never moves forward.

## Brand and style rules

- The brand's `imageStyle` / brief (when present) is the base register of every prompt; the
  locked attributes are repeated verbatim in every prompt, never summarised.
- Gentle, specific motion/scene language (slow, subtle, drifting); for `plush` add "plush toy,
  soft fabric texture, photorealistic toy photography" to every prompt.
- No text, captions, logos or watermarks in any frame. Kitchen words are banned in anything
  owner-facing (`reason` texts, notes).

## Canvas and provider

Every image is `1080×1920` portrait: request kie.ai with `aspect_ratio: "9:16"` and normalise
with ffmpeg (`scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920`). The
reference is text-to-image (`google/imagen4-fast` by default — the consistency-grade model);
scenes are image-to-image (`gpt-image/1.5-image-to-image`) with the reference as a base64 data
URI in `input_urls`. Protocol (create task → poll → download) is in
`$SKILL_DIR/.hub/c-ai-media/SKILL.md`.

## Tool notes

- Read dimensions with `ffprobe -v error -select_streams v:0 -show_entries stream=width,height
  -of default=noprint_wrappers=1 FILE`.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Earlier steps'
  files are in `prior/`.
- Never print or write a secret anywhere, including logs and `reason` texts.
