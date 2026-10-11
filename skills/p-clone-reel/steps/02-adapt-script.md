# Adapt the script to the brand

Rewrite the chosen section of the reference transcript as the brand's own script: same structure,
same beat count, same word count ±10 % so the timing survives — new topic, brand vocabulary, brand
CTA. This is writing work only: no audio, no video.

## You receive

- `prior/source_transcript.json` — `text`, `words`, `duration`, `wpm`.
- `prior/format_analysis.json` — `hook`, `sections`, `pacing`.
- `inputs/topic/topic.json` — `{"text": "..."}` when supplied; dir absent → keep the reference's
  topic, re-angled to the brand (`brief.json.brand.brief`, `intent`).
- `inputs/section/section.json` — `{"choice": "full|opening|middle"}`; dir absent → `full`.
- `brief.json` — `brand` (name, brief, vocabulary notes), `intent`, `targets`.

## You must produce

- `saves/adapted_script.md` — the narration, with a short YAML front matter:

```md
---
section: full
source_words: 118
adapted_words: 121
target_seconds: 44
---
<hook line>

<one idea per sentence…>

<CTA line>
```

The body is TTS-clean prose: no headings after the front matter, no stage directions, no markdown
emphasis, numbers and URLs written as they should be spoken.

## How

```bash
mkdir -p work saves
python3 - <<'PY'
import json, os
t = json.load(open("prior/source_transcript.json")); f = json.load(open("prior/format_analysis.json"))
sec = "full"
if os.path.exists("inputs/section/section.json"): sec = json.load(open("inputs/section/section.json")).get("choice") or "full"
win = next((s for s in f["sections"] if s["id"] == sec), None) if sec != "full" else {"start": 0, "end": t["duration"]}
if win is None: win = {"start": 0, "end": t["duration"]}
words = [w for w in t["words"] if win["start"] <= w["start"] < win["end"]]
json.dump({"section": sec, "start": win["start"], "end": win["end"], "words": len(words), "text": " ".join(w["w"] for w in words), "wpm": t["wpm"]}, open("work/section.json", "w"))
print(f"section={sec} words={len(words)} seconds={win['end']-win['start']:.1f}")
PY
```

### 1. Map the beats

From `work/section.json` and `format_analysis.hook`, list the reference's beats in order (hook →
set-up → payoff(s) → close) with each beat's word count. This is the skeleton you fill.

### 2. Write the brand version

For each beat write the brand's sentence(s) with the **same word count ±10 %**: the hook keeps its
type (question stays a question, stat stays a stat — with a true brand stat or none), the body
makes the brand's point on the owner's `topic`, the close becomes the brand's CTA (`brief.json`
brand CTA wording; the end card itself is rendered later). Apply the brand vocabulary and tone
from `brief.json.brand.brief`. Never copy a reference sentence; never add claims the brief does
not support. Make it TTS-clean: `2x` → "twice", `/pricing` → "slash pricing", acronyms spelled
out when ambiguous.

### 3. Time it and write the save

```bash
python3 - <<'PY'
import json, re
s = json.load(open("work/section.json")); body = open("work/adapted.txt").read().strip()
n = len(body.split()); src = s["words"]; wpm = s["wpm"] or 150
secs = round(n / wpm * 60)
assert abs(n - src) <= max(3, round(src * 0.10)), f"adapted {n} words vs source {src} (±10% needed)"
assert 25 <= secs <= 65, f"adapted script times to {secs}s; the reel needs 30–60 s"
open("saves/adapted_script.md", "w").write(f"---\nsection: {s['section']}\nsource_words: {src}\nadapted_words: {n}\ntarget_seconds: {secs}\n---\n{body}\n")
print(f"OK {n} words ≈ {secs}s")
PY
```

If the chosen section times under 25 s at the reference's pace, extend by keeping the section's
beats and adding one brand payoff beat (still inside ±10 % of a `full` adaptation is not required
then — note `section` in the front matter and the harness check uses the section's own window).

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing `topic` is not a blocker (fall
back to the reference topic in brand voice); a missing transcript is a failure of the previous
step — exit non-zero and say so.

## Checks the harness runs

- `script_length_matches_source` — `adapted_words` is within ±10 % (min ±3) of `source_words`
  in the front matter, and `target_seconds` is 25–65.
