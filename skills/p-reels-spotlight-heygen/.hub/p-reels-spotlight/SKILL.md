---
name: p-reels-spotlight
description: Full-frame premium reel — speaker fills the frame on ONE continuous never-cut voice bed, kinetic word-synced captions + SFX + cinematic grade ride over the whole reel, motion-graphics takeovers (and optional transcript-synced b-roll) cover the picture at planned beats, first-frame cover poster is baked in. Replaces p-reels-fmt3 and adds optional b-roll takeovers. Trigger on "premium talking-head edit", "viral caption edit of my video", "kinetic captions + b-roll over my talking head", "full-frame reel with b-roll cutaways", "make a premium reel from this clip", "agency-style edit with graphics and b-roll", "spotlight reel".
when-to-use: Use when the user uploads a talking-head clip (or wants a HeyGen avatar) and wants the speaker full-frame the whole time with premium kinetic captions, optional b-roll takeover beats, and a baked-in feed-poster cover. NOT for PIP layouts (speaker in a bottom inset — use p-reels-pip). NOT faceless (no talking head — use p-reels-faceless). The `broll[]` parameter is optional — omit it and this skill behaves identically to p-reels-fmt3.
version: 1.0.0
kind: pipeline
visibility: catalog
providers: heygen
produces:
  dish: Premium Spotlight Reel
  format: 9:16 vertical video
  duration: 20-60s
inputs: [talking_head_video, broll, script]
dependsOn: [c-reel-premium, c-broll-sync, c-typing-ui, f-hyperframes, f-hyperframes-cli, c-ffmpeg, c-cloud-media, c-overlay-fx, c-shorts-qa-gate, c-eval-runner]
metadata:
  hermes:
    vendored: [c-overlay-fx, c-reel-premium, c-broll-sync, c-typing-ui, f-hyperframes, f-hyperframes-cli, c-ffmpeg, c-cloud-media, c-shorts-qa-gate]
---



> ## ⚡ Frame integrity + integrated CTA (MANDATORY — 2026-06-16)
> - **Frame 0 is NEVER black.** The first frame must be a bright money-shot — the cover-freeze of the strongest illustrative beat (Step 10 cover rule). Verify `ffmpeg ... signalstats` → `YAVG > 30`. No black / hook-blank / fade-in opener.
> - **The LAST frame is NEVER black.** The reel must end on content, not a fade-to-black or trailing blank. Verify the final frame `YAVG > 30`.
> - **CTA is integrated by DEFAULT, not optional.** Every reel/VSL ends on a branded **CTA beat baked into the timeline** (offer line + handle/URL), as the final illustrative HyperFrames card. Do not ship a reel whose last beat is filler or black. (In p-reels-split this is the Step 9 CTA takeover; other recipes must add an equivalent closing CTA card.)

> ## ⚡ HyperFrames = illustrative, NOT just titles (MANDATORY — 2026-06-16)
> Every HyperFrames graphics scene MUST pair its title with an **illustrative animation that depicts the point** — never a bare kinetic title card. Examples: a 45-post feed grid staggering in (`back.out`), a count-up stat with day-dots, an animated waveform for "voice", platform chips popping in. Match the premium reference in `cfw-marketing/creatives/productions/restaurants-vsl/hyperframes` (`DIAG-calendar` feed-grid, `HF-*` motion) **and** `cfw-marketing/creatives/productions/fnb-split-screen-short/gen-rich-cards.py`: grid + glow + vignette background, GSAP eased + staggered elements, brand palette, depth (shadows/shine). **Make it as rich and premium as possible — a title-only card is a defect.**

# p-reels-spotlight — Full-Frame Premium Reel (continuous-audio bed + kinetic captions + optional b-roll)

A vertical 9:16 reel built on **one continuous voice bed**: the speaker's narration audio plays
unbroken for the entire reel and is **never cut or silenced**. Visually it is a premium edit —
the speaker plays full-frame, **word-synced kinetic captions** ride over the whole reel, full-frame
**motion-graphics takeovers** (and optionally **transcript-matched b-roll** clips) cover the picture
at planned beats, **SFX** (whoosh/impact/riser) land on the cuts, a **cinematic grade** finishes the
image, and a **0.4s first-frame cover poster** is prepended for feed-thumbnail integrity.

```
audio:   ████████████████████████████████████████████████  ← speaker VO, ONE unbroken bed (+SFX under)
video:   [speaker][== GFX / B-ROLL ==][speaker][== GFX / B-ROLL ==][speaker+CTA takeover]
captions: ▁▂▃ kinetic word-synced captions over EVERYTHING ▃▂▁
cover:   [0.4s ■ money-shot freeze][← full reel with cover already in position 0]
```

**vs p-reels-fmt3:** identical pipeline + the same continuous-bed law + one added capability:
`broll[]` input fed through `c-broll-sync` → matched beats become full-frame takeovers alongside
graphics beats. No b-roll supplied → zero code path change; the skill is a strict superset.

## The one rule that defines this skill

**The speaker's narration audio is the single, never-interrupted voice bed.** Graphics AND b-roll
take over the *picture*, never the *sound*. The bed audio is loudnormed ONCE (Step 2) and reaches the
final mux untouched — SFX are mixed UNDER it with `amix=normalize=0` so the VO level never moves. If
at any timestamp the VO is silent during a takeover, the reel is broken (continuity proof in Step 9).

## Inputs

| Parameter | Required | Default | Description |
|---|---|---|---|
| `talking_head_video` | Yes* | — | Uploaded talking-head MP4 (real face + real voice) OR a reused HeyGen render. **Its audio is the continuous voice bed.** Reused 16:9 studio renders often carry white side bands — Step 1.5 crops them (left/right only, never the top). *If absent, produce via `c-script` → `c-heygen`.* |
| `broll[]` | No | `[]` | Array of b-roll clips to intercut at transcript-matched beats. Each element: `{clip: "path.mp4", duration: N, cues: [{start,end,text}]}`. When empty, the skill is identical to p-reels-fmt3. |
| `broll_coverage_pct` | No | `30` | Target % of reel runtime covered by b-roll beats (passed to `c-broll-sync`). |
| `broll_clip_seconds` | No | `4` | Default on-screen duration per b-roll window. |
| `broll_min_seconds` | No | `2` | Minimum b-roll window duration. |
| `broll_max_seconds` | No | `6` | Maximum b-roll window duration. |
| `broll_order` | No | `transcript-match` | `transcript-match` · `as-given` · `even`. |
| `broll_reuse` | No | `false` | Allow clips to be reused to hit coverage target. |
| `brand` | Yes | — | Palette + typography via the Visual Identity Gate (Brand Brief → DESIGN.md → named style → dark-premium default). The planner emits `{bg, accent, fg}` 6-digit hexes. Never hard-code. |
| `captions` | No | **on** | Kinetic word-synced caption overlay. `off` only if the brief says no captions. |
| `sfx` | No | **on** | Sound design from shipped pack (`assets/sfx/` — CC0). |
| `grade` | No | planner picks | `warm-amber` or `clean-bright`. |
| `cover_at` | No | planner picks | Timestamp (seconds) past the hook to use as the money-shot for the 0.4s cover freeze. The Step 4 edit plan should emit this; if absent, Step 10 picks mid-content automatically. |
| `cta_card` | No | brand default | Auto-generated end-card takeover (`CTA_DURATION`, 3 s) right after the last spoken word, never over speech. Step 2 holds the last frame with silence so the full card fits (WI2.89); nothing is appended after the bed. Pass `off` to skip (no tail). |
| `cta_text` | No | `FOLLOW FOR MORE` | Hero line on the end card. Resolve from the active brand (`brand-overrides/<slug>/brand.json` `cta.line`, or the order's `copy.cta`). The fallback is generic and carries no brand. |
| `cta_handle` | No | — (no handle line) | Handle/URL on the end card. Resolve from the active brand (`brand-overrides/<slug>/brand.json` `cta.handle`, or the brand's primary social account in the order's brand context). **If the brand has no handle, leave it empty: the card renders without a handle line.** Never invent one and never reuse another brand's. |
| `brand_name` | No | — (no kicker) | Brand name for the kicker line above the hero. Resolve from the brand context; empty → kicker omitted. |
| `avatar_layout` | No | `fill` | `fill` (band-clean → scale-to-cover) or `letterbox`. |
| `target_duration` | No | = bed length | The VO is the master; the edit covers exactly it. |
| `topic` / `script` | Conditional | — | Only when producing a fresh avatar via `c-heygen`. |

## Output

One 9:16 (1080×1920) H.264+AAC MP4 with a 0.4s cover-freeze prepended (`short-with-cover.mp4`);
separate `cover.png` as explicit thumbnail. Speaker full-frame on a continuous voice bed, kinetic
captions over the whole reel, graphics and/or b-roll takeovers at planned beats, SFX, cinematic grade,
CTA end-card. Both artifacts uploaded to R2 — **the MP4 R2 public URL is the deliverable** (Step 11).

## Steps

> **End-card copy is per-brand — never hard-code (CFW-354 / M1-00).** Before running, resolve
> `CTA_TEXT`, `CTA_HANDLE` and `BRAND_NAME` from the ACTIVE brand (its `brand-overrides/<slug>/brand.json`
> `cta.line` / `cta.handle` / `brand` when present, else the brand context the order carries) and export
> them. If the brand has no handle, leave `CTA_HANDLE` empty: Step 8 then renders the end card **without a
> handle line**. Never reuse another brand's copy or handle, and never invent a handle.
>
> **`cta_card` comes from the order too (WI2.90).** Set `CTA_CARD` to the order's `cta_card` (`on` unless
> the order says `off`) and export it with the copy above. `off` means Step 2 adds no silent tail and
> Step 8 renders no end card; anything other than `on` counts as `off`, as in the steps path.

Set up variables:

```bash
AVATAR="<path to talking-head mp4>"
BROLL_CLIPS="${BROLL_CLIPS:-[]}"   # JSON array of broll descriptors; empty = fmt3 behavior
BROLL_COVERAGE="${BROLL_COVERAGE_PCT:-30}"
BROLL_CLIP_SECS="${BROLL_CLIP_SECONDS:-4}"
BROLL_MIN_SECS="${BROLL_MIN_SECONDS:-2}"
BROLL_MAX_SECS="${BROLL_MAX_SECONDS:-6}"
BROLL_ORDER="${BROLL_ORDER:-transcript-match}"
BROLL_REUSE="${BROLL_REUSE:-false}"
CTA_TEXT="${CTA_TEXT:-FOLLOW FOR MORE}"
CTA_HANDLE="${CTA_HANDLE:-}"    # empty = no handle line on the end card (per-brand; never a placeholder)
BRAND_NAME="${BRAND_NAME:-}"    # empty = no kicker line on the end card
CTA_CARD="${CTA_CARD:-on}"      # the order's cta_card (WI2.90): off = no Step 2 tail and no Step 8 end card
CTA_DURATION="${CTA_DURATION:-3}"
W="{production}/interim/spotlight" ; mkdir -p "$W"
OUT_BASE="{production}/final/spotlight-reel"
OUT_RAW="$OUT_BASE.mp4"
OUT="${OUT_BASE}-with-cover.mp4"
COVER_PNG="{production}/final/spotlight-cover.png"
mkdir -p "$(dirname "$OUT")"
SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-reels-spotlight-heygen/.hub/p-reels-spotlight"
BROLL_SYNC_DIR="$SKILL_DIR/../c-broll-sync"
PREMIUM_DIR="$SKILL_DIR/../c-reel-premium"
TYPING_DIR="$SKILL_DIR/../c-typing-ui"
```

