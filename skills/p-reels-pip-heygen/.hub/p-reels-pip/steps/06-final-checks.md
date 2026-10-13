# Final checks and captions

Prove continuity, bake the first-frame cover, run the QA gate and the mechanical delivery gate,
and write the per-platform post captions. Nothing creative happens here; a failing gate means the
reel is NOT delivered.

## You receive

- `prior/assembled_video.mp4` — the finished reel (background + PIP + end card + captions).
- `prior/beat_list.json` — `cover_at`, `beats[]` (b-roll windows for the continuity proof).
- `prior/transcripts.json` — `.words` (source for the post captions).
- `inputs/cta/cta.json` — CTA text / brand name / handle when supplied; else `brief.json.brand`.
- `brief.json` — `targets` (platform list), `brand.slug`, intent.

## You must produce

- `saves/final_video.mp4` — 1080×1920 30 fps: a 0.4 s money-shot freeze at position 0 followed by
  the assembled reel; AAC 48 kHz stereo throughout; duration = assembled + 0.4 s.
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
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
OUT_RAW=prior/assembled_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_RAW")
```

### 1. Verify — stream sanity + continuity proof

```bash
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,codec_name,width,height,r_frame_rate -of json "$OUT_RAW"
ffmpeg -v error -i "$OUT_RAW" -f null -
python3 - "$OUT_RAW" <<'PY'
import json, subprocess, sys
out = sys.argv[1]; bl = json.load(open("prior/beat_list.json"))
windows = [(float(b["start"]), float(b["end"])) for b in bl["beats"]]
bad = []
for s, e in sorted(windows):
    r = subprocess.run(["ffmpeg","-hide_banner","-ss",str(s),"-t",str(e-s),"-i",out,"-af","volumedetect","-f","null","-"], capture_output=True, text=True)
    line = next((l for l in r.stderr.splitlines() if "mean_volume" in l), "MISSING")
    print(f"window {s:.1f}-{e:.1f}s: {line.strip()}")
    if "MISSING" in line or "-inf" in line: bad.append((s, e))
assert not bad, f"voice silent under beats {bad}"
PY
```

### 2. Visual QA frames — read each one with vision

```bash
for pct in 05 20 40 60 80 95; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -y -ss "$t" -i "$OUT_RAW" -frames:v 1 work/qa_$pct.png
done
```

Per frame: (a) the face is whole inside the ringed PIP card, bottom-centre, never cropped;
(b) captions sit above the PIP zone (nothing textual below y≈1240), accent on the emphasis word;
(c) Latin script only; (d) graphics beats show a rich illustrative card, b-roll beats show the
planned clip; (e) grade subtle, skin natural; (f) no black/empty frame. A failed item means you
stop and report which — do not "fix" the picture here (that is a rerun of an earlier step).

### 3. First-frame cover (mandatory)

Feeds use frame 1 as the poster; the hook animates from black. Prepend a 0.4 s freeze of the
money shot at `cover_at`.

```bash
COVER_AT=$(python3 -c "import json; p=json.load(open('prior/beat_list.json')); print(p.get('cover_at', $DUR*0.35))")
ffmpeg -y -ss "$COVER_AT" -i "$OUT_RAW" -frames:v 1 saves/cover.png
ffmpeg -y -loop 1 -t 0.4 -i saves/cover.png -f lavfi -t 0.4 -i "anullsrc=r=48000:cl=stereo" \
  -vf "scale=1080:1920,setsar=1,fps=30,format=yuv420p" \
  -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/cover-freeze.mp4
printf "file '%s'\nfile '%s'\n" "$PWD/work/cover-freeze.mp4" "$PWD/$OUT_RAW" > work/concat-cover.txt
ffmpeg -y -f concat -safe 0 -i work/concat-cover.txt \
  -c:v libx264 -pix_fmt yuv420p -preset medium -crf 18 -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart saves/final_video.mp4
