# SFX, loudness and captions

Master the mix: an optional subtle SFX bed under the voice, two-pass loudness normalisation to
−14 LUFS, and — when the owner asked for them — burned word-level captions. This is the ONLY step
that touches loudness.

## You receive

- `prior/composite_video.mp4` — the assembled video (+ outro).
- `prior/transcripts.json` — `words` and `srt` for captions.
- `prior/broll_plan.json` — `pip_side` per row (captions must clear the PIP corner of each beat).
- `inputs/captions/captions.json` — `{"choice": "on|off"}`; dir absent → `off`.
- `brief.json` — `options.sfx` (on), `brand` accent colour.

## You must produce

- `saves/mastered_video.mp4` — 1920×1080, 25 fps, H.264 yuv420p, AAC 48 kHz stereo at
  −14 LUFS (±0.5 after two-pass), captions burned when `on`.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"
IN=prior/composite_video.mp4
CAPS=$(python3 -c "import json,os;p='inputs/captions/captions.json';print(json.load(open(p)).get('choice','off') if os.path.exists(p) else 'off')")
SFX=$(python3 -c "import json;print((json.load(open('brief.json')).get('options') or {}).get('sfx','on'))")
```

### 1. SFX bed (`c-ffmpeg/references/audio-processing.md`) — when `sfx = on`

From the CC0 pack `$SKILL_DIR/.hub/c-reel-premium/assets/sfx/`: an intro sting at 0 s and a soft
transition cue at each section boundary (`prior/transcripts.json.sections[].start`, skip the
first). Mix at **−18 dB** relative to the voice — the bed never drowns narration.

```bash
# build work/sfx.wav as a silent 48 kHz stereo track with the cues placed by adelay, then:
ffmpeg -y -i "$IN" -i work/sfx.wav -filter_complex "[1:a]volume=-18dB[s];[0:a][s]amix=inputs=2:duration=first:normalize=0[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 work/mixed.mp4
```

`sfx = off` → `cp "$IN" work/mixed.mp4`.

### 2. Two-pass loudnorm to −14 LUFS

```bash
ffmpeg -i work/mixed.mp4 -af loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json -f null - 2> work/ln1.txt
eval "$(python3 -c "
import json,re; j=json.loads(re.search(r'\{[^{}]*\}\s*$', open('work/ln1.txt').read(), re.S).group(0))
print(' '.join(f'{k}={j[v]}' for k,v in (('MI','input_i'),('MT','input_tp'),('ML','input_lra'),('MTH','input_thresh'))))")"
ffmpeg -y -i work/mixed.mp4 -af "loudnorm=I=-14:LRA=11:TP=-1.5:measured_I=$MI:measured_LRA=$ML:measured_TP=$MT:measured_thresh=$MTH:linear=true" \
  -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 work/loudnorm.mp4
ffmpeg -i work/loudnorm.mp4 -af loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json -f null - 2>&1 | grep -o '"input_i" : "[^"]*"'
```

The verify line must read −14 ± 0.5. No clipping (`TP ≤ −1.0`), no silence gap > 2 s
(`silencedetect=n=-45dB:d=2` reports nothing before the outro).

### 3. Captions — when `captions = on`

Word-level captions from `prior/transcripts.json.words`: lower band (`CAP_TOP=820`), centred,
Inter 56 px white with the **brand accent** on the active word, each caption ≤ 8 words, clear of
both bottom corners (the PIP card alternates left/right: keep text inside x 420–1500). Build an
ASS file in `work/captions.ass` with per-word `\k` karaoke timing and burn:

```bash
ffmpeg -y -i work/loudnorm.mp4 -vf "ass=work/captions.ass" -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -g 25 -c:a copy -movflags +faststart saves/mastered_video.mp4
```

`captions = off` → `ffmpeg -y -i work/loudnorm.mp4 -c copy -movflags +faststart saves/mastered_video.mp4`.
Captions never render over the outro or the CTA card's text area.

### 4. Verify

```bash
ffmpeg -v error -i saves/mastered_video.mp4 -f null -
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 saves/mastered_video.mp4
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing `captions` choice means off;
an undecodable composite is a failure of the previous step — exit non-zero and say so.

## Checks the harness runs

- `master_loudness` — integrated loudness of `saves/mastered_video.mp4` is −14 LUFS ± 1.5.
- `master_has_speech` — `volumedetect` mean volume between −32 and −8 dB (speech present, not
  crushed).