### Step 1 — Source the speaker video (the voice bed)

Use the uploaded talking head (download to local disk first — never composite from remote URLs),
or reuse an existing avatar render, or produce one via `c-script` → `c-heygen` (9:16, one pass so
the narration is unbroken). Probe it — the duration is the master reel length:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 "$AVATAR"
ffmpeg -hide_banner -i "$AVATAR" -af "silencedetect=noise=-35dB:d=0.5" -f null - 2>&1 \
  | grep -E "silence_(start|end)" || echo "narration continuous"
```

### Step 1.5 — Detect & crop white side bands (BEFORE anything else)

Reused 16:9 HeyGen / studio renders frequently carry baked-in **white/cream bands** down the left
and right. Measure thin edge columns vs the centre and, if bands exist, **crop LEFT/RIGHT only —
NEVER the top** (the head must not be cut):

```bash
W_SRC=$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "$AVATAR")
H_SRC=$(ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$AVATAR")
col_luma () {
  v=$(ffmpeg -hide_banner -loglevel error -ss 13 -i "$AVATAR" -vframes 1 \
        -vf "crop=2:$H_SRC:$1:0,scale=1:1,format=gray" -f rawvideo - 2>/dev/null | xxd -p)
  echo $((16#$v))
}
LEFT=0;  for x in $(seq 0 5 $((W_SRC/2)));    do [ "$(col_luma $x)" -lt 245 ] && { LEFT=$x;  break; }; done
RIGHT=$W_SRC; for x in $(seq $((W_SRC-2)) -5 $((W_SRC/2))); do [ "$(col_luma $x)" -lt 245 ] && { RIGHT=$((x+2)); break; }; done
CW=$(( RIGHT - LEFT )); CW=$(( CW - CW % 2 ))
if [ "$LEFT" -gt 4 ] || [ "$RIGHT" -lt $((W_SRC-4)) ]; then
  ffmpeg -y -i "$AVATAR" -vf "crop=$CW:$H_SRC:$LEFT:0,setsar=1" \
    -c:v libx264 -pix_fmt yuv420p -c:a copy "$W/avatar-clean.mp4"
  AVATAR_CLEAN="$W/avatar-clean.mp4"
else
  AVATAR_CLEAN="$AVATAR"
fi
```

`crop=W:H:X:0` — y-offset `0` guarantees the top edge (and head) is preserved.

### Step 2 — Build the speaker bed (full length, scale-to-cover, loudnormed ONCE)

```bash
ffmpeg -y -i "$AVATAR_CLEAN" \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 "$W/base.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/base.mp4")
```

`letterbox` layout: `scale=1080:-2,pad=1080:1920:0:(1920-ih)/2:color=0x0F172A`.
**Do not slice the bed** — one unbroken audio track. Loudnorm happens here and NEVER again.

**Audio trim (mandatory):** strip silent buffers + filler words before the bed is sealed.
Use `silencedetect` to identify leading dead air and trim ONLY if the silence START is within
the first 1.0s (prevents trimming internal speech pauses mid-content — bake-off bug fix):

```bash
# BUG FIX: original code extracted silence_end (when speech begins) without checking
# WHERE the silence started. An internal pause (e.g. "Tools." + pause + next sentence)
# produces a silence_end that looks like leading silence but is actually mid-content.
# Fix: extract BOTH silence_start and silence_end from the FIRST detected silence event;
# only trim if silence_start < 1.0s (i.e., the silence genuinely begins at the very start).
SILENCE_EVENTS=$(ffmpeg -hide_banner -i "$W/base.mp4" \
  -af "silencedetect=noise=-40dB:d=0.4" -f null - 2>&1 | grep "silence_")

SILENCE_START_0=$(echo "$SILENCE_EVENTS" | grep silence_start | head -1 \
  | grep -oP 'silence_start: \K[\d.]+' || echo "999")
SILENCE_END_0=$(echo "$SILENCE_EVENTS" | grep silence_end | head -1 \
  | grep -oP 'silence_end: \K[\d.]+' || echo "0")

TRIM_START=$(python3 -c "
s_start = float('$SILENCE_START_0')
s_end   = float('$SILENCE_END_0')
# Only trim if the silence genuinely STARTS within the first 1.0s (leading silence).
# Never trim if silence_start >= 1.0s — that is a mid-content pause.
if s_start < 1.0 and s_end > 0.3:
    print(max(0, s_end - 0.05))
else:
    print(0)
")

if python3 -c "exit(0 if float('$TRIM_START') > 0.3 else 1)"; then
  ffmpeg -y -ss "$TRIM_START" -i "$W/base.mp4" -c copy "$W/base-trimmed.mp4" \
    && mv "$W/base-trimmed.mp4" "$W/base.mp4"
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/base.mp4")
  echo "[spotlight] trimmed ${TRIM_START}s of leading silence"
fi
```

**End-card tail (WI2.89, mandatory):** The end card never covers speech (WI2.86), so the bed needs room after the last spoken word.
When the speech runs to the end of the clip (or nearly), hold the last frame with silence until
`cta_duration` + 0.5 s follows the speech end (a tail of at most 3.5 s). The speech end is
where the final silence starts (`silencedetect` −40 dB, 0.3 s); with no trailing silence it is
the clip end. `cta_card: off` adds no tail, and a clip that already ends in enough silence is
left as it is. The tail is part of the sealed bed: captions, takeovers, checks and the reel all
time against it, and the end card then shows in full right after the last word.

```bash
python3 - "$W/base.mp4" "${CTA_CARD:-on}" "${CTA_DURATION:-3}" <<'PY' || exit 1
# WI2.89: hold the last frame with silence so the end card fits after the last spoken word.
import math, os, re, subprocess, sys
src, card, want = sys.argv[1], sys.argv[2], float(sys.argv[3])
MARGIN, MAX_TAIL = 0.5, 3.5   # speech end + cta_duration + MARGIN, tail at most MAX_TAIL
def dur(p):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)
if card != "on":
    print("[spotlight] end-card tail: cta_card off, no tail"); sys.exit(0)
d = dur(src)
log = subprocess.run(["ffmpeg", "-hide_banner", "-i", src, "-af", "silencedetect=noise=-40dB:d=0.3", "-f", "null", "-"],
                     capture_output=True, text=True).stderr
starts = [float(x) for x in re.findall(r"silence_start: (-?[0-9.]+)", log)]
ends = [float(x) for x in re.findall(r"silence_end: (-?[0-9.]+)", log)]
speech_end = d                       # no silence runs to the end: the speech fills the clip
if starts and (len(ends) < len(starts) or ends[-1] >= d - 0.05):
    speech_end = max(0.0, starts[-1])
tail = math.ceil(max(0.0, min(want + MARGIN, MAX_TAIL) - (d - speech_end)) * 30) / 30
if tail <= 0:
    print("[spotlight] end-card tail: %.2fs of silence already follows the speech, no tail" % (d - speech_end)); sys.exit(0)
tmp = src[:-4] + "-tail.mp4"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf", "tpad=stop_mode=clone:stop_duration=%.3f" % tail,
                "-af", "apad=pad_dur=%.3f" % tail, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
                "-c:a", "aac", "-ar", "48000", "-ac", "2", tmp], check=True)
got = dur(tmp)
if abs(got - (d + tail)) > 0.1:
    sys.exit("end-card tail: bed is %.3fs, expected %.3fs" % (got, d + tail))
os.replace(tmp, src)
print("[spotlight] end-card tail: speech ends %.2fs, held the last frame + silence for %.2fs (bed %.2fs)" % (speech_end, tail, got))
PY
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/base.mp4")
```

### Step 3 — Transcribe with WORD timestamps

> **Run the block below VERBATIM. Do NOT invent your own `cfw-transcribe` invocation.**
> `cfw-transcribe --format` accepts ONLY `text | segments | srt | vtt` — **there is no `words`
> format** (`--format words` is a hard error). Word-level timing is derived by converting the SRT
> in the `python3` step below; that is the only supported path. Word-timestamp guidance lives in
> the vendored sub-skill — read it with `skill_view` on skill **`f-hyperframes`**, file
> **`references/transcript-guide.md`** (NOT under `p-reels-spotlight`, which has no `references/` dir).

```bash
# LOCAL transcription is the default (M1-09 / D13): mlx_whisper → whisper → npx hyperframes@0.7.5
# transcribe (whisper.cpp). The hosted Gemini backend (`cfw-transcribe`) runs ONLY when the order
# carries the brand's `gemini` provider key — the runner exports it as GEMINI_API_KEY from the
# order's brand provider keys. NEVER read a key from a file on this machine; when the variable is
# unset the Gemini branch is skipped and local Whisper runs.
# known_transcript path: if provided externally (e.g. by p-reels-spotlight-heygen wrapper), write
# it to $W/words.json and skip this block.
if [ -n "${GEMINI_API_KEY:-}" ] && command -v cfw-transcribe >/dev/null 2>&1; then
  cfw-transcribe --input "$W/base.mp4" --out "$W/transcript.srt" --format srt
  # Convert SRT → words.json
  python3 - "$W/transcript.srt" "$W/words.json" <<'PY'
import re, json, sys
lines = open(sys.argv[1]).read().strip().split('\n\n')
words = []
for block in lines:
    parts = block.strip().split('\n')
    if len(parts) < 3: continue
    ts = parts[1]; text = ' '.join(parts[2:])
    def t2s(s): h,m,rest=s.replace(',','.').split(':'); return int(h)*3600+int(m)*60+float(rest)
    s, e = ts.split(' --> ')
    for w in text.split(): words.append({"text": w, "start": t2s(s.strip()), "end": t2s(e.strip())})
json.dump(words, open(sys.argv[2], 'w'))
PY
elif command -v mlx_whisper >/dev/null 2>&1; then
  echo "[spotlight] local transcription: mlx_whisper"
  mlx_whisper "$W/base.mp4" --model mlx-community/whisper-small --output-dir "$W" --output-format json
  python3 -c "import json; d=json.load(open('$W/base.json')); words=[{'text':s['text'],'start':s['start'],'end':s['end']} for s in d.get('segments',[])] ; json.dump(words,open('$W/words.json','w'))"
