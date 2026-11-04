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
  "avatar_mode": "supplied",
  "words": [{"w": "Most", "start": 0.12, "end": 0.38}, ...],
  "spoken_words": [{"w": "Most", "start": 0.12, "end": 0.38}, ...],
  "segments": [{"text": "...", "start": 0.12, "end": 4.9}, ...],
  "sections": [{"id": "hook", "title": "Hook", "type": "talking-head", "start": 0.0, "end": 31.2}, ...],
  "srt": "1\n00:00:00,120 --> 00:00:04,900\n...\n" }
```

`words` is the script, aligned to the speech. `spoken_words` is what was actually heard, straight from
the recogniser (`work/words-raw.json`), including words the speaker said that are not in the script and
that alignment drops. Captions are built from both, so no spoken moment is left without a caption;
save every recognised word, unedited.

`sections` carries the section map re-expressed in seconds (`start` of its first word, `end` =
start of the next section; last ends at `duration`). `avatar_mode` is `supplied` (the owner's clip),
`avatar` (HeyGen render) or `voice` (voice-only bed), read from the tag `avatar_render` wrote
into `prior/avatar_video.mp4`; every later step reads it from this file.

## How

```bash
mkdir -p work saves
ffmpeg -y -i prior/avatar_video.mp4 -vn -ar 16000 -ac 1 work/avatar.wav
bash "$CFW_RENDER_SKILLS_DIR/p-longform/.hub/c-audio/scripts/transcribe.sh" work/avatar.wav work/words-raw.json
MODE=$(ffprobe -v error -show_entries format_tags=comment -of default=nw=1:nk=1 prior/avatar_video.mp4 | sed -n 's/.*cfw-avatar-mode=\([a-z]*\).*/\1/p' | head -1)
case "$MODE" in supplied|avatar|voice) ;; *) echo "avatar_mode tag missing on prior/avatar_video.mp4 — treating it as an avatar render"; MODE=avatar ;; esac
echo "avatar_mode=$MODE"
```

`transcribe.sh` runs offline (whisper.cpp). It writes `work/words-raw.json` =
`{"duration", "text", "wpm", "words": [{"w","start","end"}]}`, and exits non-zero with a plain
message when the audio cannot be transcribed (that is a failure of `avatar_render`, not an ask).

### 1. Align to the script

Whisper misses brand names and numbers. Align the recognised words to the TTS script body so
the section map's `start_word` offsets (word positions in the script) land on the right second.
Keep the **script spelling** with the **recognised timing**; a script word Whisper did not
hear gets a time spread evenly across the gap; a word Whisper added that is not in the script
is dropped. Never shift a recognised timestamp to "fix" the text. The result is one entry per
script word, in `work/words-aligned.json`. If less than half of the words match, the clip is
not a render of this script: say so and fail.

```bash
python3 - <<'PY'
import difflib, json, re
raw = json.load(open("work/words-raw.json"))["words"]
script = re.sub(r"^---.*?---\s*", "", open("prior/tts_script.md", encoding="utf-8").read(), flags=re.S).split()
assert len(raw) >= 500, f"only {len(raw)} words recognised — the audio is silent, music or the wrong language"
norm = lambda x: re.sub(r"[^a-z0-9]", "", x.lower())
sm = difflib.SequenceMatcher(None, [norm(x["w"]) for x in raw], [norm(x) for x in script], autojunk=False)
ratio = sm.ratio()
assert ratio >= 0.5, f"only {ratio:.0%} of the spoken words match the script — the video is not a render of this script"
out = [None] * len(script)
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if i2 > i1 and j2 > j1:                              # spoken words [i1,i2) <-> script words [j1,j2)
        t0, t1 = raw[i1]["start"], raw[i2 - 1]["end"]
        for k in range(j2 - j1):
            if tag == "equal" or i2 - i1 == j2 - j1:
                a, b = raw[i1 + k]["start"], raw[i1 + k]["end"]
            else:
                a = t0 + (t1 - t0) * k / (j2 - j1); b = t0 + (t1 - t0) * (k + 1) / (j2 - j1)
            out[j1 + k] = {"w": script[j1 + k], "start": a, "end": b}
for j, x in enumerate(out):                              # script words nobody spoke: spread across the gap
    if x is None:
        lo = j - 1
        while lo >= 0 and out[lo] is None: lo -= 1
        hi = j + 1
        while hi < len(out) and out[hi] is None: hi += 1
        t0 = out[lo]["end"] if lo >= 0 else 0.0
        t1 = out[hi]["start"] if hi < len(out) else max(t0, raw[-1]["end"])
        n = hi - lo - 1; k = j - lo - 1
        out[j] = {"w": script[j], "start": t0 + (t1 - t0) * k / n, "end": t0 + (t1 - t0) * (k + 1) / n}
for x in out: x["start"] = round(max(x["start"], 0.0), 3); x["end"] = round(max(x["end"], x["start"]), 3)
for a, b in zip(out, out[1:]): b["start"] = max(b["start"], a["start"])      # starts never go back
json.dump(out, open("work/words-aligned.json", "w"))
print(f"aligned {len(out)} script words, {len(raw)} recognised, match {ratio:.0%}")
PY
```

### 2. Sections in seconds

```bash
MODE="$MODE" python3 - <<'PY'
import json, os
w = json.load(open("work/words-aligned.json")); sm = json.load(open("prior/section_map.json"))
heard = [{"w": x["w"], "start": round(x["start"], 3), "end": round(x["end"], 3)} for x in json.load(open("work/words-raw.json"))["words"]]
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
json.dump({"duration": round(dur,2), "avatar_mode": os.environ["MODE"], "words": w, "spoken_words": heard, "segments": segs, "sections": secs, "srt": srt}, open("saves/transcripts.json","w"))
print(f"OK {len(w)} words, {len(segs)} segments, {len(secs)} sections, avatar_mode={os.environ['MODE']}")
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
