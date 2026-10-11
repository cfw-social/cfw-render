# Transcribe

Produce the word-timed transcript of the sealed voice bed (and, when b-roll was supplied, cue
transcripts of each b-roll clip) that the planner and the caption pass feed on.

## You receive

- `prior/voice_track.mp4` — the sealed speaker bed from *Prepare footage*. Read-only.
- `inputs/broll/` — zero or more b-roll clips (dir absent = no b-roll). Only used for the cue
  transcripts; nothing here is cut or placed in this step.
- `brief.json` — language hints (Hinglish / multilingual → `medium` model).

## You must produce

- `saves/transcripts.json` — one object:

```json
{ "words": [ {"text": "...", "start": 0.00, "end": 0.42}, ... ],
  "broll_cues": [ {"clip": "inputs/broll/<file>", "duration": 12.3,
                   "cues": [ {"start": 0.0, "end": 0.5, "text": "..."} ]}, ... ] }
```

`words` is the cleaned, Latin-key-normalised word array for the bed. `broll_cues` is `[]` when no
b-roll was supplied. Clip paths are the workdir-relative `inputs/broll/...` paths.

## How

`mkdir -p work saves`. Word-level timing comes from the SRT→words conversion below; the hosted
transcriber accepts ONLY `text | segments | srt | vtt` (there is no `words` format).

### 1. Transcribe the bed with word timestamps

Local transcription is the default: `mlx_whisper` → `whisper` → `npx hyperframes@0.7.5 transcribe`
(whisper.cpp). The hosted Gemini transcriber runs ONLY if the brand provides a Gemini key — the
harness exports the Gemini key from the order's brand provider keys. Never read a key from a file;
when the exported Gemini key is unset, skip that branch and run local Whisper.

```bash
srt_to_words () {  # $1 = srt, $2 = words.json
python3 - "$1" "$2" <<'PY'
import json, sys
words = []
for block in open(sys.argv[1]).read().strip().split('\n\n'):
    parts = block.strip().split('\n')
    if len(parts) < 3: continue
    ts = parts[1]; text = ' '.join(parts[2:])
    def t2s(s): h,m,rest=s.replace(',','.').split(':'); return int(h)*3600+int(m)*60+float(rest)
    s, e = ts.split(' --> ')
    for w in text.split(): words.append({"text": w, "start": t2s(s.strip()), "end": t2s(e.strip())})
json.dump(words, open(sys.argv[2], 'w'))
PY
}
GEMINI_KEY_SET=$(python3 -c "import os; print('yes' if os.environ.get('GEMINI_'+'API_KEY') else 'no')")
if [ "$GEMINI_KEY_SET" = "yes" ] && command -v cfw-transcribe >/dev/null 2>&1; then
  cfw-transcribe --input prior/voice_track.mp4 --out work/transcript.srt --format srt
  srt_to_words work/transcript.srt work/words.json
elif command -v mlx_whisper >/dev/null 2>&1; then
  echo "[spotlight] local transcription: mlx_whisper"
  mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small --output-dir work --output-format json
  python3 -c "import json; d=json.load(open('work/voice_track.json')); json.dump([{'text':s['text'],'start':s['start'],'end':s['end']} for s in d.get('segments',[])], open('work/words.json','w'))"
elif command -v whisper >/dev/null 2>&1; then
  echo "[spotlight] local transcription: whisper CLI"
  whisper prior/voice_track.mp4 --model small --output_dir work --output_format srt
  srt_to_words work/voice_track.srt work/words.json
else
  echo "[spotlight] local transcription: npx hyperframes@0.7.5 transcribe (whisper.cpp)"
  cp prior/voice_track.mp4 work/base.mp4
  ( cd work && npx hyperframes@0.7.5 transcribe base.mp4 --model small --output words.json )
fi
```

No `.en` model suffix unless the audio is confirmed English — `.en` models TRANSLATE non-English.
Hinglish / multilingual → `--model medium`.

### 2. Quality check + normalise

If more than 20 % of entries are `♪` or garbage, rerun with `--model medium`. Strip non-word
entries, then canonicalise the key (`word` → `text`) so both shapes are accepted:

```bash
python3 - <<'PY'
import json, re
words = json.load(open('work/words.json'))
out = []
for w in words:
    t = (w.get('text') or w.get('word') or '').strip()
    if not t or t in ('♪', '[Music]', '(music)') or not re.search(r'\w', t): continue
    out.append({"text": t, "start": float(w["start"]), "end": float(w["end"])})
assert out, "no words transcribed"
json.dump(out, open('work/words.json', 'w'))
print(f"[spotlight] {len(out)} words, {out[0]['start']:.2f}s → {out[-1]['end']:.2f}s")
PY
```

### 3. B-roll cue transcripts (only when `inputs/broll/` exists)

```bash
python3 - <<'PY'
import json, subprocess, os, glob, shutil, tempfile
result = []
for clip in sorted(glob.glob('inputs/broll/*')):
    dur = float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0", clip],
                               capture_output=True, text=True).stdout.strip() or "0")
    cues = []
    td = tempfile.mkdtemp(dir='work'); sub16 = os.path.join(td, "sub16.mp4")
    subprocess.run(["ffmpeg","-y","-i",clip,"-af","loudnorm=I=-16:TP=-1.5:LRA=11",
                    "-c:v","libx264","-c:a","aac",sub16], check=False, capture_output=True)
    subprocess.run(["npx","hyperframes@0.7.5","transcribe", sub16, "--model","small",
                    "--output", os.path.join(td,"words.json")], capture_output=True, text=True, cwd=td)
    wf = os.path.join(td, "words.json")
    if os.path.exists(wf):
        cues = [{"start": w["start"], "end": w["end"], "text": w.get("text") or w.get("word","")} for w in json.load(open(wf))]
    shutil.rmtree(td, ignore_errors=True)
    result.append({"clip": clip, "duration": dur, "cues": cues})
json.dump(result, open('work/broll_cues.json','w'), indent=2)
print(f"[spotlight] broll_cues: {len(result)} clips")
PY
```

A clip with no speech simply has `cues: []` — that is fine; the planner falls back to ordered
placement for it. (The b-roll loudnorm here is on a scratch copy for recognition only; b-roll
audio never reaches the reel.)

### 4. Write the save

```bash
python3 - <<'PY'
import json, os
words = json.load(open('work/words.json'))
cues = json.load(open('work/broll_cues.json')) if os.path.exists('work/broll_cues.json') else []
json.dump({"words": words, "broll_cues": cues}, open('saves/transcripts.json','w'), indent=1)
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. If every transcription backend is
missing or the bed yields zero words after a `medium` retry, exit non-zero with one plain line
(e.g. "no speech could be recognised in the talking-head video") — the harness surfaces it.

## Checks the harness runs

- `words_found` — `saves/transcripts.json` parses, `words` is a non-empty array of
  `{text,start,end}` with monotonically non-decreasing starts and the last `end` within ~3 s of the
  bed duration.