elif command -v whisper >/dev/null 2>&1; then
  echo "[spotlight] local transcription: whisper CLI"
  whisper "$W/base.mp4" --model small --output_dir "$W" --output_format srt
  python3 - "$W/base.srt" "$W/words.json" <<'PY'
import re, json, sys
lines = open(sys.argv[1]).read().strip().split('\n\n')
words = []
for block in lines:
    parts = block.strip().split('\n')
    if len(parts) < 3: continue
    ts = parts[1]; text = ' '.join(parts[2:])
    def t2s(s): h,m,rest=s.replace(',','.').split(':'); return int(h)*3600+int(m)*60+float(rest)
    s, e = ts.split(' --> ')
    for w in text.split(): words.append({"text": w, "start": t2s(s.strip()), "end": t2s(e.strip())})
json.dump(words, open(sys.argv[2], 'w'))
PY
else
  echo "[spotlight] local transcription: npx hyperframes@0.7.5 transcribe (whisper.cpp)"
  cd "$W" && npx hyperframes@0.7.5 transcribe base.mp4 --model small
fi
# NO .en suffix unless audio is confirmed English — .en models TRANSLATE non-English.
# Hinglish/multilingual → --model medium. Output: word-level transcript JSON.
```

Run the transcript quality check (read it via `skill_view` on skill `f-hyperframes`, file `references/transcript-guide.md`): if >20% of
entries are `♪`/garbage, retry with `--model medium`; strip non-word entries. Save the cleaned
word array to `$W/words.json` (`[{text,start,end}]`).

After saving words.json, normalize the word key so both `{word,start,end}` and `{text,start,end}`
formats are accepted (wrappers may supply either form):

```bash
# Normalize word key: accept both {word,start,end} and {text,start,end} — canonicalize to {text,...}
python3 -c "
import json
words=json.load(open('$W/words.json'))
words=[{**w,'text':w.get('text') or w.get('word','')} for w in words]  # normalize word→text
json.dump(words, open('$W/words.json','w'))
"
```

### Step 3b — Transcribe b-roll clips (if broll supplied)

For each b-roll clip that has no `cues` array (or empty `cues`), run a quick transcription to
enable `transcript-match` placement:

```bash
# Build broll_cues.json — array of {clip, duration, cues[]}
# If broll_clips is already populated with cues, skip this step.
HAVE_BROLL=$(echo "$BROLL_CLIPS" | python3 -c "import json,sys; clips=json.load(sys.stdin); print(len(clips) > 0)")
if [ "$HAVE_BROLL" = "True" ]; then
  python3 - "$W" "$BROLL_CLIPS" <<'PY'
import json, subprocess, os, sys, shutil, tempfile
W, clips_raw = sys.argv[1], sys.argv[2]
clips = json.loads(clips_raw)
result = []
for cl in clips:
    dur = float(subprocess.run(
        ["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0", cl["clip"]],
        capture_output=True, text=True).stdout.strip() or "0")
    cues = cl.get("cues") or []
    if not cues and os.path.exists(cl["clip"]):
        td = tempfile.mkdtemp()
        sub16 = os.path.join(td, "sub16.mp4")
        subprocess.run(["ffmpeg","-y","-i",cl["clip"],"-af","loudnorm=I=-16:TP=-1.5:LRA=11",
                        "-c:v","libx264","-c:a","aac",sub16], check=False, capture_output=True)
        tr = subprocess.run(["npx","hyperframes","transcribe", sub16, "--model","small",
                             "--output",os.path.join(td,"words.json")],
                            capture_output=True, text=True, cwd=td)
        wf = os.path.join(td, "words.json")
        if os.path.exists(wf):
            words = json.load(open(wf))
            cues = [{"start": w["start"], "end": w["end"], "text": w["text"]} for w in words]
        shutil.rmtree(td, ignore_errors=True)
    result.append({"clip": cl["clip"], "duration": dur, "cues": cues})
json.dump(result, open(f"{W}/broll_cues.json","w"), indent=2)
print(f"[spotlight] broll_cues.json: {len(result)} clips")
PY
  BROLL_CUES_PATH="$W/broll_cues.json"
else
  echo "[]" > "$W/broll_cues.json"
  BROLL_CUES_PATH="$W/broll_cues.json"
fi
```

### Step 4 — PLAN the edit (YOU write the plan — the engine running this recipe is the planner)

**You — the signed-in engine executing this recipe (Codex or Claude Code) — are the planner.** Read
`$W/words.json` and the brand, think, and write ONE curated `$W/plan.json` yourself, following the
brief below as your spec. There is NO separate model call, NO API key and NO fallback model: planning
through an Anthropic/Gemini API key from a file on this machine is removed (M1-09 / D13, D39). The
later steps are mechanical executors — they fill templates from your plan and never invent anything.
The plan also emits a `cover_at` timestamp (a content beat past the hook, used for the first-frame
cover in Step 10).

The planning brief (what `plan.json` must contain):

```text
You are planning a PREMIUM 9:16 talking-head reel edit (speaker full-frame, never cut).
Output STRICT JSON ONLY (one object, no prose) to $W/plan.json.
Word transcript: $W/words.json ([{text,start,end}]).
Total duration: $DUR seconds.
Brand: <from brief via Visual Identity Gate; default bg #0F172A, accent #F97316, fg #F1F5F9>.
Schema:
{ "duration": $DUR, "energy": "high|medium|low", "grade": "warm-amber|clean-bright",
  "cover_at": <float seconds — a content beat past the hook, NOT at t=0, NOT in the hook scene>,
  "brand": {"bg":"#hex6","accent":"#hex6","fg":"#hex6"},
  "takeovers": [ {"start":s,"end":s,"template":"tk-stat|tk-keyword|tk-list|tk-quote|tk-typing-ui",
                  "fill":{<per-template keys below>}} ],
  "caption_groups": [ {"start":s,"end":s,"style":0|1|2,
        "words":[{"w":"TEXT","s":start,"e":end,"em":false}] } ],
  "sfx": [ {"t":s,"name":"whoosh-deep|whoosh-air|impact-sub|impact-punch|riser|click|pop|swipe","gain":0.0-0.8} ] }
Template fill keys — tk-stat: EYEBROW, STAT (short e.g. '3X' or '70%'), LABEL.
tk-keyword: WORD (one word), SUPPORT (short line). tk-list: TITLE, ITEM1, ITEM2, ITEM3.
tk-quote: QUOTE, ATTR. TITLE and QUOTE may wrap ONE key word in <span class="accent">WORD</span>.
tk-typing-ui: LABEL (e.g. 'claude.ai'), PROMPT (the typed text), TYPING_SPEED (0.5-1.5), BOTTOM_TAG,
and optionally CARD_LABEL (the line above the card; default 'The prompt').
RULES:
1. caption_groups cover the FULL duration, 2-4 words each, non-overlapping, break on sentence
   boundaries or pauses >=150ms. Words VERBATIM from the transcript.
2. LATIN SCRIPT ONLY: if any transcript word is in Devanagari (or any non-Latin script),
   transliterate it to Latin characters phonetically. NEVER translate.
3. At most ONE word per group gets "em":true. Some groups have none.
4. "style" cycles 0/1/2 — never the same style on adjacent groups.
5. takeovers: 2-4 windows, 3-6s each, first no earlier than t=2, none in the final 2s, >=4s of
   speaker between windows, never the same template twice in a row. Content must restate what is
   SAID in that window. Use tk-typing-ui only when the content involves AI/prompts/terminal workflows.
   Takeover text names only the order's brand ($BRAND_NAME, WI2.95): quote the speech word for word,
   or write the order's brand in place of any other brand or product the clip names; never invent one.
6. sfx: whoosh-deep at every takeover start, impact-sub 0.4s later, optional riser 1.5s before the
   biggest takeover, click/pop on at most 3 emphasis words. Max 12 cues, gain <=0.6.
7. cover_at: pick a frame from mid-content (ideally mid-sentence at peak energy) — NEVER t=0 or the
   first 3s (hook animates in from black). Typically 20-60% of total duration.
8. A visible change (takeover, emphasis pop, or caption style shift) every 2-4 seconds.
```

Write the object to `$W/plan.json` with your file-writing tool (no prose around it), then run the
mechanical guard — fix the plan and re-run until it prints `plan OK`:

```bash
# WI2.95: takeover text names only the order's brand unless it quotes the speech word for word.
cat > "$W/takeover_brand.py" <<'PY'
# WI2.95: takeover text names only the order's brand, unless it quotes the speech word for word.
# usage: python3 work/takeover_brand.py PLAN.json WORDS.json [BRAND]          (repair takeovers in place)
#        python3 work/takeover_brand.py --check PLAN.json WORDS.json [BRAND]  (exit 1 on a foreign name)
# BRAND is the order's brand name ("" = the order has none). Without it the brand comes from the
# step workdir: inputs/cta/cta.json brandName, else brief.json brand.name (as the end card does).
# A takeover line that is an exact run of transcript words (case and punctuation aside) is a quote
# and is kept. Any other line may not carry a brand-like name the order does not own: an acronym or
# CamelCase word the speech says (CFW, HubSpot) or a CamelCase word in the line. With an order brand
# the name becomes that brand; with none it is dropped. A brand is never invented. Generic acronyms
# (AI, CEO, ...) and the channels a reel talks about (Instagram, TikTok, ...) are not brands here.
import html, json, os, re, sys

TOKEN = re.compile(r"[A-Za-z0-9]+(?:['’.&-][A-Za-z0-9]+)*")
TAG = re.compile(r"(<[^>]*>)")
POSS = re.compile(r"['’]s$", re.I)
SKIP = {"tk-typing-ui": {"LABEL", "TYPING_SPEED"}}
HTML_KEYS = {"TITLE", "QUOTE"}
# Generic acronyms and the channels / tools a reel talks about: never a competing brand.
GENERIC = set("""i ai api apis ceo cto cfo coo cmo diy faq seo roi kpi kpis crm saas b2b b2c dm dms pr hr it ui ux
url pdf ok tv usa uk eu us am pm mvp llm llms gpt cta ctas asap fyi q1 q2 q3 q4 ugc ar vr id ip sms
instagram ig tiktok youtube yt linkedin facebook fb threads pinterest reddit x twitter whatsapp snapchat google
chatgpt claude gemini openai anthropic""".split())


def norm(t):
    return re.sub(r"[^a-z0-9']", "", t.lower().replace("’", "'"))


def base(t):
    return norm(POSS.sub("", t))


def shaped(t):
    # an acronym (2+ capitals, no lower case) or CamelCase word, by its own spelling
    b = POSS.sub("", t)
    letters = re.sub(r"[^A-Za-z]", "", b)
    if len(letters) >= 2 and letters.isupper():
        return True
    return bool(re.search(r"[a-z][A-Z]", b))


