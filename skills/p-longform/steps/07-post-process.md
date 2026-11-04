# SFX, loudness and captions

Master the mix: an optional subtle SFX bed under the voice, two-pass loudness normalisation to
−14 LUFS, and — when the owner asked for them — burned word-level captions. This is the ONLY step
that touches loudness.

## You receive

- `prior/composite_video.mp4` — the assembled video (+ outro).
- `prior/transcripts.json` — `words` (the script, aligned) and `spoken_words` (everything the
  recogniser heard, with times) for captions.
- `prior/broll_plan.json` — its last row (`gfx:cta`) is the end card: captions stop where it starts.
  Captions never depend on the layout rows or on `pip_side`: the caption text sits in x 420–1500,
  which is clear of the PIP card on both sides, on every beat.
- `inputs/captions/captions.md` — the choice as raw text, `on` or `off` (the worker stages every
  typed answer as `<id>.md`; `captions.json` `{"choice": "on|off"}` and `captions.txt` are read
  too). Captions are **on** unless the answer is `off`: a dir that is absent is not a refusal.
- `brief.json` — `options.sfx` (on), `brand` accent colour.

## You must produce

- `saves/mastered_video.mp4` — 1920×1080, 25 fps, H.264 yuv420p, AAC 48 kHz stereo at
  −14 LUFS (±0.5 after two-pass), captions burned when `on`.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"
IN=prior/composite_video.mp4
CAPS=$(python3 "$SKILL_DIR/scripts/captions.py" choice --dir .)   # on | off; on unless the owner said off
case "$CAPS" in on|off) ;; *) echo "captions choice unreadable"; exit 1 ;; esac
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
ffmpeg -hide_banner -nostats -i work/mixed.mp4 -af loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json -f null - 2> work/ln1.txt
eval "$(python3 -c "
import json,re; j=json.loads(re.findall(r'\{[^{}]*\}', open('work/ln1.txt').read())[-1])
print(' '.join(f'{k}={j[v]}' for k,v in (('MI','input_i'),('MT','input_tp'),('ML','input_lra'),('MTH','input_thresh'))))")"
ffmpeg -y -i work/mixed.mp4 -af "loudnorm=I=-14:LRA=11:TP=-1.5:measured_I=$MI:measured_LRA=$ML:measured_TP=$MT:measured_thresh=$MTH:linear=true" \
  -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 work/loudnorm.mp4
ffmpeg -i work/loudnorm.mp4 -af loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json -f null - 2>&1 | grep -o '"input_i" : "[^"]*"'
```

(`-nostats` keeps ffmpeg's progress line out of `work/ln1.txt`, so the JSON measurement is the
last thing in it; the parser takes the last `{...}` either way.) The verify line must read −14 ± 0.5. No clipping (`TP ≤ −1.0`), no silence gap > 2 s
(`silencedetect=n=-45dB:d=2` reports nothing before the outro).

### 3. Captions — when `captions = on` (the default)

Captions are made here and nowhere else (`composite` draws none), by one checked-in script, so every
render has the same captions: `scripts/captions.py`. Do not write your own caption code, do not edit
the file it writes, do not change the burn command and **never download a font**: the burn uses the
Inter Bold file bundled in `fonts/` through an explicit font folder. `build` reads
`prior/transcripts.json` (the aligned `words` plus the recognised words in `spoken_words` that fall in a
real hole, so words the speaker added to the script are captioned too, and no word shows twice) and the end card start in `prior/broll_plan.json`, and it
writes `work/captions.ass`: every spoken word, in the lower band (`CAP_TOP=820`), centred inside
x 420–1500, Inter 56 px white on a dark box, one or two lines of at most 7 words, with the **brand
accent** on the active word. Nothing starts at or after the end card. Every spoken word is captioned,
including the ones spoken over a card, a slide, a diagram or a full-screen still. A caption is never
skipped because of what is on screen. If the transcript has no `spoken_words` (a restored run), `build`
transcribes the narration itself; if it cannot, it stops and says why.

```bash
if [ "$CAPS" = on ]; then
  python3 "$SKILL_DIR/scripts/captions.py" build --dir . --out work/captions.ass \
    && python3 "$SKILL_DIR/scripts/captions.py" verify --dir . --ass work/captions.ass \
    && python3 "$SKILL_DIR/scripts/captions.py" burn --dir . --in work/loudnorm.mp4 --ass work/captions.ass --out saves/mastered_video.mp4
else
  ffmpeg -y -i work/loudnorm.mp4 -c copy -movflags +faststart saves/mastered_video.mp4
fi
```

`verify` measures the speech from the narration audio (`prior/composite_video.mp4`), not from the
transcript. It fails (and so does the run) when speech goes more than 3 s without a caption, when under
97 % of the speech time is captioned, or when a caption is on screen over the end card. It prints the
coverage and the worst gap. `burn` stops when no ffmpeg with the `ass` filter is found (it tries
`CFW_FFMPEG` when set, else the ffmpeg on `PATH`, else the ffmpeg-full install). If either fails, fix the
input it names (a missing narration or transcript); if you cannot, exit non-zero and say what it printed. A second
`build` gives the same file. Do not loosen the check and do not burn a file it rejected. Only an
explicit `off` burns nothing. The end card stays clean so the final check can match it.

### 4. Verify

```bash
ffmpeg -v error -i saves/mastered_video.mp4 -f null -
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 saves/mastered_video.mp4
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing `captions` choice means on, and
only an explicit `off` skips them; an undecodable composite is a failure of the previous step — exit
non-zero and say so.

## Checks the harness runs

- `master_loudness` — integrated loudness of `saves/mastered_video.mp4` is −14 LUFS ± 1.5.
- `master_has_speech` — `volumedetect` mean volume between −32 and −8 dB (speech present, not
  crushed). When captions are on it also runs `captions.py verify` on `work/captions.ass`: no stretch
  of voiced narration over 3 s without a caption, at least 97 % of the voiced time captioned, nothing
  over the end card. It fails when captions are off but the brief's intent asks for them. Keep
  `work/captions.ass` in place until the step ends; the check reads it.
