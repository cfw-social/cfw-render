# Transcribe

Produce the word-level timing of the voice bed. These timestamps are **ground truth** for every
beat boundary, caption and b-roll window downstream — the `data-duration` of each composition
equals its VO span.

## You receive

- `prior/voice_bed.mp4` — the sealed narration bed (30–90 s).
- `inputs/script/script.json` or `prior/approved_script.md` — the script text, used to correct
  recognised words (brand names, product terms) without changing any timestamp.

## You must produce

- `saves/transcripts.json`:

```json
{ "duration": 47.3,
  "words": [{"text": "Stop", "start": 0.12, "end": 0.41}, ...],
  "segments": [{"text": "Stop guessing your menu prices.", "start": 0.12, "end": 2.9}, ...],
  "srt": "1\n00:00:00,120 --> 00:00:02,900\nStop guessing your menu prices.\n\n..." }
```

`words` is a flat array covering the whole bed; `start` < `end`, monotonic, in seconds.

## How

```bash
mkdir -p work saves
ffmpeg -y -i prior/voice_bed.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le work/bed.wav
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_bed.mp4)
```

### 1. Word-level ASR (local chain — in this order)

1. `mlx_whisper` (Apple Silicon): `python3 -m mlx_whisper work/bed.wav --model mlx-community/whisper-large-v3-turbo --word-timestamps True --output-format json --output-dir work/asr`
2. `whisper` CLI (openai-whisper): `whisper work/bed.wav --model medium --word_timestamps True --output_format json --output_dir work/asr`
3. `whisper.cpp` if installed (`-ojf` for word JSON).

No hosted ASR: there is no Gemini / OpenAI key in this workdir and the step must not look for one.
If none of the three tools exist, fail with "no local speech-to-text available on this machine".

### 2. Normalise to the contract and align to the script

```bash
python3 - <<'PY'
import glob, json
src = json.load(open(sorted(glob.glob("work/asr/*.json"))[0]))
words = []
for seg in src.get("segments", []):
    for w in seg.get("words", []):
        t = (w.get("word") or w.get("text") or "").strip()
        if t: words.append({"text": t, "start": round(float(w["start"]), 3), "end": round(float(w["end"]), 3)})
assert len(words) >= 20, f"only {len(words)} words recognised — bed may be silent"
for a, b in zip(words, words[1:]): assert a["start"] <= b["start"], "non-monotonic word timing"
json.dump({"words": words, "segments": [{"text": s["text"].strip(), "start": s["start"], "end": s["end"]} for s in src["segments"]]}, open("work/words.json", "w"), indent=1)
PY
```

Then compare `work/words.json` text to the script: fix misheard brand/product tokens by editing
`text` ONLY (never a timestamp). Build the SRT from `segments`, read `duration` from `$BED_DUR`,
and write `saves/transcripts.json` with `duration`, `words`, `segments`, `srt`.

```bash
python3 -c "
import json; t=json.load(open('saves/transcripts.json'))
assert t['words'] and t['words'][-1]['end'] <= t['duration'] + 0.5, 'words run past the bed'
print(len(t['words']), 'words over', t['duration'], 's')"
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing ASR tool or a silent bed is a
failure: exit non-zero with the reason.

## Checks the harness runs

- `words_found` — `saves/transcripts.json` has ≥ 20 words, monotonic, within the bed duration.