def plain(v):
    return html.unescape(TAG.sub(" ", v))


def stop(msg):
    print("takeover brand check: " + msg, file=sys.stderr)
    sys.exit(1)


def order_brand():
    cta = {}
    if os.path.isfile("inputs/cta/cta.json"):
        cta = json.load(open("inputs/cta/cta.json"))
    if not os.path.isfile("brief.json") and not cta:
        stop("no order brand: pass BRAND, or run in the step workdir with brief.json (WI2.95)")
    brief = json.load(open("brief.json")) if os.path.isfile("brief.json") else {}
    b = (brief.get("brand") or {}) if isinstance(brief, dict) else {}
    return str((cta.get("brandName") if isinstance(cta, dict) else "") or b.get("name") or "").strip()


def transcript(words):
    """the transcript's plain tokens, and the brand-like names it speaks (acronyms, CamelCase)"""
    toks, names = [], set()
    for w in words:
        t = str(w.get("text", w.get("w", w.get("word", "")))) if isinstance(w, dict) else str(w)
        for m in TOKEN.finditer(t):
            toks.append(norm(m.group(0)))
            if shaped(m.group(0)):
                names.add(base(m.group(0)))
    return toks, names


def all_caps(value):
    letters = re.sub(r"[^A-Za-z]", "", plain(value))
    return bool(letters) and letters.isupper()


def foreign(value, names, own):
    """the names in this line that the order does not own"""
    out = []
    for m in TOKEN.finditer(plain(value)):
        tok, b = m.group(0), base(m.group(0))
        if not b or b in own or b in GENERIC or not re.search(r"[a-z]", b):
            continue
        if b in names or re.search(r"[a-z][A-Z]", POSS.sub("", tok)):
            out.append(tok)
    return out


def quoted(value, said):
    toks = [norm(t) for t in TOKEN.findall(plain(value))]
    toks = [t for t in toks if t]
    return bool(toks) and (" " + " ".join(toks) + " ") in (" " + " ".join(said) + " ")


def fix_text(seg, names_hit, brand, is_html, caps):
    hit = {base(t) for t in names_hit}
    toks = list(TOKEN.finditer(seg))
    out, pos, i = [], 0, 0
    while i < len(toks):
        m = toks[i]
        if base(m.group(0)) not in hit:
            i += 1
            continue
        j = i  # a run of adjacent names ("Acme Labs") is one name
        while j + 1 < len(toks) and base(toks[j + 1].group(0)) in hit and seg[toks[j].end():toks[j + 1].start()].strip() == "":
            j += 1
        last = toks[j].group(0)
        poss = POSS.search(last)
        out.append(seg[pos:m.start()])
        if brand:
            name = brand.upper() if caps else brand
            if is_html:
                name = html.escape(name)
            out.append(name + (poss.group(0) if poss else ""))
            pos = toks[j].end()
        else:
            pos = toks[j].end()
            # drop the name and the space after it (or before it at the end)
            rest = seg[pos:]
            if rest[:1] == " ":
                pos += 1
            elif out and out[-1].endswith(" "):
                out[-1] = out[-1][:-1]
        i = j + 1
    out.append(seg[pos:])
    return "".join(out)


def fix_value(value, names_hit, brand, is_html):
    caps = all_caps(value)
    if not is_html:
        return re.sub(r"\s{2,}", " ", fix_text(value, names_hit, brand, False, caps)).strip()
    parts = TAG.split(value)
    parts = [p if TAG.fullmatch(p) else fix_text(p, names_hit, brand, True, caps) for p in parts]
    new = "".join(parts)
    new = re.sub(r"<span[^>]*>\s*</span>", "", new)
    return re.sub(r"[ \t]{2,}", " ", new).strip()


def problems(plan, said, names, own):
    bad = []
    for i, tk in enumerate(plan.get("takeovers") or []):
        fill = tk.get("fill") if isinstance(tk, dict) else None
        if not isinstance(fill, dict):
            continue
        skip = SKIP.get(tk.get("template"), set())
        for key, v in fill.items():
            if key in skip or not isinstance(v, str):
                continue
            hits = foreign(v, names, own)
            if hits and not quoted(v, said):
                bad.append((i, key, v, hits))
    return bad


