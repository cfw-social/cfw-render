# Fetch and transcribe the reference

Get the reference reel onto disk as a decodable MP4, transcribe it word by word, and describe its
format so the later steps can adapt the script and rebuild the layout. No brand work happens here.

## You receive

- `inputs/source_reel/` — either a video file (`.mp4`/`.mov`/`.webm`) or `source_reel.json`
  with `{"url": "<public reel link>"}`; when the owner pasted a link CFW already copied the media
  into Media, so prefer a video file in the dir when one exists.
- `brief.json` — `brand`, `options`.

## You must produce

- `saves/source_video.mp4` — the reference, H.264 yuv420p, ≤ 1080 px tall, AAC audio, 10–300 s.
- `saves/source_transcript.json` — `{"text": "...", "words": [{"w": "...", "start": 0.0, "end": 0.4}, ...], "duration": <s>, "wpm": <n>}`.
- `saves/format_analysis.json` — the format read:

```json
{ "hook": {"type": "question|claim|stat|story", "seconds": 2.8, "text": "..."},
  "sections": [{"id": "opening", "start": 0, "end": 6.1}, {"id": "middle", "start": 6.1, "end": 38.0}, {"id": "close", "start": 38.0, "end": 44.2}],
  "pacing": {"cuts_per_10s": 4, "wpm": 162},
  "layout": {"presenter": "pip|full|none", "pip": {"cx": 540, "cy": 1500, "diameter": 420}, "split": false},
  "orientation": "portrait|landscape|square", "captions_present": true }
```

## How

```bash
mkdir -p work saves
SRC=$(ls inputs/source_reel/*.mp4 inputs/source_reel/*.mov inputs/source_reel/*.webm 2>/dev/null | head -1 || true)
URL=$(python3 -c "import json,os; p='inputs/source_reel/source_reel.json'; print(json.load(open(p)).get('url','') if os.path.exists(p) else '')")
if [ -z "$SRC" ] && [ -z "$URL" ]; then
  echo '{ "inputId": "source_reel", "reason": "Please share the reel to re-make: a public link or the video file.", "count": 1 }' > needs_input.json; exit 0
fi
if [ -z "$SRC" ]; then
  yt-dlp -f "bestvideo[height<=1080]+bestaudio/best" --merge-output-format mp4 -o work/source-raw.mp4 "$URL" \
    || { echo '{ "inputId": "source_reel", "reason": "That link could not be downloaded — please check it is public, or upload the video file instead.", "count": 1 }' > needs_input.json; exit 0; }
  SRC=work/source-raw.mp4
fi
ffmpeg -y -i "$SRC" -vf "scale=-2:'min(1080,ih)'" -c:v libx264 -pix_fmt yuv420p -preset fast -crf 20 \
  -c:a aac -ar 48000 -ac 2 -movflags +faststart saves/source_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/source_video.mp4)
python3 -c "d=float('$DUR'); assert 10 <= d <= 300, f'reference {d:.1f}s outside 10–300 s'"
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 saves/source_video.mp4 | grep -q . \
  || { echo '{ "inputId": "source_reel", "reason": "The reel has no audio track, so there is nothing to transcribe — please share a reel with speech.", "count": 1 }' > needs_input.json; exit 0; }
```

If the reference is outside 10–300 s or has no speech, that is an input problem: ask for
`source_reel` with the measured duration in the reason.

### 1. Transcribe with word timestamps (`c-audio` → Whisper)

```bash
ffmpeg -y -i saves/source_video.mp4 -vn -ar 16000 -ac 1 work/source.wav
bash "$CFW_RENDER_SKILLS_DIR/p-clone-reel/.hub/c-audio/scripts/transcribe.sh" work/source.wav work/source-words.json
```

Normalise to the `words` shape above (`w`, `start`, `end` in seconds), join into `text`, compute
`wpm = words / (duration/60)`. Fewer than 15 words means the reel is music-only — ask for another
`source_reel`.

### 2. Read the format

Sample frames at 5/20/40/60/80/95 % (`ffmpeg -ss T -frames:v 1 work/f_XX.png`) and look at them:
is there a presenter, full-frame or a circle/rounded PIP? Measure the PIP centre and diameter in
source pixels and scale to the 1080×1920 canvas. Count hard cuts (`select='gt(scene,0.3)'` with
`showinfo`) for `cuts_per_10s`. Split the transcript into `opening` (hook until the first idea
lands), `middle` and `close` (CTA / sign-off) by meaning, not fixed seconds. Write
`saves/format_analysis.json`; every number is measured, none guessed.

## Checks the harness runs

- `source_decodes` — `saves/source_video.mp4` decodes end to end (`ffmpeg -v error -f null -`)
  and has an audio stream with non-silent content.
- `words_found` — `saves/source_transcript.json` has ≥ 15 `words` with monotonic timestamps.
