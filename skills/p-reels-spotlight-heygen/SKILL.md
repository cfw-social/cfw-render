---
name: p-reels-spotlight-heygen
description: Full-frame premium reel from a script via HeyGen avatar — generates the talking-head video via HeyGen, then delegates ALL compositing to p-reels-spotlight. Provider work only; no ffmpeg compositing in this skill. Trigger on "HeyGen spotlight reel", "full-frame avatar reel from script", "script to premium reel via avatar", "generate HeyGen reel full frame", "avatar kinetic-captions reel from script".
when-to-use: Use when the user has a SCRIPT (not an uploaded clip) and wants a full-frame premium spotlight reel (speaker fills the frame) using a HeyGen avatar. This wrapper handles ONLY provider work (generating or reusing the HeyGen render). All compositing, kinetic captions, b-roll takeovers, grade, and SFX are handled by p-reels-spotlight. Do NOT use this when the user has already uploaded a talking-head clip — use p-reels-spotlight directly in that case. For a bottom-PIP avatar reel use p-reels-pip-heygen.
version: 1.0.0
kind: pipeline
visibility: catalog
produces:
  dish: HeyGen Avatar Spotlight Reel
  format: 9:16 vertical video
  duration: 20-60s
inputs: [script, broll, avatar_id, voice_id, known_transcript]
dependsOn: [c-heygen, p-reels-spotlight]

  hermes:
    vendored:
      - c-heygen           # provider step — generates avatar MP4 from script
      # NOTE: does NOT vendor p-reels-spotlight's components — that core owns them.
      # This wrapper delegates to p-reels-spotlight entirely; all rendering lives there.
    delegates_to: p-reels-spotlight
metadata:
  hermes:
    vendored:
      - { name: c-broll, load: ".hub/c-broll/SKILL.md" }
      - { name: c-broll-sync, load: ".hub/c-broll-sync/SKILL.md" }
      - { name: c-cloud-media, load: ".hub/c-cloud-media/SKILL.md" }
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
      - { name: p-reels-spotlight, load: ".hub/p-reels-spotlight/SKILL.md" }
    progressive: true
---




> ## ⚡ Frame integrity + integrated CTA (MANDATORY — 2026-06-16)
> - **Frame 0 is NEVER black.** The first frame must be a bright money-shot — the cover-freeze of the strongest illustrative beat (Step 10 cover rule). Verify `ffmpeg ... signalstats` → `YAVG > 30`. No black / hook-blank / fade-in opener.
> - **The LAST frame is NEVER black.** The reel must end on content, not a fade-to-black or trailing blank. Verify the final frame `YAVG > 30`.
> - **CTA is integrated by DEFAULT, not optional.** Every reel/VSL ends on a branded **CTA beat baked into the timeline** (offer line + handle/URL), as the final illustrative HyperFrames card. Do not ship a reel whose last beat is filler or black. (In p-reels-split this is the Step 9 CTA takeover; other recipes must add an equivalent closing CTA card.)

> ## ⚡ HyperFrames = illustrative, NOT just titles (MANDATORY — 2026-06-16)
> Every HyperFrames graphics scene MUST pair its title with an **illustrative animation that depicts the point** — never a bare kinetic title card. Examples: a 45-post feed grid staggering in (`back.out`), a count-up stat with day-dots, an animated waveform for "voice", platform chips popping in. Match the premium reference in `cfw-marketing/creatives/productions/restaurants-vsl/hyperframes` (`DIAG-calendar` feed-grid, `HF-*` motion) **and** `cfw-marketing/creatives/productions/fnb-split-screen-short/gen-rich-cards.py`: grid + glow + vignette background, GSAP eased + staggered elements, brand palette, depth (shadows/shine). **Make it as rich and premium as possible — a title-only card is a defect.**

# p-reels-spotlight-heygen — HeyGen Avatar → Full-Frame Spotlight Reel

**This is a thin provider wrapper.** It does two things:

1. Resolve the talking-head video by calling `c-heygen` with the script (or reusing a cached render if one exists for this exact script).
2. Delegate to `p-reels-spotlight` — passing the resolved video, the script as `known_transcript` (so the core skips transcription), and any b-roll inputs unchanged.

**HARD RULE: this wrapper contains ZERO compositing logic.** No ffmpeg filter graphs, no caption rendering, no grade, no SFX, no HyperFrames compositions. All of that lives in `p-reels-spotlight`. Any change to rendering must happen there, not here (anti-drift law from the consolidation plan §3e).

This wrapper proves the `<layout>-<source>` pattern: the *same* `c-heygen` output feeds either the PIP core (`p-reels-pip-heygen`) or the full-frame core (`p-reels-spotlight-heygen`) depending only on which wrapper is invoked. The HeyGen step is identical in both.

## Inputs

| Param | Required | Default | Notes |
|---|---|---|---|
| `script` | YES | — | Full narration script. Passed to `c-heygen` for the avatar render, and forwarded as `known_transcript` to `p-reels-spotlight` so the core skips re-transcription. |
| `avatar_id` | YES | brand config | HeyGen avatar ID. Read from brand DNA / brand config if not explicitly supplied. |
| `voice_id` | YES | brand config | HeyGen voice ID. Read from brand DNA / brand config if not explicitly supplied. |
| `broll[]` | No | `[]` | B-roll clips. Passed through unchanged to `p-reels-spotlight`. |
| `broll_coverage_pct` | No | 30 | Passed through to `p-reels-spotlight`. |
| Any other `p-reels-spotlight` param | No | core defaults | All unrecognized params are forwarded verbatim to `p-reels-spotlight`. |