def main(argv):
    check = argv[:1] == ["--check"]
    args = argv[1:] if check else argv
    if len(args) not in (2, 3):
        stop("usage: takeover_brand.py [--check] PLAN.json WORDS.json [BRAND] (WI2.95)")
    path, wpath = args[0], args[1]
    brand = args[2].strip() if len(args) == 3 else order_brand()
    for p in (path, wpath):
        if not os.path.isfile(p):
            stop("file not found: %s (WI2.95)" % p)
    try:
        plan, words = json.load(open(path)), json.load(open(wpath))
    except ValueError as exc:
        stop("not valid JSON: %s (WI2.95)" % exc)
    if isinstance(words, dict):
        words = words.get("words") or []
    if not isinstance(plan, dict) or not isinstance(words, list):
        stop("plan must be a JSON object and words a JSON list (WI2.95)")
    said, names = transcript(words)
    own = {base(t) for t in TOKEN.findall(brand)}
    bad = problems(plan, said, names, own)
    if check:
        for i, key, v, hits in bad:
            print("takeover brand check: takeover %d %s %r names %s, not the order brand %r, and is not a word-for-word "
                  "quote of the speech - quote the speech or use the order brand (WI2.95)"
                  % (i + 1, key, v, "/".join(hits), brand or "(none)"), file=sys.stderr)
        sys.exit(1 if bad else 0)
    for i, key, v, hits in bad:
        tk = plan["takeovers"][i]
        new = fix_value(v, hits, brand, key in HTML_KEYS)
        if not re.search(r"[A-Za-z0-9]", plain(new)):
            stop("takeover %d %s %r is only a foreign name; rewrite it from the speech (WI2.95)" % (i + 1, key, v))
        tk["fill"][key] = new
        print("[plan] takeover %d %s: %r -> %r (names %s; order brand %r)" % (i + 1, key, v, new, "/".join(hits), brand or "(none)"))
    if bad:
        json.dump(plan, open(path, "w"), indent=2)
    else:
        print("[plan] takeover brand: no foreign brand names, plan unchanged")
    left = problems(plan, said, names, own)
    for i, key, v, hits in left:
        print("takeover brand check: takeover %d %s %r still names %s (WI2.95)" % (i + 1, key, v, "/".join(hits)), file=sys.stderr)
    sys.exit(1 if left else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
PY
python3 "$W/takeover_brand.py" "$W/plan.json" "$W/words.json" "$BRAND_NAME" || exit 1
BRAND_NAME="$BRAND_NAME" python3 - "$W/plan.json" "$DUR" <<'PY'
import json,re,sys
p=json.load(open(sys.argv[1])); dur=float(sys.argv[2])
assert p["caption_groups"], "no caption groups"
# WI2.89: the bed ends in a silent end-card tail (at most 3.5 s), so allow 4.5 s.
assert abs(p["caption_groups"][-1]["end"]-dur) < 4.5, "captions do not cover the bed"
assert not re.search(r'[ऀ-ॿ]', json.dumps(p)), "Devanagari in plan — Latin script only"
for tk in p.get("takeovers",[]): assert 2.5 <= tk["end"]-tk["start"] <= 7, f"bad takeover window {tk}"
cover_t = float(p.get("cover_at", dur * 0.4))
assert cover_t >= 2.0, f"cover_at={cover_t} is inside the hook — must be >= 2s"
import os, subprocess
_d = os.path.dirname(sys.argv[1])
assert subprocess.run([sys.executable, os.path.join(_d, "takeover_brand.py"), "--check", sys.argv[1],
                       os.path.join(_d, "words.json"), os.environ.get("BRAND_NAME", "")]).returncode == 0, \
    "takeover text names a brand the order does not own (WI2.95) — run python3 $W/takeover_brand.py"
print(f"plan OK: {len(p['caption_groups'])} groups, {len(p.get('takeovers',[]))} takeovers, "
      f"{len(p.get('sfx',[]))} sfx, cover_at={cover_t}s")
PY
```

### Step 4b — Plan beat list with c-broll-sync (skip if no b-roll)

When `broll[]` is supplied, run `c-broll-sync` to compute the takeover beat list. The beats from
c-broll-sync are **merged** with the graphics takeovers from plan.json — b-roll beats become
additional full-frame takeovers; they do not replace the graphics takeovers planned in Step 4.

> **`scene_plan.json` is MANDATORY (CFW-131).** `plan.js` emits graphics beats with no copy and now exits 1 rather than hand a blank card downstream. Before this call, author `$W/scene_plan.json` (contract: `.hub/c-broll-sync/SCENE-PLAN.md` — one `graphic` scene per 4–6 s idea with `headline` / `eyebrow` / `ghost` / `type`, `avatar` scenes for talking-head windows, optional `broll` scenes to pin clips, `cover: true` on the cover scene) and validate it: `node "$BROLL_SYNC_DIR/scripts/validate-scene-plan.js" "$W/scene_plan.json" --bed-dur "$BED_DUR" --transcript <words.json>`. Every `graphics` beat then carries `scene.title_html` + a `slug` (`beat<N>-<id>`).

```bash
if [ "$HAVE_BROLL" = "True" ]; then
  BED_DUR="$DUR"
  # Write brand blob for c-broll-sync
  python3 -c "import json; p=json.load(open('$W/plan.json')); json.dump(p['brand'], open('$W/brand.json','w'))"

  node "$BROLL_SYNC_DIR/scripts/plan.js" \
    --transcript "$W/words.json" \
    --broll      "$W/broll_cues.json" \
    --coverage   "$BROLL_COVERAGE" \
    --clip-secs  "$BROLL_CLIP_SECS" \
    --min-secs   "$BROLL_MIN_SECS" \
    --max-secs   "$BROLL_MAX_SECS" \
    --order      "$BROLL_ORDER" \
    --reuse      "$BROLL_REUSE" \
    --bed-dur    "$BED_DUR" \
    --brand      "$W/brand.json" \
    --scene-plan "$W/scene_plan.json" \
    --out        "$W/beat_list.json"

  # Log shortfall if any
  python3 -c "
import json; bl=json.load(open('$W/beat_list.json'))
if bl.get('shortfall_note'): print('[spotlight] c-broll-sync:', bl['shortfall_note'])
broll_beats=[b for b in bl['beats'] if b['kind']=='broll']
print(f'[spotlight] beat_list: {len(bl[\"beats\"])} beats, {len(broll_beats)} broll windows, {bl[\"achieved_broll_pct\"]:.1f}% coverage')
"
fi
```

### Step 5 — Assemble the composition (FILL templates — never author) and render

Every creative value is in `plan.json` (and `beat_list.json` when b-roll is present); this step is
mechanical. B-roll beats are rendered as ffmpeg-composed takeover clips; graphics takeovers are
filled from the shipped HyperFrames templates. The render is **silent** — audio comes back in Step 7.

**Part A — Pre-render any b-roll takeover clips (if beat_list present)**

```bash
if [ "$HAVE_BROLL" = "True" ] && [ -f "$W/beat_list.json" ]; then
  python3 - "$W" <<'PY'
import json, subprocess, sys, os
W = sys.argv[1]
bl = json.load(open(f"{W}/beat_list.json"))
broll_beats = [b for b in bl["beats"] if b["kind"] == "broll"]
os.makedirs(f"{W}/broll_takeovers", exist_ok=True)
for b in broll_beats:
    idx = b["index"]
    clip = b["broll"]["clip"]
    t_in = float(b["broll"]["in"])
    t_out = float(b["broll"]["out"])
    dur_w = round(t_out - t_in, 3)
    out_path = f"{W}/broll_takeovers/broll_tk{idx}.mp4"
    # Trim + FIT + BLURRED-FILL composite, silent (audio stripped — bed is the VO).
    # Replaces scale-to-COVER (increase+crop) which cropped non-9:16 sources like
    # website screen-captures badly.  The clip is shown whole; a heavy-blurred zoomed
    # copy fills the frame edges.  For true 9:16 clips the fit copy == the frame —
    # blurred-fill is a harmless no-op.  Blur strength: boxblur=40:2 (tunable).
    subprocess.run([
        "ffmpeg", "-y", "-ss", str(t_in), "-t", str(dur_w), "-i", clip,
        "-vf", (
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,"
            "boxblur=40:2,setsar=1[bg];"
            "[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,setsar=1[fg];"
            "[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"
        ),
        "-map", "[bv]",
        "-an",  # strip audio — the VO bed carries through
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        out_path
    ], check=True)
    b["_rendered_path"] = out_path
    print(f"[spotlight] broll clip {idx}: {clip} [{t_in:.2f}..{t_out:.2f}] → {out_path}")
# Save updated beat_list with rendered paths
json.dump(bl, open(f"{W}/beat_list.json","w"), indent=2)
PY
fi
```

**Part B — Build the HyperFrames composition (graphics takeovers + captions)**

```bash
python3 - "$W" "$SKILL_DIR" "$TYPING_DIR" <<'PY'
import json, html, os, shutil, sys
W, SKILL, TYPING = sys.argv[1], sys.argv[2], sys.argv[3]

def find_gsap(skill_dir):
    # f-gsap is vendored under .hub/ in the pack, and a sibling in the source repo.
    for c in (f"{skill_dir}/.hub/f-gsap/vendor/gsap.min.js",
              f"{skill_dir}/../f-gsap/vendor/gsap.min.js"):
        if os.path.exists(c):
            return c
    raise SystemExit("[p-reels-spotlight] FATAL: vendored gsap.min.js not found "
                     "(expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/). "
                     "NEVER fall back to a CDN — the render box blocks outbound library fetches.")

plan = json.load(open(f"{W}/plan.json"))
beat_list_path = f"{W}/beat_list.json"
have_broll = os.path.exists(beat_list_path)
dur, brand = round(float(plan["duration"]), 2), plan["brand"]
proj = f"{W}/comp"
os.makedirs(f"{proj}/compositions", exist_ok=True)
shutil.copy(f"{W}/base.mp4", f"{proj}/base.mp4")
# Vendor GSAP into the comp root AND the compositions/ subdir so the local
# <script src="gsap.min.js"> in root-shell.html (root) + tk-*/typing-scene
# sub-compositions (compositions/) resolves at render — never a CDN.
gsap_src = find_gsap(SKILL)
shutil.copy(gsap_src, f"{proj}/gsap.min.js")
shutil.copy(gsap_src, f"{proj}/compositions/gsap.min.js")

def fill(t, m):
    for k, v in m.items(): t = t.replace("{{%s}}" % k, str(v))
    return t

RAW_KEYS = {"TITLE", "QUOTE", "PROMPT"}  # may carry HTML

tkdivs = []
track_idx = 1

# --- Graphics takeovers from plan.json ---
for i, tk in enumerate(plan.get("takeovers", [])):
    d = round(float(tk["end"]) - float(tk["start"]), 2)
    m = {"ID": f"tk{i}", "DURATION": d, "BG": brand["bg"], "ACCENT": brand["accent"], "FG": brand["fg"]}
    for k, v in tk["fill"].items():
        m[k] = str(v) if k in RAW_KEYS else html.escape(str(v))
    tpl_name = tk["template"]
    if tpl_name == "tk-typing-ui":
        # WI2.87: c-typing-ui as a sub-composition KEEPS its <template> wrapper and takes this slot's
        # composition id (stripped and left as "typing-scene", HyperFrames never gets ready, the render
        # fails and every takeover falls back to a still card). Its ts-* ids/classes and script are
        # scoped to the slot, and every key it reads is filled.
        import re as re_mod
        m["ACCENT"] = str(brand["accent"]).lstrip("#")   # the scene writes #{{ACCENT}}
        # WI2.91: the scene reads PROMPT inside a JS "..." literal and decodes its entities in-page. html.escape
        # alone let a backslash change the typed text and a carriage return break the script (the render
        # failed). CR/CRLF become one line break; the HTML-escaped text is JSON-encoded (ASCII) as the
        # literal's body, so backslash, quote, control characters and U+2028/2029 are escaped, and < > { }
        # become \u escapes: no </script> break-out, no {{KEY}} in a prompt is ever filled. The other keys
        # the scene reads in JS literals drop line breaks and carry a backslash as &#92;.
        prompt = str(tk["fill"].get("PROMPT", "")).replace("\r\n", "\n").replace("\r", "\n")
        m["PROMPT"] = json.dumps(html.escape(prompt).replace("\n", "&#10;"), ensure_ascii=True)[1:-1].translate(
            {ord("<"): "\\u003c", ord(">"): "\\u003e", ord("{"): "\\u007b", ord("}"): "\\u007d"})
        for k in ("TYPING_SPEED", "VARIANT", "BOTTOM_TAG"):
            if k in m:
                m[k] = re_mod.sub(r"[\r\n\u2028\u2029]+", " ", str(m[k])).replace("\\", "&#92;")
        m.setdefault("CARD_LABEL", "The prompt")   # the label above the card (neutral; no "paste this")
        for k, v in (("TYPING_SPEED", "1.0"), ("BOTTOM_TAG", ""), ("VARIANT", "full"), ("BOTTOM_TAG_DISPLAY", "")):
            m.setdefault(k, v)
        tpl_src = open(f"{TYPING}/templates/typing-scene.html").read()
        tpl_src = tpl_src[tpl_src.index('<template id="typing-scene-template">'):]   # drop the usage comment
        assert tpl_src.count('id="ts-label">The prompt · paste this</div>') == 1, \
            "FATAL: c-typing-ui typing-scene.html card label changed shape; cannot fill CARD_LABEL (WI2.91)"
        tpl_src = tpl_src.replace('id="ts-label">The prompt · paste this</div>', 'id="ts-label">{{CARD_LABEL}}</div>')
        tpl_src = re_mod.sub(r'(?<=[.#"])ts-', f"tk{i}-ts-", tpl_src.replace("typing-scene", f"tk{i}"))
        tpl_src = tpl_src.replace("<script>\n", "<script>\n(function () {\n", 1)
        tpl_src = tpl_src.replace("\n  </script>\n</div>\n</template>", "\n})();\n  </script>\n</div>\n</template>")
        assert f'<template id="tk{i}-template">' in tpl_src and f'__timelines["tk{i}"]' in tpl_src and "})();" in tpl_src, \
            "FATAL: c-typing-ui typing-scene.html changed shape; cannot slot it as a takeover"
        tpl_content = fill(tpl_src, m)
    else:
        tpl_content = fill(open(f"{SKILL}/templates/{tpl_name}.html").read(), m)
    out_path = f"{proj}/compositions/tk{i}.html"
    open(out_path, "w").write(tpl_content)
    tk_start = tk["start"]
    tkdivs.append(
        f'<div id="tk{i}-slot" class="takeover-slot" data-composition-id="tk{i}" '
        f'data-composition-src="compositions/tk{i}.html" data-start="{tk_start}" '
        f'data-duration="{d}" data-width="1080" data-height="1920" '
        f'data-track-index="{track_idx}"></div>')
    track_idx += 1

# --- B-roll takeover stubs (they overlay via ffmpeg in Step 6b, but we need placeholder timing) ---
# b-roll beats sit outside HyperFrames — they are overlaid in the mux step.
# No HyperFrames divs are emitted for broll beats.

# BUG FIX (captions invisible under b-roll — bake-off 2026-06-12):
# Do NOT write caption-overlay.html here and do NOT include a caption-slot div
# in root-shell.html. Step 5 renders graphics takeovers ONLY.
# Step 6b then overlays b-roll on the graded output.
# Step 7 (c-reel-premium) is the SOLE caption burn pass — it feeds on the
# fully-composited output (post b-roll), so captions land on top of b-roll frames.
#
# DOUBLE-PROCESSING GUARD: if c-reel-premium has already been applied to the
# input (e.g. polished.mp4 exists and REEL_IN points to it), DO NOT call it
# again. The step order below enforces this — c-reel-premium is called once in
# Step 7 on bed-broll.mp4 (never on an output that already went through premium).

root = open(f"{SKILL}/templates/root-shell.html").read()
open(f"{proj}/index.html", "w").write(fill(root, {
    "DURATION": dur, "VIDEO_SRC": "base.mp4", "BG": brand["bg"],
    "TAKEOVER_DIVS": "\n  ".join(tkdivs),
    "CAPTION_DIV": ""}))   # empty — captions are burned by c-reel-premium in Step 7
print(f"assembled: {len(tkdivs)} graphics takeovers (captions deferred to Step 7), {dur}s")
PY

# box-compat: gpt-5.5 sometimes emits a double-hash hex (##0F172A) → white bg. Collapse it
# before lint/render (BG + takeover content flow in from the LLM plan).
sed -i 's/##/#/g' "$W/comp/index.html"
cd "$W/comp" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 validate
```

**Render in the BACKGROUND** (per the f-hyperframes-cli render gate — this render runs 60–600s; a
foreground call gets killed at the runtime ceiling and the cook fails with no resume):

- `terminal(command="cd $W/comp && npx hyperframes@0.7.5 render --output $W/visuals.mp4 --fps 30 --quality high", background=true, notify_on_complete=true)` → returns a `session_id`
- `process(action="wait", session_id=<id>)` to block until done (or `poll` to check progress)
- WI2.92: if the render exits non-zero or leaves no `$W/visuals.mp4`, STOP and exit non-zero with
  `takeovers: hyperframes render of $W/comp failed; no still fallback (WI2.92): <the hyperframes error>`.
  There is no still-card, PNG or ffmpeg-overlay takeover fallback.

Only after the render completes, verify the output **and stamp proof for the delivery gate**:

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 "$W/visuals.mp4"

# DELIVERY-GATE PROOF (Step 10.6 reads this). The real HyperFrames render MUST run —
# writing this stamp is how the gate knows graphics takeovers were actually rendered
# (not hand-burned / skipped). N = graphics-takeover count from the plan.
mkdir -p "$W/.gate"
python3 - "$W" <<'PY'
import json, sys, subprocess, os
W = sys.argv[1]
plan = json.load(open(f"{W}/plan.json"))
n = len(plan.get("takeovers", []))
vis = f"{W}/visuals.mp4"
# visuals.mp4 must exist and be a real, non-trivial video (>0.5s, 1080x1920).
probe = subprocess.run(["ffprobe","-v","error","-select_streams","v:0",
    "-show_entries","stream=width,height:format=duration","-of","json", vis],
    capture_output=True, text=True)
assert probe.returncode == 0, f"visuals.mp4 not a valid video — HyperFrames render did not run: {probe.stderr}"
meta = json.loads(probe.stdout)
w = meta["streams"][0]["width"]; h = meta["streams"][0]["height"]
d = float(meta["format"]["duration"])
assert (w, h) == (1080, 1920), f"visuals.mp4 dims {w}x{h} != 1080x1920"
assert d > 0.5, f"visuals.mp4 duration {d}s too short — render produced nothing"
json.dump({"rendered": n, "engine": "hyperframes@0.7.5", "fallback": False,
           "visuals_s": round(d, 2)}, open(f"{W}/.gate/hyperframes.json", "w"))
print(f"[gate-stamp] hyperframes: {n} graphics takeovers rendered, visuals {d:.1f}s")
PY
```

### Step 6 — Grade + audio mux (bed untouched, SFX under, ONE pass)

```bash
python3 - "$W" "$SKILL_DIR" <<'PY' > "$W/mux.sh"
import json, sys
W, SKILL = sys.argv[1], sys.argv[2]
plan = json.load(open(f"{W}/plan.json"))
cues = plan.get("sfx", [])
GRADES = {
  "warm-amber":   "curves=r='0/0 0.5/0.55 1/1':b='0/0 0.5/0.46 1/0.95',eq=contrast=1.05:saturation=1.08,unsharp=5:5:0.5",
  "clean-bright": "eq=brightness=0.02:contrast=1.06:saturation=1.1,unsharp=5:5:0.5",
}
grade = GRADES.get(plan.get("grade", "clean-bright"), GRADES["clean-bright"])
inputs = " ".join(f"-i \"{SKILL}/assets/sfx/{c['name']}.wav\"" for c in cues)
parts, mix = [], "[1:a]"
for j, c in enumerate(cues):
    ms = int(float(c["t"]) * 1000)
    parts.append(f"[{j+2}:a]adelay={ms}|{ms},volume={min(float(c.get('gain', 0.5)), 0.8)}[s{j}]")
    mix += f"[s{j}]"
if cues:
    fc = ";".join(parts) + f";{mix}amix=inputs={len(cues)+1}:normalize=0:duration=first[aout]"
else:
    fc = "[1:a]anull[aout]"
print(f'''ffmpeg -y -i "{W}/visuals.mp4" -i "{W}/base.mp4" {inputs} \\
  -filter_complex "[0:v]{grade},format=yuv420p[vout];{fc}" \\
  -map "[vout]" -map "[aout]" \\
  -c:v libx264 -preset medium -crf 19 -r 30 \\
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart "{W}/bed.mp4"''')
PY
bash "$W/mux.sh"
```

**Never loudnorm again here** — the bed was normalized once in Step 2; `normalize=0` keeps it at
exactly that level with SFX tucked under.

### Step 6b — Overlay b-roll takeovers (skip if no b-roll)

B-roll takeover clips produced in Step 5A are composited over the graded bed using ffmpeg's
time-gated overlay. The VO bed audio passes through untouched.

```bash
if [ "$HAVE_BROLL" = "True" ] && [ -f "$W/beat_list.json" ]; then
  python3 - "$W" <<'PY' > "$W/broll_overlay.sh"
import json, sys
W = sys.argv[1]
bl = json.load(open(f"{W}/beat_list.json"))
broll_beats = [b for b in bl["beats"] if b["kind"] == "broll" and "_rendered_path" in b]
if not broll_beats:
    # No rendered broll — passthrough
    print(f'cp "{W}/bed.mp4" "{W}/bed-broll.mp4"')
    sys.exit(0)

# Chain overlays: start with bed.mp4, add each broll clip as a time-windowed overlay.
# Each clip uses setpts to align its PTS to the beat's start time on the bed.
inputs = [f'"{W}/bed.mp4"']
for b in broll_beats:
    inputs.append(f'"{b["_rendered_path"]}"')

filter_parts = []
cur_v = "[0:v]"
for i, b in enumerate(broll_beats):
    t_start = float(b["start"])
    t_end   = float(b["end"])
    next_v = f"[ov{i}]" if i < len(broll_beats) - 1 else "[vfinal]"
    # setpts shifts the clip so it starts at t_start on the bed timeline
    filter_parts.append(
        f"[{i+1}:v]setpts=PTS-STARTPTS+{t_start}/TB[brl{i}];"
        f"{cur_v}[brl{i}]overlay=enable='between(t,{t_start},{t_end})':eof_action=pass{next_v}"
    )
    cur_v = next_v

fc = ";".join(filter_parts)
input_str = " ".join(f"-i {inp}" for inp in inputs)
print(f"""ffmpeg -y {input_str} \\
  -filter_complex "{fc}" \\
  -map "[vfinal]" -map "0:a" \\
  -c:v libx264 -pix_fmt yuv420p -preset medium -crf 19 -r 30 \\
  -c:a copy -movflags +faststart "{W}/bed-broll.mp4"
""")
PY
  bash "$W/broll_overlay.sh"
else
  cp "$W/bed.mp4" "$W/bed-broll.mp4"
fi
```

### Step 7 — Apply c-reel-premium (captions + SFX + grade polish)

# BUG FIX (bake-off 2026-06-12): c-reel-premium is called EXACTLY ONCE here, on
# bed-broll.mp4 (the graded + b-roll-composited output from Steps 6+6b).
# Step 5 no longer burns captions into the HyperFrames composition.
# DOUBLE-PROCESSING GUARD: never call c-reel-premium on polished.mp4 — that is
# the OUTPUT of this step. REEL_IN must be bed-broll.mp4 (or bed.mp4 if no b-roll).
# Feeding polished.mp4 back into c-reel-premium will double-burn captions + double-grade.

```bash
REEL_IN="$W/bed-broll.mp4"
REEL_OUT="$W/polished.mp4"
WORDS_JSON="$W/words.json"
PLAN_BRAND=$(python3 -c "import json; p=json.load(open('$W/plan.json')); print(json.dumps(p['brand']))")
ACCENT_HEX=$(echo "$PLAN_BRAND" | python3 -c "import json,sys; print(json.load(sys.stdin)['accent'].lstrip('#'))")
FG_HEX=$(echo "$PLAN_BRAND" | python3 -c "import json,sys; print(json.load(sys.stdin)['fg'].lstrip('#'))")

REEL_IN="$REEL_IN" REEL_OUT="$REEL_OUT" WORDS_JSON="$WORDS_JSON" \
  CAP_TOP="1180" CAPTIONS="${CAPTIONS:-on}" SFX="${SFX:-on}" \
  GRADE="$(python3 -c "import json; print(json.load(open('$W/plan.json')).get('grade','clean-bright'))")" \
  bash -c "$(cat <<'WRAPPER'
source "$PREMIUM_DIR/SKILL.md"   # load the step functions if exported, else inline below
WRAPPER
)"

# c-reel-premium is called inline (it is a component, not a shell-sourced lib).
# Run its steps directly: P1 (plan captions+sfx+grade), P2 (render overlay), P3 (mux), P4 (QA).
# See c-reel-premium/SKILL.md for the full step bodies.
# The variables PREMIUM_DIR, REEL_IN, REEL_OUT, WORDS_JSON, CAP_TOP are already set above.
run_skill c-reel-premium \
  REEL_IN="$REEL_IN" \
  REEL_OUT="$REEL_OUT" \
  WORDS_JSON="$WORDS_JSON" \
  CAP_TOP="1180" \
  CAPTIONS="${CAPTIONS:-on}" \
  SFX="${SFX:-on}"

# DELIVERY-GATE PROOF (Step 10.6 reads this). c-reel-premium is the SOLE kinetic-caption
# + SFX + grade pass. Hand-burning captions with raw ffmpeg/drawtext is a DEFECT and will
# NOT write this stamp → the gate blocks upload. polished.mp4 must exist and differ from
# the input (proving the pass actually transformed the video).
mkdir -p "$W/.gate"
python3 - "$W" "$REEL_IN" "$REEL_OUT" <<'PY'
import sys, os, json
W, rin, rout = sys.argv[1], sys.argv[2], sys.argv[3]
assert os.path.exists(rout) and os.path.getsize(rout) > 100_000, \
    f"c-reel-premium output {rout} missing/empty — the premium pass did not run"
assert os.path.getsize(rout) != os.path.getsize(rin), \
    "polished.mp4 is byte-identical to the input — c-reel-premium was a no-op (captions not burned)"
json.dump({"applied": True, "captions": os.environ.get("CAPTIONS", "on"),
           "sfx": os.environ.get("SFX", "on")}, open(f"{W}/.gate/premium.json", "w"))
print("[gate-stamp] premium: kinetic captions + SFX + grade applied")
PY
```

### Step 7.5 — Overlay-FX beats (OPTIONAL — Director-placed, OFF by default)

Default behavior is unchanged: a no-op unless the Director supplies `overlay_beats`. When set, the
Director MAY drop 1–3 animated overlay graphics (pill / sticker / mini-flowchart) on top of the
assembled reel at chosen beats, via `c-overlay-fx`. Each overlay renders to a transparent (alpha)
clip and is `overlay`-composited over `polished.mp4` — the picture underneath is never re-encoded
into the graphic.

**The Director picks BOTH the moment AND a SAFE position from the map below.** An overlay must NEVER
cover the speaker's face or the HyperFrames title/captions.

**Safe-zone map — `spotlight` format (1080×1920):** the speaker fills the frame, so usable room is
limited. **SAFE = the top margin/corners and the bottom margin/corners only** (roughly `y < 160` or
`y > 1700`, hugging the edges) — and never under the burned caption band. Keep overlays small and in
the corners; the mid-frame is always the face.

```bash
# overlay_beats: a JSON array the Director sets, e.g.
#   [{"type":"sticker","text":"LIVE","position":{"x":80,"y":120},"start":1.5,"duration":2.0}]
# Each spec also carries brand context. Empty/unset → skip entirely (default).
OVERLAY_BEATS="${overlay_beats:-[]}"
if [ "$(echo "$OVERLAY_BEATS" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -gt 0 ]; then
  OVERLAY_FX_DIR="$SKILL_DIR/../c-overlay-fx"
  [ -z "$OVERLAY_FX_DIR" ] && { echo "[spotlight] overlay_beats set but c-overlay-fx not found — skipping"; OVERLAY_BEATS="[]"; }
fi
if [ "$(echo "$OVERLAY_BEATS" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -gt 0 ]; then
  CUR="$W/polished.mp4"
  i=0
  echo "$OVERLAY_BEATS" | python3 -c 'import sys,json;[print(json.dumps(o)) for o in json.load(sys.stdin)]' | while IFS= read -r spec; do
    i=$((i+1))
    echo "$spec" > "$W/overlay-$i.json"
    OVPNG="$W/overlay-$i.mov"   # transparent alpha clip
    node "$OVERLAY_FX_DIR/render-overlay.cjs" "$W/overlay-$i.json" "$OVPNG"
    X=$(echo "$spec" | python3 -c 'import sys,json; print(json.load(sys.stdin)["position"]["x"])')
    Y=$(echo "$spec" | python3 -c 'import sys,json; print(json.load(sys.stdin)["position"]["y"])')
    ST=$(echo "$spec" | python3 -c 'import sys,json; print(json.load(sys.stdin)["start"])')
    DU=$(echo "$spec" | python3 -c 'import sys,json; print(json.load(sys.stdin)["duration"])')
    EN=$(python3 -c "print(${ST}+${DU})")
    ffmpeg -y -i "$CUR" -itsoffset "$ST" -i "$OVPNG" \
      -filter_complex "[0:v][1:v]overlay=${X}:${Y}:format=auto:enable='between(t,${ST},${EN})'[v]" \
      -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -preset medium -crf 19 \
      -c:a copy -movflags +faststart "$W/polished-ov-$i.mp4"
    CUR="$W/polished-ov-$i.mp4"
  done
  LAST=$(ls -1 "$W"/polished-ov-*.mp4 2>/dev/null | sort -V | tail -1)
  [ -n "$LAST" ] && cp "$LAST" "$W/polished.mp4"
fi
```

### Step 8 — CTA end-card (FINAL TAIL TAKEOVER — not an append)

**Hard rule:** the CTA end-card is the **last graphics takeover** of the bed. It never covers
speech (WI2.86): it starts at `max(bed − CTA_DURATION, last word end)` and covers the rest of the
bed. Step 2's silent tail (WI2.89) leaves `CTA_DURATION` + 0.5 s after the last word, so the full
card shows right after the speech. Total reel duration = bed duration. Nothing is appended.

```bash
# WI2.90: cta_card off (CTA_CARD, from the order) renders no end card; Step 2 added no tail either.
if [ "${CTA_CARD:-on}" != "on" ]; then
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/polished.mp4")
echo "[spotlight] end card: cta_card off, no end card"
cp "$W/polished.mp4" "$OUT_RAW"
else
BG_HEX=$(python3 -c "import json; print(json.load(open('$W/plan.json'))['brand']['bg'].lstrip('#'))")
ACCENT_HEX=$(python3 -c "import json; print(json.load(open('$W/plan.json'))['brand']['accent'].lstrip('#'))")
FG_HEX=$(python3 -c "import json; print(json.load(open('$W/plan.json'))['brand']['fg'].lstrip('#'))")

CTA_DURATION="${CTA_DURATION:-3.0}"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/polished.mp4")
# WI2.86/WI2.89: the card starts only after the last spoken word ends and covers the rest of the bed.
CTA_START=$(python3 - "$BED_DUR" "$CTA_DURATION" "$W" <<'PY'
import json, os, sys
bed, want, w = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
ends = [float(x["end"]) for x in json.load(open(os.path.join(w, "words.json"))) if isinstance(x, dict) and "end" in x]
for g in json.load(open(os.path.join(w, "plan.json"))).get("caption_groups") or []:
    ends += [float(x["e"]) for x in g.get("words") or [] if isinstance(x, dict) and "e" in x]
if not ends:
    sys.exit("end card: no word timings in words.json or the plan caption groups")
print("%.3f" % max(bed - want, max(ends)))
PY
) || exit 1
CTA_DURATION=$(python3 -c "print('%.3f' % max(0.0, ${BED_DUR} - ${CTA_START}))")
python3 -c "import sys; sys.exit(0 if ${CTA_DURATION} >= 1.0 else 'end card: only ${CTA_DURATION}s of bed after the last spoken word; the Step 2 end-card tail (WI2.89) is missing')" || exit 1
# Per-brand end card (CFW-354 / M1-00): kicker = BRAND_NAME, hero = CTA_TEXT, handle = CTA_HANDLE.
# scripts/cta-card.py OMITS the kicker/handle layer when its variable is empty — a brand with no
# known handle gets a card with no handle line, never a placeholder or another brand's handle.
CTA_DURATION="$CTA_DURATION" CTA_TEXT="$CTA_TEXT" CTA_HANDLE="${CTA_HANDLE:-}" BRAND_NAME="${BRAND_NAME:-}" \
  python3 "$SKILL_DIR/scripts/cta-card.py" "$W/plan.json" "$W/cta-card.json" \
    "$W/cta-card" "$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js" || exit 1

# WI2.93: hyperframes 0.7.5 renders a project DIRECTORY ($W/cta-card/index.html, written by
# cta-card.py), never the .json spec ("Not a directory"). The card must animate, so there is no
# still ffmpeg drawtext card: a failed render stops the step with the reason.
npx hyperframes@0.7.5 render "$W/cta-card" --fps 30 --quality high --output "$W/cta-card.mp4" && [ -f "$W/cta-card.mp4" ] \
  || { echo "end card: hyperframes render of $W/cta-card failed; no still fallback card (WI2.93)" >&2; exit 1; }

# BED_DUR, CTA_START and CTA_DURATION were set above (WI2.86/WI2.89): the card follows the last word.

ffmpeg -y -i "$W/polished.mp4" -itsoffset "${CTA_START}" -i "$W/cta-card.mp4" \
  -filter_complex "[0:v][1:v]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
  -map "[v]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -c:a copy \
  -movflags +faststart "$OUT_RAW"
fi   # WI2.90: end of the cta_card on branch

if [ -n "${MUSIC:-}" ]; then
  FADE_START=$(python3 -c "print(${BED_DUR} - 0.5)")
  ffmpeg -y -i "$OUT_RAW" -i "$MUSIC" \
    -filter_complex "[1:a]aloop=loop=-1:size=2e9,atrim=duration=${BED_DUR},asetpts=PTS-STARTPTS,volume=-22dB,afade=in:st=0:d=0.8,afade=out:st=${FADE_START}:d=0.5[bg];[0:a][bg]amix=inputs=2:duration=first:normalize=0[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 \
    -movflags +faststart "$W/reel-with-music.mp4" && mv "$W/reel-with-music.mp4" "$OUT_RAW"
fi
```

### Step 9 — Verify (mandatory continuity proof + Visual QA Gate)

```bash
ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=codec_type,codec_name,width,height,r_frame_rate -of json "$OUT_RAW"
ffmpeg -v error -i "$OUT_RAW" -f null -

# CONTINUITY PROOF — VO present during every takeover (both graphics AND b-roll windows):
python3 - "$W/plan.json" "$W/beat_list.json" "$OUT_RAW" <<'PY'
import json, os, subprocess
plan = json.load(open(os.sys.argv[1]))
bl_path = os.sys.argv[2]
out = os.sys.argv[3]
windows = [(float(t["start"]), float(t["end"])) for t in plan.get("takeovers", [])]
if os.path.exists(bl_path):
    bl = json.load(open(bl_path))
    windows += [(float(b["start"]), float(b["end"])) for b in bl["beats"] if b["kind"] == "broll"]
for s, e in sorted(windows):
    r = subprocess.run(
        ["ffmpeg","-hide_banner","-ss",str(s),"-t",str(e-s),"-i",out,"-af","volumedetect","-f","null","-"],
        capture_output=True, text=True)
    vol_line = next((l for l in r.stderr.splitlines() if "mean_volume" in l), "MISSING")
    print(f"window {s:.1f}-{e:.1f}s: {vol_line.strip()}")
import sys as _sys
_sys.exit(0)
PY
# Every window must report a real (non -inf) mean_volume.

# Visual QA Gate — extract 6 frames and READ each with vision:
for pct in 05 20 40 60 80 95; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -y -ss "$t" -i "$OUT_RAW" -frames:v 1 "$W/qa_$pct.png"
done
```

Per frame CHECK:
- [ ] **(a)** Captions visible + legible in lower band, brand accent on emphasis word, NOT on face.
- [ ] **(b)** Latin script only — zero Devanagari glyphs.
- [ ] **(c)** Takeover frames show opaque full-frame card OR b-roll clip (no blank frames).
- [ ] **(d)** Grade is subtle — skin tones natural.
- [ ] **(e)** No black/empty frame anywhere.
- [ ] **(f)** B-roll beats show the correct clip trimmed to the right window.

### Step 10 — First-frame cover (§2d — MANDATORY)

IG/TikTok use frame 1 as the feed poster. The hook scene animates in from black, so frame 1 is
blank → blank thumbnail. Fix: prepend a **0.4s freeze of the money-shot frame** tagged by the Step 4
edit plan's `cover_at` timestamp (a content beat past the hook).

```bash
COVER_AT=$(python3 -c "import json; p=json.load(open('$W/plan.json')); print(p.get('cover_at', $DUR * 0.4))")

# 1. Extract money-shot frame
ffmpeg -y -ss "$COVER_AT" -i "$OUT_RAW" -frames:v 1 -q:v 2 "$COVER_PNG"

# 2. Freeze to a 0.4s clip (1080×1920 / 30fps / silent stereo — matches reel specs)
# BUG FIX: anullsrc MUST be a proper lavfi input (-f lavfi -i), NOT an -af filter.
# Using -af with an anullsrc filter attaches it to the image's (absent) audio stream,
# producing no audio stream → the concat drops audio entirely.
ffmpeg -y -loop 1 -t 0.4 -i "$COVER_PNG" \
  -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -shortest \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 \
  "$W/cover-freeze.mp4"

# 3. Concat cover freeze + reel (re-encode to avoid non-monotonic DTS from -c copy)
# BUG FIX: -c copy on a demuxer concat of independently-encoded clips causes DTS
# non-monotonic errors in some ffmpeg builds. Re-encode both streams.
printf "file '%s'\nfile '%s'\n" "$W/cover-freeze.mp4" "$OUT_RAW" > "$W/concat-cover.txt"
ffmpeg -y -f concat -safe 0 -i "$W/concat-cover.txt" \
  -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart "$OUT"

# Verify: with-cover duration = raw duration + 0.4s (±0.05)
COVER_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
python3 -c "
import sys
raw=$BED_DUR; cov=float('$COVER_DUR')
assert abs(cov - (raw + 0.4)) < 0.1, f'cover duration mismatch: expected ~{raw+0.4:.2f}s, got {cov:.2f}s'
print(f'cover OK: {cov:.2f}s (raw {raw:.2f}s + 0.40s freeze)')
"
# Frame 1 of $OUT must NOT be black — eyeball $COVER_PNG (already extracted):
echo "[spotlight] cover frame: $COVER_PNG"
```

### QA gate (MANDATORY — run before upload)

Run the shared eval engine (`c-eval-runner`) on the final MP4. It reads this
recipe's `acceptance.json`, delegates the mechanical gate to `c-shorts-qa-gate`,
runs the spotlight-specific geometry checks, and writes a structured `scorecard.json`.
**Do NOT upload if it exits non-zero (verdict FAIL).**

```bash
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_MP4> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → <video_dir>/eval/scorecard.json ; frame sweep → <video_dir>/eval/
```

- **HARD** (verdict FAIL, exit 1, blocks delivery): mechanical gate (loudness ≈ -14
  LUFS, frame-0 brightness > 0x30, resolution/fps, audio present), duration 20–62s,
  canvas exactly 1080×1920, no black frames on any sampled timestamp.
- **PERCEPTUAL** (verdict NEEDS_VISION until resolved): the Step 9 (a)–(f) checks
  plus the VO-continuity and cover-moneyshot checks are emitted as PENDING criteria
  with a frame sweep — resolve them with a vision pass (read the frames or run
  `c-vision-qa`) and set each pass/fail before upload.

The full checklist lives in `acceptance.json` (the per-recipe spec). A brand may layer
`brand-overrides/<brand-slug>/acceptance.json` to tighten thresholds (same id wins,
new ids appended). If any HARD check fails, fix the render and re-run — never deliver
a failing gate.

**Interim gate (fail-fast, recommended on expensive runs):**
```bash
bash .hub/c-eval-runner/scripts/eval-run.sh base.mp4 --recipe-dir "$SKILL_DIR" --step speakerbed   # after Step 2
```
See `.hub/c-eval-runner/SKILL.md` for the spec format + built-in checks, and
`cfw-skills-pack/docs/skills-audit.md` §4 for the generic eval architecture.

### Step 10.6 — DELIVERY GATE (MECHANICAL · HARD · blocks upload)

**This gate is NON-NEGOTIABLE and runs immediately before Step 11. If it exits non-zero, STOP —
do NOT run `cfw-upload`, do NOT call `propose_composition`.** It proves — mechanically, not
perceptually — that the premium reel pipeline actually ran, so a weak/rushed executor cannot ship a
degraded reel (missing HyperFrames graphics, hand-burned captions) as if it were premium. The
proof-stamps come from Step 5 (`hyperframes.json`) and Step 7 (`premium.json`). A fallback stamp
always fails the gate: there is no takeover fallback (WI2.92).

```bash
python3 - "$W" "$OUT" <<'PY' || { echo "🚫 DELIVERY BLOCKED — see failures above. Fix the render and re-run Steps 5–7; do NOT upload or propose_composition."; exit 1; }
import json, os, sys, subprocess
W, OUT = sys.argv[1], sys.argv[2]
fail = []

plan = json.load(open(f"{W}/plan.json"))
planned_tk = len(plan.get("takeovers", []))

# 1) HyperFrames graphics takeovers actually rendered (no fallback, WI2.92).
hf_path = f"{W}/.gate/hyperframes.json"
if not os.path.exists(hf_path):
    fail.append("Step 5 HyperFrames stamp missing — the graphics render never ran (or was skipped).")
else:
    hf = json.load(open(hf_path))
    if hf.get("fallback"):
        fail.append("HyperFrames fallback stamp found — there is no takeover fallback (WI2.92); fix the render.")
    elif planned_tk > 0 and hf.get("rendered", 0) < planned_tk:
        fail.append(f"Only {hf.get('rendered',0)}/{planned_tk} planned graphics takeovers rendered.")

# 2) Premium pass (kinetic captions + SFX + grade) actually applied.
pr_path = f"{W}/.gate/premium.json"
if not os.path.exists(pr_path) or not json.load(open(pr_path)).get("applied"):
    fail.append("Step 7 premium stamp missing — captions were NOT burned by c-reel-premium "
                "(raw ffmpeg/drawtext caption burns are a defect).")

# 3) Final deliverable exists, is 1080x1920, and is non-trivial.
probe = subprocess.run(["ffprobe","-v","error","-select_streams","v:0",
    "-show_entries","stream=width,height:format=duration","-of","json", OUT],
    capture_output=True, text=True)
if probe.returncode != 0:
    fail.append(f"final MP4 {OUT} is not a valid video.")
else:
    m = json.loads(probe.stdout)
    w, h = m["streams"][0]["width"], m["streams"][0]["height"]
    if (w, h) != (1080, 1920):
        fail.append(f"final dims {w}x{h} != 1080x1920.")

# 4) c-eval-runner scorecard must not be FAIL (if it was run — it is mandatory in the QA gate).
sc = f"{os.path.dirname(OUT)}/eval/scorecard.json"
if os.path.exists(sc):
    verdict = json.load(open(sc)).get("verdict")
    if verdict == "FAIL":
        fail.append("c-eval-runner scorecard verdict = FAIL.")
else:
    fail.append("c-eval-runner scorecard missing — run the QA gate (above) before delivery.")

if fail:
    print("DELIVERY GATE FAILURES:")
    for f in fail:
        print(f"  ✗ {f}")
    sys.exit(1)
print("✅ DELIVERY GATE PASSED — HyperFrames graphics + premium captions verified. OK to upload.")
PY
```

### Step 11 — Upload to R2 and print the URL (LAST LINE)

Upload BOTH the with-cover MP4 and the cover PNG as separate Outputs:

```bash
# Upload the with-cover MP4 (the deliverable)
cfw-upload "$OUT" 2>/dev/null || bash _scripts/upload-to-recordings.sh "$OUT"
# Upload the cover PNG as the explicit thumbnail Output
cfw-upload "$COVER_PNG" 2>/dev/null || bash _scripts/upload-to-recordings.sh "$COVER_PNG"
```

Clean up `$W` after both URLs are confirmed.
**Print the R2 public URL of `$OUT` as the final line of output.** Never print an input URL.

## No fallback assembly (WI2.92)

There is no still-card, PNG or ffmpeg-overlay stand-in for the graphics takeovers. On 2026-10-21
that fallback hid a total render failure ("Composition has zero duration. Runtime ready: false")
and the reel still reached Reviews. If `npx hyperframes@0.7.5 render` fails, Step 5 fails with the
hyperframes error; `hyperframes doctor` output may go in that reason, but it never unlocks a fallback.

## Notes & gotchas

- **The speaker audio is the single voice bed — never cut it.** Takeovers (graphics AND b-roll)
  cover the picture only. SFX mix with `amix=normalize=0` so the VO level never moves.
- **Loudnorm the bed ONCE** (Step 2). c-reel-premium and Step 6/6b must NOT re-normalize.
- **No b-roll → identical to p-reels-fmt3.** `$HAVE_BROLL=False` → Steps 3b, 4b, 5A, 6b are all
  no-ops; `beat_list.json` is never written; the pipeline is byte-for-byte equivalent to fmt3's
  output (same templates, same mux, same cover logic added in Step 10).
- **B-roll audio is always stripped** (ffmpeg `-an` in Step 5A). The VO bed is the only audio track.
- **B-roll beats sit outside HyperFrames** — they are pre-rendered clips overlaid via ffmpeg in
  Step 6b, not HyperFrames sub-compositions. This avoids loading external video inside
  HyperFrames compositions (which can stall headless chromium).
- **c-broll-sync is a planner — it does not render.** Its beat_list.json drives Step 5A + 6b.
- **The engine running the recipe plans (Step 4); the later steps execute.** The executor fills
  templates — it never authors HTML or picks takeover content. No API key is involved in planning.
- **Hinglish / non-English captions stay Latin-script.** The planner transliterates; the mechanical
  guard + Visual QA Gate (b) both reject Devanagari. Never translate.
- **cover_at must be past the hook (≥ 2s).** The plan guard enforces this. If the plan omits
  `cover_at`, Step 10 defaults to `DUR * 0.4`.
- **cover-freeze.mp4 must be silent stereo** (not mono, not absent). The concat step needs matching
  audio specs or ffmpeg will drop the audio channel.
- **Fonts:** Oswald / Inter / JetBrains Mono only. Barlow Condensed is NOT compiler-resolved.
- **Takeover cards keep content in the TOP ~55%** — the caption band sits at y≈1180-1440.
- **{{ACCENT}} must be a 6-digit hex** (templates append alpha as hex pairs).
- **HyperFrames authoring traps** (full list in fmt3 SKILL.md § Notes): root = full HTML doc;
  timing on loader divs only; bare `getComputedStyle(el)` not `window.`; no tags in comments.
- **SFX pack is CC0** (`assets/sfx/` — ffmpeg-synthesized). Never use unlicensed packs.
- **Reuse before you render.** Check prior avatar renders before calling HeyGen.
- **Reels trim audio by default** — the mandatory trim in Step 2 strips silent buffers. Un-trimmed
  audio is a defect.

### Box-compat gotchas (Ubuntu 22.04 / Hermes — folded from on-box validation)

- **No key files, no hosted-box paths (M1-09).** The recipe never reads a `.env` or any other
  machine-specific file. `GEMINI_API_KEY` (Step 3) exists only if the runner exported it from the
  order's brand provider keys; planning (Step 4) is done by the engine running the recipe itself.
- **`##` CSS guard.** gpt-5.5 occasionally emits a double-hash hex (`--bg: ##0F172A`) → white background.
  After writing the generated HyperFrames comp (Step 5), collapse double-hash to single
  (`sed -i 's/##/#/g' "$W/comp/index.html"`) before lint/render.
- **Three.js linter no-op.** The HyperFrames linter false-flags any composition whose text contains the
  literal "THREE" (e.g. a caption "THREE.") as a missing-Three.js error. Inject a harmless Three.js CDN
  `<script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>` into that
  composition's `<head>` to satisfy the linter — it is never used at runtime.
- **(ffprobe csv N/A here.)** Spotlight reads width/height with single-field `-of csv=p=0` calls (one
  value each), which parse identically on Ubuntu — no `awk` rework needed. The multi-field `width,height`
  ffprobe in Steps 5/6 is a diagnostic echo, not parsed into shell vars.
- **(CTA end card is a HyperFrames project, WI2.93.)** Step 8 renders `$W/cta-card/` (index.html +
  gsap.min.js written by `scripts/cta-card.py`) with `hyperframes render <dir>`; there is no ffmpeg
  `drawtext` fallback card, so a failed render fails the step.
