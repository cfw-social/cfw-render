# Faceless reel — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-reels-faceless`
recipe for the CFW render harness. You are given only this file, your step's file, the order brief
and the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a Faceless reel is

A 9:16 (1080×1920, 30 fps) reel with **no talking head and no avatar**. The spine is **one
continuous voice bed**: a brand-voice ElevenLabs narration of the script, loudnormed once and never
cut, re-timed or re-normalised after it is sealed. The whole picture is a sequence of beats: full-
frame HyperFrames motion-graphics compositions (chart, terminal, typing-UI card, checklist, stat,
diagram — each with an illustrative hero, never a bare title) and, when b-roll was supplied,
transcript-matched b-roll windows up to the coverage budget. Kinetic word-synced captions ride in
the lower third, SFX sit UNDER the voice, a brand outro / CTA card closes the reel, and a 0.4 s
money-shot cover frame sits at position 0.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/script/script.json` (`{"text": "..."}`; a `.txt`/`.md` in the same dir is also acceptable), `inputs/voice_id/voice_id.json` (`{"text": "<ElevenLabs voice id>"}`), `inputs/broll/` (zero or more clips), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent), `inputs/outro/` (one portrait clip). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text, `elevenlabs.voiceId` when the brand has one) and any `options` the owner set (listed per step, every option has a default). |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.mp4` video, `.png` image, `.json` json, `.md` text). Only the files your step file lists are present. When the owner chose the "research and write my script first" path, `prior/approved_script.md` holds the script instead of `inputs/script/`. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (video `.mp4`, image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe `voice_over` may ask for `script` / `voice_id` and `plan_beats` may ask for `broll`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-faceless"`; vendored components live at `$SKILL_DIR/.hub/<name>` (`c-audio`, `c-broll-sync`, `c-reel-premium`, `c-typing-ui`, `c-eval-runner`, `c-shorts-qa-gate`, `c-overlay-fx`, `f-gsap`, `f-hyperframes`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path. The ElevenLabs key exists only as `ELEVENLABS_API_KEY` in the
environment, exported by the harness from the order's brand provider keys; a step that needs it
and finds it unset fails with a plain message — it never searches for a key.

## Asking for an input (`needs_input.json`)

When your step cannot proceed because an input your step may ask for (its manifest `canAsk`) is
missing or unusable, write this file in the workdir and STOP without writing any output:

```json
{ "inputId": "<manifest input id>", "reason": "<one short sentence the owner can act on>", "count": 1 }
```

`count` is optional (how many items you need). The reason is owner-facing: plain words, no paths,
no stack traces. Do not write `needs_input.json` for anything that is not an input (a tool error
is a failure, not an ask). When the owner answers, the harness reruns the step from scratch.

## Brand rules (every step)

- **Palette / typography come from the brand**, via the Visual Identity Gate in this order: brand
  brief → brand `DESIGN.md` / palette in `brief.json` → a named style the brief asks for →
  the dark-premium default `bg #0F172A`, `accent #F97316`, `fg #F1F5F9`. Hexes are 6-digit.
  Never hard-code a brand's colours into a template.
- **Every graphics beat is illustrative**: title + an animation that depicts the point (grid
  staggering in, count-up stat, animated waveform, chips popping). A title-only card is a defect.
- **Visual doctrine:** FOREGROUND HERO; `gsap.from()` so every element ends visible; ambient
  motion for the full beat; SVG-only icons (no emoji, no remote images); thematic ghost glyph per
  beat; one composition per beat; Oswald + JetBrains Mono (Inter for body).
- **End-card copy is per-brand**: hero line, kicker and handle come from `inputs/cta/cta.json`
  (`text`, `brandName`, `handle`), else `brief.json.brand`. A brand with no handle gets a card
  with **no handle line** — never invent one.
- **Frame 0 and the last frame are never black.** The reel ends on the outro / CTA card.
- **Latin script only** in captions and cards: transliterate phonetically, never translate.
- **Cards keep content in the TOP ~65 %** — the caption band sits at y ≈ 1450–1700 (lower third).
- Kitchen words are banned in anything owner-facing (`reason` texts, captions): no chef / dish /
  cook / serving / plated / tasting.

## Style defaults

| Option (in `brief.json.options`) | Default | Meaning |
|---|---|---|
| `target_seconds` | `45` | Target reel length (30–90) — guides beat count and the script check. |
| `captions` | `on` | Kinetic word-synced captions in the lower third. `off` only if the brief says so. |
| `sfx` | `on` | Whoosh / impact / riser from the CC0 pack `$SKILL_DIR/.hub/c-reel-premium/assets/sfx/`. |
| `grade` | planner picks | `warm-amber` or `clean-bright`. |
| `broll_coverage_pct` / `broll_clip_seconds` / `broll_min_seconds` / `broll_max_seconds` / `broll_order` / `broll_reuse` | `30` / `4` / `2` / `6` / `transcript-match` / `false` | B-roll planner knobs (only when b-roll was supplied). |
| `overlay_beats` | `[]` | Optional animated overlay stickers (`c-overlay-fx`); empty = none. |

## Tool notes

- Run every long render in the background if your engine offers it; a HyperFrames render takes
  60–600 s. Verify outputs with `ffprobe` before moving on.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` is the duration idiom used
  throughout; width/height are read one field at a time.
- Loudness is normalised **once**, in `voice_over` (−14 LUFS). `assemble` re-masters the final mix
  to −14 after SFX; no other step touches loudness.
- HyperFrames is pinned: `npx hyperframes@0.7.5`. GSAP is vendored at
  `$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js` — copy it into each composition dir and load it with
  a LOCAL `<script src="gsap.min.js">`; never a CDN (outbound library fetches are blocked).
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Never read anything
  from `saves/` that you did not write — earlier steps' files are in `prior/`.
- Never print or write a secret (API key, token) anywhere, including logs and `reason` texts.
