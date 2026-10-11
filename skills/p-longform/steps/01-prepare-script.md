# Prepare the script and section map

Turn the owner's script into a TTS-clean narration and a **section map** that follows the chosen
`format`. No audio, no video and no graphics here — this step decides the structure every later
step follows.

## You receive

- `inputs/script/script.json` — `{"text": "..."}` (a `.txt`/`.md` in the same dir is also
  acceptable) — OR `prior/approved_script.md` when the owner chose the research-and-write path
  (use it verbatim).
- `inputs/format/format.json` — `{"choice": "vsl|demo|tutorial"}`.
- `brief.json` — `brand`, `intent`, `options.speed`.

## You must produce

- `saves/tts_script.md` — front matter + TTS-clean narration body:

```md
---
format: vsl
words: 1840
estimated_seconds: 736
---
<narration, one paragraph per section, no headings, no stage directions>
```

- `saves/section_map.json`:

```json
{ "format": "vsl",
  "sections": [
    {"id": "hook", "title": "Hook", "type": "talking-head", "words": 90, "start_word": 0},
    {"id": "problem", "title": "The problem", "type": "concept", "words": 310, "start_word": 90}
  ],
  "cta": {"section": "cta", "last_60s": true} }
```

`type` ∈ `talking-head | concept | demo-recording | side-by-side | cta`. Required section ids per
format — `vsl`: `hook, problem, agitation, solution, proof, offer, cta`; `demo`: `hook, overview,
walkthrough_*, recap, cta`; `tutorial`: `intro, step_*, recap, cta`.

## How

```bash
mkdir -p work saves
eval "$(python3 - <<'PY'
import glob, json, os, shlex
def text_input(i):
    j = f"inputs/{i}/{i}.json"
    if os.path.exists(j): return (json.load(open(j)).get("text") or "").strip()
    for f in sorted(glob.glob(f"inputs/{i}/*")):
        if f.endswith((".txt", ".md")): return open(f).read().strip()
    return ""
fmt = ""
if os.path.exists("inputs/format/format.json"): fmt = json.load(open("inputs/format/format.json")).get("choice") or ""
script = text_input("script") or (open("prior/approved_script.md").read().strip() if os.path.exists("prior/approved_script.md") else "")
print("SCRIPT=" + shlex.quote(script)); print("FMT=" + shlex.quote(fmt))
PY
)"
[ -n "$SCRIPT" ] || { echo '{ "inputId": "script", "reason": "Please provide the full script for the video.", "count": 1 }' > needs_input.json; exit 0; }
case "$FMT" in vsl|demo|tutorial) ;; *) echo '{ "inputId": "format", "reason": "Please choose the video format: VSL, demo or tutorial.", "count": 1 }' > needs_input.json; exit 0 ;; esac
WORDS=$(printf '%s' "$SCRIPT" | wc -w | tr -d ' ')
[ "$WORDS" -ge 700 ] && [ "$WORDS" -le 3200 ] || { echo "{ \"inputId\": \"script\", \"reason\": \"The script is $WORDS words — a 5–20 minute video needs roughly 750–3000 words.\", \"count\": 1 }" > needs_input.json; exit 0; }
printf '%s\n' "$SCRIPT" > work/script-raw.md
```

### 1. Make it TTS-clean (`c-script`)

A `.md`-style draft (headings, `[stage directions]`, bullet lists, bold) is cleaned: drop
headings and directions, flatten lists into sentences, keep the author's words. Spell tricky
tokens for speech (`2x` → "twice", `/pricing` → "slash pricing", "e.g." → "for example"). Do
not add or remove claims. Write `work/tts.txt`.

### 2. Section map

Split `work/tts.txt` into the format's required sections by meaning (word offsets, not seconds —
timecodes arrive from `transcribe`). For `demo`, each distinct feature walkthrough is its own
`walkthrough_<n>` section of type `demo-recording`; for `tutorial`, each `step_<n>` is `concept`
or `demo-recording` depending on whether it explains or shows. The last section is always `cta`.
A `vsl` whose script has no offer / CTA beat is missing structure: ask for `script` with a reason
saying which beats are missing.

### 3. Time it and write the saves

```bash
python3 - <<'PY'
import json
body = open("work/tts.txt").read().strip(); n = len(body.split())
speed = (json.load(open("brief.json")).get("options") or {}).get("speed") or 1.0
secs = round(n / (150 * float(speed)) * 60)
assert 300 <= secs <= 1200, f"script times to {secs}s; need 300–1200 s"
sm = json.load(open("work/section_map.json"))
assert sm["sections"][-1]["id"] == "cta", "last section must be cta"
open("saves/tts_script.md", "w").write(f"---\nformat: {sm['format']}\nwords: {n}\nestimated_seconds: {secs}\n---\n{body}\n")
json.dump(sm, open("saves/section_map.json", "w"), indent=2)
print(f"OK {n} words ≈ {secs}s, {len(sm['sections'])} sections")
PY
```

Out of range at 150 wpm → it is a script problem: ask for `script` with the measured minutes.

## Checks the harness runs

- `script_timed_5_20min` — `estimated_seconds` in the front matter is 300–1200 and matches
  `words / (150 × speed) × 60` within 5 %.
- `sections_follow_format` — `section_map.sections` contains the format's required ids in order,
  with `cta` last and `start_word` monotonic.
