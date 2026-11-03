# Assemble

Marry the body track to the voice bed, add the brand outro, then run the premium pass (kinetic
captions, SFX under the voice, grade) and master the mix to −14 LUFS. The bed audio is never cut
or re-timed; the outro's own audio (if any) plays only after the bed ends.

## You receive

- `prior/body_video.mp4` — the silent body at bed length.
- `prior/voice_bed.mp4` — the narration (audio is the only part used).
- `prior/transcripts.json` — `words` for caption timing.
- `prior/beat_list.json` — `grade` hint, beat boundaries for SFX cues.
- `inputs/outro/` — one portrait clip when supplied (dir absent = generate the brand card outro).
- `brief.json` — `options.captions` / `sfx` / `grade` / `overlay_beats`, `brand`.

## You must produce

- `saves/assembled_video.mp4` — 1080×1920, 30 fps, H.264 + AAC 48 kHz stereo, duration = bed +
  outro, −14 LUFS ± 1.5, voice audible under every beat, ending on the brand outro.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-faceless"
PREMIUM="$SKILL_DIR/.hub/c-reel-premium"; OVERLAY="$SKILL_DIR/.hub/c-overlay-fx"
```

### 1. Mux the voice onto the body

```bash
ffmpeg -y -i prior/body_video.mp4 -i prior/voice_bed.mp4 -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 -shortest work/body.mp4
```

### 2. Brand outro (mandatory)

- `inputs/outro/` supplied → normalise it to 1080×1920 / 30 fps / AAC stereo
  (`work/outro.mp4`); pad silent audio if the clip has none.
- Otherwise author ONE closing HyperFrames card (same pipeline as `render_graphics`: brand
  palette, logo/wordmark text, handle only if it exists, 2.5 s, ambient motion) and render it to
  `work/outro.mp4` with a silent stereo track.

The CTA beat already closes the bed; the outro follows it, so the reel never ends on filler.

```bash
printf "file '%s'\nfile '%s'\n" "$PWD/work/body.mp4" "$PWD/work/outro.mp4" > work/concat.txt
ffmpeg -y -f concat -safe 0 -i work/concat.txt -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -c:a aac -b:a 192k -ar 48000 -ac 2 work/assembled-raw.mp4
```

### 3. Premium pass — `c-reel-premium` P1–P4

Follow `$PREMIUM/SKILL.md` with these defaults for this format: `REEL_IN=work/assembled-raw.mp4`,
`REEL_OUT=work/premium.mp4`, words JSON from `prior/transcripts.json`, `CAP_TOP=1450` (lower third
— the cards fill the centre down to ≈ 1330 px), `CAPTIONS=on`, `SFX=on` with cues at beat
boundaries mixed `amix=normalize=0` UNDER the voice, `GRADE` from the beat list (else
`warm-amber`). Honour `brief.json.options` overrides. If `overlay_beats` is non-empty render each
sticker with `$OVERLAY/render-overlay.cjs` and overlay it at its window. Minimal fallback when the
premium pass cannot run: captions off, no SFX, no grade — copy `work/assembled-raw.mp4`.

### 4. Master to −14 LUFS (two-pass) and seal

```bash
STATS=$(ffmpeg -hide_banner -nostats -i work/premium.mp4 -af "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1 | python3 -c "import sys,json,re; m=re.search(r'\{[^{}]*\}', sys.stdin.read()); print(json.dumps(json.loads(m.group(0)) if m else {}))")
AF=$(python3 -c "
import json,sys; s=json.loads(sys.argv[1])
print('loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true' % (s['input_i'],s['input_tp'],s['input_lra'],s['input_thresh'],s['target_offset']) if s else 'loudnorm=I=-14:TP=-1.5:LRA=11')" "$STATS")
ffmpeg -y -i work/premium.mp4 -c:v copy -af "$AF" -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/assembled_video.mp4
```

### 5. Continuity proof

For every beat window run `volumedetect` on `saves/assembled_video.mp4`; a window with
`mean_volume -inf` or below −40 dB means the voice was dropped — fix the mux, never deliver.
Confirm the last frame (`-sseof -0.1`) has mean luma > 30/255 and is the outro.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. An unreadable outro clip is a failure
to report (the owner can resend it), not something to silently replace.

## Checks the harness runs

- `vo_continuous_bed` — voice audible (mean above −40 dB) in every beat window of
  `saves/assembled_video.mp4`.
- `brand_outro_at_end` — the final 0.5 s is not black and the duration equals bed + outro ± 0.3 s.
