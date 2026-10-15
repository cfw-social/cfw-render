# Longform video — shared rules (prepended to every step)

You are the signed-in engine (Codex or Claude Code) running ONE step of the `p-longform` recipe
for the CFW render harness. You are given only this file, your step's file, the order brief and
the files listed below. Do not look for the rest of the recipe and do not run other steps.

## What a Longform video is

One 16:9 (1920×1080, 25 fps) H.264 MP4 of 5–20 minutes, parameterised by **`format`**:

| `format` | Structure | Visual layer |
|---|---|---|
| `vsl` | Sales-letter beats: hook → problem → agitation → solution → proof → offer → CTA (CTA mandatory in the last 60 s) | Avatar + GFX cards (stat reveals, quotes, offer banners) + AI stills + b-roll |
| `demo` | Product / feature walkthrough led by screen recordings | Screen recordings primary, avatar PIP, callout overlays |
| `tutorial` | Step-by-step educational with section titles / chapter markers | Section-by-section stitch: talking head, demo recording, concept slides (HyperFrames), side-by-side |

The spine is **one continuous narration**: a HeyGen avatar on a `#00FF00` green screen when the
brand (or owner) names an avatar, otherwise an ElevenLabs voice-over. It is rendered once, never
cut or re-timed; every visual is laid over it by transcript timecode. The three formats share one
composite engine (`c-ffmpeg`) and differ only in section map, visual layer and narrative arc.

## The step workdir (fixed layout)

The harness runs you in a fresh **step workdir** — the current directory. Use only relative paths.

| Where | What |
|---|---|
| `inputs/<inputId>/` | The order inputs by manifest input id: `inputs/script/script.json` (`{"text": "..."}`; a `.txt`/`.md` in the same dir is also acceptable), `inputs/format/format.json` (`{"choice": "vsl|demo|tutorial"}`), `inputs/source_video/` (one landscape green-screen or opaque avatar render), `inputs/avatar_id/avatar_id.json` and `inputs/voice_id/voice_id.json` (`{"text": "<id>"}`), `inputs/broll/` (zero or more clips / stills / screen recordings), `inputs/cta/cta.json` (`{"text","brandName","handle"}`; any key may be absent), `inputs/outro/` (one landscape clip), `inputs/captions/captions.json` (`{"choice": "on|off"}`). An input dir that does not exist means the input was not supplied. |
| `brief.json` | The order brief: `intent`, `targets`, `brand` (slug, name, palette/typography when known, `brief` text, `heygen.avatarId` / `heygen.voiceId` / `elevenlabs.voiceId` when the brand has them) and any `options` the owner set (every option has a default). |
| `prior/<saveId>.<ext>` | Earlier steps' saved outputs the harness downloaded for you, named by manifest save id (`.mp4` video, `.png` image, `.json` json, `.md` text). Only the files your step file lists are present. When the owner chose the "research and write my script first" path, `prior/approved_script.md` holds the script instead of `inputs/script/`. |
| `saves/<saveId>.<ext>` | **Where you write THIS step's saves.** The manifest `saves[]` carry no path — the path is always `saves/<id>.<ext>` (video `.mp4`, image `.png`, json `.json`, text `.md`). The harness uploads exactly these files, then runs your step's `checks[]` itself. Missing or malformed = the step failed. |
| `work/` | Your scratch space. Anything here is discarded when the step ends. |
| `needs_input.json` | Written by you ONLY when the step cannot proceed without an input listed in your step's `canAsk`. In this recipe `prepare_script` may ask for `script` / `format`, `avatar_render` for `avatar_id` / `voice_id` / `source_video`, `plan_broll` for `broll`. |
| `$CFW_RENDER_SKILLS_DIR` | Exported by the harness: the skills bundle root. `SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"`; vendored components live at `$SKILL_DIR/.hub/<name>` (`c-script`, `c-heygen`, `c-broll`, `c-broll-sync`, `c-reel-premium`, `c-typing-ui`, `c-html-gfx`, `c-audio`, `c-production`, `c-ffmpeg`, `c-ai-media`, `f-remotion`, `f-hyperframes`, `f-gsap`, `c-shorts-qa-gate`, `c-eval-runner`). Nothing else on the machine is read. |