COVER_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/final_video.mp4)
python3 -c "raw=$DUR; cov=float('$COVER_DUR'); assert abs(cov-(raw+0.4))<0.1, f'cover duration mismatch {cov:.2f} vs {raw+0.4:.2f}'; print(f'cover OK: {cov:.2f}s')"
```

(`anullsrc` must be a lavfi input, not an `-af` filter; the concat must re-encode — `-c copy`
gives non-monotonic DTS.) Frame 0 of `saves/final_video.mp4` must not be black (`signalstats`
`YAVG > 30`) and the LAST frame must not be black either — look at `saves/cover.png`; it must
show the speaker in the PIP over a content beat, not a card, not a fade.

### 4. QA gate — `c-eval-runner` (mandatory)

```bash
BRAND_SLUG=$(python3 -c "import json; print(json.load(open('brief.json'))['brand'].get('slug',''))")
bash "$SKILL_DIR/.hub/c-eval-runner/scripts/eval-run.sh" saves/final_video.mp4 --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → saves/eval/scorecard.json ; move it out of saves/: mv saves/eval work/eval
```

HARD (verdict FAIL, exit 1): loudness ≈ −14 LUFS, frame-0 brightness > 0x30, resolution/fps,
audio present, duration 20–62 s, canvas 1080×1920, no black frame at any sample. PERCEPTUAL
(NEEDS_VISION): (a)–(f) plus VO-continuity and cover-moneyshot are emitted PENDING with a frame
sweep — resolve each with your vision pass over `work/eval/` frames and set pass/fail.

### 5. Delivery gate (mechanical, hard)

```bash
python3 - <<'PY' || { echo "DELIVERY BLOCKED — fix the render (rerun the failing step); do not deliver."; exit 1; }
import json, os, subprocess
fail = []
m = json.loads(subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height:format=duration","-of","json","saves/final_video.mp4"], capture_output=True, text=True).stdout)
w, h, d = m["streams"][0]["width"], m["streams"][0]["height"], float(m["format"]["duration"])
if (w, h) != (1080, 1920): fail.append(f"final dims {w}x{h} != 1080x1920")
if not (20 <= d <= 62): fail.append(f"duration {d:.1f}s outside 20–62s")
sc = "work/eval/scorecard.json"
if not os.path.exists(sc): fail.append("c-eval-runner scorecard missing — run the QA gate")
elif json.load(open(sc)).get("verdict") == "FAIL": fail.append("c-eval-runner verdict = FAIL")
if fail: print("DELIVERY GATE FAILURES:"); [print("  x", f) for f in fail]; raise SystemExit(1)
print("DELIVERY GATE PASSED")
PY
```

### 6. Per-platform post captions

Write `saves/captions.json` yourself from `prior/transcripts.json` words, the brief's intent and
the CTA copy (`inputs/cta/cta.json` → `brief.json.brand`): a hook line in the speaker's own words,
one line of value, the CTA; 3–8 relevant hashtags for Instagram/TikTok, a ≤ 100-char title plus
description for YouTube, no hashtags and a fuller first line for LinkedIn. Include the brand handle
only if one exists. Latin script only; no kitchen words. Validate: `python3 -c "import json;
c=json.load(open('saves/captions.json')); assert 'default' in c"`.

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A gate failure is a failure: leave
`saves/final_video.mp4` in place for inspection, exit non-zero and say which check failed and at
which timestamp so the right earlier step can be rerun.

## Checks the harness runs

- `qa_gate` — the `c-eval-runner` reel gate on `saves/final_video.mp4` is not FAIL (loudness,
  frame-0 brightness, resolution/fps, audio present).
- `duration_window` — duration within 20–62 s.
- `canvas_1080x1920` — video stream exactly 1080×1920.
- `frame_not_black` — frames at 5/20/40/60/80/95 % have mean luma above 16/255.
- Perceptual (vision pass): `face_whole_in_pip`, `latin_script_only`, `broll_beats_correct`,
  `cover_is_moneyshot` (frame 0 and `saves/cover.png` show the speaker PIP over a content beat at
  `cover_at`, not black, not a card, not a fade).
