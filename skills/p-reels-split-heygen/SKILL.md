---
name: p-reels-split-heygen
description: Make a 50/50 split-screen reel from a SCRIPT using a HeyGen avatar — generates the talking-head video (ElevenLabs v3 voice → HeyGen v3 Avatar III, 16:9 1080p), then delegates ALL compositing to p-reels-split (graphics top half, face bottom half). Provider work only; no ffmpeg compositing in this skill. Trigger on "make a split-screen reel from a script with my avatar", "HeyGen split-screen reel", "script to 50/50 reel via avatar", "graphics-on-top face-on-bottom reel from a script".
when-to-use: Use when the user has a SCRIPT (not an uploaded clip) and wants a 50/50 split-screen reel (transcript-synced graphics in the TOP half, avatar face in the BOTTOM half) using a HeyGen avatar. This wrapper handles ONLY provider work (generating or reusing the HeyGen render via ElevenLabs v3 + HeyGen v3 Avatar III). All split/cut-zoom compositing, captions, grade, SFX, and CTA are handled by p-reels-split. Do NOT use this when the user has already recorded or uploaded a talking-head clip — use p-reels-split directly in that case. For a bottom-PIP avatar reel use p-reels-pip-heygen; for a full-frame avatar reel use p-reels-spotlight-heygen.
version: 1.0.0
kind: pipeline
visibility: catalog
providers: heygen, elevenlabs
produces:
  dish: HeyGen Avatar Split-Screen Reel
  format: 9:16 vertical video
  duration: 20-60s
inputs: [script, voice, avatar_id, broll, broll_style, bottom_cutzoom, known_transcript]
dependsOn: [c-heygen, p-reels-split]

  hermes:
    vendored:
      - c-heygen           # provider tier reference (MCP/API/browser fallbacks) — split-heygen
                           # uses its own ElevenLabs-v3 → HeyGen-v3 API path (scripts/voice-to-reel.sh).
      # NOTE: does NOT vendor p-reels-split's components — that core owns them.
      # This wrapper delegates to p-reels-split entirely; all rendering lives there.
    delegates_to: p-reels-split
