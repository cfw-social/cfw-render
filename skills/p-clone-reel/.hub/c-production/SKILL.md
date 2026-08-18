---
name: c-production
description: Production management for the creative studio. Use for creating production folder structures, running delivery checklists, updating the HTML dashboard, verifying output files, managing snap detection, extracting hook clips, and coordinating multi-step pipeline state.
when_to_use: Trigger on production folder, create production, delivery checklist, dashboard update, snap detection, hook clip, c-ffmpeg verify, c-ffmpeg delivery, production structure, interim folder, finals folder, production state, step checkpoint, output verify.
allowed-tools: Bash, Read, Write, Edit
kind: component
visibility: internal
dependsOn: [c-broll, c-ffmpeg]
requires: ffmpeg, python3
---


# Studio Production — Folder, Delivery & Dashboard


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `{brand_local_path}` | Yes | Caller / ecosystem.yaml | Absolute path to brand folder (e.g. `/Users/vasanth/MarketingMr/passiveincome/Royal-Mysorian`) |
| `{production-name}` | Yes | Caller | Short slug for this production (e.g. `ai-shortcuts-ep01`) |

## Production Folder Structure

Create this structure at `{brand_local_path}/creatives/productions/{production-name}/`:

```
{production}/
  interim/
    scripts/        ← STEP 1: script drafts + final script
    audio/          ← STEP 2: TTS/voiceover renders (NO SFX here)
    c-broll/          ← STEP 3: project b-roll clips
      segments/
      gfx/
    broll-plan/     ← STEP 4: timing plans, b-roll placement sheets
    video/
      base/         ← STEP 5: raw renders — read-only, NEVER modify
      compositing/  ← STEP 6: compositing exports in progress
  final/            ← STEP 7: ONLY deliverables (ls-* / pr-* prefix)
```

**AI-generated images** → `{brand_local_path}/creatives/brolls/images/` (NEVER in interim/)
**SFX** → `/Users/vasanth/Code/skills/sfx/` (NEVER in audio/)
**Deliverables** → `final/` only — never copy to brand `creatives/` before delivery

```bash
# Create production folder
PROD="{brand_path}/creatives/productions/{name}"
mkdir -p "$PROD/interim/scripts" "$PROD/interim/audio" \
  "$PROD/interim/broll/segments" "$PROD/interim/broll/gfx" \
  "$PROD/interim/broll-plan" \
  "$PROD/interim/video/base" "$PROD/interim/video/compositing" \
  "$PROD/final"
```

## Naming Convention

Every deliverable filename starts with an aspect ratio prefix:

| Prefix | Meaning |
|--------|---------|
| `ls-` | Landscape (> 1.3 ratio) |
| `sq-` | Square (0.77–1.3 ratio) |
| `pr-` | Portrait (< 0.77 ratio) |

**Full format:** `{aspect}-{category}{NN}-{description}.{ext}`

| Category | Code | Example |
|----------|------|---------|
| AI image/clip | `aimg` | `ls-aimg01-explainer-scene.mp4` |
| Website scroll | `wbst` | `ls-wbst01-homepage-hero.mp4` |
| Screen recording | `scrn` | `sq-scrn01-terminal-demo.mp4` |
| Mobile recording | `mobi` | `pr-mobi01-phone-scan.mp4` |
| Graphic | `gfx` | `ls-gfx01-lower-third.mp4` |
| Banner | `bnr` | `ls-bnr01-subscribe-cta.png` |

## Delivery Checklist (Run Before Marking Final)

Run `ffmpeg-verify-output` then `ffmpeg-delivery-checklist` on every final:

```bash
# Verify output integrity
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,codec_name \
  -of default=noprint_wrappers=1 "$FINAL"

# Check audio stream exists
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "$FINAL"

# Check duration
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$FINAL"
```

### 12-Point Delivery Checklist

1. Video codec: H.264 (libx264)
2. Pixel format: yuv420p
3. Audio codec: AAC
4. Audio loudness: -14 LUFS (landscape) / -16 LUFS (portrait/shorts)
5. Captions burned in (shorts only)
6. Outro card present (shorts only)
7. B-roll coverage ≥ 80% (shorts) / ≥ 70% (VSL)
8. Aspect ratio correct (1920x1080 landscape, 1080x1920 portrait)
9. No black frames at start/end
10. No audio sync drift (check at 1:00, 3:00, 5:00 for long-form)
11. Filename follows naming convention (ls-/sq-/pr- prefix)
12. File is in `final/` not `interim/`

## Dashboard Updates (MANDATORY)

**Rule: If you produced output but didn't update the dashboard, you haven't finished the step.**

After EVERY recipe step that produces output, update the HTML dashboard immediately.

```bash
# Find the production dashboard
DASH="$PROD/dashboard.html"

# Update step status in dashboard
# Step IDs: 1=script, 2=tts, 3=c-broll, 4=plan, 5=avatar, 6=composite, 7=final
```

Dashboard lives at `{production}/dashboard.html`. The root studio dashboard is at `${STUDIO_ROOT}/dashboard.html`.

Start dashboard server from project root:
```bash
cd "${STUDIO_ROOT}" && nohup python3 -m http.server 8889 > /tmp/dashboard-server.log 2>&1 & disown
```

## Snap Detection (for bg-swap reel)

Detect finger-snap frame in video for background swap:

```bash
# Analyze audio for snap transient (sharp attack)
ffmpeg -i "$VIDEO" -af "silencedetect=noise=-30dB:d=0.01" -f null - 2>&1 | grep silence_end

# Or use volume threshold spike
ffmpeg -i "$VIDEO" -af "volumedetect" -f null - 2>&1
```

Snap frame = loudest transient peak. Note frame number and timestamp for compositing split point.

## Hook Clip Extraction

Extract first N seconds for hook-jacked reel:

```bash
# Extract hook (first 5s)
ffmpeg -i "$SOURCE" -t 5 -c copy "$PROD/interim/video/base/hook-clip.mp4"

# NEVER speed-adjust the hook clip — it changes the viral timing
```

## Anti-Patterns

- Never modify raw renders in `video/base/` — copy before editing
- Never store SFX in production `audio/`
- Never put AI images in interim/ — they go straight to `brolls/images/`
- Never copy assets to brand `creatives/` BEFORE delivery
- Never write finals to deprecated `output/` folder
- Never skip steps 6–8 (b-roll) for shorts — these are mandatory
- Never run batch scripts for composite+downstream after step 4 — each short runs independently

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

