# Clone reel — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-clone-reel`
recipe for the CFW render harness. You are given only this file, your step's file, the order brief
and the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a Clone reel is

A 9:16 (1080×1920, 30 fps) reel of 30–60 s that **re-makes a reference reel in the brand's voice**.
The owner supplies a public link or a video file of a reel whose format works. We transcribe it,
analyse its format (hook structure, pacing, visual rhythm, where the presenter sits in the frame),
adapt the script to the brand's topic and vocabulary at the same word count so the timing is
preserved, narrate it — with a HeyGen avatar on a green screen when the brand has one, otherwise
an ElevenLabs voice-over — and composite the narration into the reference layout: avatar PIP at
the detected position or a split (reference-format visuals on top, avatar below). A brand outro /
CTA card closes the reel and a 0.4 s money-shot cover sits at position 0.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/source_reel/` holds either `source_reel.json` (`{"url": "..."}` for a link — CFW copied the file into Media too, so a `.mp4` may sit beside it) or one video file; `inputs/topic/topic.json` (`{"text": "..."}`), `inputs/section/section.json` (`{"choice": "full|opening|middle"}`), `inputs/avatar_id/avatar_id.json` and `inputs/voice_id/voice_id.json` (`{"text": "<id>"}`), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text, `heygen.avatarId` / `heygen.voiceId` / `elevenlabs.voiceId` when the brand has them) and any `options` the owner set (every option has a default). |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.mp4` video, `.png` image, `.json` json, `.md` text). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (video `.mp4`, image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe `ingest_reference` may ask for `source_reel` and `generate_narration` may ask for `avatar_id` / `voice_id`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-clone-reel"`; vendored components live at `$SKILL_DIR/.hub/<name>` (`c-audio`, `c-heygen`, `c-html-gfx`, `c-production`, `c-ffmpeg`, `c-shorts-qa-gate`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path. Provider keys exist only as `HEYGEN_API_KEY` and `ELEVENLABS_API_KEY`
in the environment, exported by the harness from the order's brand provider keys; a step that
needs one and finds it unset fails with a plain message — it never searches for a key.

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

- **We copy the format, never the content.** The adapted script carries the brand's own claims and
  vocabulary; no sentence from the reference is reused verbatim beyond structural connectives, and
  the reference footage itself is never shown as the brand's own — it informs layout and rhythm.
- **Palette / typography come from the brand**: brand brief → palette in `brief.json` → the
  dark-premium default `bg #0F172A`, `accent #F97316`, `fg #F1F5F9`. Hexes are 6-digit.
- **End-card copy is per-brand**: offer line, brand name and handle come from `inputs/cta/cta.json`
  (`text`, `brandName`, `handle`), else `brief.json.brand`. A brand with no handle gets a card
  with **no handle line** — never invent one.
- **Frame 0 and the last frame are never black.** The reel ends on the outro / CTA card.
- **Green-screen keying is two-pass `colorkey`** (`0x00FF00:0.25:0.05` then `0x00FF00:0.40:0.01`),
  never `chromakey`; a green fringe is a defect.
- **Latin script only** in captions and cards: transliterate phonetically, never translate.
- Kitchen words are banned in anything owner-facing (`reason` texts, captions): no chef / dish /
  cook / serving / plated / tasting.

## Style defaults

| Option (in `brief.json.options`) | Default | Meaning |
|---|---|---|
| `cover_style` | `card-holding` | `card-holding` (avatar beside a brand card) or `faceless-card` (brand card only). |
| `layout` | `auto` | `auto` (follow the detected reference layout), `pip` or `split`. |
| `captions` | `on` | Word-synced captions in the lower third. |
| `speed` | `1.0` | Narration speed multiplier (1.0–1.15). |

## Tool notes

- Run every long render or provider poll in the background if your engine offers it; a HeyGen
  render takes 2–10 min. Verify outputs with `ffprobe` before moving on.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` is the duration idiom used
  throughout; width/height are read one field at a time.
- Loudness is normalised **once**, in `generate_narration` (−14 LUFS). `composite` re-masters the
  final mix to −14 after SFX / outro; no other step touches loudness.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Never read anything
  from `saves/` that you did not write — earlier steps' files are in `prior/`.
- Never print or write a secret (API key, token) anywhere, including logs and `reason` texts.