metadata:
  hermes:
    vendored:
      - { name: c-audio, load: ".hub/c-audio/SKILL.md" }
      - { name: c-broll-sync, load: ".hub/c-broll-sync/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-heygen, load: ".hub/c-heygen/SKILL.md" }
      - { name: c-overlay-fx, load: ".hub/c-overlay-fx/SKILL.md" }
      - { name: c-reel-premium, load: ".hub/c-reel-premium/SKILL.md" }
      - { name: c-shorts-qa-gate, load: ".hub/c-shorts-qa-gate/SKILL.md" }
      - { name: c-typing-ui, load: ".hub/c-typing-ui/SKILL.md" }
      - { name: f-gsap, load: ".hub/f-gsap/SKILL.md" }
      - { name: f-hyperframes, load: ".hub/f-hyperframes/SKILL.md" }
      - { name: f-hyperframes-cli, load: ".hub/f-hyperframes-cli/SKILL.md" }
      - { name: p-reels-split, load: ".hub/p-reels-split/SKILL.md" }
      - { name: wowx-motions, load: ".hub/wowx-motions/SKILL.md" }
    progressive: true
---




> ## ⚡ Frame integrity + integrated CTA (MANDATORY — 2026-06-16)
> - **Frame 0 is NEVER black.** The first frame must be a bright money-shot — the cover-freeze of the strongest illustrative beat (Step 10 cover rule). Verify `ffmpeg ... signalstats` → `YAVG > 30`. No black / hook-blank / fade-in opener.
> - **The LAST frame is NEVER black.** The reel must end on content, not a fade-to-black or trailing blank. Verify the final frame `YAVG > 30`.
> - **CTA is integrated by DEFAULT, not optional.** Every reel/VSL ends on a branded **CTA beat baked into the timeline** (offer line + handle/URL), as the final illustrative HyperFrames card. Do not ship a reel whose last beat is filler or black. (In p-reels-split this is the Step 9 CTA takeover.)

> ## ⚡ HyperFrames = illustrative, NOT just titles (MANDATORY — 2026-06-16)
> Every HyperFrames graphics scene MUST pair its title with an **illustrative animation that depicts the point** — never a bare kinetic title card. Examples: a 45-post feed grid staggering in (`back.out`), a count-up stat with day-dots, an animated waveform for "voice", platform chips popping in. Match the premium reference in `cfw-marketing/creatives/productions/restaurants-vsl/hyperframes` (`DIAG-calendar` feed-grid, `HF-*` motion) **and** `cfw-marketing/creatives/productions/fnb-split-screen-short/gen-rich-cards.py`: grid + glow + vignette background, GSAP eased + staggered elements, brand palette, depth (shadows/shine). **Make it as rich and premium as possible — a title-only card is a defect.**

# p-reels-split-heygen — HeyGen Avatar → 50/50 Split-Screen Reel

**This is a thin provider wrapper.** It does two things:

1. Resolve the talking-head video by running the ElevenLabs-v3 → HeyGen-v3 provider step
   (`scripts/voice-to-reel.sh`) on the script — or reusing a cached render for this exact
   script + avatar + voice combo.
2. Delegate to `p-reels-split` — passing the resolved video as `talking_head_video`, the script as
   `known_transcript` (so the core skips transcription), and any b-roll / style inputs unchanged.

**HARD RULE: this wrapper contains ZERO compositing logic.** No ffmpeg filter graphs, no caption
rendering, no grade, no SFX, no HyperFrames compositions, no cut-zoom. All of that lives in
`p-reels-split`. Any change to rendering must happen there, not here (anti-drift law — same as
`p-reels-pip-heygen` / `p-reels-spotlight-heygen`).

This wrapper completes the `<layout>-<source>` family: the *same* audio-driven HeyGen render feeds
the PIP core (`p-reels-pip-heygen`), the full-frame core (`p-reels-spotlight-heygen`), **or** the
split-screen core (`p-reels-split-heygen`) depending only on which wrapper is invoked. The one
difference here is the provider path: split-heygen uses the **ElevenLabs v3 (cloned voice) → HeyGen
v3 audio-driven Avatar III, rendered 16:9 1080p** pipeline (proven for the split-screen archetype),
not c-heygen's green-screen TTS render. **16:9 is mandatory** — 9:16 letterboxes the landscape
avatar and pixelates after the bottom-zone crop + cut-zoom upscale.

## Inputs

| Param | Required | Default | Notes |
|---|---|---|---|
| `script` | YES | — | Full narration script. Rendered to the avatar via ElevenLabs+HeyGen, and forwarded as `known_transcript` to `p-reels-split` so the core skips re-transcription. |
| `voice` | No | `qfNHzU5pVyzMLm53FhzY` | ElevenLabs voice_id (cloned "Vasanth-042026"). Model is `eleven_v3`. Read from brand config if supplied there. |
| `avatar_id` | No | `9273e994f1ed484d9031afa3725676c5` | HeyGen avatar id — **Avatar III "GG-4k"**. Do NOT swap to an Avatar IV/V id; the generation is set by the id itself (no version param exists in the API). |
| `broll[]` | No | `[]` | B-roll clips for the TOP half. Passed through unchanged to `p-reels-split`. |
| `broll_style` | No | `card` | TOP-zone b-roll rendering (`card` wowx canvas-wrap / `blurred-fill`). Passed through to `p-reels-split`. |
| `bottom_cutzoom` | No | `true` | Cut-zoom the avatar face on every beat. Recommended `true` for a single continuous avatar read (adds short-form energy). Passed through to `p-reels-split`. |
| `known_transcript` | No | `=script` | Pre-computed word-level transcript. Defaults to the script text. |
| Any other `p-reels-split` param | No | core defaults | All unrecognized params (`broll_coverage_pct`, `bottom_fit`, `cta_text`, `cta_handle`, beat cadence, etc.) are forwarded verbatim to `p-reels-split`. |

## Step 0/1 — Resolve the talking-head video (ElevenLabs v3 → HeyGen v3, with cached-render reuse)

**Reuse rule: never burn ElevenLabs/HeyGen credits for a script that has already been rendered.**

The provider step is `scripts/voice-to-reel.sh` (promoted from the fnb-split-screen-short
production). It runs ElevenLabs `eleven_v3` TTS on the script, uploads the audio to HeyGen, generates
an audio-driven `type:avatar` video at `aspect_ratio:16:9 resolution:1080p`, polls to completion, and
downloads the MP4. It prints the finished path as its last line.

```bash
SCRIPT="<the narration script text>"
PRODUCTION="{production}"
VOICE_ID="${voice:-qfNHzU5pVyzMLm53FhzY}"
AVATAR_ID="${avatar_id:-9273e994f1ed484d9031afa3725676c5}"
CACHE_DIR="$PRODUCTION/interim/heygen-cache"
mkdir -p "$CACHE_DIR"

# Stable cache key from script + avatar + voice
CACHE_KEY=$(printf "%s|%s|%s" "$SCRIPT" "$AVATAR_ID" "$VOICE_ID" | sha256sum | cut -c1-16)
CACHED_VIDEO="$CACHE_DIR/avatar-${CACHE_KEY}.mp4"

if [ -f "$CACHED_VIDEO" ]; then
  echo "[p-reels-split-heygen] Reusing cached HeyGen render: $CACHED_VIDEO"
  TALKING_HEAD_VIDEO="$CACHED_VIDEO"
else
  echo "[p-reels-split-heygen] No cached render — running ElevenLabs→HeyGen provider step"

  # Locate this skill dir (box deployments live under ~/.hermes/profiles/<slug>/skills/cfw/)
  SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" \
    /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-reels-split-heygen 2>/dev/null | head -1)

  # Provider step — requires ELEVENLABS_API_KEY + HEYGEN_API_KEY in the environment.
  # Writes the finished avatar MP4 to $CACHED_VIDEO and prints the path on its last line.
  EL_VOICE="$VOICE_ID" HG_AVATAR="$AVATAR_ID" \
    bash "$SKILL_DIR/scripts/voice-to-reel.sh" "$SCRIPT" "$CACHED_VIDEO"

  [ -f "$CACHED_VIDEO" ] || { echo "[p-reels-split-heygen] FATAL: provider step did not produce a video"; exit 1; }
  TALKING_HEAD_VIDEO="$CACHED_VIDEO"
fi

# Sanity check before handing off
[ -f "$TALKING_HEAD_VIDEO" ] || { echo "[p-reels-split-heygen] FATAL: talking head not found"; exit 1; }
ffprobe -v error -show_entries format=duration -of csv=p=0 "$TALKING_HEAD_VIDEO" \
  | grep -qE '^[0-9]' || { echo "[p-reels-split-heygen] FATAL: ffprobe failed on talking head"; exit 1; }
```

> **Provider-tier fallback (c-heygen):** `scripts/voice-to-reel.sh` is the audio-driven Avatar-III
> API path and is the default. If it fails (API outage, credit block, avatar unavailable), fall back
> to `c-heygen`'s tier order (MCP → API → browser → human) to obtain a talking-head MP4 for the same
> script — then continue from "Sanity check" above. Whichever path produced it, the file must be a
> **16:9 1080p** landscape render so the bottom-zone crop/cut-zoom stays sharp.

## Step 2 — Delegate to p-reels-split (this is the only other step)

Pass the resolved talking-head video, the original script as `known_transcript` (avoids redundant
transcription in the core), and all b-roll / style inputs unchanged. The wrapper's job is done here.

```bash
# known_transcript: the script text is the ground-truth transcript.
# p-reels-split Step 3 reads $KNOWN_TRANSCRIPT_JSON and skips transcription when set.
KNOWN_TRANSCRIPT_JSON="${known_transcript:-$SCRIPT}"

# Run p-reels-split — executor reads p-reels-split/SKILL.md and executes all its steps.
# All split/cut-zoom compositing, captions, grade, SFX, CTA, and upload happen inside p-reels-split.
run_skill p-reels-split \
  TALKING_HEAD_VIDEO="$TALKING_HEAD_VIDEO" \
  BROLL_CLIPS="${BROLL_CLIPS:-[]}" \
  KNOWN_TRANSCRIPT_JSON="$KNOWN_TRANSCRIPT_JSON" \
  PRODUCTION="$PRODUCTION" \
  AVATAR_ID="$AVATAR_ID" \
  VOICE_ID="$VOICE_ID"
# Style/cadence params are read from env by p-reels-split. Recommended defaults for an avatar read:
#   bottom_cutzoom=true (zoom-cut energy on a single continuous read)
#   broll_style=card    (premium canvas-wrap for app/screen-recording b-roll)
# Pass any other p-reels-split param (broll_coverage_pct, bottom_fit, cta_text, cta_handle,
# broll_clip_seconds, etc.) through the calling environment unchanged.
```

> **Eval gate:** Delivery is gated by `p-reels-split`'s `acceptance.json` via `c-eval-runner` — see p-reels-split QA-gate step (Step 11). This wrapper needs no `acceptance.json` of its own; the gate runs inside the base recipe before upload.

The R2 URL is emitted by `p-reels-split` as its final output line. This wrapper prints nothing additional.

## What this wrapper does NOT do

- No ffmpeg compositing of any kind (no vstack, no cut-zoom, no blurred-fill)
- No HyperFrames template rendering
- No caption generation or burn-in
- No b-roll beat planning
- No grade or SFX
- No cover-frame extraction
- No upload — `p-reels-split` handles upload

All of the above live exclusively in `p-reels-split`. This file must never grow those steps.
