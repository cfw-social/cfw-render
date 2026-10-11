# Final checks and captions

Bake the first-frame cover, run the QA gate and the mechanical delivery gate, prove the picture
with a vision pass across the runtime, write chapter markers and the per-platform post text.
Nothing creative happens here; a failing gate means the video is NOT delivered.

## You receive

- `prior/mastered_video.mp4` — the finished video.
- `prior/broll_plan.json` — rows (which beats are PIP / full-avatar / GFX, for the vision pass).
- `prior/transcripts.json` — `sections` (chapters), `words` (post text source).
- `prior/section_map.json` — `format`.
- `inputs/cta/cta.json` — CTA text / brand name / handle when supplied; else `brief.json.brand`.
- `brief.json` — `targets`, `brand.slug`, intent, `options.broll_coverage`.

## You must produce

- `saves/final_video.mp4` — 1920×1080 25 fps: a 0.4 s money-shot freeze at position 0 followed by
  the mastered video; AAC 48 kHz stereo throughout.
- `saves/cover.png` — the money-shot frame (1920×1080).
- `saves/chapters.json` — `[{"start": 0, "title": "Hook"}, ...]` from `sections` (also written as
  YouTube chapter lines inside the description).
- `saves/captions.json` — per-platform post text:

```json
{ "default": {"caption": "...", "hashtags": ["..."]},
  "youtube":  {"title": "...", "description": "...\n\n0:00 Hook\n0:31 The problem\n...", "hashtags": ["..."]},
  "linkedin": {"caption": "..."},
  "facebook": {"caption": "..."} }
```

One key per platform in `brief.json.targets` plus `default`. Plain Latin text, no kitchen words,
no handle unless the brand has one.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"
IN=prior/mastered_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")
ffmpeg -v error -i "$IN" -f null -
```

### 1. First-frame cover (mandatory)

The money shot is the brightest illustrative beat — a `FULLSCREEN_BROLL` GFX row or a PIP beat
over bright footage, never the hook's bare avatar, never the CTA. Pick from the plan:

```bash
python3 -c "
import json; p=json.load(open('prior/broll_plan.json'))
c=[r for r in p['rows'] if r['layout']!='AVATAR_FULL' and r['asset']!='gfx:cta' and r['start']>30]
print(round(c[0]['start']+min(2.5,(c[0]['end']-c[0]['start'])/2),1) if c else round(float('$DUR')*0.3,1))" > work/cover_at.txt
best=""; bestv=0
for t in "$(cat work/cover_at.txt)" $(python3 -c "print(round($DUR*0.45,1), round($DUR*0.6,1))"); do
  ffmpeg -y -ss "$t" -i "$IN" -frames:v 1 "work/c_$t.png"; v=$(identify -format "%[fx:int(mean*255)]" "work/c_$t.png")
  [ "$v" -gt "$bestv" ] && { bestv=$v; best="work/c_$t.png"; }
