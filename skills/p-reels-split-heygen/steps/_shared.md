# Split-screen reel — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-reels-split-heygen` recipe
for the CFW render harness. You are given only this file, your step's file, the order brief and
the files listed below. Do not look for the rest of the recipe and do not run other steps.

## This is the script-driven (HeyGen avatar) variant of `p-reels-split`

There is NO `inputs/talking_head/` in this recipe. The leading `generate_avatar` step renders the
speaker from the `script` input with the brand's HeyGen avatar and saves it as `talking_head`, so
from `prepare_footage` onward the talking-head video is **`prior/talking_head.mp4`**. Wherever a
step file reads `inputs/talking_head/*`, read `prior/talking_head.mp4` instead; a step may never
ask for `talking_head` (it is not an input here — `needs_input.json` for it is a failure). The
script text is also available at `inputs/script/script.json` (`{"text"}`) — the `transcribe`
step still produces word timings from the audio (do not skip it: HeyGen does not emit word times).
Provider keys (HEYGEN_API_KEY and ELEVENLABS_API_KEY) are exported by the harness from the order's brand
provider credentials; they are never read from a file and never printed. Everything below is the
base recipe's shared contract and applies unchanged.

## What a split reel is

A 9:16 (1080×1920, 30 fps) reel with a **hard 50/50 split at y=960** built on **one continuous
voice bed**: the uploaded talking-head's own audio plays unbroken for the whole reel and is
**never cut, re-timed or re-normalised** after the bed is sealed. The **top zone** (1080×960,
y 0→960) is a beat grid of transcript-synced illustrative HyperFrames cards and b-roll (b-roll
wrapped as a rounded brand-bordered card via `wowx-motions`, or blurred-fill). The **bottom zone**
(1080×960, y 960→1920) is the speaker, scaled to cover the zone (or fit + blurred-fill). The two
zones are joined with `vstack` — never `overlay`: no inset, no bleed, no overlap. Captions are
big, word-synced and sit in the top zone (`CAP_TOP=860`) — never over the face. SFX sit UNDER the
voice (`amix=normalize=0`). The deliverable carries a 0.4 s money-shot cover frame at position 0
and ends on a branded CTA end card that overlays the last seconds of the bed (nothing is appended
unless an `outro` was supplied).

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/talking_head/` (exactly one video file), `inputs/broll/` (zero or more clips), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent), `inputs/outro/` (one optional clip). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `recipe`, `intent`, `targets` (platform list), `brand` (slug, name, palette/typography when known, `brief` text) and any `options` the owner set (listed per step, every option has a default). |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by their manifest save id (`.mp4` video, `.png`/`.jpg` image, `.json` json, `.md` text). Only the files your step file lists are present. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (video `.mp4`, image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe `prepare_footage` may ask for `talking_head` and `plan_beats` may ask for `broll`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. Every step resolves `RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")` and `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"`; vendored components live at `$SKILL_DIR/.hub/<name>` (`c-broll-sync`, `c-reel-premium`, `c-typing-ui`, `c-eval-runner`, `c-shorts-qa-gate`, `c-overlay-fx`, `wowx-motions`, `f-gsap`, `f-hyperframes`). The split motion-card template is `$SKILL_DIR/templates/split-motion-card.html`. Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path: API keys exist only if the harness exported them from the order's
brand provider keys, and a step that needs one and finds it unset uses its local path.

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

- **The format is locked; only the brand's colours, fonts and visualisations vary.** Palette /
  typography come from the brand, via the Visual Identity Gate in this order: brand brief → brand
  `DESIGN.md` / palette in `brief.json` → a named style the brief asks for → the dark-premium
  default `bg #0F172A`, `accent #F97316`, `fg #F1F5F9`. Hexes are 6-digit. Never hard-code a
  brand's colours into a template. The b-roll card border is the brand accent; the card canvas is
  the brand bg.
- **End-card copy is per-brand**: hero line, kicker and handle come from `inputs/cta/cta.json`
  (`text`, `brandName`, `handle`), never from a template default. A brand with no handle gets a
  card with **no handle line** — never invent one.
- **Latin script only** in captions and cards: transliterate phonetically, never translate.
- **Fonts:** Oswald / Inter / JetBrains Mono (cards), Montserrat Bold (seam captions) only.
- **Split-safe:** every top-zone card is 1080×960 and FILLS it (a card with content crammed at the
  top and a void below is a defect); captions sit at `CAP_TOP=860`, above the y=960 seam; nothing
  textual ever enters the bottom zone.
- Kitchen words are banned in anything owner-facing (`reason` texts, captions).

## Style defaults

| Option (in `brief.json.options`) | Default | Meaning |
|---|---|---|
| `captions` | `on` | Kinetic word-synced captions (top zone, at the seam). |
| `sfx` | `on` | Whoosh at every beat seam + pop on the hook, CC0 pack under `c-reel-premium`. |
| `grade` | planner picks | `warm-amber` or `clean-bright`. |
| `broll_coverage_pct` / `broll_clip_seconds` / `broll_min_seconds` / `broll_max_seconds` / `broll_order` / `broll_reuse` | `30` / `5` / `5` / `5` / `transcript-match` / `false` | `c-broll-sync` knobs — a fixed 5 s beat grid (b-roll only when supplied; `0` coverage = 100 % graphics). |
| `broll_style` | `card` | `card` = `wowx-motions` rounded card on the brand canvas with camera motion; `blurred-fill` = full-bleed fit + blurred edges. |
| `bottom_fit` | `cover` | `cover` = face scaled to cover 1080×960; `fit` = whole face + blurred side fill. |
| `bottom_cutzoom` | `false` | `true` = zoom-cut the face per beat (1.0× on b-roll beats, 1.4× on card beats). |
| `cta_card` / `cta_duration` | `on` / `3` | End-card takeover over the final seconds of the bed. |
| `overlay_beats` | `[]` | Optional `c-overlay-fx` stickers (top zone only); empty = none. |

## Tool notes

- Run every long render in the background if your engine offers it; a HyperFrames render takes
  60–600 s. Verify outputs with `ffprobe` before moving on.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` is the duration idiom; width
  and height are read with `-of default=noprint_wrappers=1` + awk (Ubuntu's csv format differs).
- Loudness is normalised **once**, in `prepare_footage`. No later step may loudnorm again.
- HyperFrames is pinned: `npx hyperframes@0.7.5`. GSAP is vendored at
  `$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js` — never load a CDN copy. Strip HTML comments from
  composition bodies before `hyperframes lint` (v0.6.95 root_missing_composition_id false positive).
  Collapse any `##hex` to `#hex` before lint/render.
- `filter_complex` strings are ONE line — no comments, no embedded newlines.
- `vstack` needs both inputs at exactly 1080×960 and the same duration — normalise before stacking.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Earlier steps'
  files are in `prior/`.
- Never print or write a secret (API key, token) anywhere, including logs and `reason` texts.
