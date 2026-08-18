---
name: p-reels-split
description: Turn an uploaded talking-head video into a premium 9:16 reel with a clean 50/50 vertical split — the TOP half (y 0→960) holds transcript-synced motion graphics and b-roll; the BOTTOM half (y 960→1920) is the speaker's face, scaled to fill the zone (blurred-fill if the aspect ratio mismatches). The talking head's own voice is the single audio bed. This is the "split-screen" archetype: neither face overlaps graphics, nor is the face reduced to a small inset. Trigger on "split-screen reel", "top graphics bottom face", "50/50 reel", "split-screen talking head", "face on the bottom half", "graphics on top face on bottom".
when-to-use: Use when the user uploads their own talking-head clip (real face + real voice — NOT a HeyGen avatar) and wants a 9:16 reel where the face occupies the full bottom half and transcript-synced graphics / b-roll occupy the full top half. NO overlap between the two zones. Distinct from: p-reels-spotlight (full-frame face, no graphics split), p-reels-pip (small rounded PIP inset over a full-frame background), p-reels-faceless (no talking head at all). The split is always 50/50 — 960px each half on a 1080×1920 canvas.
version: 1.1.0
kind: pipeline
visibility: catalog
produces:
  dish: Uploaded Talking-Head Split-Screen Reel
  format: 9:16 vertical video
  duration: 20-60s
inputs: [talking_head_video, broll, known_transcript, outro, broll_style, bottom_cutzoom]
dependsOn: [c-ffmpeg, c-audio, c-reel-premium, c-broll-sync, c-typing-ui, f-hyperframes, f-hyperframes-cli, f-gsap, c-overlay-fx, wowx-motions, c-shorts-qa-gate, c-eval-runner]

  hermes:
    vendored: [c-reel-premium, c-broll-sync, c-typing-ui, c-ffmpeg, c-audio, f-hyperframes, f-hyperframes-cli, f-gsap, c-overlay-fx, wowx-motions, c-shorts-qa-gate]