done
[ "$bestv" -gt 30 ] || { echo "no bright cover candidate (best YAVG $bestv) — rerun composite"; exit 1; }
cp "$best" saves/cover.png
ffmpeg -y -loop 1 -t 0.4 -i saves/cover.png -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1920:1080,setsar=1,fps=25,format=yuv420p" -shortest -tune stillimage -c:v libx264 -g 25 -c:a aac -ar 48000 -ac 2 work/cover-freeze.mp4
printf "file '%s'\nfile '%s'\n" "$PWD/work/cover-freeze.mp4" "$PWD/$IN" > work/concat-cover.txt
ffmpeg -y -f concat -safe 0 -i work/concat-cover.txt -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.1 -preset medium -crf 18 -g 25 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/final_video.mp4
```

(The concat must re-encode — `-c copy` gives non-monotonic DTS.) Verify frame 0 and the last
frame: `ffmpeg -ss T -i saves/final_video.mp4 -vf signalstats -frames:v 1 -f null -` → `YAVG > 30`.

### 2. Visual QA frames — read each one with vision

```bash
for pct in 15 30 45 60 75 90; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))"); ffmpeg -y -ss "$t" -i saves/final_video.mp4 -frames:v 1 work/qa_$pct.png
done
ffmpeg -y -sseof -45 -i saves/final_video.mp4 -frames:v 1 work/qa_cta.png
```

Per frame, with the plan row for that time: (a) background never a bare black void; (b) on
full-avatar beats the whole face is visible, not cropped or stretched, no green ghost fringe;
(c) on PIP beats the rounded gold-rim card is fully on screen in the planned corner; (d) graphics
and captions clear that corner; (e) the background fills 1920×1080 — no pillarbox / letterbox
bands; (f) captions (when on) legible with the accent active word, inside the lower band;
(g) frame 0 is the money shot; (h) GFX / b-roll coverage is plausible against the plan; (i) the
`qa_cta.png` frame shows the branded CTA card; (j) lip movement plausibly matches speech on
avatar beats; (k) no green fringe anywhere colorkey ran. A failed item means you stop and report
which — do not "fix" the picture here (that is a rerun of an earlier step).

### 3. QA gate — `c-eval-runner` (mandatory)

```bash
BRAND_SLUG=$(python3 -c "import json; print(json.load(open('brief.json'))['brand'].get('slug',''))")
bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" saves/final_video.mp4 --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
mv saves/eval work/eval 2>/dev/null || true   # scorecard → work/eval/scorecard.json; never leave extras in saves/
```

HARD (verdict FAIL): loudness −14 ± 1.5, frame-0 `YAVG > 30`, resolution 1920×1080 / fps, audio
present, duration 300–1200 s. PERCEPTUAL (NEEDS_VISION): (a)–(k) — resolve each with your pass.

### 4. Delivery gate (mechanical, hard)

```bash
python3 - <<'PY' || { echo "DELIVERY BLOCKED — fix the render (rerun the failing step); do not deliver."; exit 1; }
import json, os, subprocess
fail = []
m = json.loads(subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height:format=duration","-of","json","saves/final_video.mp4"], capture_output=True, text=True).stdout)
w, h, d = m["streams"][0]["width"], m["streams"][0]["height"], float(m["format"]["duration"])
if (w, h) != (1920, 1080): fail.append(f"final dims {w}x{h} != 1920x1080")
if not (300 <= d <= 1200): fail.append(f"duration {d:.0f}s outside 300–1200s")
sc = "work/eval/scorecard.json"
if not os.path.exists(sc): fail.append("c-eval-runner scorecard missing — run the QA gate")
elif json.load(open(sc)).get("verdict") == "FAIL": fail.append("c-eval-runner verdict = FAIL")
if fail: print("DELIVERY GATE FAILURES:"); [print("  x", f) for f in fail]; raise SystemExit(1)
print("DELIVERY GATE PASSED")
PY
```

### 5. Chapters and per-platform post text

`saves/chapters.json` from `transcripts.sections` (+0.4 s for the cover freeze; titles are the
section titles, no kitchen words). `saves/captions.json`: a ≤ 100-char YouTube title, a
description with the hook, one value paragraph, the CTA and the chapter lines; LinkedIn / Facebook
a fuller first line and no hashtags; 3–8 hashtags where used. Brand handle only if it exists.
Validate: `python3 -c "import json; c=json.load(open('saves/captions.json')); assert 'default' in c; json.load(open('saves/chapters.json'))"`.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A gate failure is a failure: leave
`saves/final_video.mp4` in place for inspection, exit non-zero and say which check failed at which
timestamp so the right earlier step can be rerun.

## Checks the harness runs

- `qa_gate` — the `c-eval-runner` gate (format `vsl` landscape set) on `saves/final_video.mp4` is not FAIL.
- `duration_window` — duration within 300–1200 s.
- `canvas_1920x1080` — video stream exactly 1920×1080.
- `frame0_not_black` — frame at 1 % has `YAVG > 30`.
- Perceptual (vision pass): `bg_not_black`, `avatar_full_whole_face`, `pip_card_on_screen`,
  `gfx_clears_pip`, `bg_fills_frame`, `captions_legible` (skipped when captions are off),
  `frame0_moneyshot`, `broll_coverage`, `cta_visible_end`, `lipsync_plausible`, `no_green_fringe`.
