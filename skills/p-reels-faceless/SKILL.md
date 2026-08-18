---
name: p-reels-faceless
description: Turn a script into a fully-rendered premium faceless reel — TTS voiceover in the brand voice, then the visual track is full-frame HyperFrames motion-graphics (per-beat animated compositions: charts, terminals, typing-UI cards, diagrams, checklists) with OPTIONAL transcript-synced b-roll filling up to the coverage budget, plus baked-in kinetic captions, SFX, cinematic grade, CTA takeover, and a first-frame cover freeze for IG/TikTok feed. NO talking head, NO avatar. Replaces p-reels-fmt4 and adds optional b-roll (the hf-fmt5 way) plus the typing-UI graphics vocabulary. Trigger on "faceless reel from this script", "no-avatar explainer with b-roll", "script to premium animated reel", "faceless short with stock footage and motion graphics".
when-to-use: Use when you want a faceless 9:16 vertical reel — brand TTS voiceover over full-frame graphics, with optional b-roll clips filling some beats transcript-synced while remaining beats get real animated HyperFrames compositions. If no b-roll is supplied, the entire visual track is brand motion-graphics (preserving fmt4 behavior exactly). Never use for PIP layout (p-reels-pip) or uploaded talking-head (p-reels-spotlight). Prefer this over p-reels-fmt4 for all new cooks — it is the direct replacement.
version: 1.0.0
kind: pipeline
visibility: catalog
providers: elevenlabs
produces:
  dish: Faceless Premium Reel
  format: 9:16 vertical video
  duration: 30-90s
inputs: [script]
dependsOn: [c-audio, c-broll-sync, c-typing-ui, c-reel-premium, c-ffmpeg, c-cloud-media, f-hyperframes, f-hyperframes-cli, f-gsap, c-overlay-fx, c-shorts-qa-gate, c-eval-runner]

  hermes:
    vendored: [c-audio, c-reel-premium, c-broll-sync, c-typing-ui, c-ffmpeg, f-hyperframes, f-hyperframes-cli, f-gsap, c-overlay-fx, c-shorts-qa-gate]