Never read any file outside the workdir and `$CFW_RENDER_SKILLS_DIR`. There is no `.env`, no key
file and no hosted-box path. Provider keys exist only as `HEYGEN_API_KEY`, `ELEVENLABS_API_KEY`
and `KIE_API_KEY` in the environment, exported by the harness from the order's brand provider
keys; a step that needs one and finds it unset fails with a plain message — it never searches.

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

- **Frame 0 is NEVER black** (`YAVG > 30`) — the cover freeze of the strongest illustrative beat.
  **The last frame is NEVER black** — the video ends on the CTA card or the brand outro.
- **CTA is integrated by default**: a branded CTA card (offer line + handle/URL) is baked into the
  final 60 s, as the last illustrative card. Mandatory for `vsl`, default for `demo` / `tutorial`.
- **Every graphics card is illustrative** — title + an animation / hero that depicts the point
  (feed grid staggering in, count-up stat, waveform, chips). A title-only card is a defect.
- **Palette / typography come from the brand**: brand brief → palette in `brief.json` → the
  dark-premium default `bg #0F172A`, `accent #F97316`, `fg #F1F5F9`. Fonts are mapped names
  (`'Poppins'`, `'Inter'`, `'Oswald'`, `'JetBrains Mono'`) — never a `var(--font-*)`.
- **PIP card** is a rounded rectangle (~304×380, bottom corner alternating left/right across beats,
  ~72 px margin, thin gold `#D4A84C` border, soft shadow) — never a circle, never borderless.
  Graphics and captions never enter the PIP zone of the current beat.
- **Green-screen keying is two-pass `colorkey`** (`0x00FF00:0.25:0.05` then `0x00FF00:0.40:0.01`),
  never `chromakey`; detect the background type from edge pixels first — an opaque avatar is not
  keyed.
- **End-card copy is per-brand**: offer line, brand name, handle from `inputs/cta/cta.json`, else
  `brief.json.brand`. No handle → no handle line. Never invent one.
- Kitchen words are banned in anything owner-facing (`reason` texts, captions, chapter titles).

## Style defaults

| Option (in `brief.json.options`) | Default | Meaning |
|---|---|---|
| `speed` | `1.0` | Narration speed (1.0–1.25). |
| `broll_coverage` | `80` | Minimum % of runtime with b-roll / GFX over the avatar (hook and final CTA beat exempt). |
| `num_gfx` | `6` | GFX cards to render (stat reveals, quotes, CTA banner). |
| `num_images` | `4` | AI stills via `c-ai-media` (Kie) to supplement GFX. `0` disables. |
| `sfx` | `on` | Subtle SFX bed (intro sting, section transitions) at −18 dB under the voice. |
| `remotion` | `off` for vsl/demo, `on` for tutorial | Render animated diagram sections. |
| `pip_mode` | `corner` | `full` (talking head fills frame), `corner` (PIP card), `none` (voice only). |

## Tool notes

- Longform renders are long: a HeyGen job takes 5–30 min, a composite 10–40 min. Run them in the
  background if your engine offers it and poll; verify every output with `ffprobe`.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` is the duration idiom used
  throughout; width/height are read one field at a time.
- **No `#` comments inside `filter_complex` strings.** Save filter graphs over 3 lines to a `.sh`.
- Concat lists: write with `printf`, absolute `$PWD/...` paths, and always re-encode (never
  `-c copy` across differently encoded segments). Freeze frames: `-loop 1 -tune stillimage -r 25`.
- Loudness is normalised **once**, two-pass, in `post_process` (−14 LUFS). No other step touches
  loudness.
- HyperFrames is pinned: `npx hyperframes@0.7.5`. GSAP is vendored at
  `$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js` — load it LOCALLY, never from a CDN.
- Keep intermediate files in `work/`; write only the listed saves into `saves/`. Never read anything
  from `saves/` that you did not write — earlier steps' files are in `prior/`.
- Never print or write a secret (API key, token) anywhere, including logs and `reason` texts.
