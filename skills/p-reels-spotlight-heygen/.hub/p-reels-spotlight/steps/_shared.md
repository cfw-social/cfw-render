# Spotlight reel — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-reels-spotlight`
recipe for the CFW render harness. You are given only this file, your step's file, the order brief
and the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a Spotlight reel is

A 9:16 (1080×1920, 30 fps) reel built on **one continuous voice bed**: the speaker's narration
audio plays unbroken for the whole reel and is **never cut, re-timed or re-normalised** after the
bed is sealed. The speaker plays full-frame; word-synced kinetic captions ride over everything;
full-frame motion-graphics takeovers (and, when b-roll was supplied, transcript-matched b-roll
clips) cover the *picture* at planned beats — never the *sound*. SFX sit UNDER the voice
(`amix=normalize=0`). The deliverable carries a 0.4 s money-shot cover frame at position 0 and
ends on a branded CTA end card that overlays the last seconds of the bed (nothing is appended).

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/talking_head/` (exactly one video file), `inputs/broll/` (zero or more clips), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text) and any `options` the owner set (listed per step, every option has a default). |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.mp4` video, `.png`/`.jpg` image, `.json` json, `.md` text). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (video `.mp4`, image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk` (below). In this recipe only `plan_broll` may ask (for `broll`). |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-spotlight"`; vendored components live at `$SKILL_DIR/.hub/<name>` (`c-broll-sync`, `c-reel-premium`, `c-typing-ui`, `c-eval-runner`, `c-shorts-qa-gate`, `c-overlay-fx`, `f-gsap`, `f-hyperframes`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. In particular there is no
`.env`, no key file and no hosted-box path: API keys exist only if the harness exported them from
the order's brand provider keys, and a step that needs one and finds it unset uses its local path.

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
- **End-card copy is per-brand** (CFW-354 / M1-00): the hero line, kicker and handle come from
  `inputs/cta/cta.json` (`text`, `brandName`, `handle`), never from a template default. A brand
  with no handle gets a card with **no handle line** — never invent one, never reuse another
  brand's.
- **Latin script only** in captions and cards: transliterate phonetically, never translate.
- **Fonts:** Oswald / Inter / JetBrains Mono only.
- **Takeover cards keep content in the TOP ~55 %** — the caption band sits at y ≈ 1180–1440.
- Kitchen words are banned in anything owner-facing (`reason` texts, captions): no chef / dish /
  cook / serving / plated / tasting.

## Style defaults

| Option (in `brief.json.options`) | Default | Meaning |
|---|---|---|
| `captions` | `on` | Kinetic word-synced captions over the whole reel. `off` only if the brief says so. |
| `sfx` | `on` | Whoosh / impact / riser from the CC0 pack `$SKILL_DIR/assets/sfx/`. |
| `grade` | planner picks | `warm-amber` or `clean-bright`. |
| `avatar_layout` | `fill` | `fill` = scale-to-cover; `letterbox` = pad on `#0F172A`. |
| `broll_coverage_pct` / `broll_clip_seconds` / `broll_min_seconds` / `broll_max_seconds` / `broll_order` / `broll_reuse` | `30` / `4` / `2` / `6` / `transcript-match` / `false` | B-roll planner knobs (only when b-roll was supplied). |
| `cta_card` | `on` | End-card takeover over the final `cta_duration` seconds. `off` skips it. |
| `cta_duration` | `3` | Seconds of bed the end card covers. |
| `overlay_beats` | `[]` | Optional animated overlay stickers (`c-overlay-fx`); empty = none. |
| `music` | none | Optional background-music file path inside `inputs/`; none = no music. |

## Tool notes

- Run every long render in the background if your engine offers it; a HyperFrames render takes
  60–600 s. Verify outputs with `ffprobe` before moving on.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` is the duration idiom used
  throughout; width/height are read one field at a time.
- Loudness is normalised **once**, in `prepare_footage`. No later step may loudnorm again.
- HyperFrames is pinned: `npx hyperframes@0.7.5`. GSAP is vendored at
  `$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js` — never load a CDN copy.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Never read anything from `saves/` that you did not write — earlier steps' files are in `prior/`.
- Never print or write a secret (API key, token) anywhere, including logs and `reason` texts.