metadata:
  hermes:
    vendored:
      - { name: c-audio, load: ".hub/c-audio/SKILL.md" }
      - { name: c-broll-sync, load: ".hub/c-broll-sync/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-overlay-fx, load: ".hub/c-overlay-fx/SKILL.md" }
      - { name: c-reel-premium, load: ".hub/c-reel-premium/SKILL.md" }
      - { name: c-shorts-qa-gate, load: ".hub/c-shorts-qa-gate/SKILL.md" }
      - { name: c-typing-ui, load: ".hub/c-typing-ui/SKILL.md" }
      - { name: f-gsap, load: ".hub/f-gsap/SKILL.md" }
      - { name: f-hyperframes, load: ".hub/f-hyperframes/SKILL.md" }
      - { name: f-hyperframes-cli, load: ".hub/f-hyperframes-cli/SKILL.md" }
      - { name: wowx-motions, load: ".hub/wowx-motions/SKILL.md" }
    progressive: true
---




> ## ⚡ Frame integrity + integrated CTA (MANDATORY — 2026-06-16)
> - **Frame 0 is NEVER black.** The first frame must be a bright money-shot — the cover-freeze of the strongest illustrative beat (Step 10 cover rule). Verify `ffmpeg ... signalstats` → `YAVG > 30`. No black / hook-blank / fade-in opener.
> - **The LAST frame is NEVER black.** The reel must end on content, not a fade-to-black or trailing blank. Verify the final frame `YAVG > 30`.
> - **CTA is integrated by DEFAULT, not optional.** Every reel/VSL ends on a branded **CTA beat baked into the timeline** (offer line + handle/URL), as the final illustrative HyperFrames card. Do not ship a reel whose last beat is filler or black. (In p-reels-split this is the Step 9 CTA takeover; other recipes must add an equivalent closing CTA card.)

> ## ⚡ HyperFrames = illustrative, NOT just titles (MANDATORY — 2026-06-16)
> Every HyperFrames graphics scene MUST pair its title with an **illustrative animation that depicts the point** — never a bare kinetic title card. Examples: a 45-post feed grid staggering in (`back.out`), a count-up stat with day-dots, an animated waveform for "voice", platform chips popping in. Match the premium reference in `cfw-marketing/creatives/productions/restaurants-vsl/hyperframes` (`DIAG-calendar` feed-grid, `HF-*` motion) **and** `cfw-marketing/creatives/productions/fnb-split-screen-short/gen-rich-cards.py`: grid + glow + vignette background, GSAP eased + staggered elements, brand palette, depth (shadows/shine). **Make it as rich and premium as possible — a title-only card is a defect.**

> ## ⚡ LOCKED FORMAT — identical for EVERY brand (MANDATORY — 2026-06-18)
> This is the approved house format for ALL brands (mr-growth-guide, cfw-social, b-vasanth, demo
> brands — everyone). The **structure below never changes**. The ONLY things that vary per brand are
> the **background color, font/accent colors, and some visualizations** — pulled from the brand's
> visual identity. Everything else is fixed at 100%. Reference builds: the MGG navy "Claude Opus
> free on AWS" reel + `cfw-marketing/creatives/productions/fnb-split-screen-short/`.
>
> 1. **9:16 1080×1920, hard 50/50 split at y=960 (`vstack`, never overlay).**
> 2. **Top zone = 5-second beat grid** alternating illustrative HyperFrames cards ↔ b-roll. B-roll
>    is **wrapped as a rounded card with a brand-accent border on the brand bg** (not full-bleed).
> 3. **CARDS MUST FILL THE FULL 960px ZONE** — eyebrow + title up top, illustration **vertically
>    centered and enlarged** to occupy the middle/lower zone. A card with content crammed at the top
>    and a black void below is a **defect**. (Chips: large, stacked, ~680px wide. Bignum: ~340–380px.)
> 4. **Bottom zone = HeyGen Avatar III.** If the avatar is a **greenscreen** render, chroma-key
>    (`chromakey`+`despill`) and place it on the **SAME brand background** as the cards so top+bottom
>    read as one designed piece.
> 5. **CAPTIONS = BIG, AT THE SEAM.** Word-synced kinetic captions, **~86px Montserrat Bold**,
>    centered, positioned **at the split line (`\an5\pos(540,~1012)`)**, with **ONE accent-color
>    keyword per chunk** and a fade+pop entrance. NOT tiny, NOT floating high in the top zone. This
>    big seam caption is the signature of the format (the fnb "REAL BAKERY'S" treatment).
> 6. **Premium pass:** brand grade (`eq`+`unsharp`), whoosh SFX at every beat seam + a pop on the
>    hook, audio **loudnorm to −14 LUFS / −1.5 dBTP** (raw HeyGen is ~−22 LUFS).
> 7. **Avatar cut-zoom** optional polish: ~1.0× on b-roll beats, ~1.1–1.4× punch-in on card beats.
>
> **Per-brand variables ONLY:** bg color, accent/font colors, specific visualizations. Pull from the
> brand's `.config/brand.yaml` / visual identity. Cross-brand SOP: `brain-personal →
> vasanth-hq/sops/short-form-reel-recipe`.

# p-reels-split — 50/50 Split-Screen Reel from Uploaded Talking-Head Video

Produces one 9:16 (1080×1920) H.264 MP4 with two equal zones:

```
┌──────────────────────────────┐  1080×1920
│  TOP ZONE    (y 0 → 960)     │  ← transcript-synced graphics (HyperFrames) or
│                              │     uploaded b-roll (BLURRED-FILL, 1080×960 crop).
│   [ graphics / b-roll ]      │     c-broll-sync plans this zone's beat list.
│                              │     All content and captions live here.
├──────────────────────────────┤  ← hard split line at y=960
│  BOTTOM ZONE (y 960 → 1920)  │  ← talking-head face, scaled to fill 1080×960.
│                              │     BLURRED-FILL if aspect ratio mismatches
│   [ talking-head face ]      │     (face shown whole, no cropping — blurred copy
│                              │     fills any side gaps if source is not 16:9+).
└──────────────────────────────┘
```

The clip's own voice is the single continuous audio bed. No TTS, no replacement audio.

> **Have a SCRIPT instead of a clip?** This core is source-agnostic — `talking_head_video` works for a manually-recorded clip OR a HeyGen avatar render. If you're starting from a script (no clip yet), use **`p-reels-split-heygen`**, which generates the avatar (ElevenLabs v3 → HeyGen v3 Avatar III, 16:9) and then delegates straight back here.

**Layout vs. the other cores:**

| Core | Face position | Graphics position |
|---|---|---|
| `p-reels-spotlight` | Full-frame (fills 1080×1920) | None |
| `p-reels-pip` | Small rounded inset, bottom-center | Full-frame background |
| **`p-reels-split`** | **Bottom half, 1080×960** | **Top half, 1080×960** |
| `p-reels-faceless` | None | Full-frame background |

---

## Inputs

| Param | Required | Default | Notes |
|---|---|---|---|
| `talking_head_video` | YES | — | Uploaded clip (real face + real voice). The face occupies the bottom half; the audio is the duration master. Download to local disk first. |
| `broll[]` | No | `[]` | Uploaded b-roll clips. Placed in the TOP half by `c-broll-sync` where the transcript matches. When empty → 100% graphics top half. |
| `known_transcript` | No | — | Pre-computed word-level transcript `[{text,start,end}]`. Skips Step 3 transcription. |
| `outro` | No | off | Optional outro mp4 appended via concat after the main reel. |
| `bottom_fit` | No | `cover` | `cover` = scale-to-COVER-crop the face into 1080×960 (portrait sources read best; top/bottom of source may crop slightly). `fit` = scale-to-FIT + blurred-fill side gaps (face always whole, no cropping). |
| `broll_style` | No | `card` | TOP-zone b-roll rendering. `card` (default) = `wowx-motions` STAGE — floats the clip as a rounded, shadowed card on a brand-colour canvas with camera motion (`card-focus` / alternating `card-orbit`). Best for flat screen-recordings / app demos. `blurred-fill` = legacy boxblur-bg + fit-fg (use only when a full-bleed look is wanted). |
| `bottom_cutzoom` | No | `false` | When `true`, the bottom (talking-head) zone is split at the beat boundaries and each segment alternates zoom — wide (~1.0) on b-roll beats, punched-in (~1.10–1.14) on graphics beats — giving a zoom-cut on every beat. Adds short-form energy to a single continuous read (e.g. a HeyGen avatar). `false` = one static cover-fill. |

### c-broll-sync coverage params (passthrough)

| Param | Default | Meaning |
|---|---|---|
| `broll_coverage_pct` | `30` | Target % of bed covered by b-roll in the TOP zone. Set `0` for 100% graphics. |
| `broll_clip_seconds` | `4` | Default on-screen duration per b-roll window. |
| `broll_min_seconds` | `2` | Min window clamp. |
| `broll_max_seconds` | `6` | Max window clamp. |
| `broll_order` | `transcript-match` | `transcript-match` / `as-given` / `even`. |
| `broll_reuse` | `false` | Whether clips may be reused to hit the coverage target. |

---

## Parameter Table

| Parameter | Default | Notes |
|---|---|---|
| Canvas | 1080×1920, 30 fps | 9:16 portrait |
| Canvas color | `#0F172A` | Dark navy — fallback fill only (covered by both zones) |
| Split point | y = 960 | Exact 50/50 half. Never move this. |
| Top zone | 1080×960 (y 0 → 960) | Graphics or b-roll. b-roll uses BLURRED-FILL into 1080×960. |
| Bottom zone | 1080×960 (y 960 → 1920) | Talking head, BLURRED-FILL into 1080×960. Face is always whole — never cropped. |
| Top-half b-roll fit | BLURRED-FILL (1080×960) | Same 3-chain filter as p-reels-pip but cropped to 1080×960, not 1080×1920. |
| Bottom face fit | `cover` (default) | `cover` = scale-to-COVER-crop fills 1080×960 with the face (top/bottom may crop; reads well for portrait sources). `fit` = scale-to-FIT + blurred-fill side gaps (face always whole). Set via `bottom_fit=fit`. |
| Audio | talking head's own track | Loudnormed once in Step 2. |
| Target duration | = talking-head length | VO is the master; background is built to cover it exactly (`shortest=1`). |
| Encode | H.264, yuv420p, CRF 19, `+faststart` | AAC stereo 48k 192k |
| CAP_TOP | `860` | Captions sit in the top zone, well below the split seam. Kept ≤ 900 so they never touch the face zone. |

---

## Top-Half Graphics Constraint

All content (motion graphics, captions, b-roll) must stay in **y 0 → 960**. This is enforced in
two complementary ways:

1. **CSS `--split-band` var (960px):** every HyperFrames template in `templates/` sets
   `height: 960px` on the root div and `overflow: hidden`. Content physically cannot extend below
   y=960 within the composition window.

2. **c-typing-ui `VARIANT=top-half`:** typing-ui and hook-scene templates are called with
   `VARIANT=top-half` instead of `pip-safe`. The top-half variant constrains itself to 960px tall.
   If c-typing-ui does not support `top-half`, the caller wraps the rendered output with
   `crop=1080:960:0:0` in ffmpeg before vstacking — the crop acts as a hard clip gate.

3. **ffmpeg vstack composite:** the final composite is `vstack=inputs=2` — top clip (1080×960)
   stacked above bottom clip (1080×960), producing exactly 1080×1920 with a hard pixel boundary at
   y=960. There is no overlay, no alpha, no bleed. Even if a graphics frame exceeds 960px it is
   mechanically cut by the top input's fixed height.

---

## 50/50 Composite Technique

The final composition uses **`vstack`**, not `overlay`:

```
ffmpeg -i top-zone.mp4 -i bottom-zone.mp4 \
  -filter_complex "[0:v][1:v]vstack=inputs=2[v]" \
  -map "[v]" -map 1:a ...
```

- `[0:v]` = top zone (1080×960, graphics/b-roll, no audio)
- `[1:v]` = bottom zone (1080×960, talking head, has audio)
- Audio comes from the bottom (talking head) input — `[1:a]`
- `vstack` requires BOTH inputs to be exactly 1080×960. Both are pre-normalised to that size
  (scale + blurred-fill) before the vstack call — mismatched sizes produce a fatal ffmpeg error.
- `shortest=1` is applied at the bed-build stage (Step 7) so the output matches the talking-head duration.

---

## Steps

Set up variables:

```bash
TH="<path to downloaded talking-head mp4>"
W="<production>/interim/split" ; mkdir -p "$W" "$W/src" "$W/top_beats"
OUT="<production>/final/split-reel-with-cover.mp4" ; mkdir -p "$(dirname "$OUT")"
FF="ffmpeg"
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-reels-split 2>/dev/null | head -1)

BROLL_SYNC_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-broll-sync 2>/dev/null | head -1)
PREMIUM_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-reel-premium 2>/dev/null | head -1)
TYPING_UI_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-typing-ui 2>/dev/null | head -1)
WOWX_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name wowx-motions 2>/dev/null | head -1)

BROLL_COVERAGE_PCT="${broll_coverage_pct:-30}"
BROLL_CLIP_SECS="${broll_clip_seconds:-4}"
BROLL_MIN_SECS="${broll_min_seconds:-2}"
BROLL_MAX_SECS="${broll_max_seconds:-6}"
BROLL_ORDER="${broll_order:-transcript-match}"
BROLL_REUSE="${broll_reuse:-false}"
BROLL_STYLE="${broll_style:-card}"          # card (wowx canvas-wrap) | blurred-fill
BOTTOM_CUTZOOM="${bottom_cutzoom:-false}"    # zoom-cut the face on every beat
# Brand canvas colour for broll_style=card (from brand.json; fallback dark navy). Hex WITHOUT '#'.
BRAND_BG=$(python3 -c "import json;print(json.load(open('$W/brand.json')).get('bg','0F172A').lstrip('#'))" 2>/dev/null || echo 0F172A)
export BROLL_STYLE WOWX_DIR BRAND_BG BOTTOM_CUTZOOM   # Step 6/7 Python read these from env
# Short-form fixed-cadence tip: for a beat every Ns set broll_clip_seconds=N + broll_min_seconds=N
# + broll_max_seconds=N (e.g. 5/5/5). If c-broll-sync still emits uneven beats, post-rewrite
# beat_list.json onto a fixed N-second grid alternating broll/graphics before Step 6.

# Transcription (Step 3): prefer a CACHED mlx model + offline mode to avoid HF-auth download
# failures — `export HF_HUB_OFFLINE=1` and use whisper-large-v3-turbo (cached) over whisper-small.

# Split geometry — NEVER change these
SPLIT_H=960    # top zone height = bottom zone height = canvas_height / 2
CANVAS_W=1080
CANVAS_H=1920
```

### Step 1 — Localize + probe the talking-head video (MANDATORY)

```bash
# Download talking-head to $W/src/th.mp4 if it's a remote URL
# (use cfw-download or curl; never composite from remote URLs)

ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,duration,codec_name \
  -of default=noprint_wrappers=1 "$TH"

BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TH")

$FF -hide_banner -i "$TH" -t 60 -af volumedetect -f null - 2>&1 \
  | grep -E "mean_volume|max_volume"
# max_volume near 0 dB, mean_volume ~-20 dB = real speech.
# ~-90 dB = STOP — no narration; report and ask for a different source.
```

### Step 1.5 — Detect + crop white side-bands (BEFORE anything else)

```bash
TH_W=$(ffprobe -v error -select_streams v -show_entries stream=width  -of csv=p=0 "$TH")
TH_H=$(ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$TH")

col_luma() {
  v=$($FF -hide_banner -loglevel error -ss $(echo "$BED_DUR/2"|bc) -i "$TH" -vframes 1 \
        -vf "crop=2:$TH_H:$1:0,scale=1:1,format=gray" -f rawvideo - 2>/dev/null | xxd -p)
  echo $((16#$v))
}

BAND_LEFT=0
for x in $(seq 0 5 $((TH_W/2))); do
  [ "$(col_luma $x)" -lt 245 ] && { BAND_LEFT=$x; break; }
done
BAND_RIGHT=$TH_W
for x in $(seq $((TH_W-2)) -5 $((TH_W/2))); do
  [ "$(col_luma $x)" -lt 245 ] && { BAND_RIGHT=$((x+2)); break; }
done
CLEAN_W=$(( BAND_RIGHT - BAND_LEFT )); CLEAN_W=$(( CLEAN_W - CLEAN_W % 2 ))

if [ "$BAND_LEFT" -gt 4 ] || [ "$BAND_RIGHT" -lt $((TH_W-4)) ]; then
  $FF -y -i "$TH" -vf "crop=$CLEAN_W:$TH_H:$BAND_LEFT:0,setsar=1" \
    -c:v libx264 -pix_fmt yuv420p -c:a copy "$W/th-clean.mp4"
  TH_CLEAN="$W/th-clean.mp4"
else
  TH_CLEAN="$TH"
fi

read TH_CW TH_CH < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of default=noprint_wrappers=1 "$TH_CLEAN" | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')  # box-compat: Ubuntu 22.04 csv format differs → use default+awk
```

### Step 2 — Build the loudnormed voice bed (ONCE, never again)

The talking head is kept at its original resolution here (audio extraction only).
The visual bottom-half layer is rendered separately in Step 6.

```bash
# Extract loudnormed audio only — the bottom-half face video is built in Step 6.
$FF -y -i "$TH_CLEAN" \
  -vn -af "loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000" \
  -c:a aac -ar 48000 -ac 2 -b:a 192k \
  "$W/voice-bed.aac"

# Also need duration master from the cleaned clip
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TH_CLEAN")
echo "bed duration: $BED_DUR seconds"
```

### Step 3 — Transcribe with word timestamps (skip when known_transcript provided)

```bash
if [ -n "$KNOWN_TRANSCRIPT_JSON" ]; then
  echo "$KNOWN_TRANSCRIPT_JSON" | python3 -c "
import json,sys
words=json.load(sys.stdin)
words=[{**w,'text':w.get('text') or w.get('word','')} for w in words]
print(json.dumps(words))
" > "$W/transcript.json"
  echo "[p-reels-split] Using provided transcript — skipping transcription"
else
  # cfw-transcribe fallback chain:
  #   1. cfw-transcribe (Gemini cloud / MLX) — preferred
  #   2. mlx_whisper — fast on Apple Silicon, available on the box
  #   3. whisper — Python CLI fallback
  #   If none is available and known_transcript was NOT provided, STOP and report.
  # box-compat: cfw-transcribe (Gemini backend) needs GEMINI_API_KEY; source from box
  # env file when not already in the environment. Harmless no-op off-box.
  [ -z "${GEMINI_API_KEY:-}" ] && GEMINI_API_KEY=$(grep GEMINI_API_KEY /opt/cfw-agent/.env 2>/dev/null | cut -d= -f2-) || true
  export GEMINI_API_KEY
  if command -v cfw-transcribe >/dev/null 2>&1; then
    cfw-transcribe --input "$W/voice-bed.aac" --out "$W/transcript.srt" --format srt
  elif command -v mlx_whisper >/dev/null 2>&1; then
    echo "[p-reels-split] cfw-transcribe not found — falling back to mlx_whisper"
    mlx_whisper "$W/voice-bed.aac" --model mlx-community/whisper-small --output-dir "$W" --output-format srt
    mv "$W/voice-bed.srt" "$W/transcript.srt"
  elif command -v whisper >/dev/null 2>&1; then
    echo "[p-reels-split] cfw-transcribe not found — falling back to whisper CLI"
    whisper "$W/voice-bed.aac" --model small --output_dir "$W" --output_format srt
    mv "$W/voice-bed.srt" "$W/transcript.srt"
  else
    echo "[p-reels-split] FATAL: no transcription tool found (cfw-transcribe, mlx_whisper, or whisper). Install cfw-transcribe or provide known_transcript." >&2
    exit 1
  fi
  python3 - "$W/transcript.srt" "$W/transcript.json" <<'PY'
import re, json, sys
lines = open(sys.argv[1]).read().strip().split('\n\n')
words = []
for block in lines:
    parts = block.strip().split('\n')
    if len(parts) < 3: continue
    ts = parts[1]
    text = ' '.join(parts[2:])
    def t2s(ts_str):
        h,m,rest = ts_str.replace(',','.').split(':')
        return int(h)*3600+int(m)*60+float(rest)
    start_s, end_s = ts.split(' --> ')
    for word in text.split():
        words.append({"text": word, "start": t2s(start_s.strip()), "end": t2s(end_s.strip())})
json.dump(words, open(sys.argv[2], 'w'))
PY

  python3 - "$W/transcript.json" <<'PY'
import json, sys, re
words = json.load(open(sys.argv[1]))
garbage = sum(1 for w in words if re.match(r'[♪\[\(]', w.get('text','')) or not w.get('text','').strip())
pct = garbage/len(words)*100 if words else 100
assert pct < 20, f"Transcript quality too low ({pct:.0f}% garbage). Retry with --model medium."
print(f"Transcript OK: {len(words)} words, {pct:.1f}% garbage")
PY
fi
```

### Step 4 — Build the b-roll cue index (for the top zone)

```bash
BROLL_CUES_JSON="[]"

if [ ${#BROLL_CLIPS[@]} -gt 0 ]; then
  TMP_CUES="$W/broll_cues_build"
  mkdir -p "$TMP_CUES"

  build_broll_cue() {
    local clip="$1"
    local fname=$(basename "$clip")
    local dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip" 2>/dev/null || echo 0)
    local srt_out="$TMP_CUES/${fname%.mp4}.srt"
    local cues_out="$TMP_CUES/${fname%.mp4}.json"

    local has_audio=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$clip" 2>/dev/null | head -1)
    if [ -n "$has_audio" ]; then
      # Use same transcribe fallback chain as Step 3
      if command -v cfw-transcribe >/dev/null 2>&1; then
        cfw-transcribe --input "$clip" --out "$srt_out" --format srt 2>/dev/null
      elif command -v mlx_whisper >/dev/null 2>&1; then
        mlx_whisper "$clip" --model mlx-community/whisper-small --output-dir "$(dirname "$srt_out")" --output-format srt 2>/dev/null && \
        mv "$(dirname "$srt_out")/$(basename "$clip" .mp4).srt" "$srt_out" 2>/dev/null || true
      elif command -v whisper >/dev/null 2>&1; then
        whisper "$clip" --model small --output_dir "$(dirname "$srt_out")" --output_format srt 2>/dev/null && \
        mv "$(dirname "$srt_out")/$(basename "$clip" .mp4).srt" "$srt_out" 2>/dev/null || true
      fi
      [ -f "$srt_out" ] && python3 - "$srt_out" "$cues_out" <<'PY'
import re, json, sys
lines = open(sys.argv[1]).read().strip().split('\n\n')
cues = []
for block in lines:
    parts = block.strip().split('\n')
    if len(parts) < 3: continue
    ts = parts[1]; text = ' '.join(parts[2:])
    def t2s(s): h,m,rest=s.replace(',','.').split(':'); return int(h)*3600+int(m)*60+float(rest)
    start_s, end_s = ts.split(' --> ')
    cues.append({"start": t2s(start_s.strip()), "end": t2s(end_s.strip()), "text": text.strip()})
json.dump(cues, open(sys.argv[2], 'w'))
PY
    else
      echo "[]" > "$cues_out"
    fi
    local cues_json=$(cat "$cues_out" 2>/dev/null || echo '[]')
    echo "{\"clip\":\"$fname\",\"duration\":$dur,\"cues\":$cues_json}"
  }

  NPROC=$(nproc 2>/dev/null || echo 4)
  MAXJOBS=$(( NPROC > 1 ? NPROC - 1 : 1 ))
  ENTRY_FILES=()
  for clip in "${BROLL_CLIPS[@]}"; do
    out_f="$TMP_CUES/$(basename "$clip" .mp4)_entry.json"
    build_broll_cue "$clip" > "$out_f" &
    ENTRY_FILES+=("$out_f")
    while [ "$(jobs -r | wc -l)" -ge "$MAXJOBS" ]; do wait -n; done
  done
  wait

  BROLL_CUES_JSON=$(python3 -c "
import json, sys
entries = []
for f in sys.argv[1:]:
    try: entries.append(json.loads(open(f).read()))
    except: pass
print(json.dumps(entries))
" "${ENTRY_FILES[@]}")
  echo "$BROLL_CUES_JSON" > "$W/broll_cues.json"
fi

echo "$BROLL_CUES_JSON" > "$W/broll_cues.json"
echo "[p-reels-split] broll cue index: $(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(len(d),"clips")' < "$W/broll_cues.json")"
```

### Step 5 — Plan the top-half beat list with c-broll-sync

`c-broll-sync` plans the top zone exactly as it does for the full background in p-reels-pip —
the beat list structure is identical; only the rendering target is 1080×960 instead of 1080×1920.

```bash
node "$BROLL_SYNC_DIR/scripts/plan.js" \
  --transcript "$W/transcript.json" \
  --broll      "$W/broll_cues.json" \
  --coverage   "$BROLL_COVERAGE_PCT" \
  --clip-secs  "$BROLL_CLIP_SECS" \
  --min-secs   "$BROLL_MIN_SECS" \
  --max-secs   "$BROLL_MAX_SECS" \
  --order      "$BROLL_ORDER" \
  --reuse      "$BROLL_REUSE" \
  --bed-dur    "$BED_DUR" \
  --brand      "$W/brand.json" \
  --out        "$W/beat_list.json"

python3 - "$W/beat_list.json" "$BED_DUR" <<'PY'
import json, sys
bl = json.load(open(sys.argv[1]))
assert bl["beats"], "no beats in beat_list.json"
prev_end = 0.0
for b in bl["beats"]:
    assert abs(b["start"] - prev_end) < 0.15, f"gap at beat {b['index']}: {prev_end} → {b['start']}"
    prev_end = b["end"]
print(f"beat_list OK: {len(bl['beats'])} beats, achieved broll {bl.get('achieved_broll_pct',0):.1f}%")
PY

COVER_AT=$(python3 -c "
import json; bl=json.load(open('$W/beat_list.json'))
mid = float('$BED_DUR') * 0.30
for b in bl['beats']:
    if b['start'] >= mid:
        print(round(b['start'] + (b['end']-b['start'])*0.5, 2))
        break
else:
    print(round(float('$BED_DUR')*0.35, 2))
")
echo "[p-reels-split] cover_at: ${COVER_AT}s"
```

### Step 6 — Build the top-half track (1080×960, all beats)

Each beat targets a **1080×960** canvas. Graphics templates render to that size; b-roll clips
are BLURRED-FILL composited into 1080×960. Concurrent build, same parallel pattern as p-reels-pip.

```bash
NPROC=$(nproc 2>/dev/null || echo 4)
MAXJOBS=$(( NPROC > 1 ? NPROC - 1 : 1 ))
N_BEATS=$(python3 -c "import json; print(len(json.load(open('$W/beat_list.json'))['beats']))")

build_top_beat() {
  local i=$1
  python3 - "$i" "$W/beat_list.json" "$W" "$FF" "$TYPING_UI_DIR" "$SKILL_DIR" <<'PY'
import json, sys, os, subprocess, html, re, shutil

def find_gsap(skill_dir):
    # f-gsap is vendored under .hub/ in the pack, and a sibling in the source repo.
    for c in (f"{skill_dir}/.hub/f-gsap/vendor/gsap.min.js",
              f"{skill_dir}/../f-gsap/vendor/gsap.min.js"):
        if os.path.exists(c):
            return c
    raise SystemExit("[p-reels-split] FATAL: vendored gsap.min.js not found "
                     "(expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/). "
                     "NEVER fall back to a CDN — the render box blocks outbound library fetches.")

i = int(sys.argv[1])
bl = json.load(open(sys.argv[2]))
beat = bl["beats"][i]
W, FF = sys.argv[3], sys.argv[4]
TYPING_UI_DIR, SKILL_DIR = sys.argv[5], sys.argv[6]

dur = round(float(beat["end"]) - float(beat["start"]), 2)
out = f"{W}/top_beats/top_beat{i}.mp4"
# Top zone dimensions
TW, TH_PX = 1080, 960

if beat["kind"] == "broll":
    b = beat["broll"]
    clip_path = os.path.join(W, "src", b["clip"])
    # broll_style switch (read from exported env): "card" = wowx canvas-wrap, else blurred-fill.
    BROLL_STYLE = os.environ.get("BROLL_STYLE", "card")
    WOWX_DIR    = os.environ.get("WOWX_DIR", "")
    BRAND_BG    = os.environ.get("BRAND_BG", "0F172A")
    if BROLL_STYLE == "card" and WOWX_DIR:
        # CANVAS-WRAP (wowx-motions STAGE): float the clip as a rounded, shadowed card on the
        # brand canvas with camera motion. Best for flat app/screen-recordings — far more
        # premium + legible than blurred-fill. Alternate card-focus / card-orbit for variety.
        trimmed = f"{W}/top_beats/_wxin{i}.mp4"
        subprocess.run([FF, "-ss", str(b["in"]), "-to", str(b["out"]),
            "-i", clip_path, "-an", "-y", trimmed], check=True)
        motion = "card-orbit" if (i % 4 == 2) else "card-focus"
        subprocess.run(["python3", f"{WOWX_DIR}/wowx_motion.py", trimmed, "-m", motion, out,
            "--bg", f"0x{BRAND_BG}", "--canvas", f"{TW}x{TH_PX}",
            "--card-scale", "0.86", "--corner-radius", "0.04", "--intensity", "1.1"], check=True)
    else:
        # BLURRED-FILL into 1080×960 (legacy full-bleed):
        #   split [0:v] first → [a] bg chain, [b] fg chain (avoids fatal double-read of [0:v])
        #   [bg] scale to COVER 1080×960, boxblur, setsar
        #   [fg] scale to FIT inside 1080×960 (whole clip visible, no crop)
        #   overlay fg centred on bg
        subprocess.run([FF,
            "-ss", str(b["in"]), "-to", str(b["out"]), "-i", clip_path,
            "-vf", (
                f"[0:v]split[_a][_b];"
                f"[_a]scale={TW}:{TH_PX}:force_original_aspect_ratio=increase,crop={TW}:{TH_PX},"
                f"boxblur=40:2,setsar=1[bg];"
                f"[_b]scale={TW}:{TH_PX}:force_original_aspect_ratio=decrease,setsar=1[fg];"
                f"[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"
            ),
            "-map", "[bv]",
            "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-y", out
        ], check=True)
else:
    scene = beat.get("scene", {})
    scene_type = scene.get("type", "")
    gdir = f"{W}/gfx_top{i}"; os.makedirs(gdir, exist_ok=True)

    if scene_type in ("typing-ui", "hook"):
        tmpl_file = "typing-scene.html" if scene_type == "typing-ui" else "hook-scene.html"
        tmpl = open(f"{TYPING_UI_DIR}/templates/{tmpl_file}").read()
        tmpl = re.sub(r'<template[^>]*>\s*', '', tmpl)
        tmpl = re.sub(r'\s*</template>', '', tmpl)
        tmpl = re.sub(r'<!--.*?-->', '', tmpl, flags=re.DOTALL)
        if scene_type == "typing-ui":
            replacements = {
                "DURATION": str(dur),
                "LABEL": html.escape(scene.get("label", "claude.ai")),
                "PROMPT": html.escape(scene.get("prompt", "")),
                "TYPING_SPEED": str(scene.get("typing_speed", "1.0")),
                "ACCENT": scene.get("brand", {}).get("accent", "F97316").lstrip("#"),
                "VARIANT": "top-half",
                "BOTTOM_TAG": html.escape(scene.get("bottom_tag", "")),
            }
        else:
            replacements = {
                "DURATION": str(dur),
                "EYEBROW": html.escape(scene.get("eyebrow", "")),
                "LINE1": scene.get("title_html", html.escape(scene.get("ghost", ""))),
                "LINE2": scene.get("line2", ""),
                "LINE3": scene.get("line3", ""),
                "SUBHEAD": scene.get("subhead", ""),
                "ACCENT": scene.get("brand", {}).get("accent", "F97316").lstrip("#"),
            }
        body = tmpl
        for k, v in replacements.items():
            body = body.replace("{{" + k + "}}", v)
        # Standalone full HTML doc; constrain viewport to 1080×960 (top half only)
        idx_html = (
            f'<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
            f'<script src="gsap.min.js"></script>\n'  # vendored locally — never a CDN (copied into gdir below)
            f'<style>html,body{{margin:0;padding:0;width:1080px;height:960px;overflow:hidden;background:#0F172A;}}</style>\n'
            f'</head><body>{body}</body></html>'
        )
    else:
        # Split-safe motion card (--split-band: 0px — content fills all 960px of the top zone)
        tpl_path = f"{SKILL_DIR}/templates/split-motion-card.html"
        tmpl = open(tpl_path).read()
        replacements = {
            "DURATION": str(dur),
            "EYEBROW": html.escape(scene.get("eyebrow", "")),
            "GHOST": html.escape(scene.get("ghost", "")),
            "TITLE_HTML": scene.get("title_html", ""),
            "ACCENT": scene.get("brand", {}).get("accent", "F97316"),
            "BG": scene.get("brand", {}).get("bg", "0F172A"),
            "FG": scene.get("brand", {}).get("fg", "F1F5F9"),
        }
        body = tmpl
        for k, v in replacements.items():
            body = body.replace("{{" + k + "}}", v)
        body = re.sub(r'<template[^>]*>\s*', '', body)
        body = re.sub(r'\s*</template>', '', body)
        body = re.sub(r'<!--.*?-->', '', body, flags=re.DOTALL)
        body = re.sub(
            r'<div class="sc-root">',
            f'<div class="sc-root" data-composition-id="root" data-start="0" data-duration="{dur}" data-width="1080" data-height="960">',
            body, count=1)
        idx_html = (
            f'<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
            f'<script src="gsap.min.js"></script>\n'  # vendored locally — never a CDN (copied into gdir below)
            f'<style>html,body{{margin:0;padding:0;width:1080px;height:960px;overflow:hidden;background:#0F172A;}}</style>\n'
            f'</head><body>{body}</body></html>'
        )

    # box-compat: gpt-5.5 sometimes emits a double-hash hex (##0F172A) → white bg. Collapse it.
    idx_html = idx_html.replace("##", "#")
    open(f"{gdir}/index.html", "w").write(idx_html)
    # Vendor GSAP into the comp dir so the local <script src="gsap.min.js"> resolves at render.
    shutil.copy(find_gsap(SKILL_DIR), f"{gdir}/gsap.min.js")
    # --width/--height flags are NOT supported by the hyperframes CLI; canvas size is set via
    # data-width/data-height on the root div and CSS (html,body width/height 1080px/960px).
    subprocess.run(
        f"npx hyperframes@0.7.5 lint >/dev/null 2>&1 && "
        f"npx hyperframes@0.7.5 render --output {out} --quality high --fps 30",
        shell=True, cwd=gdir, check=True
    )

print(f"top beat {i} ({beat['kind']}) done → {out}")
PY
}

for i in $(seq 0 $((N_BEATS-1))); do
  build_top_beat "$i" &
  while [ "$(jobs -r | wc -l)" -ge "$MAXJOBS" ]; do wait -n; done
done
wait

for i in $(seq 0 $((N_BEATS-1))); do
  [ -s "$W/top_beats/top_beat$i.mp4" ] || { echo "[p-reels-split] FATAL: top beat $i did not render"; exit 1; }
done

# Concat top beats into top-all.mp4 (normalised to 1080×960/30fps/yuv420p)
python3 - "$W" "$N_BEATS" <<'PY' > "$W/top_concat.sh"
import sys
W, N = sys.argv[1], int(sys.argv[2])
lines = [f"file '{W}/top_beats/top_beat{i}.mp4'" for i in range(N)]
open(f"{W}/top_concat.txt", "w").write("\n".join(lines))
print(f'ffmpeg -y -f concat -safe 0 -i "{W}/top_concat.txt" '
      f'-vf "scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,setsar=1,fps=30,format=yuv420p" '
      f'-c:v libx264 -preset medium -crf 20 -an "{W}/top-all.mp4"')
PY
bash "$W/top_concat.sh"

# VERIFY top track brightness
echo "[p-reels-split] Verifying top-zone brightness..."
for t in 1 $(python3 -c "print(round(float('$BED_DUR')/2,1))") $(python3 -c "print(round(float('$BED_DUR')-1,1))"); do
  $FF -ss "$t" -i "$W/top-all.mp4" -frames:v 1 \
    -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*'
done
# YAVG near 0 on all samples → top zone is black → fix Step 6 before proceeding.
```

### Step 7 — Build the bottom-half face track (1080×960)

The talking-head clip is rendered into a 1080×960 layer. Two fit modes are supported via
`bottom_fit` (default `cover`):

- **`cover`** (default): scale-to-COVER-crop fills the full 1080×960 with the face. Portrait
  sources (9:16 talking head) read best — the face fills the zone with no blurred side-bands.
  Top/bottom of the source may be slightly cropped.
- **`fit`**: scale-to-FIT + blurred-fill — face is always whole (no cropping); a blurred-copy
  background fills any side gaps if the source is not 16:9.

The loudnormed audio is muxed in here so the vstack step has audio on the bottom input.

```bash
BOTTOM_FIT="${bottom_fit:-cover}"   # cover | fit

if [ "${BOTTOM_CUTZOOM:-false}" = "true" ]; then
  # CUT-ZOOM: split the face at beat boundaries, alternate zoom per beat — wide 1.0x on b-roll
  # beats, punched-in 1.4x on graphics beats — for a hard zoom-cut on every beat. Audio is the
  # single loudnormed bed, muxed after the silent concat (lip-sync preserved; only framing cuts).
  mkdir -p "$W/av"
  python3 - "$W/beat_list.json" "$W" "$TH_CLEAN" "$FF" <<'PY'
import json, os, subprocess, sys
bl=json.load(open(sys.argv[1]))["beats"]; W,TH,FF=sys.argv[2],sys.argv[3],sys.argv[4]
WIDE, TIGHT = 1.0, 1.4   # b-roll beat = wide ; graphics beat = punched-in
# Probe source dims so the zoom crops from FULL-RES source (sharp) and is TOP-ANCHORED
# (head stays at the top; crop comes off the bottom — never crop the forehead).
import subprocess as _sp
SW,SH=[int(x) for x in _sp.run(["ffprobe","-v","error","-select_streams","v:0",
    "-show_entries","stream=width,height","-of","csv=p=0:s=x",TH],capture_output=True,text=True).stdout.strip().split("x")]
BASE_W=min(SW, SH*1080/960)   # widest 1.125-aspect crop that fits the source
lines=[]
for k,b in enumerate(bl):
    z = WIDE if b["kind"]=="broll" else TIGHT
    cw=int(round(BASE_W/z/2))*2; ch=int(round(cw*960/1080/2))*2
    x=int((SW-cw)/2); y=0          # centered horizontally, TOP-anchored vertically
    seg=f"{W}/av/s{k}.mp4"
    subprocess.run([FF,"-y","-ss",str(b["start"]),"-to",str(b["end"]),"-i",TH,"-an",
        "-vf",f"crop={cw}:{ch}:{x}:{y},scale=1080:960:flags=lanczos,setsar=1,fps=30,format=yuv420p",
        "-c:v","libx264","-preset","slow","-crf","17",seg],check=True)
    lines.append(f"file 'av/s{k}.mp4'")
open(f"{W}/av_concat.txt","w").write("\n".join(lines)+"\n")
print(f"cut-zoom: {len(bl)} segments (1.0x↔1.4x)")
PY
  $FF -y -f concat -safe 0 -i "$W/av_concat.txt" -an -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p "$W/av/bottom-video.mp4"
  $FF -y -i "$W/av/bottom-video.mp4" -i "$W/voice-bed.aac" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 -shortest "$W/bottom-all.mp4"
else
  # Fix: split [0:v] before forking into bg/fg chains to avoid fatal double-read of [0:v].
  if [ "$BOTTOM_FIT" = "fit" ]; then
    # scale-to-FIT + blurred-fill (face always whole, no cropping)
    FC_BOTTOM="[0:v]split[_a][_b];[_a]scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,boxblur=40:2,setsar=1[bg];[_b]scale=1080:960:force_original_aspect_ratio=decrease,setsar=1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"
  else
    # cover (default): scale-to-COVER-crop — face fills 1080×960, portrait sources read well
    FC_BOTTOM="[0:v]scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,setsar=1,format=yuv420p,fps=30[bv]"
  fi
  $FF -y -i "$TH_CLEAN" -i "$W/voice-bed.aac" \
    -filter_complex "$FC_BOTTOM" \
    -map "[bv]" -map 1:a \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    -shortest "$W/bottom-all.mp4"
fi

# Note: -shortest clips to the shorter of the two inputs (TH_CLEAN video vs voice-bed.aac).
# Since voice-bed.aac was derived from TH_CLEAN, durations should match within ±0.05s.
BOTTOM_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/bottom-all.mp4")
echo "[p-reels-split] bottom track duration: ${BOTTOM_DUR}s (fit_mode=$BOTTOM_FIT cutzoom=${BOTTOM_CUTZOOM:-false})"
```

### Step 7.5 — Trim top-all.mp4 to match bottom-all.mp4 duration

The top zone is built from discrete beat clips concatenated to exactly `BED_DUR`. The bottom zone
may be a fraction shorter due to `-shortest` rounding. Both inputs to `vstack` must be the same
duration or ffmpeg will either error or produce a hanging last frame.

```bash
BOTTOM_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/bottom-all.mp4")
TOP_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/top-all.mp4")

python3 -c "
top, bot = float('$TOP_DUR'), float('$BOTTOM_DUR')
diff = abs(top - bot)
assert diff < 1.0, f'top/bottom duration mismatch too large: top={top:.2f}s bot={bot:.2f}s diff={diff:.2f}s — check Step 6 beat total'
print(f'duration delta: {diff:.3f}s (within 1s tolerance)')
"

# Trim top-all to bottom duration if needed (trim is a no-op when they already match)
$FF -y -i "$W/top-all.mp4" -t "$BOTTOM_DUR" \
  -c:v libx264 -preset medium -crf 20 -an -pix_fmt yuv420p "$W/top-trimmed.mp4"
```

### Step 8 — vstack: composite TOP zone over BOTTOM zone

```bash
# vstack requires both inputs to be IDENTICAL width and height.
# top-trimmed.mp4: 1080×960, no audio
# bottom-all.mp4:  1080×960, has loudnormed audio (the VO master)
# Result: 1080×1920, audio from bottom track.

$FF -y -i "$W/top-trimmed.mp4" -i "$W/bottom-all.mp4" \
  -filter_complex "[0:v][1:v]vstack=inputs=2[v]" \
  -map "[v]" -map 1:a \
  -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart \
  "$W/composed.mp4"

# Quick sanity: verify 1080×1920
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0 "$W/composed.mp4"
# Must print: 1080,1920
```

### Step 9 — CTA end-card (tail TAKEOVER — does NOT extend the reel)

Render a 2.5–3s brand CTA card (HyperFrames, 1080×1920, silent), overlay on the FINAL seconds
of the composed reel using a time-gated `enable=` window. The reel ends when the speaker ends.

```bash
CTA_DURATION="${CTA_DURATION:-3.0}"
CTA_TEXT="${CTA_TEXT:-FOLLOW FOR MORE}"
CTA_HANDLE="${CTA_HANDLE:-@handle}"

mkdir -p "$W/cta"
cat > "$W/cta/index.html" <<HTML
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<script src="gsap.min.js"></script>
<style>
html,body{margin:0;padding:0;width:1080px;height:1920px;overflow:hidden;background:rgba(15,23,42,0.85);display:flex;flex-direction:column;align-items:center;justify-content:center;}
h1{color:#F1F5F9;font-family:Oswald,sans-serif;font-size:120px;font-weight:900;text-align:center;margin:0;padding:0 80px;}
p{color:#F97316;font-family:Inter,sans-serif;font-size:56px;opacity:0.9;margin-top:40px;}
</style>
</head>
<body>
<div data-composition-id="root" data-start="0" data-duration="${CTA_DURATION}" data-width="1080" data-height="1920" style="display:flex;flex-direction:column;align-items:center;justify-content:center;width:1080px;height:1920px;">
  <h1 id="cta-text">${CTA_TEXT}</h1>
  <p id="cta-handle">${CTA_HANDLE}</p>
</div>
<script>
(function(){
  var gsap = window.__gsap || window.gsap;
  if(!gsap){return;}
  var tl = gsap.timeline({paused:true});
  tl.from("#cta-text",{opacity:0,y:40,duration:0.4,ease:"power2.out"},0.1)
    .from("#cta-handle",{opacity:0,y:20,duration:0.35,ease:"power2.out"},0.3);
  if(!window.__timelines) window.__timelines={};
  window.__timelines["root"]=tl;
})();
</script>
</body></html>
HTML

# box-compat: gpt-5.5 sometimes emits a double-hash hex (--bg: ##0F172A) → white bg.
# Collapse any double-hash to single before lint/render.
sed -i 's/##/#/g' "$W/cta/index.html"
# Vendor GSAP into the CTA comp dir so the local <script src="gsap.min.js"> resolves at render.
GSAP=$(for p in "$SKILL_DIR/.hub/f-gsap/vendor" "$SKILL_DIR/.hub/f-gsap/vendor"; do [ -f "$p/gsap.min.js" ] && echo "$p/gsap.min.js" && break; done)
[ -n "$GSAP" ] || { echo "[p-reels-split] FATAL: vendored gsap.min.js not found (expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/) — NEVER fall back to a CDN"; exit 1; }
cp "$GSAP" "$W/cta/gsap.min.js"
cd "$W/cta" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output "$W/cta-card.mp4" --fps 30 --quality high
cd -

COMPOSED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/composed.mp4")
CTA_START=$(python3 -c "print(round(${COMPOSED_DUR} - ${CTA_DURATION}, 3))")

$FF -y -i "$W/composed.mp4" -itsoffset "${CTA_START}" -i "$W/cta-card.mp4" \
  -filter_complex "[0:v][1:v]overlay=enable='between(t,${CTA_START},${COMPOSED_DUR})':eof_action=pass[v]" \
  -map "[v]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -c:a copy -movflags +faststart "$W/with-cta.mp4"

FINAL_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/with-cta.mp4")
python3 -c "
dur, final = float('$COMPOSED_DUR'), float('$FINAL_DUR')
assert abs(dur - final) < 0.1, f'CTA extended the reel: {dur:.2f}s → {final:.2f}s'
print(f'CTA OK: {final:.2f}s (was {dur:.2f}s)')
"

if [ -n "${OUTRO_PATH:-}" ] && [ -f "$OUTRO_PATH" ]; then
  $FF -y -i "$OUTRO_PATH" \
    -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
    -c:v libx264 -preset medium -crf 20 -an "$W/outro-norm.mp4"
  printf "file '%s'\nfile '%s'\n" "$W/with-cta.mp4" "$W/outro-norm.mp4" > "$W/outro_concat.txt"
  $FF -y -f concat -safe 0 -i "$W/outro_concat.txt" -c copy "$W/pre-premium.mp4"
else
  cp "$W/with-cta.mp4" "$W/pre-premium.mp4"
fi
```

### Step 9.5 — c-reel-premium pass (captions + SFX + grade) — DEFAULT ON

Captions sit in the **top zone only** — `CAP_TOP=860` keeps them away from the split seam and
the face zone below it.

```bash
PW="$W/premium"; mkdir -p "$PW"

REEL_IN="$W/pre-premium.mp4"
REEL_OUT="$W/polished.mp4"
WORDS_JSON="$W/transcript.json"
CAP_TOP=860       # captions in top zone only — well above the y=960 split seam
CAPTIONS="${CAPTIONS:-on}"
SFX="${SFX:-on}"
GRADE="${GRADE:-}"

# box-compat: the Opus/kimi planning fallback (no subscription auth on-box) needs
# ANTHROPIC_API_KEY; source from box env file when not already set. No-op off-box.
[ -z "${ANTHROPIC_API_KEY:-}" ] && ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY /opt/cfw-agent/.env 2>/dev/null | cut -d= -f2-) || true
export ANTHROPIC_API_KEY

DUR_CHECK=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$REEL_IN")

PLAN_PROMPT="You are planning the PREMIUM POLISH layer for an assembled 9:16 reel (captions + SFX + grade — the picture is already edited; do NOT plan any takeovers or cuts).
Output STRICT JSON ONLY (one object, no prose).
Word transcript: $(cat "$WORDS_JSON")
Total duration: $DUR_CHECK seconds.
Brand: <from brief via Visual Identity Gate; default accent #F97316, fg #F1F5F9>.
Schema:
{ \"grade\": \"warm-amber|clean-bright\",
  \"brand\": {\"accent\":\"#hex6\",\"fg\":\"#hex6\"},
  \"caption_groups\": [ {\"start\":s,\"end\":s,\"style\":0|1|2,
        \"words\":[{\"w\":\"TEXT\",\"s\":start,\"e\":end,\"em\":false}] } ],
  \"sfx\": [ {\"t\":s,\"name\":\"whoosh-deep|whoosh-air|impact-sub|impact-punch|riser|click|pop|swipe\",\"gain\":0.0-0.6} ] }
RULES:
1. caption_groups cover the FULL duration, 2-4 words each, non-overlapping.
2. LATIN SCRIPT ONLY: transliterate any non-Latin script phonetically. NEVER translate.
3. At most ONE word per group gets \"em\":true.
4. \"style\" cycles 0/1/2 — never same style on adjacent groups.
5. sfx: 4-10 cues total; gain <=0.6. None in first 1s.
NOTE: Available SFX in c-reel-premium/assets/sfx/: whoosh-air.wav, whoosh-deep.wav, impact-punch.wav, impact-sub.wav, riser.wav, click.wav, pop.wav, swipe.wav. Names whoosh-soft and impact-soft do NOT exist — use whoosh-air/whoosh-deep and impact-sub/impact-punch respectively.
IMPORTANT: CAP_TOP=$CAP_TOP — captions must stay ABOVE y=$CAP_TOP (top zone only). The bottom half (y 960–1920) is the talking-head face — captions must NOT enter it."

PREMIUM_PLAN=$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
  -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
  -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL \
  timeout 240 claude --print "$PLAN_PROMPT" 2>/dev/null \
  | python3 -c "import sys,re; m=re.search(r'\{.*\}', sys.stdin.read(), re.S); print(m.group(0) if m else '')")

if ! echo "$PREMIUM_PLAN" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "[p-reels-split] Opus unavailable — planning premium on kimi"
  PREMIUM_PLAN=$(claude --print "$PLAN_PROMPT" 2>/dev/null \
    | python3 -c "import sys,re; m=re.search(r'\{.*\}', sys.stdin.read(), __import__('re').S); print(m.group(0) if m else '')")
fi
echo "$PREMIUM_PLAN" > "$PW/plan.json"

python3 - "$PW/plan.json" "$DUR_CHECK" <<'PY'
import json,re,sys
p=json.load(open(sys.argv[1])); dur=float(sys.argv[2])
assert p["caption_groups"], "no caption groups"
assert abs(p["caption_groups"][-1]["end"]-dur) < 3.0, "captions do not cover the reel"
assert not re.search(r'[ऀ-ॿ]', json.dumps(p)), "Devanagari in plan — Latin script only"
print(f"premium plan OK: {len(p['caption_groups'])} groups, {len(p.get('sfx',[]))} sfx")
PY

if [ "${CAPTIONS:-on}" = "on" ]; then
  python3 - "$PW" "$PREMIUM_DIR" "$REEL_IN" "$CAP_TOP" <<'PY'
import json, os, shutil, sys, subprocess
PW, PREMIUM, REEL, CAP_TOP = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
plan = json.load(open(f"{PW}/plan.json"))
dur = round(float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
  "-of","csv=p=0",REEL],capture_output=True,text=True).stdout.strip()),2)
proj = f"{PW}/comp"; os.makedirs(f"{proj}/compositions", exist_ok=True)
shutil.copy(REEL, f"{proj}/reel-in.mp4")
def fill(t, m):
    for k, v in m.items(): t = t.replace("{{%s}}" % k, str(v))
    return t
cap = open(f"{PREMIUM}/templates/caption-overlay.html").read()
open(f"{proj}/compositions/caption-overlay.html","w").write(fill(cap, {
    "DURATION": dur, "CAP_TOP": CAP_TOP,
    "ACCENT": plan["brand"]["accent"], "FG": plan["brand"]["fg"],
    "GROUPS_JSON": json.dumps(plan["caption_groups"])}))
root = open(f"{PREMIUM}/templates/root-shell-polish.html").read()
open(f"{proj}/index.html","w").write(fill(root, {"DURATION": dur, "VIDEO_SRC": "reel-in.mp4"}))
print(f"premium comp: {len(plan['caption_groups'])} groups, {dur}s, cap_top={CAP_TOP}")
PY
  # Vendor GSAP into the premium comp dir (and the compositions/ subdir) so the local
  # <script src="gsap.min.js"> in root-shell-polish.html + caption-overlay.html resolves at render.
  GSAP=$(for p in "$SKILL_DIR/.hub/f-gsap/vendor" "$SKILL_DIR/.hub/f-gsap/vendor"; do [ -f "$p/gsap.min.js" ] && echo "$p/gsap.min.js" && break; done)
  [ -n "$GSAP" ] || { echo "[p-reels-split] FATAL: vendored gsap.min.js not found (expected under .hub/f-gsap/vendor/ or ../f-gsap/vendor/) — NEVER fall back to a CDN"; exit 1; }
  cp "$GSAP" "$PW/comp/gsap.min.js"
  cp "$GSAP" "$PW/comp/compositions/gsap.min.js"
  # ⚠ RENDER IS 60–600s: run this comp render via the terminal tool with background=true +
  #   notify_on_complete=true, then process(action="wait") — a foreground render is killed at the
  #   runtime ceiling and the cook fails with no resume. See the f-hyperframes-cli render gate.
  cd "$PW/comp" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 validate && \
    npx hyperframes@0.7.5 render --output "$PW/visuals.mp4" --fps 30 --quality high
  cd - >/dev/null
else
  cp "$REEL_IN" "$PW/visuals.mp4"
fi

python3 - "$PW" "$PREMIUM_DIR" "$REEL_IN" <<'PY' > "$PW/mux.sh"
import json, sys
PW, PREMIUM, REEL = sys.argv[1], sys.argv[2], sys.argv[3]
plan = json.load(open(f"{PW}/plan.json"))
cues = plan.get("sfx", [])
GRADES = {
  "warm-amber":   "curves=r='0/0 0.5/0.55 1/1':b='0/0 0.5/0.46 1/0.95',eq=contrast=1.05:saturation=1.08,unsharp=5:5:0.5",
  "clean-bright": "eq=brightness=0.02:contrast=1.06:saturation=1.1,unsharp=5:5:0.5",
  "off":          "null",
}
grade = GRADES.get(plan.get("grade","clean-bright"), GRADES["clean-bright"])
inputs = " ".join(f"-i \"{PREMIUM}/assets/sfx/{c['name']}.wav\"" for c in cues)
parts, mix = [], "[1:a]"
for j, c in enumerate(cues):
    ms = int(float(c["t"])*1000)
    parts.append(f"[{j+2}:a]adelay={ms}|{ms},volume={min(float(c.get('gain',0.5)),0.6)}[s{j}]")
    mix += f"[s{j}]"
fc = (";".join(parts)+f";{mix}amix=inputs={len(cues)+1}:normalize=0:duration=first[aout]") if cues else "[1:a]anull[aout]"
print(f'''ffmpeg -y -i "{PW}/visuals.mp4" -i "{REEL}" {inputs} \\
  -filter_complex "[0:v]{grade},format=yuv420p[vout];{fc}" \\
  -map "[vout]" -map "[aout]" \\
  -c:v libx264 -preset medium -crf 19 -r 30 \\
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart "{PW}/polished.mp4"''')
PY
bash "$PW/mux.sh" && cp "$PW/polished.mp4" "$W/polished.mp4"
```

### Step 9.7 — Overlay-FX beats (OPTIONAL — Director-placed, OFF by default)

Default behavior is unchanged: a no-op unless the Director supplies `overlay_beats`. When set, the
Director MAY drop 1–3 animated overlay graphics (pill / sticker / mini-flowchart) on top of the
assembled reel at chosen beats, via `c-overlay-fx`. Each overlay renders to a transparent (alpha)
clip and is `overlay`-composited over `polished.mp4` — the picture underneath is never re-encoded
into the graphic.

**The Director picks BOTH the moment AND a SAFE position from the map below.** An overlay must NEVER
cover the face or the HyperFrames title/captions.

**Safe-zone map — `split` format (1080×1920, seam at y=960):**
- TOP half (`y < 960`) holds graphics + the title/captions — avoid the **upper title band** (~`y120–460`).
- BOTTOM half (`y ≥ 960`) is the talking-head face — avoid the face box (~`x270–810, y1000–1750`).
- **SAFE = the top corners, a mid-band around `y700–900` (under the title, above the seam), and the
  lower-left / lower-right margins** (`x < 240` or `x > 840`) below the face box.

```bash
# overlay_beats: a JSON array the Director sets, e.g.
#   [{"type":"flowchart","nodes":["A","B"],"position":{"x":120,"y":760},"start":3.0,"duration":3.0}]
# Each spec also carries brand context. Empty/unset → skip entirely (default).
OVERLAY_BEATS="${overlay_beats:-[]}"
if [ "$(echo "$OVERLAY_BEATS" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -gt 0 ]; then
  OVERLAY_FX_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/vasanth/Code/skills -maxdepth 5 -type d -name c-overlay-fx 2>/dev/null | head -1)
  [ -z "$OVERLAY_FX_DIR" ] && { echo "[p-reels-split] overlay_beats set but c-overlay-fx not found — skipping"; OVERLAY_BEATS="[]"; }
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
    $FF -y -i "$CUR" -itsoffset "$ST" -i "$OVPNG" \
      -filter_complex "[0:v][1:v]overlay=${X}:${Y}:format=auto:enable='between(t,${ST},${EN})'[v]" \
      -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -preset medium -crf 19 \
      -c:a copy -movflags +faststart "$W/polished-ov-$i.mp4"
    CUR="$W/polished-ov-$i.mp4"
  done
  LAST=$(ls -1 "$W"/polished-ov-*.mp4 2>/dev/null | sort -V | tail -1)
  [ -n "$LAST" ] && cp "$LAST" "$W/polished.mp4"
fi
```

### Step 10 — First-frame cover rule (§2d — MANDATORY)

```bash
$FF -y -ss "$COVER_AT" -i "$W/polished.mp4" -frames:v 1 -q:v 2 "$W/cover.png"

$FF -y -loop 1 -t 0.4 -i "$W/cover.png" \
  -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -shortest \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 \
  "$W/cover-freeze.mp4"

printf "file '%s'\nfile '%s'\n" "$W/cover-freeze.mp4" "$W/polished.mp4" > "$W/cover_concat.txt"
$FF -y -f concat -safe 0 -i "$W/cover_concat.txt" \
  -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart \
  "$W/split-reel-with-cover.mp4"
cp "$W/split-reel-with-cover.mp4" "$OUT"

COVER_PNG="$W/cover.png"
echo "[p-reels-split] cover.png extracted at ${COVER_AT}s"
```

### Step 11 — Verify (mandatory)

```bash
$FF -v error -i "$OUT" -f null -

ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
  -of default=noprint_wrappers=1 "$OUT"

EXPECTED_DUR=$(python3 -c "print(round(float('$BED_DUR') + 0.4, 1))")
ACTUAL_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
python3 -c "
exp, act = float('$EXPECTED_DUR'), float('$ACTUAL_DUR')
assert abs(exp - act) < 0.5, f'duration mismatch: expected ~{exp:.2f}s, got {act:.2f}s'
print(f'duration OK: {act:.2f}s')
"

$FF -hide_banner -ss 1 -t $((${BED_DUR%.*}-2)) -i "$OUT" -af volumedetect -f null - 2>&1 \
  | grep -E "mean_volume|max_volume"

for pct in 05 20 40 60 80 95; do
  t=$(python3 -c "print(round(float('$ACTUAL_DUR')*0.${pct},1))")
  $FF -y -ss "$t" -i "$OUT" -frames:v 1 "$W/qa_$pct.png"
done
```

**For each frame, check:**
- [ ] **(a) Top half (y 0–960) has real content** — motion graphics or b-roll, NOT black.
- [ ] **(b) Bottom half (y 960–1920) shows the complete face** — forehead to chin, not cropped.
- [ ] **(c) Hard split line at y=960** — top and bottom zones do not overlap or bleed.
- [ ] **(d) Face fills the bottom half** — it is not a small inset; it occupies the full 960px of height.
- [ ] **(e) No pillarbox bars in either zone** — BLURRED-FILL covers any width gaps.
- [ ] **(f) Captions are in the top zone only** — none appear in the bottom half over the face.
- [ ] **(g) Frame 0 (cover)** is the money-shot — not black or a hook frame.

**If ANY check fails: fix, re-render, re-check. Never upload a failing reel.**

### QA gate (MANDATORY — run before upload)

Run the shared eval engine (`c-eval-runner`) on the final MP4. It reads this
recipe's `acceptance.json`, delegates the mechanical gate to `c-shorts-qa-gate`,
runs the split-specific geometry checks, and writes a structured `scorecard.json`.
**Do NOT upload if it exits non-zero (verdict FAIL).**

```bash
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_MP4> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → <video_dir>/eval/scorecard.json ; frame sweep → <video_dir>/eval/
```

- **HARD** (verdict FAIL, exit 1, blocks delivery): mechanical gate (loudness ≈ -14
  LUFS, frame-0 brightness > 0x30, resolution/fps, audio present), duration 20–62s,
  canvas exactly 1080×1920, top zone (y 0–960) not black on any sampled frame.
- **PERCEPTUAL** (verdict NEEDS_VISION until resolved): the Step-11 (a)–(g) checks
  are emitted as PENDING criteria with a frame sweep — resolve them with a vision
  pass (read the frames or run `c-vision-qa`) and set each pass/fail before upload.

The full checklist lives in `acceptance.json` (the per-recipe spec). A brand may layer
`brand-overrides/<brand-slug>/acceptance.json` to tighten thresholds (same id wins,
new ids appended). If any HARD check fails, fix the render and re-run — never deliver
a failing gate.

**Interim gates (fail-fast, recommended on expensive runs):**
```bash
bash .hub/c-eval-runner/scripts/eval-run.sh voice-bed.aac --recipe-dir "$SKILL_DIR" --step voicebed   # after Step 2
bash .hub/c-eval-runner/scripts/eval-run.sh top-all.mp4   --recipe-dir "$SKILL_DIR" --step toptrack    # after Step 6
bash .hub/c-eval-runner/scripts/eval-run.sh composite.mp4 --recipe-dir "$SKILL_DIR" --step composite   # after Step 8
```
See `.hub/c-eval-runner/SKILL.md` for the spec format + built-in checks, and
`cfw-skills-pack/docs/skills-audit.md` §4 for the generic eval architecture.

### Step 11.9 — DELIVERY GATE (MECHANICAL · HARD · blocks upload)

**Runs immediately before upload. If it exits non-zero, STOP — do NOT upload or propose.** It
proves mechanically that the premium pass actually ran (via the stamp c-reel-premium writes) and
that the eval scorecard is not FAIL, so a degraded reel can't ship silently.

```bash
python3 - "$OUT" "$W" <<'PY' || { echo "🚫 DELIVERY BLOCKED — fix the render/premium pass and re-run; do NOT upload."; exit 1; }
import os, sys, json, glob, subprocess
FINAL, W = sys.argv[1], sys.argv[2]
fail = []
stamps = glob.glob(f"{W}/**/.gate/premium.json", recursive=True)
if not any(json.load(open(s)).get("applied") for s in stamps if os.path.exists(s)):
    fail.append("premium stamp missing — c-reel-premium did not run (raw caption burns are a defect).")
sc = os.path.join(os.path.dirname(os.path.abspath(FINAL)), "eval", "scorecard.json")
if not os.path.exists(sc):
    fail.append("c-eval-runner scorecard missing — run the QA gate before delivery.")
elif json.load(open(sc)).get("verdict") == "FAIL":
    fail.append("c-eval-runner scorecard verdict = FAIL.")
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

### Step 12 — Upload to R2 and print the URL (LAST LINE)

```bash
cfw-upload "$OUT" 2>/dev/null || bash _scripts/upload-to-recordings.sh "$OUT"
cfw-upload "$COVER_PNG" 2>/dev/null || true
```

Clean up `$W` after the URL is confirmed.

---

## Notes & gotchas

- **50/50 is fixed.** The split is always at y=960 on a 1080×1920 canvas. Never move it.
- **vstack, not overlay.** The two zones are combined with `vstack=inputs=2`. Overlay would allow bleed and requires alpha handling. vstack is a hard pixel boundary.
- **Both inputs to vstack must be 1080×960.** Pre-normalise BOTH in their respective build steps. A dimension mismatch → ffmpeg fatal error with "Inputs are not the same size".
- **Bottom face fit default is `cover`.** `bottom_fit=cover` (default) scales-to-COVER-crops the face into 1080×960 — portrait talking-head sources fill the zone cleanly. Use `bottom_fit=fit` only when the face MUST not be cropped (e.g. unusual aspect ratios with important frame edges).
- **`[0:v]` must be split before forking.** Both the b-roll blurred-fill and the `fit` bottom-zone filter split `[0:v]` into `[_a][_b]` before the bg/fg chains. Reading `[0:v]` twice in one filter_complex is a fatal ffmpeg error.
- **SFX names in c-reel-premium/assets/sfx/:** `whoosh-air`, `whoosh-deep`, `impact-punch`, `impact-sub`, `riser`, `click`, `pop`, `swipe`. The planner schema lists `whoosh-soft` / `impact-soft` — these do NOT exist. Use `whoosh-air` and `impact-sub` as their equivalents.
- **Top-half graphics constraint is triple-enforced:** CSS `height:960px` on the template div, `overflow:hidden` on `html/body`, and ffmpeg `crop=1080:960` before concat (Step 6 concat normalisation).
- **CAP_TOP=860** (not 1020 like p-reels-pip). Captions live in the top zone. Setting too close to 960 risks clipping near the seam — 860 provides 100px of comfort margin.
- **No loudnorm after Step 2.** The premium pass uses `amix=normalize=0`.
- **Cover rule is mandatory.** `cover_at` comes from the beat plan. Frame 1 of the final MP4 must be the money-shot, not a black/hook frame.
- **Top-zone duration = BED_DUR.** The top-beat concat is normalised to BED_DUR; Step 7.5 trims it to match the bottom layer's `-shortest` output before vstacking.
- **No `#` comments inside `filter_complex`** (ffmpeg parse error). Use shell variables.
- **HyperFrames template height = 960.** `data-width="1080" data-height="960"` on the root div and `html,body { width:1080px; height:960px; }` in CSS. The `--width`/`--height` CLI flags are NOT supported by hyperframes CLI — canvas size is controlled via the HTML/data-attrs only.
- **Root composition = FULL HTML doc.** Bare fragment → `Unexpected token '*'`. `<template>` wrapper stripped before standalone render. HTML comments stripped before lint.
- **`window.__timelines["root"] = tl`** — dict form, NOT `.push()`.
- **`broll_style=card` (default) wraps b-roll in the canvas via `wowx-motions`.** Flat app/screen-recordings read far better as a rounded, shadowed card on the brand bg with camera motion than as blurred-fill. Requires `WOWX_DIR` + `BRAND_BG` exported; falls back to blurred-fill if `wowx-motions` isn't found. Pass `broll_style=blurred-fill` for the old full-bleed look.
- **`bottom_cutzoom=true` gives a zoom-cut every beat** — wide 1.0x on b-roll beats, punched-in **1.4x** on graphics beats. Great for short-form energy and for a single continuous read (HeyGen avatar). It only changes framing, never the audio (single muxed bed). Tune the `WIDE`/`TIGHT` constants in the Step 7 Python.
  - **TOP-ANCHORED zoom (mandatory):** the crop is anchored at `y=0` (head stays at the top, crop comes off the bottom) — NEVER centered, which eats the forehead.
  - **Crop from FULL-RES source, not a pre-downscaled frame:** crop the zoom window directly from the source's native pixels then `scale=...:flags=lanczos`. Downscaling to the zone first and then upscaling the zoom = visible pixelation. (And generate the HeyGen avatar at **`aspect_ratio:"16:9"` 1080p**, never 9:16 — 9:16 letterboxes to ~1080×608 and pixelates after the zoom.)
- **Short-form = fixed beat cadence.** For "a beat every N seconds," set `broll_clip_seconds=broll_min_seconds=broll_max_seconds=N` (e.g. 5). If `c-broll-sync` still returns uneven beats, post-rewrite `beat_list.json` onto a fixed N-second grid alternating `broll`/`graphics` before Step 6 — this is what makes a true 5s-cadence reel.
- **Transcription is offline-first.** `whisper-small` can fail to download on HF auth; `export HF_HUB_OFFLINE=1` and use a cached model (`mlx-community/whisper-large-v3-turbo`). Fix obvious ASR slips in the SRT before building `transcript.json`.
- **Premium captions have a deterministic fallback.** When the Step 9.5 `claude --print` planner is unavailable, build the plan directly from `transcript.json`: 2–4 word groups, cycle `style` 0/1/2 (never adjacent-equal), emphasise the longest word per group, full-duration coverage. Reproducible and auth-free.
- **HeyGen avatars ARE a valid source** despite the "when-to-use" wording. Drop the render in as `talking_head_video` and pass `known_transcript` (or transcribe its audio in Step 3). The continuous TTS read becomes the master audio; the top-zone beats + `bottom_cutzoom` supply the visual variety the MCP render lacks (the MCP has no scene-split / pacing / audio-enhance controls).

### Box-compat gotchas (Ubuntu 22.04 / Hermes — folded from on-box validation)

- **ffprobe csv differs on Ubuntu.** `read W H < <(... -of csv=p=0:s=' ' ...)` mis-parses there.
  Use `-of default=noprint_wrappers=1` piped through `awk -F=` to read width/height into shell vars
  (Step 1). Single-field `-of csv=p=0` (one value, e.g. duration) is unaffected.
- **No `--dangerously-skip-permissions`.** That flag is blocked for `root` on the box — drop it from
  every `claude --print` call (Step 9.5 planning). The call still works without it.
- **Source `GEMINI_API_KEY` before `cfw-transcribe`** (Step 3). cfw-transcribe's Gemini backend reads
  it from the env; on-box it lives in `/opt/cfw-agent/.env`. The guard is a no-op off-box.
- **Source `ANTHROPIC_API_KEY` before the premium planner fallback** (Step 9.5). On-box there is no
  subscription auth, so the Opus/kimi fallback needs the key from `/opt/cfw-agent/.env`. No-op off-box.
- **CTA / graphics fallback HTML must be a real HyperFrames standalone composition** — full HTML doc,
  a root element with `data-composition-id="root"` + `data-width/height/start/duration`, and a registered
  `window.__timelines["root"]`. (Both the Step 9 CTA fallback and the Step 6 graphics builder already
  satisfy this.)
- **`##` CSS guard.** gpt-5.5 occasionally emits a double-hash hex (`--bg: ##0F172A`) → white background.
  After writing ANY generated HyperFrames HTML, collapse double-hash to single — `sed -i 's/##/#/g'`
  (Step 9 CTA) or `idx_html.replace("##","#")` (Step 6 graphics builder).
- **Three.js linter no-op.** The HyperFrames linter false-flags any composition whose text contains the
  literal "THREE" (e.g. a caption "THREE.") as a missing-Three.js error. Inject a harmless Three.js CDN
  `<script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>` into that
  composition's `<head>` to satisfy the linter — it is never used at runtime.
