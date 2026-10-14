# Transcribe

Produce the word-level transcript of the avatar track. The SRT-style timecodes are **ground
truth** for every later step: section boundaries, b-roll plan rows, GFX placements and captions
all use these timestamps — never estimates from word counts.

## You receive

- `prior/avatar_video.mp4` — the sealed avatar track.
- `prior/section_map.json` — sections with `start_word` offsets (to be converted to seconds here).
- `prior/tts_script.md` — the narration text, used to correct recognition errors.

## You must produce

- `saves/transcripts.json`:

```json
{ "duration": 736.4,
  "words": [{"w": "Most", "start": 0.12, "end": 0.38}, ...],
  "segments": [{"text": "...", "start": 0.12, "end": 4.9}, ...],
  "sections": [{"id": "hook", "title": "Hook", "type": "talking-head", "start": 0.0, "end": 31.2}, ...],
  "srt": "1\n00:00:00,120 --> 00:00:04,900\n...\n" }
```

`sections` carries the section map re-expressed in seconds (`start` of its first word, `end` =
start of the next section; last ends at `duration`).

## How

```bash
mkdir -p work saves
ffmpeg -y -i prior/avatar_video.mp4 -vn -ar 16000 -ac 1 work/avatar.wav
bash "$CFW_RENDER_SKILLS_DIR/p-longform/.hub/c-audio/scripts/transcribe.sh" work/avatar.wav work/words-raw.json
```

### 1. Align to the script

Whisper misses brand names and numbers. Align `work/words-raw.json` to the TTS script body (a
sequence alignment on lower-cased tokens — `difflib.SequenceMatcher` is enough): where the
recognised word differs from the script word at the same position, keep the **script spelling**
with the **recognised timing**. Insertions / deletions keep Whisper's timing for neighbours. Never
shift timestamps to "fix" the text.

### 2. Sections in seconds

```bash
python3 - <<'PY'
import json
w = json.load(open("work/words-aligned.json")); sm = json.load(open("prior/section_map.json"))
dur = float(__import__("subprocess").run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0","prior/avatar_video.mp4"],capture_output=True,text=True).stdout)
secs = []
for i, s in enumerate(sm["sections"]):
    start = w[min(s["start_word"], len(w)-1)]["start"]
    end = w[min(sm["sections"][i+1]["start_word"], len(w)-1)]["start"] if i+1 < len(sm["sections"]) else dur
    secs.append({**{k: s[k] for k in ("id","title","type")}, "start": round(start,2), "end": round(end,2)})
segs = []  # ≤ 12 words or ≤ 6 s per segment, split on sentence ends
cur = []
for t in w:
    cur.append(t)
    if t["w"].endswith((".", "?", "!")) or len(cur) >= 12 or (cur[-1]["end"] - cur[0]["start"]) > 6:
        segs.append({"text": " ".join(x["w"] for x in cur), "start": cur[0]["start"], "end": cur[-1]["end"]}); cur = []
if cur: segs.append({"text": " ".join(x["w"] for x in cur), "start": cur[0]["start"], "end": cur[-1]["end"]})
def ts(x): h=int(x//3600); m=int(x%3600//60); s=x%60; return f"{h:02d}:{m:02d}:{int(s):02d},{int(round((s-int(s))*1000)):03d}"
srt = "".join(f"{i+1}\n{ts(s['start'])} --> {ts(s['end'])}\n{s['text']}\n\n" for i, s in enumerate(segs))
assert len(w) >= 500, f"only {len(w)} words recognised"
json.dump({"duration": round(dur,2), "words": w, "segments": segs, "sections": secs, "srt": srt}, open("saves/transcripts.json","w"))
print(f"OK {len(w)} words, {len(segs)} segments, {len(secs)} sections")
PY
```

Fewer than 500 words on a 5-minute-plus track means the audio is wrong (silence, music, wrong
language) — that is a failure of `avatar_render`; exit non-zero and say so.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. Everything you need is in `prior/`; a
missing or undecodable file is a failure of the previous step.

## Checks the harness runs

- `words_found` — `saves/transcripts.json` has ≥ 500 `words` with monotonic non-negative
  timestamps and `sections` covering `0 → duration` without gaps.
