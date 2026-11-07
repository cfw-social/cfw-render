---
name: c-ffmpeg
description: All FFmpeg video/audio operations for the creative studio. Use when compositing video, applying chroma key (green screen), building portrait/landscape layouts, trimming clips, concatenating segments, adjusting speed, adding zoompan/Ken Burns effects, normalizing audio loudness, detecting snap points, or running delivery quality checks.
when_to_use: Trigger on any mention of c-ffmpeg, video composite, green screen, PIP, chroma key, concat, trim, speed adjust, loudnorm, zoompan, portrait layout, landscape layout, audio mixing, SFX mix, delivery checklist, or ffprobe verify.
allowed-tools: Bash
kind: component
visibility: internal
requires: ffmpeg
---

# FFmpeg — Creative Studio Video Engine


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.
FFmpeg powers every video operation: compositing, chroma key, layout assembly, audio mixing, trimming, and delivery verification.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `{production}` | Yes | Caller | Absolute path to production folder |
| `$INPUT` / `$OUTPUT` | Yes | Caller | Input/output video file paths |
| `$LAYOUT` | Conditional | Caller | Portrait layout: `bottom-avatar`, `split-broll`, `pip-broll`, `split-equal`, `popout` |
| `$SPEED` | Conditional | Caller | Speed multiplier (0.5–2.0, chain for outside range) |

## Non-Negotiable Rules

**1. Chroma key color is always `0x00FF00`.**
Never sample green from the video. Never trust a b-roll plan's color value. Always use `#00FF00` two-pass:
```bash
colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01
```
`chromakey` filter is NOT available in this build — always use `colorkey`.

**2. Never crop-and-stretch the avatar.** That distorts the aspect ratio.
- WRONG: `crop=1920:880,scale=1920:1080`
- RIGHT: `scale=2208:1242,crop=1920:1080:144:0` (1.15x zoom, then crop — preserves ratio)

**3. Audio-per-segment architecture.** Never separate audio from video in composites.
- WRONG: cut video-only segments → concatenate → add one audio strip (drift accumulates 5+ min)
- RIGHT: every segment (AVATAR, PIP, FULLSCREEN) carries its own synced audio → concatenate preserves sync
- Segment audio must NOT be AAC: each AAC segment ends with up to 21 ms of padding that the concat
  keeps, so a long video drifts. `scripts/build-segments.py` writes PCM segments and the concat
  encodes AAC once.
- AVATAR segments: cut from `avatar-on-bg.mp4` WITH audio using output-level seeking (`-i file -ss $START`)
- PIP/FULLSCREEN segments: take audio from `$BASE` at `-ss $START` (`-map "1:a"`)

**4. No `#` comments inside `filter_complex` strings.** Causes parse error. Save complex commands as `.sh` scripts.

**5. Gap-free b-roll windows.** Extend each segment's `enable` window to the START of the next segment. Eliminates 0.5–1.5s avatar flashes. Never speed up b-roll (`itsscale`/`setpts`) in overlay chains — causes freezes.

## Quick Reference

### Trim a clip (frame-accurate)
```bash
ffmpeg -i input.mp4 -ss $START -t $DURATION -c:v libx264 -c:a aac -y output.mp4
```

### Concat via demuxer (same codec, no re-encode)
```bash
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```

### Concat via filter (re-encode, flexible codecs)
```bash
ffmpeg -i seg1.mp4 -i seg2.mp4 -filter_complex \
  "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" -c:v libx264 -c:a aac -y output.mp4
```

### Static image → video clip with Ken Burns
```bash
ffmpeg -loop 1 -i image.png \
  -vf "scale=1920:1080,zoompan=z='min(zoom+0.001,1.3)':d=375:s=1920x1080" \
  -t 15 -r 25 -c:v libx264 -pix_fmt yuv420p -y output.mp4
```
- Whiteboard images (MGG): use `1.1x` max → `z='min(zoom+0.0003,1.1)'`
- General/cinematic: `1.3x` is fine