## Step 1 — Resolve the talking-head video (HeyGen, with cached-render reuse)

**Reuse rule: never burn HeyGen credits for a script that has already been rendered.**

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd 2>/dev/null)"
[ -d "$SKILL_DIR/.hub" ] || SKILL_DIR="$(find "$HOME/.hermes/skills" "$HOME/.claude/skills" \
   -type d -name p-reels-spotlight-heygen -print 2>/dev/null | head -1)"
SCRIPT="<the narration script text>"
PRODUCTION="{production}"
CACHE_DIR="$PRODUCTION/interim/heygen-cache"
mkdir -p "$CACHE_DIR"

# Build a stable cache key from the script + avatar/voice combo
CACHE_KEY=$(printf "%s|%s|%s" "$SCRIPT" "$AVATAR_ID" "$VOICE_ID" \
  | sha256sum | cut -c1-16)
CACHED_VIDEO="$CACHE_DIR/avatar-${CACHE_KEY}.mp4"

if [ -f "$CACHED_VIDEO" ]; then
  echo "[p-reels-spotlight-heygen] Reusing cached HeyGen render: $CACHED_VIDEO"
  TALKING_HEAD_VIDEO="$CACHED_VIDEO"
else
  echo "[p-reels-spotlight-heygen] No cached render found — invoking c-heygen"

  # --- Invoke c-heygen ---
  # c-heygen reads: $AVATAR_ID, $VOICE_ID, $SCRIPT, $HEYGEN_API_KEY
  # It writes the green-screen MP4 to:
  #   $PRODUCTION/interim/video/base/<slug>-green-screen.mp4
  # Follow c-heygen SKILL.md in full (MCP → API → Browser → Human tier order).
  # After c-heygen completes, the output path is in $HEYGEN_OUT (set by c-heygen).

  # Run c-heygen skill — executor reads c-heygen/SKILL.md and executes all its steps.
  run_skill c-heygen \
    AVATAR_ID="$AVATAR_ID" \
    VOICE_ID="$VOICE_ID" \
    SCRIPT="$SCRIPT" \
    PRODUCTION="$PRODUCTION"

  # After c-heygen: locate the generated MP4
  HEYGEN_OUT=$(find "$PRODUCTION/interim/video/base" -name "*green-screen.mp4" \
    -newer "$CACHE_DIR" 2>/dev/null | sort -t/ -k1 | tail -1)

  if [ -z "$HEYGEN_OUT" ] || [ ! -f "$HEYGEN_OUT" ]; then
    echo "[p-reels-spotlight-heygen] ERROR: c-heygen did not produce a video. Stop."
    exit 1
  fi

  # Cache it for future runs with the same script+avatar+voice
  cp "$HEYGEN_OUT" "$CACHED_VIDEO"
  echo "[p-reels-spotlight-heygen] HeyGen render cached: $CACHED_VIDEO"
  TALKING_HEAD_VIDEO="$CACHED_VIDEO"
fi

# Sanity check before handing off
[ -f "$TALKING_HEAD_VIDEO" ] || { echo "[p-reels-spotlight-heygen] FATAL: talking head not found"; exit 1; }
ffprobe -v error -show_entries format=duration -of csv=p=0 "$TALKING_HEAD_VIDEO" \
  | grep -qE '^[0-9]' || { echo "[p-reels-spotlight-heygen] FATAL: ffprobe failed on talking head"; exit 1; }
```

## Step 2 — Delegate to p-reels-spotlight (this is the only other step)

Pass the resolved talking-head video, the original script as `known_transcript` (avoids redundant transcription in the core), and all b-roll inputs unchanged. The wrapper's job is done here.

```bash
# known_transcript: the script text is the ground-truth transcript.
# p-reels-spotlight Step 3 is the transcription step.
# When KNOWN_TRANSCRIPT_JSON is set, pass it so the core can skip re-transcription;
# p-reels-spotlight reads the variable and skips Step 3 when populated.
KNOWN_TRANSCRIPT_JSON="$SCRIPT"

# Run p-reels-spotlight — executor reads p-reels-spotlight/SKILL.md and executes all its steps.
# All compositing, kinetic captions, b-roll takeovers, grade, SFX, cover rule, and upload
# happen inside p-reels-spotlight.
run_skill p-reels-spotlight \
  AVATAR="$TALKING_HEAD_VIDEO" \
  BROLL_CLIPS="${BROLL_CLIPS:-[]}" \
  KNOWN_TRANSCRIPT_JSON="$KNOWN_TRANSCRIPT_JSON" \
  PRODUCTION="$PRODUCTION" \
  AVATAR_ID="$AVATAR_ID" \
  VOICE_ID="$VOICE_ID"
# All other params (broll_coverage_pct, broll_clip_seconds, cta_text, captions, sfx, grade, etc.)
# are passed through if set in the calling environment — p-reels-spotlight reads them from env.
```

> **Eval gate:** Delivery is gated by `p-reels-spotlight`'s `acceptance.json` via `c-eval-runner` — see p-reels-spotlight QA-gate step. This wrapper needs no `acceptance.json` of its own; the gate runs inside the base recipe before upload.

The R2 URL is emitted by `p-reels-spotlight` as its final output line. This wrapper prints nothing additional.

## What this wrapper does NOT do

- No ffmpeg compositing of any kind
- No HyperFrames template rendering
- No caption generation or burn-in
- No b-roll beat planning
- No grade or SFX
- No cover-frame extraction
- No upload — `p-reels-spotlight` handles upload

All of the above live exclusively in `p-reels-spotlight`. This file must never grow those steps.
