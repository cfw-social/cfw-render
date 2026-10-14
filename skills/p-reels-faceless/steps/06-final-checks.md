# Final checks and captions

Bake the first-frame cover, run the QA gate and the mechanical delivery gate, prove the picture
with a vision pass, and write the per-platform post captions. Nothing creative happens here; a
failing gate means the reel is NOT delivered.

## You receive

- `prior/assembled_video.mp4` — the finished reel (bed + outro, mastered, captioned).
- `prior/beat_list.json` — `cover_at`, beats (b-roll windows for the vision pass).
- `prior/transcripts.json` — `words` (source for the post captions).
- `inputs/cta/cta.json` — CTA text / brand name / handle when supplied; else `brief.json.brand`.
- `brief.json` — `targets` (platform list), `brand.slug`, intent.

## You must produce

- `saves/final_video.mp4` — 1080×1920 30 fps: a 0.4 s money-shot freeze at position 0 followed by
  the assembled reel; AAC 48 kHz stereo throughout.
- `saves/cover.png` — the money-shot frame (1080×1920) extracted at `cover_at`.
- `saves/captions.json` — per-platform post text:

```json
{ "default": {"caption": "...", "hashtags": ["..."]},
  "instagram": {"caption": "...", "hashtags": ["..."]},
  "tiktok":    {"caption": "...", "hashtags": ["..."]},
  "youtube":   {"title": "...", "description": "...", "hashtags": ["..."]},
  "linkedin":  {"caption": "..."} }
```

One key per platform in `brief.json.targets` plus `default`. Plain Latin text, no kitchen words,
no handle unless the brand has one.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-faceless"
OUT_RAW=prior/assembled_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_RAW")
ffmpeg -v error -i "$OUT_RAW" -f null -
```

### 1. First-frame cover (mandatory)

The hook card animates in from the background, so frame 1 would be a flat card. Prepend a 0.4 s
freeze of the money shot at `cover_at` (planner-chosen; fallback 35 % into the bed, never the
hook). On dark-palette brands a card with a bright 60 px+ headline is a valid cover; prefer
footage or the brightest card.

```bash
COVER_AT=$(python3 -c "import json; p=json.load(open('prior/beat_list.json')); print(p.get('cover_at') or round($DUR*0.35,1))")
ffmpeg -y -ss "$COVER_AT" -i "$OUT_RAW" -frames:v 1 saves/cover.png
ffmpeg -y -loop 1 -t 0.4 -i saves/cover.png -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1080:1920,setsar=1,fps=30,format=yuv420p" -shortest \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/cover-freeze.mp4
printf "file '%s'\nfile '%s'\n" "$PWD/work/cover-freeze.mp4" "$PWD/$OUT_RAW" > work/concat-cover.txt
ffmpeg -y -f concat -safe 0 -i work/concat-cover.txt \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/final_video.mp4
```

(`anullsrc` must be a lavfi input; the concat must re-encode — `-c copy` gives non-monotonic
DTS.) Verify the cover: `identify saves/cover.png` is a real 1080×1920 PNG and its mean luma is
> 48/255 OR (mean ≥ 8, luma range ≥ 128, ≥ 2 % bright pixels).

### 2. Visual QA frames — read each one with vision

```bash
for pct in 05 20 40 60 80 95; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -y -ss "$t" -i saves/final_video.mp4 -frames:v 1 work/qa_$pct.png
done
```

Per frame: (a) captions in the lower third never overlap card text; (b) text legible at phone
size, no tofu boxes; (c) brand palette, not the template default; (d) the card has an
illustrative hero, not a bare title; (e) Latin script only; (f) b-roll beats show the planned
clip; (g) no black/empty frame; (h) the last frame is the brand outro. A failed item means you
stop and report which — do not "fix" the picture here (that is a rerun of an earlier step).

### 3. QA gate — `c-eval-runner` (mandatory)

```bash
BRAND_SLUG=$(python3 -c "import json; print(json.load(open('brief.json'))['brand'].get('slug',''))")
bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" saves/final_video.mp4 --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
mv saves/eval work/eval 2>/dev/null || true   # scorecard → work/eval/scorecard.json; never leave extras in saves/
```

HARD (verdict FAIL): loudness −14 ± 1.5 LUFS, frame-0 contrast rule, resolution/fps, audio
present, duration 27–93 s, canvas 1080×1920. PERCEPTUAL (NEEDS_VISION): items (a)–(h) plus
cover-moneyshot are emitted PENDING with a frame sweep — resolve each with your vision pass.

### 4. Delivery gate (mechanical, hard)

```bash
python3 - <<'PY' || { echo "DELIVERY BLOCKED — fix the render (rerun the failing step); do not deliver."; exit 1; }
import json, os, subprocess
fail = []
m = json.loads(subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height:format=duration","-of","json","saves/final_video.mp4"], capture_output=True, text=True).stdout)
w, h, d = m["streams"][0]["width"], m["streams"][0]["height"], float(m["format"]["duration"])
if (w, h) != (1080, 1920): fail.append(f"final dims {w}x{h} != 1080x1920")
if not (27 <= d <= 93): fail.append(f"duration {d:.1f}s outside 27–93s")
sc = "work/eval/scorecard.json"
if not os.path.exists(sc): fail.append("c-eval-runner scorecard missing — run the QA gate")
elif json.load(open(sc)).get("verdict") == "FAIL": fail.append("c-eval-runner verdict = FAIL")
if fail: print("DELIVERY GATE FAILURES:"); [print("  x", f) for f in fail]; raise SystemExit(1)
print("DELIVERY GATE PASSED")
PY
```

### 5. Per-platform post captions

Write `saves/captions.json` yourself from `prior/transcripts.json` words, the brief's intent and
the CTA copy: the hook line in the script's own words, one line of value, the CTA; 3–8 relevant
hashtags for Instagram/TikTok, a ≤ 100-char title plus description for YouTube, no hashtags and a
fuller first line for LinkedIn. Include the brand handle only if one exists. Latin script only; no
kitchen words; never new claims. Validate: `python3 -c "import json;
c=json.load(open('saves/captions.json')); assert 'default' in c"`.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A gate failure is a failure: leave
`saves/final_video.mp4` in place for inspection, exit non-zero and say which check failed and at
which timestamp so the right earlier step can be rerun.

## Checks the harness runs

- `qa_gate` — the `c-eval-runner` reel gate on `saves/final_video.mp4` is not FAIL.
- `duration_window` — duration within 27–93 s.
- `canvas_1080x1920` — video stream exactly 1080×1920.
- `frame_not_black` — frames at 5/20/40/60/80/95 % have mean luma above 16/255.
- `cover_has_contrast` — frame 0 is bright (mean > 48/255) or a dark card with a bright headline.
- `final_loudness` — integrated loudness −14 LUFS ± 1.5.
- Perceptual (vision pass): `no_overlapping_text`, `text_legible_mobile`, `brand_colors_correct`,
  `foreground_hero_present`, `latin_script_only`, `broll_beats_correct`, `cover_is_moneyshot`
  (frame 0 and `saves/cover.png` show the chosen scene at `cover_at`, not black, not a fade).