### Speed adjust
```bash
-vf "setpts=PTS/1.25"            # video 1.25x
-af "atempo=1.25"                # audio 1.25x
-af "atempo=2.0,atempo=1.25"    # audio 2.5x (chain for >2.0)
```

### Verify output
```bash
ffprobe -v error \
  -show_entries format=duration,size \
  -show_entries stream=codec_name,width,height \
  -of json output.mp4
```

### Compress image for YouTube thumbnail (< 2 MB)
```bash
ffmpeg -i input.png -q:v 2 output.jpg
```

## Portrait/Non-16:9 in Landscape Composites

Never force-scale portrait video to 1920x1080 — causes distortion. Use pillarboxing:
```bash
scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black
```

## Loudnorm (Two-Pass)

FFmpeg 8.1 `loudnorm` applies dynamic compression even with `linear=true`. Use two-pass:

**Pass 1 — measure:** `ffmpeg -i input.mp3 -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null /dev/null 2>&1 | tail -20`

**Pass 2 — apply as simple volume:** `ffmpeg -i input.mp3 -af "volume=+4.5dB" -y output.mp3`

Target: -14 LUFS (YouTube), -1.5 dBFS true peak.
## Scripts

### `scripts/build-segments.py` — one 1920×1080 segment per b-roll plan row

Used by `p-longform` step 06 (composite). Pure ffmpeg + Python standard library, no network,
deterministic. It builds the audio-per-segment architecture of rule 3 from a `broll_plan.json`:

```bash
python3 "$SKILL_DIR/.hub/c-ffmpeg/scripts/build-segments.py" --plan prior/broll_plan.json \
  --avatar work/avatar-on-bg.mp4 --avatar-raw prior/avatar_video.mp4 --key "<colorkey chain or empty>" \
  --visuals work/visuals --broll inputs/broll --out work/seg \
  --pip-card rounded --pip-size 304x380 --pip-margin 72 --pip-border "#D4A84C" [--no-pip] [--dry-run]
```

- Rows: `{start, end, layout, asset, zoom, pip_side}`. Layouts `AVATAR_FULL`, `PIP_CORNER` (rounded
  card, gold border, outside-only shadow, alternating corner), `PIP_SIDE` (640-wide avatar column),
  `FULLSCREEN_BROLL`, `SIDE_BY_SIDE` (960 + 960). Assets: `broll/<file>` in `--broll` (looped),
  `gfx:`/`hf:`/`still:<id>` as `<id>.mp4` or `<id>.png` in `--visuals` (last frame held). A picture
  that is not 16:9 gets a blurred fill, never bars. `zoom: slow-in` is a 1.0 → 1.08 push-in.
- Output `seg-0001-<layout>.mp4`, … (25 fps, `-g 25`, yuv420p) plus `segments.json`. Rows are cut on
  the 25 fps grid so they join with no gap. The audio of each row is the exact window of
  `--avatar-raw`, stored as **PCM** (QuickTime container named `.mp4`): AAC per segment adds up to
  21 ms of silence at each cut and drifts a long video by seconds; the concat's single AAC encode
  is the only AAC pass. Measured: 106 segments / 600 s, audio markers 0.0 ms off after the concat.
- `--no-pip` (voice-only / `pip_mode: none`): PIP and side rows are built as `FULLSCREEN_BROLL`.
- A finished segment is reused on a rerun; stale `seg-*.mp4` files are removed.
- Exit 0 ok; 1 ffmpeg failed or an output did not verify; 2 bad input (nothing encoded), with the
  row number in the message. Needs only ffmpeg/ffprobe (PATH, then `/opt/homebrew/bin`).

## References (loaded on demand)

- **[Portrait layouts](references/portrait-layouts.md)** — bottom-avatar, split-broll, pip-broll, split-equal, popout. Read for any 9:16 composite.
- **[Landscape PIP](references/landscape-pip.md)** — 16:9 avatar + b-roll PIP with audio-per-segment. Read for VSL.
- **[Audio processing](references/audio-processing.md)** — SFX mixing (adelay, amix, volume levels), SFX library paths.
- **[Delivery checklist](references/delivery.md)** — 12 mandatory pre-delivery quality checks.

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

