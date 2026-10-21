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

### 0. Known script (WI2.72)

Captions come from these words, so a mis-heard word would be burned into the reel. When the
order carries the script the voice was made from — `inputs/script/*` (`script.json` `{"text"}`
or a `.txt`/`.md`), else `prior/approved_script.md`, else `prior/script.md` — the helper below
passes it to `mlx_whisper` as `--initial-prompt` and, in step 2b, corrects the recognised
words against it. An uploaded talking-head clip has no script file, so step 2b checks the words
against the order brief's `intent` instead (WI2.88): when the owner pasted the script there, a
mis-heard word is fixed the same way; a brief that is only a topic matches under 60 % and
changes nothing. With neither, the words are left exactly as recognised and the helper says so.

```bash
mkdir -p work saves
cat > work/script_align.py <<'PY'
# WI2.72: check recognised words against the known script and fix mis-heard ones.
# usage: python3 work/script_align.py words.json   (fix words.json in place)
#        python3 work/script_align.py --prompt     (print the script text, or nothing)
# The script is the first of: inputs/script/* (script.json {"text"} or .txt/.md),
# prior/approved_script.md, prior/script.md. WI2.88: with no script file (an uploaded clip) the
# order brief's intent (brief.json) is checked as the script; a brief that is only a topic matches
# under 60 % and changes nothing. Neither -> the words are left unchanged.
import difflib, glob, json, os, re, sys

def script_text():
    for p in sorted(glob.glob('inputs/script/*')) + ['prior/approved_script.md', 'prior/script.md']:
        if not os.path.isfile(p):
            continue
        raw = open(p, encoding='utf-8').read()
        if p.endswith('.json'):
            try:
                raw = str((json.loads(raw) or {}).get('text') or '')
            except (ValueError, AttributeError):
                raw = ''
        raw = raw.strip()
        if raw:
            return raw
    return ''

def brief_script():
    # WI2.88: an uploaded clip's order has no script file; the owner may have pasted the script
    # as the brief. It is only a candidate: align() leaves the words alone unless 60 % match.
    try:
        brief = json.load(open('brief.json', encoding='utf-8'))
    except (OSError, ValueError):
        return ''
    intent = brief.get('intent') if isinstance(brief, dict) else None
    return intent.strip() if isinstance(intent, str) else ''

def norm(t):
    return re.sub(r"[^0-9a-z]", "", t.lower())

def dress(rec, scr):
    # the script's word, wearing the recognised token's leading/trailing punctuation
    core = re.sub(r"^\W+|\W+$", "", scr) or scr
    lead = re.match(r"^\W*", rec).group(0)
    tail = re.search(r"\W*$", rec).group(0)
    return lead + core + tail

def align(words, script, max_block=4, min_ratio=0.6):
    toks = []  # (entry index, token)
    for i, w in enumerate(words):
        for t in str(w['text']).split():
            if norm(t):
                toks.append([i, t])
    scr = [t for t in script.split() if norm(t)]
    a, b = [norm(t) for _, t in toks], [norm(t) for t in scr]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    ratio = sum(m.size for m in sm.get_matching_blocks()) / max(len(a), 1)
    report = {"script_words": len(scr), "recognised_words": len(a), "match": round(ratio, 3),
              "fixed": [], "dropped": [], "left": []}
    spans = []  # (first, last) entry of each fewer-words fix
    if not scr or ratio < min_ratio:
        report["note"] = "the script does not match this voice; words left as recognised"
        return words, report
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal' or op == 'insert':
            continue
        n, m = i2 - i1, j2 - j1
        if max(n, m) > max_block:
            report["left"].append(" ".join(t for _, t in toks[i1:i2]))
            continue
        if op == 'delete':
            for k in range(i1, i2):
                report["dropped"].append(toks[k][1]); toks[k][1] = None
            continue
        if n > m:  # WI2.77: fewer script words than heard ('New York' -> 'NYC'): one caption
            joined = " ".join(scr[j1:j2])  # from the start of the first heard word to the end of the last
            core = re.sub(r"^\W+|\W+$", "", joined) or joined
            new = re.match(r"^\W*", toks[i1][1]).group(0) + core + re.search(r"\W*$", toks[i2 - 1][1]).group(0)
            report["fixed"].append([" ".join(t for _, t in toks[i1:i2]), new])
            toks[i1][1] = new
            for k in range(i1 + 1, i2):
                toks[k][1] = None
            spans.append((toks[i1][0], toks[i2 - 1][0]))
            continue
        for k in range(n):  # replace: spread the script words over the recognised slots
            s0, s1 = round(k * m / n), round((k + 1) * m / n)
            new = " ".join(dress(toks[i1 + k][1], t) for t in scr[j1 + s0:j1 + s1]) or None
            report["fixed"].append([toks[i1 + k][1], new])
            toks[i1 + k][1] = new
    texts = {}
    for i, t in toks:
        texts.setdefault(i, [])
        if t:
            texts[i].append(t)
    head = list(range(len(words)))  # WI2.77: entries a fewer-words fix spans fold into their first
    for first, last in spans:
        for i in range(first + 1, last + 1):
            head[i] = head[first]
    out, kept = [], {}
    for i, w in enumerate(words):
        if head[i] != i and head[i] in kept:
            o = kept[head[i]]
            more = " ".join(texts[i]) if i in texts else str(w.get('text', '')).strip()
            if more:
                o['text'] = (str(o.get('text', '')).strip() + " " + more).strip()
            if 'end' in w:
                o['end'] = w['end']
            continue
        if i in texts and not texts[i]:
            continue  # every token of this entry was not in the script
        new = dict(w)
        if i in texts:
            new['text'] = " ".join(texts[i])
        out.append(new)
        kept[i] = new
    return out, report

if __name__ == '__main__':
    if sys.argv[1:] == ['--prompt']:
        print(script_text()); sys.exit(0)
    path = sys.argv[1]
    text, source = script_text(), "script"
    if not text:  # WI2.88: no script file -> the brief, when it is the spoken script
        text, source = brief_script(), "brief"
    if not text:
        print("[transcribe] no script text: words left as recognised (an uploaded clip has no script)")
        sys.exit(0)
    words = json.load(open(path))
    out, rep = align(words, text)
    rep["source"] = source
    if source == "brief" and rep.get("note"):
        rep["note"] = "the brief is not the spoken script; words left as recognised"
    assert out, "script check removed every word"
    json.dump(out, open(path, 'w'))
    json.dump(rep, open(os.path.join(os.path.dirname(path) or '.', 'script_align.json'), 'w'), indent=1)
    print("[transcribe] script check (%s): match %.2f, fixed %d, dropped %d, left %d%s" % (
        source, rep["match"], len(rep["fixed"]), len(rep["dropped"]), len(rep["left"]),
        (" - " + rep["note"]) if rep.get("note") else ""))
PY
```

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
  SCRIPT_PROMPT=$(python3 work/script_align.py --prompt)
  # WI2.77: an explicit branch, so the prompt is two arguments in bash, sh and zsh
  if [ -n "$SCRIPT_PROMPT" ]; then
    mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx --output-dir work --output-format json --initial-prompt "$SCRIPT_PROMPT"
  else
    mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx --output-dir work --output-format json
  fi
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

### 2b. Check the words against the script (WI2.72)

Align the cleaned words to the script (difflib on lower-cased letters and digits). A short
mismatch (4 words or fewer) is fixed: a mis-heard word takes the script word, a recognised word
that is not in the script is dropped. No time is left without a caption: when the script says it
in fewer words than were heard (heard "New York", script "NYC"), those script words become one
caption from the start of the first heard word to the end of the last (WI2.77); otherwise
timings are not edited. When under 60 % of the words
match, the script is not what was spoken and the words are left as recognised. What changed is
in `work/script_align.json`.

```bash
python3 work/script_align.py work/words.json || exit 1
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
  `{text,start,end}` with monotonically non-decreasing starts and the last `end` within ~4.5 s of the
  bed duration (the bed ends in a silent end-card tail of up to 3.5 s, WI2.89).
