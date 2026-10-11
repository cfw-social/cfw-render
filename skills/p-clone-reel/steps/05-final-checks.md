# Final checks and captions

Bake the first-frame cover, run the QA gate and the mechanical delivery gate, prove the picture
with a vision pass, and write the per-platform post captions. Nothing creative happens here; a
failing gate means the reel is NOT delivered.

## You receive

- `prior/composite_video.mp4` — the finished reel (narration + outro, mastered, captioned).
- `prior/format_analysis.json` — `layout.presenter` (tells the vision pass whether to expect a PIP).
- `prior/adapted_script.md` — source for the post captions.
- `inputs/cta/cta.json` — CTA text / brand name / handle when supplied; else `brief.json.brand`.
- `brief.json` — `targets` (platform list), `brand.slug`, `options.cover_style`, intent.

## You must produce

- `saves/final_video.mp4` — 1080×1920 30 fps: a 0.4 s money-shot freeze at position 0 followed by
  the composite; AAC 48 kHz stereo throughout.
- `saves/cover.png` — the money-shot frame (1080×1920).
- `saves/captions.json` — per-platform post text:

```json
{ "default": {"caption": "...", "hashtags": ["..."]},
  "instagram": {"caption": "...", "hashtags": ["..."]},
  "tiktok":    {"caption": "...", "hashtags": ["..."]},
  "youtube":   {"title": "...", "description": "...", "hashtags": ["..."]},
  "linkedin":  {"caption": "..."} }
```

One key per platform in `brief.json.targets` plus `default`. Plain Latin text, no kitchen words,
no handle unless the brand has one, no mention of the reference creator.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-clone-reel"
OUT_RAW=prior/composite_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_RAW")
ffmpeg -v error -i "$OUT_RAW" -f null -
```

### 1. First-frame cover (mandatory)

The money shot is the brightest brand card with the avatar visible (`cover_style=card-holding`) or
the brightest card alone (`faceless-card`). Pick it by sampling 20/35/50/65 % and taking the frame
with the highest mean luma that is not the hook (never 0–2 s). Prepend a 0.4 s freeze.

```bash
best=""; bestv=0
for pct in 20 35 50 65; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -y -ss "$t" -i "$OUT_RAW" -frames:v 1 work/c_$pct.png
  v=$(identify -format "%[fx:int(mean*255)]" work/c_$pct.png)
  [ "$v" -gt "$bestv" ] && { bestv=$v; best=work/c_$pct.png; }
done
cp "$best" saves/cover.png
ffmpeg -y -loop 1 -t 0.4 -i saves/cover.png -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1080:1920,setsar=1,fps=30,format=yuv420p" -shortest \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/cover-freeze.mp4
printf "file '%s'\nfile '%s'\n" "$PWD/work/cover-freeze.mp4" "$PWD/$OUT_RAW" > work/concat-cover.txt
ffmpeg -y -f concat -safe 0 -i work/concat-cover.txt \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 -preset medium -crf 18 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/final_video.mp4
```

(`anullsrc` must be a lavfi input; the concat must re-encode — `-c copy` gives non-monotonic
DTS.) Verify `saves/cover.png` is a real 1080×1920 PNG with mean luma > 48/255 OR (mean ≥ 8, luma
range ≥ 128, ≥ 2 % bright pixels).

### 2. Visual QA frames — read each one with vision

```bash
for pct in 05 20 40 60 80 95; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -y -ss "$t" -i saves/final_video.mp4 -frames:v 1 work/qa_$pct.png
done
```

Per frame: (a) when an avatar was used, the PIP / split avatar is present, sharp and inside the
frame; (b) no green fringe or halo around the avatar; (c) brand graphics fill the background in
the reference's rhythm — never a blank or solid-colour void, never a frame of the reference reel;
(d) Latin script only, captions clear of the avatar; (e) no black frame; (f) the last frame is the
brand CTA card. A failed item means you stop and report which — do not "fix" the picture here
(that is a rerun of `composite`).

### 3. QA gate — `c-eval-runner` (mandatory)

```bash
BRAND_SLUG=$(python3 -c "import json; print(json.load(open('brief.json'))['brand'].get('slug',''))")
bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" saves/final_video.mp4 --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
mv saves/eval work/eval 2>/dev/null || true   # scorecard → work/eval/scorecard.json; never leave extras in saves/
```

HARD (verdict FAIL): loudness −14 ± 1.5 LUFS, frame-0 brightness, resolution/fps, audio present,
duration 27–63 s, canvas 1080×1920. PERCEPTUAL (NEEDS_VISION): avatar PIP visible, no green-screen
residue, reference-format visuals visible, cover money-shot — resolve each with your vision pass.

### 4. Delivery gate (mechanical, hard)

```bash
python3 - <<'PY' || { echo "DELIVERY BLOCKED — fix the render (rerun the failing step); do not deliver."; exit 1; }
import json, os, subprocess
fail = []
m = json.loads(subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height:format=duration","-of","json","saves/final_video.mp4"], capture_output=True, text=True).stdout)
w, h, d = m["streams"][0]["width"], m["streams"][0]["height"], float(m["format"]["duration"])
if (w, h) != (1080, 1920): fail.append(f"final dims {w}x{h} != 1080x1920")
if not (27 <= d <= 63): fail.append(f"duration {d:.1f}s outside 27–63s")
sc = "work/eval/scorecard.json"
if not os.path.exists(sc): fail.append("c-eval-runner scorecard missing — run the QA gate")
elif json.load(open(sc)).get("verdict") == "FAIL": fail.append("c-eval-runner verdict = FAIL")
if fail: print("DELIVERY GATE FAILURES:"); [print("  x", f) for f in fail]; raise SystemExit(1)
print("DELIVERY GATE PASSED")
PY
```

### 5. Per-platform post captions

Write `saves/captions.json` from the adapted script's hook, the brief's intent and the CTA copy:
the hook line in the script's own words, one line of value, the CTA; 3–8 relevant hashtags for
Instagram/TikTok, a ≤ 100-char title plus description for YouTube, no hashtags and a fuller first
line for LinkedIn. Include the brand handle only if one exists. Never credit or name the reference
reel. Validate: `python3 -c "import json; c=json.load(open('saves/captions.json')); assert 'default' in c"`.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A gate failure is a failure: leave
`saves/final_video.mp4` in place for inspection, exit non-zero and say which check failed and at
which timestamp so the right earlier step can be rerun.

## Checks the harness runs

- `qa_gate` — the `c-eval-runner` reel gate on `saves/final_video.mp4` is not FAIL.
- `duration_window` — duration within 27–63 s.
- `canvas_1080x1920` — video stream exactly 1080×1920.
- `frame_not_black` — frames at 5/20/40/60/80/95 % have mean luma above 16/255.
- Perceptual (vision pass): `avatar_pip_visible` (skipped on voice-only runs),
  `no_greenscreen_residue`, `source_content_visible` (brand visuals in the reference format fill
  the background), `latin_script_only`, `cover_is_moneyshot` (frame 0 and `saves/cover.png` show
  the chosen card, not black, not a fade).