metadata:
  hermes:
    vendored:
      - { name: c-audio, load: ".hub/c-audio/SKILL.md" }
      - { name: c-broll, load: ".hub/c-broll/SKILL.md" }
      - { name: c-broll-sync, load: ".hub/c-broll-sync/SKILL.md" }
      - { name: c-cloud-media, load: ".hub/c-cloud-media/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-overlay-fx, load: ".hub/c-overlay-fx/SKILL.md" }
      - { name: c-reel-premium, load: ".hub/c-reel-premium/SKILL.md" }
      - { name: c-shorts-qa-gate, load: ".hub/c-shorts-qa-gate/SKILL.md" }
      - { name: c-typing-ui, load: ".hub/c-typing-ui/SKILL.md" }
      - { name: f-gsap, load: ".hub/f-gsap/SKILL.md" }
      - { name: f-hyperframes, load: ".hub/f-hyperframes/SKILL.md" }
      - { name: f-hyperframes-cli, load: ".hub/f-hyperframes-cli/SKILL.md" }
    progressive: true
---




> ## ⚡ Frame integrity + integrated CTA (MANDATORY — 2026-06-16)
> - **Frame 0 is NEVER black.** The first frame must be a bright money-shot — the cover-freeze of the strongest illustrative beat (Step 10 cover rule). Verify `ffmpeg ... signalstats` → `YAVG > 30`. No black / hook-blank / fade-in opener.
> - **The LAST frame is NEVER black.** The reel must end on content, not a fade-to-black or trailing blank. Verify the final frame `YAVG > 30`.
> - **CTA is integrated by DEFAULT, not optional.** Every reel/VSL ends on a branded **CTA beat baked into the timeline** (offer line + handle/URL), as the final illustrative HyperFrames card. Do not ship a reel whose last beat is filler or black. (In p-reels-split this is the Step 9 CTA takeover; other recipes must add an equivalent closing CTA card.)

> ## ⚡ HyperFrames = illustrative, NOT just titles (MANDATORY — 2026-06-16)
> Every HyperFrames graphics scene MUST pair its title with an **illustrative animation that depicts the point** — never a bare kinetic title card. Examples: a 45-post feed grid staggering in (`back.out`), a count-up stat with day-dots, an animated waveform for "voice", platform chips popping in. Match the premium reference in `cfw-marketing/creatives/productions/restaurants-vsl/hyperframes` (`DIAG-calendar` feed-grid, `HF-*` motion) **and** `cfw-marketing/creatives/productions/fnb-split-screen-short/gen-rich-cards.py`: grid + glow + vignette background, GSAP eased + staggered elements, brand palette, depth (shadows/shine). **Make it as rich and premium as possible — a title-only card is a defect.**

# p-reels-faceless — Script → Premium Faceless Reel (optional b-roll, baked-in polish)

> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section.

A 9:16 vertical reel built from a SCRIPT:

```
audio:  ████████████████████████████████████████████  ← TTS voiceover, ONE unbroken bed (+SFX under)
video:  [graphics / b-roll beats —— beat-by-beat coverage ——] [CTA takeover]
captions: ▁▂▃ kinetic word-synced captions over EVERYTHING ▃▂▁
```

**What's new vs fmt4:**
- **Optional b-roll** — supply `$BROLL_CLIPS` and `c-broll-sync` allocates b-roll beats by transcript
  match (or `as-given`/`even`); all unmatched beats stay as graphics. No b-roll → 100% graphics,
  which is exactly old fmt4 behavior (preserved in full).
- **Typing-UI scenes** — `c-typing-ui` (FULL variant) is now one of the graphics scene types
  `c-broll-sync` can emit; the OPUS planner may assign `type: "typing-ui"` or `type: "hook"` beats.
- **First-frame cover rule (§2d)** — a 0.4 s money-shot freeze is prepended to the final MP4 so the
  IG/TikTok feed thumbnail is never blank.
- **c-reel-premium** — kinetic captions + SFX + cinematic grade baked in exactly like fmt3.

**What's identical to fmt4 (ported verbatim):**
- `c-audio` TTS → `cfw-transcribe` word timestamps → OPUS beat plan → parallel `delegate_task` render
- Visual doctrine: FOREGROUND HERO, `gsap.from()` ends-visible, ambient motion, SVG-only icons,
  thematic ghost glyph, one composition per beat, brand-driven palette.
- Visual QA gate (6-frame sample + per-beat motion proof), upload to R2, final URL as last line.

---

## Inputs / Params

| Param | Required | Default | Description |
|-------|----------|---------|-------------|
| `$SCRIPT` | Yes | — | Path to the VO script (markdown or plain text). HOOK + body beats. |
| `$OUT_DIR` | Yes | — | Output folder (`mkdir -p`). |
| `$VOICE_ID` | No | `$ELEVENLABS_DEFAULT_VOICE_ID` | ElevenLabs voice ID (`c-audio` presets). |
| `$BROLL_CLIPS` | No | `""` | Space-separated local paths to b-roll clip files. Empty = all-graphics (fmt4 path). |
| `$BROLL_COVERAGE_PCT` | No | `30` | Target % of reel runtime covered by b-roll. |
| `$BROLL_CLIP_SECONDS` | No | `4` | Default b-roll on-screen duration per window. |
| `$BROLL_MIN_SECONDS` | No | `2` | Min clamped b-roll window. |
| `$BROLL_MAX_SECONDS` | No | `6` | Max clamped b-roll window. |
| `$BROLL_ORDER` | No | `transcript-match` | `transcript-match` · `as-given` · `even`. |
| `$BROLL_REUSE` | No | `false` | Allow a clip to appear more than once to hit the coverage target. |
| `$OUTRO` | No | generated brand card | Optional supplied clip (1080×1920 w/ audio) for the brand outro. |
| `$TARGET` | No | `30–60s` | Target reel length; guides beat count during VO scripting. |
| `$PALETTE` | No | Visual Identity Gate | Resolved palette — NEVER hard-code; see Visual Identity Gate. |

---

## Visual doctrine (inherited from fmt4 — unchanged)

These rules are LOAD-BEARING. Violating any one of them is a HARD FAILURE.

- **FOREGROUND CONTENT IS THE HERO — MANDATORY.** Every graphics beat's composition MUST have a
  bright, dominant foreground: the beat's headline + its data-viz (chart, terminal, checklist, card).
  Ghost number + grid + glow are SUBORDINATE background decoration. A beat whose rendered frame shows
  ONLY the faint ghost glyph with no bright foreground is EMPTY and is a hard failure.
- **Author foreground with `gsap.from()` so it ENDS VISIBLE.** Every foreground element animates IN
  via `gsap.from({opacity:0, y:…})`; its END state is the element's natural visible state. NEVER
  `gsap.set(el,{opacity:0})` + later `.to({opacity:1})` — a mis-fired reveal leaves content invisible.
- **One REAL animated composition per graphics beat.** Every element animates IN; charts/bars/counters
  visibly change. A frozen card with zoom is a FAILURE.
- **Brand graphics only — Visual Identity Gate, HARD GATE.** Resolve palette BEFORE writing any HTML:
  1. Brand Brief (appended by the worker: `brand_dna.guidelines` — colors, fonts, reference renders).
  2. Brand `DESIGN.md` / `visual-style.md` if referenced.
  3. Named style → `f-hyperframes/visual-styles.md`.
  4. None → dark-premium default (`f-hyperframes/palettes/dark-premium.md`).
  Reaching for `#333`, `#3b82f6`, or `Roboto` = you skipped this gate.
- **GHOST GLYPH — MANDATORY: a thematic number or single letter, never a placeholder word.**
  Use the beat's index (`01`, `02`…), the listicle total, or a deliberate initial.
  The ghost must NEVER spell "CTA", "TITLE", "HEADER", or any layout label.
- **AMBIENT MOTION — MANDATORY: no beat may pop in then freeze.** Every beat carries continuous
  low-amplitude motion (slow yoyo/breathe/pulse on glow/grid/ghost) for its full `data-duration`.
  Stagger entrances later into the window so the beat keeps revealing. Target: any two frames ≥1s
  apart inside a beat must visibly differ (Step 9 motion proof: PSNR ≤ 45 dB pass, ≥ 50 dB fail).
- **ICONS — MANDATORY: inline SVG or CSS only.** The headless renderer has no emoji font. Every
  icon/glyph must be an `<svg>` path or a CSS shape. Never a unicode character (✓ ✕ → ▶ ⚡ 📊 all
  fail). Plain ASCII letters/digits in Oswald/JetBrains Mono are safe; decorative dingbats are not.
- **Font pairing:** Oswald (condensed display) + JetBrains Mono (code/data) — both auto-resolve in
  the HyperFrames compiler. Avoid Barlow Condensed (does not auto-resolve). No `var(--font-*)` in
  `font-family`.
- **Local media only inside compositions.** Download + `ffprobe` every asset; reference only local
  relative paths. Remote `http(s)://` URLs silently fail in the headless render.
- **Scene sequencing — one beat visible at a time.** One composition per beat, concatenated. NEVER
  lump all beats into one untimed composition.

---

## Tooling

- **TTS:** ElevenLabs `eleven_turbo_v2_5` via `c-audio`. Key: `ELEVENLABS_API_KEY` in `~/.gsai/secrets.env`.
- **Transcription:** `cfw-transcribe` (Gemini cloud default; MLX fast-path on macOS) → word-level SRT/JSON.
- **Beat planning:** `c-broll-sync` Node script (`plan.js`). OPUS sub-call for `transcript-match`.
- **Graphics (PRIMARY):** HyperFrames CLI (`npx hyperframes`) — `init` / `lint` / `render --quality high`.
- **Typing-UI scenes:** `c-typing-ui` FULL variant templates (`typing-scene.html`, `hook-scene.html`).
- **Polish:** `c-reel-premium` — kinetic captions + SFX + cinematic grade.
- **Composite + encode:** `ffmpeg` at `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`.
- **Upload:** `r2-upload` helper (`c-cloud-media`).

---

## Steps

### 0 — Setup

```bash
source ~/.gsai/secrets.env
FF=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
W="$OUT_DIR/work" ; mkdir -p "$W/gfx"
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-reels-faceless 2>/dev/null | head -1)
BROLL_SYNC_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-broll-sync 2>/dev/null | head -1)
[ -n "$BROLL_SYNC_DIR" ] || BROLL_SYNC_DIR="$SKILL_DIR/.hub/c-broll-sync"
TYPING_UI_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-typing-ui 2>/dev/null | head -1)
[ -n "$TYPING_UI_DIR" ] || TYPING_UI_DIR="$SKILL_DIR/.hub/c-typing-ui"
PREMIUM_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-reel-premium 2>/dev/null | head -1)

VOICE_ID="${VOICE_ID:-${ELEVENLABS_DEFAULT_VOICE_ID}}"
BROLL_CLIPS="${BROLL_CLIPS:-}"
BROLL_COVERAGE_PCT="${BROLL_COVERAGE_PCT:-30}"
BROLL_CLIP_SECONDS="${BROLL_CLIP_SECONDS:-4}"
BROLL_MIN_SECONDS="${BROLL_MIN_SECONDS:-2}"
BROLL_MAX_SECONDS="${BROLL_MAX_SECONDS:-6}"
BROLL_ORDER="${BROLL_ORDER:-transcript-match}"
BROLL_REUSE="${BROLL_REUSE:-false}"
```

---

### 1 — Write the VO script

Extract HOOK + body beats. Write ONE continuous VO line — spell tricky tokens for TTS
(`/terminal` → "slash terminal", `2x` → "twice as fast"). Save to `$W/vo-script.txt`.

Count beats and check estimated duration fits `$TARGET`. Aim for 6–10 beats at ~4–6s each.

---

### 2 — Generate voiceover (c-audio)

```bash
source ~/.gsai/secrets.env
curl -s -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" \
  -d "$(python3 -c "import json; print(json.dumps({'text':open('$W/vo-script.txt').read().strip(),'model_id':'eleven_turbo_v2_5','voice_settings':{'stability':0.5,'similarity_boost':0.75,'style':0.0}}))")" \
  --output "$W/vo.mp3"

# Verify real MP3 + loudnorm
file "$W/vo.mp3"
$FF -y -i "$W/vo.mp3" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a aac -b:a 192k -ar 48000 -ac 2 "$W/vo-normed.aac"
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/vo-normed.aac")
echo "Bed duration: $BED_DUR s"
```

Verify duration fits `$TARGET`.

---

### 3 — Word-level transcription

```bash
# Fallback chain: cfw-transcribe (preferred) → mlx_whisper → whisper → STOP.
# box-compat: cfw-transcribe (Gemini backend) needs GEMINI_API_KEY; source from box
# env file when not already in the environment. Harmless no-op off-box.
[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_API_KEY=$(grep GEMINI_API_KEY /opt/cfw-agent/.env 2>/dev/null | cut -d= -f2-) || true
export GEMINI_API_KEY
if command -v cfw-transcribe >/dev/null 2>&1; then
  # Gemini cloud (default); MLX fast-path on macOS
  cfw-transcribe --input "$W/vo.mp3" --out "$W/vo.srt" --format srt
  cfw-transcribe --input "$W/vo.mp3" --out "$W/vo-words.json" --format words
elif command -v mlx_whisper >/dev/null 2>&1; then
  echo "[faceless] cfw-transcribe not found — falling back to mlx_whisper"
  mlx_whisper "$W/vo.mp3" --model mlx-community/whisper-small --output-dir "$W" --output-format srt
  mv "$W/vo.srt" "$W/vo.srt" 2>/dev/null || true
  mlx_whisper "$W/vo.mp3" --model mlx-community/whisper-small --output-dir "$W" --output-format json
  python3 -c "import json; d=json.load(open('$W/vo.json')); words=[{'text':s['text'],'start':s['start'],'end':s['end']} for s in d.get('segments',[])] ; json.dump(words,open('$W/vo-words.json','w'))"
elif command -v whisper >/dev/null 2>&1; then
  echo "[faceless] cfw-transcribe not found — falling back to whisper CLI"
  whisper "$W/vo.mp3" --model small --output_dir "$W" --output_format srt
  python3 - "$W/vo.srt" "$W/vo-words.json" <<'PY'
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
  echo "[faceless] FATAL: no transcription tool found (cfw-transcribe, mlx_whisper, or whisper). Install cfw-transcribe." >&2
  exit 1
fi
```

Read `vo.srt`. Map each beat (HOOK, #1, #2 …) to its `[start → end]` window. These SRT timecodes
are GROUND TRUTH — the `data-duration` of each beat composition equals its VO span.

**Save the word-level JSON for `c-broll-sync`:**
```bash
# vo-words.json must be [{text, start, end}] array — verify
python3 -c "import json; d=json.load(open('$W/vo-words.json')); assert isinstance(d,list); print(f'{len(d)} words, first={d[0]}')"
```

---

### 4 — B-roll cue transcription (only if `$BROLL_CLIPS` is set)

**Skip this step entirely when `$BROLL_CLIPS` is empty. Jump to Step 5.**

For each b-roll clip, transcribe its audio to get cue words for `c-broll-sync` transcript-match:

```bash
# box-compat: cfw-transcribe (Gemini backend) needs GEMINI_API_KEY; source from box
# env file so the python subprocess below inherits it. Harmless no-op off-box.
[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_API_KEY=$(grep GEMINI_API_KEY /opt/cfw-agent/.env 2>/dev/null | cut -d= -f2-) || true
export GEMINI_API_KEY
# Build broll_cues.json: [{clip, duration, cues:[{text,start,end}]}]
python3 - "$W" "$BROLL_CLIPS" <<'PY'
import json, os, subprocess, sys, shlex

W = sys.argv[1]
clips = shlex.split(sys.argv[2]) if sys.argv[2].strip() else []
entries = []
for clip in clips:
    clip = clip.strip()
    if not clip:
        continue
    # Probe duration
    dur_out = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "csv=p=0", clip
    ]).decode().strip()
    dur = float(dur_out)
    # Transcribe clip audio for cue matching — same fallback chain as Step 3
    cue_json = f"{W}/broll_cue_{os.path.basename(clip).replace('.', '_')}.json"
    import shutil as _shutil
    cues = []
    try:
        if _shutil.which("cfw-transcribe"):
            subprocess.run(
                ["cfw-transcribe", "--input", clip, "--out", cue_json, "--format", "words"],
                check=True, capture_output=True
            )
            cues = json.load(open(cue_json))
        elif _shutil.which("mlx_whisper"):
            td = os.path.dirname(cue_json)
            subprocess.run(["mlx_whisper", clip, "--model", "mlx-community/whisper-small",
                            "--output-dir", td, "--output-format", "json"],
                           capture_output=True)
            base_json = os.path.join(td, os.path.splitext(os.path.basename(clip))[0] + ".json")
            if os.path.exists(base_json):
                d = json.load(open(base_json))
                cues = [{"text": s["text"], "start": s["start"], "end": s["end"]} for s in d.get("segments", [])]
        elif _shutil.which("whisper"):
            td = os.path.dirname(cue_json)
            subprocess.run(["whisper", clip, "--model", "small", "--output_dir", td,
                            "--output_format", "json"], capture_output=True)
            base_json = os.path.join(td, os.path.splitext(os.path.basename(clip))[0] + ".json")
            if os.path.exists(base_json):
                d = json.load(open(base_json))
                cues = [{"text": s["text"], "start": s["start"], "end": s["end"]} for s in d.get("segments", [])]
    except Exception:
        cues = []  # silent clip — filename heuristic fallback in c-broll-sync
    entries.append({"clip": clip, "duration": dur, "cues": cues})
json.dump(entries, open(f"{W}/broll_cues.json", "w"), indent=2)
print(f"broll_cues.json written: {len(entries)} clips")
PY
```

---

### 5 — OPUS plan the beat list (c-broll-sync)

```bash
node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript "$W/vo-words.json" \
  --broll      "${BROLL_CLIPS:+$W/broll_cues.json}" \
  --coverage   "$BROLL_COVERAGE_PCT" \
  --clip-secs  "$BROLL_CLIP_SECONDS" \
  --min-secs   "$BROLL_MIN_SECONDS" \
  --max-secs   "$BROLL_MAX_SECONDS" \
  --order      "$BROLL_ORDER" \
  --reuse      "$BROLL_REUSE" \
  --bed-dur    "$BED_DUR" \
  --brand      "$W/brand.json" \
  --out        "$W/beat_list.json"

# Verify output
python3 -c "
import json
bl = json.load(open('$W/beat_list.json'))
beats = bl['beats']
print(f'beat_list.json: {len(beats)} beats, achieved_broll={bl.get(\"achieved_broll_pct\",0):.1f}%')
if bl.get('shortfall_note'): print('[c-broll-sync]', bl['shortfall_note'])
kinds = {b['kind'] for b in beats}
print('kinds:', kinds)
"
```

**When `$BROLL_CLIPS` is empty**, pass no `--broll` flag (or an empty file). The planner emits
100% `graphics` beats, reproducing exact fmt4 behavior.

**Read the `beat_list.json`.** The planner tags each beat:
- `kind: "graphics"` — author a HyperFrames composition (may include `scene.type: "typing-ui"`,
  `"hook"`, `"chart"`, `"checklist"`, `"stat"`, etc.)
- `kind: "broll"` — slice the source clip with `broll.in`/`broll.out` via ffmpeg

Also extract the SRT-based beat windows; override any `c-broll-sync`-computed boundary if the SRT
is tighter (SRT is always ground truth for caption timing):

```bash
python3 - "$W/beat_list.json" "$W/vo.srt" <<'PY'
import json, re

bl = json.load(open("$W/beat_list.json"))
# Optionally refine beat windows from SRT here; save amended beat_list.json
print("Beat windows (c-broll-sync output):")
for b in bl["beats"]:
    print(f"  [{b['index']:02d}] {b['start']:.1f}s–{b['end']:.1f}s  {b['kind']}")
PY
```

---

### 6 — Resolve the Visual Identity Gate (ONCE — pass verbatim to every child task)

**Do this BEFORE authoring any beat HTML.**

Resolve in order:
1. Brand Brief (`brand_dna.guidelines`) — appended by the worker. Use its exact palette + typography.
2. Brand `DESIGN.md` / `visual-style.md` if referenced.
3. Named style in `f-hyperframes/visual-styles.md`.
4. Dark-premium default: `bg=#0F172A, accent=#F97316, fg=#F8FAFC`.

Capture the resolved identity as a compact JSON block saved to `$W/brand.json` (if not already
written by the worker):

```bash
# Example (replace with brand-actual values from the Brief):
cat > "$W/brand.json" <<'EOF'
{"bg":"#0F172A","accent":"#F97316","fg":"#F8FAFC","font_display":"Oswald","font_mono":"JetBrains Mono"}
EOF
```

This JSON is forwarded VERBATIM into every `delegate_task` child's context string and into the
`c-broll-sync` `--brand` flag. Children cannot see your gate result — you must pass it explicitly.

---

### 7 — Render graphics beats via parallel delegate_task

> **HARD GATE — DELEGATE ALL GRAPHICS BEATS (mirrors fmt4 Step 4 HARD GATE).**
> Author beats by calling `delegate_task` with a `tasks` array — one task per `graphics` beat.
> Running `npx hyperframes@0.7.5 init` yourself in this loop is a HARD FAILURE.
> Exception: `delegate_task` errors "unavailable" → serial fallback (inline authoring only).

**Parent (Director) does the shared setup ONCE, then delegates ALL graphics beats in a SINGLE call.**

1. Parse `beat_list.json` — extract every beat with `kind === "graphics"`.
2. Build the task array:

```json
delegate_task({
  "tasks": [
    {
      "goal": "Author + render ONE 1080x1920 animated HyperFrames composition for beat 0 (hook); return its MP4 path.",
      "context": "WORK_GFX=<abs_path>/work/gfx | index=0 slug=hook | start=0.0 end=4.2 | data-duration=4.2 | script_line=<this beat VO line> | scene_type=hook | BRAND (verbatim JSON): <brand.json contents> | typing_ui_dir=<TYPING_UI_DIR> | gsap_vendor_dir=<absolute path to f-gsap/vendor — i.e. $SKILL_DIR/.hub/f-gsap/vendor in the pack or $SKILL_DIR/.hub/f-gsap/vendor in the source repo, whichever exists> | RULES: read f-hyperframes/SKILL.md, follow p-reels-faceless Visual doctrine (FOREGROUND HERO; gsap.from() ends-visible; AMBIENT MOTION full window; SVG-only icons; ghost=beat index; Oswald+JetBrains Mono; no remote URLs). The composition's <head> loads GSAP via a LOCAL relative tag <script src=\"gsap.min.js\"></script> — NEVER a CDN URL (the render box blocks outbound library fetches). For scene_type=hook or scene_type=typing-ui: use c-typing-ui templates from typing_ui_dir (standalone render — strip <template> wrapper, wrap in full HTML doc; use FULL variant for faceless). For scene_type=standard or omitted: author a brand motion-graphic (chart/terminal/checklist/stat/diagram). RUN: npx hyperframes@0.7.5 init beatN-slug --non-interactive -> author index.html -> cp \"$gsap_vendor_dir/gsap.min.js\" beatN-slug/gsap.min.js (REQUIRED before render so the local <script src=\"gsap.min.js\"> resolves; if it references TextPlugin/MotionPathPlugin copy those too) -> npx hyperframes@0.7.5 lint (0 errors REQUIRED) -> npx hyperframes@0.7.5 render --output beatN-slug.mp4 --fps 30 --quality high. RETURN: absolute MP4 path + confirm lint=0. ONLY touch your own beat folder.",
      "toolsets": ["terminal", "skills", "web"]
    }
  ]
})
```

   Add one task object per additional `graphics` beat. `broll` beats are NOT delegated — they are
   handled in Step 8 with ffmpeg.

3. Collect every child's returned MP4 path. Verify each: `ffprobe codec_type=video` + non-empty.
4. For any failed beat: re-delegate once. If still fails, author inline (serial fallback). Never
   concat a missing beat.

**Per-beat authoring spec (what each delegate_task CHILD executes):**

For `kind: "graphics"` beats whose `scene.type` is NOT `typing-ui` or `hook`:
Author a full-frame 1080×1920 GSAP composition as in fmt4 Step 4 — genuine animated diagram/chart/
terminal/checklist in the brand palette. The composition shape:

```html
<!doctype html><html><head>
  <script src="gsap.min.js"></script>
  <style>/* opaque bg, glow, faint grid, ghost number, scene flex column */</style>
</head><body>
  <div id="root" data-composition-id="main" data-start="0" data-duration="<beat_span>"
       data-width="1080" data-height="1920">
    <div class="bg-glow"></div><div class="grid"></div><div class="ghost"><beat_index></div>
    <div class="scene"> ...beat hero content with ids... </div>
  </div>
  <script>
    window.__timelines = window.__timelines || {};
    const tl = gsap.timeline({ paused: true });
    // every element animates IN via gsap.from(); ambient motion runs full duration
    window.__timelines["main"] = tl;
  </script>
</body></html>
```

For `kind: "graphics"` beats with `scene.type: "typing-ui"` or `scene.type: "hook"`:
Use `c-typing-ui` **FULL variant** (not `pip-safe` — there is no PIP in this format):

```bash
# Standalone render from c-typing-ui templates
python3 - "$TYPING_UI_DIR/templates/typing-scene.html" "$WORK_GFX/beatN-typing/index.html" <<'PY'
import sys, html as h, re
replacements = {
    "DURATION":     "<beat_span>",
    "LABEL":        "claude.ai",       # or "Terminal" — choose based on scene content
    "PROMPT":       h.escape("<prompt text from scene spec>"),
    "TYPING_SPEED": "1.0",
    "ACCENT":       "<brand_accent_hex_no_hash>",
    "VARIANT":      "full",             # full = no PIP safe zone, fills the whole frame
    "BOTTOM_TAG":   "<optional mono caption>",
}
src, dst = sys.argv[1], sys.argv[2]
tmpl = open(src).read()
tmpl = re.sub(r'<template[^>]*>\s*', '', tmpl)
tmpl = re.sub(r'\s*</template>', '', tmpl)
for k, v in replacements.items():
    tmpl = tmpl.replace("{{" + k + "}}", v)
with open(dst, "w") as f:
    # BUG FIX: GSAP must be loaded in <head> for the standalone HyperFrames render.
    # The <template> wrapper was stripped above; the root div must carry
    # data-composition-id, data-start, data-duration for HyperFrames lint to pass.
    # window.__timelines["root"] = tl (dict form) is required — NOT .push().
    f.write(f"<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
            "<script src=\"gsap.min.js\"></script>"
            "<style>html,body{{margin:0;padding:0;width:1080px;height:1920px;overflow:hidden;background:#0F172A;}}</style>"
            f"</head><body>{tmpl}</body></html>")
PY
# box-compat: gpt-5.5 sometimes emits a double-hash hex (##0F172A) → white bg. Collapse it
# before lint/render (brand accent + prompt content flow in from the scene spec).
sed -i 's/##/#/g' "$WORK_GFX/beatN-typing/index.html"
# Vendor GSAP into the comp dir so the local <script src="gsap.min.js"> resolves at render.
# f-gsap is vendored under .hub/ in the pack and a sibling dir in the source repo.
# NEVER fall back to a CDN — the render box blocks outbound library fetches.
# Prefer the child-passed $gsap_vendor_dir; else resolve from $SKILL_DIR.
GSAP=$(for p in "$gsap_vendor_dir" "$SKILL_DIR/.hub/f-gsap/vendor" "$SKILL_DIR/.hub/f-gsap/vendor"; do [ -n "$p" ] && [ -f "$p/gsap.min.js" ] && echo "$p/gsap.min.js" && break; done)
[ -n "$GSAP" ] || { echo "[p-reels-faceless] FATAL: vendored gsap.min.js not found (expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/)"; exit 1; }
cp "$GSAP" "$WORK_GFX/beatN-typing/gsap.min.js"
# Lint + render
cd "$WORK_GFX/beatN-typing" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output beatN-typing.mp4 --fps 30 --quality high
```

---

### 8 — Prepare b-roll beat segments (only if `beat_list.json` contains any `broll` beats)

For each `kind: "broll"` beat, slice the source clip:

```bash
python3 - "$W/beat_list.json" "$W" <<'PY'
import json, subprocess, os

bl   = json.load(open("$W/beat_list.json"))
FF   = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
broll_segments = {}

for b in bl["beats"]:
    if b["kind"] != "broll":
        continue
    clip   = b["broll"]["clip"]
    t_in   = b["broll"]["in"]
    t_out  = b["broll"]["out"]
    dur    = round(t_out - t_in, 3)
    slug   = f"broll_{b['index']:02d}"
    out    = f"$W/seg-{slug}.mp4"
    # Probe source — must be local file
    subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                    "-of", "csv=p=0", clip], check=True, capture_output=True)
    # FIT + BLURRED-FILL composite: replaces scale-to-COVER (increase+crop) which
    # cropped non-9:16 sources like website screen-captures badly.  The clip is shown
    # whole; a heavy-blurred zoomed copy fills the frame edges.  For true 9:16 clips
    # the fit copy == the frame — blurred-fill is a harmless no-op.
    # Blur strength: boxblur=40:2 (tunable; stronger = more separation from fg).
    subprocess.run([
        FF, "-y", "-ss", str(t_in), "-i", clip, "-t", str(dur),
        "-vf", (
            "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,"
            "boxblur=40:2,setsar=1[bg];"
            "[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,setsar=1[fg];"
            "[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"
        ),
        "-map", "[bv]",
        "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", out
    ], check=True)
    broll_segments[b["index"]] = out
    print(f"  broll beat {b['index']}: {clip} [{t_in:.1f}–{t_out:.1f}s] → {out}")
print("broll segments prepared:", list(broll_segments.keys()))
PY
```

---

### 9 — Normalize + concat all segments in beat order

Collect graphics MP4s (from Step 7) and b-roll segments (from Step 8) in beat order. Normalize
each to uniform encode (30fps / yuv420p / 1080×1920) and concat:

```bash
python3 - "$W/beat_list.json" "$W" <<'PY'
import json, subprocess, os

bl   = json.load(open("$W/beat_list.json"))
FF   = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
seglist = []

for b in sorted(bl["beats"], key=lambda x: x["index"]):
    idx = b["index"]
    if b["kind"] == "broll":
        raw = f"$W/seg-broll_{idx:02d}.mp4"
    else:
        # Graphics beat — path returned by delegate_task child (stored in a lookup table)
        # Resolve from known naming convention: gfx/<slug>/<slug>.mp4
        slug = b.get("slug", f"beat{idx}")
        raw = f"$W/gfx/{slug}/{slug}.mp4"
    # Normalize
    out = f"$W/seg-norm-{idx:02d}.mp4"
    subprocess.run([
        FF, "-y", "-i", raw,
        "-vf", "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p",
        "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", out
    ], check=True)
    seglist.append(out)
    print(f"  seg {idx:02d}: {out}")

with open("$W/seglist.txt", "w") as f:
    for s in seglist:
        f.write(f"file '{s}'\n")
print(f"seglist.txt: {len(seglist)} segments")
PY

$FF -y -f concat -safe 0 -i "$W/seglist.txt" -c copy "$W/body-video.mp4"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 "$W/body-video.mp4"
```

---

### 10 — Mux VO onto body

The graphics track carries no audio — mux the loudnormed bed once:

```bash
$FF -y -i "$W/body-video.mp4" -i "$W/vo-normed.aac" \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 -shortest \
  "$W/body.mp4"
```

---

### 11 — Brand outro (generated card or supplied clip)

**Every reel MUST end with a brand outro — MANDATORY.**

**Default path — generated brand-card outro beat:**
Author ONE final HyperFrames composition (same pipeline as any graphics beat) as the closing card
AFTER the last content beat. Sequence it at the END of `seglist.txt` before the concat in Step 9
(or re-run the concat including the outro segment):

- Brand name as the HERO headline (from Brand Brief / `brand_dna.name`).
- Brand tagline / one-line value prop below it.
- "Follow for more" CTA chip + `@handle` if known.
- ~3–4s, same ghost/grid/glow system, brand palette. Animate with `gsap.from()`.
- SVG/CSS only — no tofu.
- The outro `index.html` loads GSAP via a LOCAL `<script src="gsap.min.js"></script>` (never a CDN).
  **Copy the vendored GSAP into the outro comp dir before rendering** so that tag resolves:

```bash
# Before `npx hyperframes@0.7.5 render` in the outro comp dir (e.g. $W/gfx/outro-brand):
OUTRO_DIR="$W/gfx/outro-brand"
GSAP=$(for p in "$SKILL_DIR/.hub/f-gsap/vendor" "$SKILL_DIR/.hub/f-gsap/vendor"; do [ -f "$p/gsap.min.js" ] && echo "$p/gsap.min.js" && break; done)
[ -n "$GSAP" ] || { echo "[p-reels-faceless] FATAL: vendored gsap.min.js not found (expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/)"; exit 1; }
cp "$GSAP" "$OUTRO_DIR/gsap.min.js"
# then: cd "$OUTRO_DIR" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output outro-brand.mp4 --fps 30 --quality high
```

```bash
# After authoring and rendering outro-brand/outro-brand.mp4:
$FF -y -i "$W/outro-brand.mp4" \
  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -an -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p "$W/seg-outro.mp4"
```

Add a trailing silent audio segment to let the brand card play after the VO ends:

```bash
OUTRO_DUR=3.5
$FF -y -f lavfi -i anullsrc=r=48000:cl=stereo -t "$OUTRO_DUR" -c:a aac "$W/outro-silence.aac"
```

Then concat body + outro segment and mux the extended audio:

```bash
printf "file '$W/body-video.mp4'\nfile '$W/seg-outro.mp4'\n" > "$W/full-seglist.txt"
$FF -y -f concat -safe 0 -i "$W/full-seglist.txt" -c copy "$W/full-video.mp4"
$FF -y -i "$W/vo-normed.aac" -i "$W/outro-silence.aac" \
  -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[a]" \
  -map "[a]" -c:a aac -b:a 192k -ar 48000 -ac 2 "$W/full-audio.aac"
$FF -y -i "$W/full-video.mp4" -i "$W/full-audio.aac" \
  -map 0:v -map 1:a -c:v copy -c:a copy -shortest "$W/with-outro.mp4"
```

**Override path — supplied `$OUTRO` clip** (skip default; localize + ffprobe it first):

```bash
# Only if OUTRO is supplied
$FF -y -i "$W/body.mp4" -i "$OUTRO" \
  -filter_complex "\
[0:v]scale=1080:1920,fps=30,setsar=1[v0];[1:v]scale=1080:1920,fps=30,setsar=1[v1];\
[0:a]aresample=48000,aformat=channel_layouts=stereo[a0];[1:a]aresample=48000,aformat=channel_layouts=stereo[a1];\
[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart "$W/with-outro.mp4"
```

The finished reel variable going forward: `ASSEMBLED="$W/with-outro.mp4"` (or `"$W/body.mp4"` if
the outro was already merged).

---

### 12 — c-reel-premium: kinetic captions + SFX + grade

```bash
# Words JSON for caption timing — the VO word transcript
WORDS_JSON="$W/vo-words.json"

# Run c-reel-premium Steps P1–P4 (follow its SKILL.md)
# Key defaults for this format:
#   CAPTIONS=on   (TTS-over-graphics; captions are the primary text layer; ON by default)
#   SFX=on        (whoosh/impact/riser cues lift beat transitions)
#   GRADE=<planner picks from plan.json, or warm-amber default>
#   REEL_IN="$ASSEMBLED"
#   REEL_OUT="$W/premium.mp4"
```

If `c-reel-premium` is not available:

```bash
# Minimal fallback: captions off, no SFX, no grade — just output the assembled reel
cp "$ASSEMBLED" "$W/premium.mp4"
echo "[p-reels-faceless] WARNING: c-reel-premium not found; premium polish skipped"
```

---

### 12.5 — Overlay-FX beats (OPTIONAL — Director-placed, OFF by default)

Default behavior is unchanged: a no-op unless the Director supplies `overlay_beats`. When set, the
Director MAY drop 1–3 animated overlay graphics (pill / sticker / mini-flowchart) on top of the
assembled reel at chosen beats, via `c-overlay-fx`. Each overlay renders to a transparent (alpha)
clip and is `overlay`-composited over `premium.mp4` — the picture underneath is never re-encoded
into the graphic.

**The Director picks BOTH the moment AND a SAFE position from the map below.** An overlay must NEVER
cover the active graphics text or the burned captions.

**Safe-zone map — `faceless` format (1080×1920):** there is no face, so there is more room — but the
full-frame graphics beat owns the center. **SAFE = the four corners and the lower third** (below the
hero content, above the caption band), avoiding wherever the active beat's graphics text sits. Read
the current beat's layout and keep the overlay clear of its hero element.

```bash
# overlay_beats: a JSON array the Director sets, e.g.
#   [{"type":"pill","text":"STEP 1","position":{"x":120,"y":1500},"start":4.0,"duration":3.0}]
# Each spec also carries brand context. Empty/unset → skip entirely (default).
OVERLAY_BEATS="${overlay_beats:-[]}"
if [ "$(echo "$OVERLAY_BEATS" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -gt 0 ]; then
  OVERLAY_FX_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-overlay-fx 2>/dev/null | head -1)
  [ -z "$OVERLAY_FX_DIR" ] && { echo "[p-reels-faceless] overlay_beats set but c-overlay-fx not found — skipping"; OVERLAY_BEATS="[]"; }
fi
if [ "$(echo "$OVERLAY_BEATS" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -gt 0 ]; then
  CUR="$W/premium.mp4"
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
    $FF -y -i "$CUR" -itsoffset "$ST" -i "$OVPNG" \
      -filter_complex "[0:v][1:v]overlay=${X}:${Y}:format=auto:enable='between(t,${ST},${EN})'[v]" \
      -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -preset medium -crf 19 \
      -c:a copy -movflags +faststart "$W/premium-ov-$i.mp4"
    CUR="$W/premium-ov-$i.mp4"
  done
  LAST=$(ls -1 "$W"/premium-ov-*.mp4 2>/dev/null | sort -V | tail -1)
  [ -n "$LAST" ] && cp "$LAST" "$W/premium.mp4"
fi
```

---

### 13 — First-frame cover rule (§2d — MANDATORY)

> IG/TikTok use frame 1 of the MP4 as the default feed poster. The hook scene animates in from
> black → frame 1 is blank → blank thumbnail. The canonical fix: prepend a 0.4s money-shot freeze.

**The OPUS beat planner (Step 5) should have tagged a `cover_at` timestamp** — a mid-content
moment past the hook. If not, pick `cover_at = bed_duration × 0.35` (early-mid of body, never
the hook).

```bash
COVER_AT="${COVER_AT:-$(python3 -c "print(round(float($BED_DUR)*0.35,1))")}"
REEL_IN="$W/premium.mp4"

# Step 1: Extract the money-shot frame
$FF -y -ss "$COVER_AT" -i "$REEL_IN" -frames:v 1 -q:v 2 "$W/cover.png"
file "$W/cover.png"   # must be a real PNG

# Step 2: Freeze to a 0.4s clip (silent stereo, reel specs)
$FF -y -loop 1 -i "$W/cover.png" -f lavfi -i anullsrc=r=48000:cl=stereo \
  -t 0.4 \
  -vf "scale=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  "$W/cover-freeze.mp4"

# Step 3: Prepend via concat (re-encode to avoid non-monotonic DTS from -c copy)
# NOTE: cover-freeze already uses -f lavfi -i anullsrc (correct lavfi input form) above.
# Re-encode here guarantees matching stream parameters across independently-encoded clips.
printf "file '$W/cover-freeze.mp4'\nfile '$REEL_IN'\n" > "$W/cover-concat.txt"
$FF -y -f concat -safe 0 -i "$W/cover-concat.txt" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart \
  "$OUT_DIR/faceless-reel-with-cover.mp4"

echo "cover.png extracted at ${COVER_AT}s → prepended 0.4s"
```

Final deliverable: `faceless-reel-with-cover.mp4` (feed thumbnail = money shot) + `cover.png`
(explicit Output thumbnail).

---

### 14 — Visual QA Gate (MANDATORY — vision + proof of motion)

> A render that was never looked at is NOT done.

**Mechanical checks:**

```bash
FINAL="$OUT_DIR/faceless-reel-with-cover.mp4"
$FF -v error -i "$FINAL" -f null -                                        # clean decode = no output
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
  -show_entries format=duration -of default=nw=1 "$FINAL"
$FF -sseof -4 -i "$FINAL" -af volumedetect -f null - 2>&1 | grep mean_volume   # outro has audio
```

Assert 1080×1920 (9:16), video+audio streams, duration in `$TARGET`, clean decode.

**Extract 6 sample frames across the reel:**

```bash
FDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL")
for pct in 05 20 40 60 80 95; do
  T=$(python3 -c "print(round(${pct}/100*$FDUR,2))")
  $FF -y -ss "$T" -i "$FINAL" -frames:v 1 -q:v 2 "$W/qa_frame_${pct}.png"
done
```

**READ each frame with vision. Check ALL of:**

- [ ] **(a)** No overlapping / jumbled text (one beat's text at a time).
- [ ] **(b)** For graphics beats: brand motion graphic, not a photo or blank rectangle.
      For b-roll beats: real footage, scale-to-cover (fills frame), no black bars.
- [ ] **(c)** Text legible at mobile size (60px+ headlines, AA contrast).
- [ ] **(d)** Brand colors correct (from Visual Identity Gate; not defaulted to white-on-black).
- [ ] **(e)** No `□` tofu boxes — if found, the icon is a unicode glyph → replace with inline SVG.
- [ ] **(f)** Ghost glyph is a thematic number/letter, not a placeholder word.
- [ ] **(g)** FOREGROUND PRESENT on every graphics beat — headline + diagram dominant, not ghost-only.
- [ ] **(h)** Brand outro at ~97% of the reel (brand name + CTA, not a content beat).
- [ ] **(i)** Cover freeze at t≈0 shows the money shot (not a black frame or hook anim).

**Per-beat motion proof — EVERY beat (not just beat 1):**

```bash
# For each beat N with window [start, end]:
# t_early = start + 0.25*(end-start), t_late = start + 0.75*(end-start)
# Skip this proof for broll beats (real footage inherently differs frame-to-frame).
$FF -y -ss <t_early> -i "$FINAL" -frames:v 1 "$W/beatN_a.png"
$FF -y -ss <t_late>  -i "$FINAL" -frames:v 1 "$W/beatN_b.png"
$FF -i "$W/beatN_a.png" -i "$W/beatN_b.png" -lavfi psnr -f null - 2>&1 | grep average
# PASS: average PSNR ≤ 45 dB (frames visibly differ → real motion).
# FAIL: inf (frozen still) OR ≥ 50 dB (near-identical → slideshow card, not a motion graphic).
```

**If ANY check fails: fix the composition and re-render. NEVER upload a reel that fails this gate.**

---

### QA gate (MANDATORY — run before upload)

Run the shared eval engine (`c-eval-runner`) on the final MP4. It reads this
recipe's `acceptance.json`, delegates the mechanical gate to `c-shorts-qa-gate`,
runs the faceless-specific geometry checks, and writes a structured `scorecard.json`.
**Do NOT upload if it exits non-zero (verdict FAIL).**

```bash
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_MP4> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → <video_dir>/eval/scorecard.json ; frame sweep → <video_dir>/eval/
```

- **HARD** (verdict FAIL, exit 1, blocks delivery): mechanical gate (loudness ≈ -14
  LUFS, frame-0 brightness > 0x30, resolution/fps, audio present), duration 30–90s,
  canvas exactly 1080×1920, no black frames on any sampled timestamp.
- **PERCEPTUAL** (verdict NEEDS_VISION until resolved): the Step 14 (a)–(i) checks
  are emitted as PENDING criteria with a frame sweep — resolve them with a vision
  pass (read the frames or run `c-vision-qa`) and set each pass/fail before upload.

The full checklist lives in `acceptance.json` (the per-recipe spec). A brand may layer
`brand-overrides/<brand-slug>/acceptance.json` to tighten thresholds (same id wins,
new ids appended). If any HARD check fails, fix the render and re-run — never deliver
a failing gate.

**Interim gates (fail-fast, recommended on expensive runs):**
```bash
bash .hub/c-eval-runner/scripts/eval-run.sh vo-normed.aac --recipe-dir "$SKILL_DIR" --step voicebed    # after Step 2
bash .hub/c-eval-runner/scripts/eval-run.sh body.mp4      --recipe-dir "$SKILL_DIR" --step assembled    # after Step 9
```
See `.hub/c-eval-runner/SKILL.md` for the spec format + built-in checks, and
`cfw-skills-pack/docs/skills-audit.md` §4 for the generic eval architecture.

### 14.9 — DELIVERY GATE (MECHANICAL · HARD · blocks upload)

**Runs immediately before upload. If it exits non-zero, STOP — do NOT upload or propose.** It
proves mechanically that the premium pass actually ran (via the stamp c-reel-premium writes) and
that the eval scorecard is not FAIL, so a degraded reel can't ship silently.

```bash
FINAL="$OUT_DIR/faceless-reel-with-cover.mp4"
python3 - "$FINAL" "$W" "$OUT_DIR" <<'PY' || { echo "🚫 DELIVERY BLOCKED — fix the render/premium pass and re-run; do NOT upload."; exit 1; }
import os, sys, json, glob, subprocess
FINAL, W, OUT_DIR = sys.argv[1], sys.argv[2], sys.argv[3]
fail = []
# 1) premium stamp (c-reel-premium writes .gate/premium.json next to its output — search the work tree)
stamps = glob.glob(f"{W}/**/.gate/premium.json", recursive=True) + glob.glob(f"{OUT_DIR}/**/.gate/premium.json", recursive=True)
if not any(json.load(open(s)).get("applied") for s in stamps if os.path.exists(s)):
    fail.append("premium stamp missing — c-reel-premium did not run (raw caption burns are a defect).")
# 2) eval scorecard present + not FAIL
sc = os.path.join(os.path.dirname(os.path.abspath(FINAL)), "eval", "scorecard.json")
if not os.path.exists(sc):
    fail.append("c-eval-runner scorecard missing — run the QA gate before delivery.")
elif json.load(open(sc)).get("verdict") == "FAIL":
    fail.append("c-eval-runner scorecard verdict = FAIL.")
# 3) final MP4 valid + 1080x1920
p = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","json", FINAL], capture_output=True, text=True)
if p.returncode != 0:
    fail.append(f"final MP4 {FINAL} not a valid video.")
else:
    s = json.loads(p.stdout)["streams"][0]
    if (s["width"], s["height"]) != (1080, 1920):
        fail.append(f"final dims {s['width']}x{s['height']} != 1080x1920.")
if fail:
    print("DELIVERY GATE FAILURES:")
    for f in fail: print(f"  ✗ {f}")
    sys.exit(1)
print("✅ DELIVERY GATE PASSED — premium pass + eval verified. OK to upload.")
PY
```

### 15 — Upload to R2 and print the URL (FINAL LINE)

```bash
bash _scripts/upload-to-recordings.sh "$OUT_DIR/faceless-reel-with-cover.mp4"
# → https://media.cfw.social/.../faceless-reel-with-cover.mp4
```

Also upload `cover.png` as a separate Output thumbnail if the production system supports it.

Clean up interim files:

```bash
rm -rf "$W/gfx" "$W/seg-"*.mp4 "$W/cover-concat.txt" "$W/full-seglist.txt"
```

**Print the R2 public URL as the FINAL LINE of output.**
NEVER print an input URL or a local file path as the result.

---

## Degenerate case — no b-roll (fmt4 compatibility)

When `$BROLL_CLIPS` is empty:
- Step 4 is skipped (no b-roll cue transcription).
- Step 5: `c-broll-sync` is called without `--broll`; the planner emits 100% `graphics` beats.
- Step 8 is skipped (no b-roll segments to slice).

All other steps run identically. The result is a fully-animated motion-graphics reel with no stock
footage — exactly what `p-reels-fmt4` produced. The ambient-motion rule, Visual QA Gate, cover
rule, and premium polish are all applied. **There is no degradation in the no-broll path.**

---

## Anti-patterns (NEVER do these)

- **NEVER render a beat as a still + Ken Burns zoom.** Every graphics beat is a real GSAP-animated
  HyperFrames composition. The motion proof (PSNR ≤ 45 dB) enforces this.
- **NEVER skip the Visual Identity Gate.** No composition HTML until the palette + typography are
  resolved. Reaching for `#333`, `#3b82f6`, or `Roboto` means you skipped it.
- **NEVER use a unicode emoji or icon-font glyph as an icon.** Headless render = no emoji font.
  Every icon is inline SVG or CSS. No exceptions.
- **NEVER let a beat pop in then freeze.** Continuous ambient motion for the full `data-duration`
  (slow yoyo/breathe/drift). Step 14 motion proof FAILS at ≥ 50 dB.
- **NEVER ship a beat that shows only the ghost number.** The foreground hero (headline + diagram)
  must be bright and dominant. Ghost-only = UNBUILT beat → fix `gsap.from()` and re-render.
- **NEVER reference remote media URLs inside a composition.** Local relative paths only; download
  + ffprobe every asset before authoring.
- **NEVER let text beats overlap in time.** One composition per beat, concatenated.
- **NEVER skip the Visual QA Gate — a render that was never looked at is not done.**
- **NEVER skip the first-frame cover rule.** A blank feed thumbnail is a defect.
- **NEVER end on a content beat.** Every reel closes on the brand outro.
- **NEVER upload without printing the R2 URL as the final line.**
- **NEVER output an input URL as the result.** The final line is the R2 URL of the rendered reel.
- **NEVER QA only beat 1.** The motion + foreground proof runs on EVERY graphics beat.
- **NEVER use c-typing-ui pip-safe variant for this format.** Always use `full` — there is no PIP.

---

## Box-compat gotchas (Ubuntu 22.04 / Hermes — folded from on-box validation)

- **Source `GEMINI_API_KEY` before `cfw-transcribe`** (Steps 3 and 4). cfw-transcribe's Gemini backend
  reads it from the env; on-box it lives in `/opt/cfw-agent/.env`, not the shell. The guard
  `[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_API_KEY=$(grep ... /opt/cfw-agent/.env ...)` is a no-op
  off-box. Step 4's cfw-transcribe runs inside a python subprocess, so the export must happen in that
  step's bash before the heredoc (it inherits the env).
- **`##` CSS guard.** gpt-5.5 occasionally emits a double-hash hex (`--bg: ##0F172A`) → white background.
  After writing ANY generated HyperFrames HTML, collapse double-hash to single — `sed -i 's/##/#/g'`.
  Applied in-skill to the typing-ui HTML (Step 7). **Every `delegate_task` graphics CHILD must do the
  same** on its authored `index.html` before `npx hyperframes@0.7.5 lint` (add `sed -i 's/##/#/g' index.html`
  to the per-beat authoring step).
- **Three.js linter no-op.** The HyperFrames linter false-flags any composition whose text contains the
  literal "THREE" (e.g. a beat hero "THREE.") as a missing-Three.js error. Inject a harmless Three.js
  CDN `<script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>` into that
  composition's `<head>` to satisfy the linter — it is never used at runtime. (Children authoring beat
  HTML must apply this when their beat text contains "THREE".)
- **(ffprobe csv / claude --print / CTA-HyperFrames patches N/A here.)** Faceless has no `read W H < <(...)`
  multi-field ffprobe (the `width,height` ffprobe in Step 9 is a diagnostic echo), no direct
  `claude --print` planning call (planning is via `c-broll-sync` + `delegate_task`), and no HyperFrames
  CTA fallback (the outro in Step 11 is a generated/​supplied card) — so those three box patches do not
  apply to this core.

---

## Fallbacks

- **TTS unavailable:** skip VO; use a music bed. The beat compositions + b-roll still carry the story.
- **HyperFrames render genuinely fails** (`npx hyperframes@0.7.5 doctor`; report EXACT error first):
  only then drop to still + `zoompan` Ken Burns (v3 path, last resort — not acceptable as default).
- **c-broll-sync unavailable:** fall back to 100% graphics (fmt4 path) and log a warning.
- **c-reel-premium unavailable:** output the assembled reel without captions/SFX/grade; log warning.
- **Fail fast:** if TTS returns non-MP3, if a beat renders as a photo instead of a brand graphic,
  or if PSNR comes back `inf` (frozen still) — stop and report. Never ship a still as animation.

---

## Output

One 9:16 (1080×1920) H.264+AAC MP4 faceless premium reel:
- TTS voiceover in the brand voice as the unbroken audio bed.
- Full-frame background: b-roll beats at the planned coverage + motion-graphics beats for the rest
  (charts / terminals / typing-UI / diagrams / checklists — one real animated HyperFrames
  composition per graphics beat).
- Kinetic word-synced captions + SFX + cinematic grade (`c-reel-premium`).
- First-frame cover freeze (0.4s money shot) → non-blank IG/TikTok feed thumbnail.
- Brand outro (generated card or supplied clip).

No talking head. No avatar. No static stills. Uploaded to R2.
**The R2 public URL is the final line of output.**
