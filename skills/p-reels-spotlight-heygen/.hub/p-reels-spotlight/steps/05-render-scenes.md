# Render scenes

Fill the shipped HyperFrames templates from the edit plan (never author new ones), render the
**silent** graphics-takeover composition over the bed picture, and pre-render any b-roll takeover
clips. Every creative value is already in the plan; this step is mechanical.

## You receive

- `prior/voice_track.mp4` — the sealed bed (picture + audio; audio is NOT used here).
- `prior/edit_plan.json` — `duration`, `brand`, `takeovers[]`.
- `prior/beat_list.json` — present only when b-roll was planned.
- `inputs/broll/` — the b-roll clips referenced by `beat_list.json` (only when present).

## You must produce

- `saves/rendered_scenes.mp4` — 1080×1920 30 fps **silent** video, full bed length: the bed
  picture with the graphics takeovers composited at their planned windows AND (when b-roll was
  planned) the trimmed b-roll takeover clips composited at their beat windows. Captions are NOT
  burned here — the premium pass does that later on the fully composited picture.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-spotlight"
TYPING_DIR="$SKILL_DIR/.hub/c-typing-ui"
cp prior/edit_plan.json work/plan.json
cp prior/voice_track.mp4 work/base.mp4
[ -f prior/beat_list.json ] && cp prior/beat_list.json work/beat_list.json
```

### Part A — Pre-render b-roll takeover clips (only if `work/beat_list.json` exists)

Trim + FIT + blurred-fill composite, silent. The clip is shown whole; a heavily blurred zoomed copy
fills the frame edges (a no-op for true 9:16 clips). Never scale-to-cover a screen capture.

```bash
if [ -f work/beat_list.json ]; then
python3 - <<'PY'
import json, subprocess, os
bl = json.load(open("work/beat_list.json"))
os.makedirs("work/broll_takeovers", exist_ok=True)
for b in [b for b in bl["beats"] if b["kind"] == "broll"]:
    idx = b["index"]; clip = b["broll"]["clip"]
    t_in = float(b["broll"]["in"]); t_out = float(b["broll"]["out"]); dur_w = round(t_out - t_in, 3)
    out_path = f"work/broll_takeovers/broll_tk{idx}.mp4"
    subprocess.run(["ffmpeg", "-y", "-ss", str(t_in), "-t", str(dur_w), "-i", clip,
        "-vf", ("[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=40:2,setsar=1[bg];"
                "[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,setsar=1[fg];"
                "[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"),
        "-map", "[bv]", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", out_path], check=True)
    b["_rendered_path"] = out_path
    print(f"[spotlight] broll clip {idx}: {clip} [{t_in:.2f}..{t_out:.2f}] → {out_path}")
json.dump(bl, open("work/beat_list.json", "w"), indent=2)
PY
fi
```

### Part B — Build the HyperFrames composition (graphics takeovers only)

```bash
python3 - work "$SKILL_DIR" "$TYPING_DIR" <<'PY'
import json, html, os, shutil, sys, re
W, SKILL, TYPING = sys.argv[1], sys.argv[2], sys.argv[3]
gsap_src = f"{SKILL}/.hub/f-gsap/vendor/gsap.min.js"
assert os.path.exists(gsap_src), "FATAL: vendored gsap.min.js not found under .hub/f-gsap/vendor/ — never fall back to a CDN"
plan = json.load(open(f"{W}/plan.json")); dur, brand = round(float(plan["duration"]), 2), plan["brand"]
proj = f"{W}/comp"; os.makedirs(f"{proj}/compositions", exist_ok=True)
shutil.copy(f"{W}/base.mp4", f"{proj}/base.mp4")
shutil.copy(gsap_src, f"{proj}/gsap.min.js"); shutil.copy(gsap_src, f"{proj}/compositions/gsap.min.js")
def fill(t, m):
    for k, v in m.items(): t = t.replace("{{%s}}" % k, str(v))
    return t
RAW_KEYS = {"TITLE", "QUOTE", "PROMPT"}  # may carry HTML
tkdivs = []
for i, tk in enumerate(plan.get("takeovers", [])):
    d = round(float(tk["end"]) - float(tk["start"]), 2)
    m = {"ID": f"tk{i}", "DURATION": d, "BG": brand["bg"], "ACCENT": brand["accent"], "FG": brand["fg"]}
    for k, v in tk["fill"].items(): m[k] = str(v) if k in RAW_KEYS else html.escape(str(v))
    if tk["template"] == "tk-typing-ui":
        src = open(f"{TYPING}/templates/typing-scene.html").read()
        src = re.sub(r'<template[^>]*>\s*', '', src); src = re.sub(r'\s*</template>', '', src)
    else:
        src = open(f"{SKILL}/templates/{tk['template']}.html").read()
    open(f"{proj}/compositions/tk{i}.html", "w").write(fill(src, m))
    tkdivs.append(f'<div id="tk{i}-slot" class="takeover-slot" data-composition-id="tk{i}" '
                  f'data-composition-src="compositions/tk{i}.html" data-start="{tk["start"]}" '
                  f'data-duration="{d}" data-width="1080" data-height="1920" data-track-index="{i+1}"></div>')
root = open(f"{SKILL}/templates/root-shell.html").read()
open(f"{proj}/index.html", "w").write(fill(root, {"DURATION": dur, "VIDEO_SRC": "base.mp4", "BG": brand["bg"],
    "TAKEOVER_DIVS": "\n  ".join(tkdivs), "CAPTION_DIV": ""}))   # captions are burned by the premium pass later
print(f"assembled: {len(tkdivs)} graphics takeovers, {dur}s")
PY
# collapse an accidental double-hash hex (##0F172A renders white)
sed -i.bak 's/##/#/g' work/comp/index.html && rm -f work/comp/index.html.bak
( cd work/comp && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 validate )
```

### Part C — Render in the BACKGROUND (60–600 s)

Run `cd work/comp && npx hyperframes@0.7.5 render --output ../visuals.mp4 --fps 30 --quality high`
as a background process and wait for it — a foreground call can be killed at the runtime ceiling.
Then verify the render really happened (this is the proof the real HyperFrames pipeline ran — the
`scenes_not_blank` check re-derives it from the saved video, so a skipped render cannot pass):

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 work/visuals.mp4
python3 - <<'PY'
import json, subprocess
plan = json.load(open("work/plan.json")); n = len(plan.get("takeovers", []))
m = json.loads(subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries",
    "stream=width,height:format=duration","-of","json","work/visuals.mp4"], capture_output=True, text=True, check=True).stdout)
w, h, d = m["streams"][0]["width"], m["streams"][0]["height"], float(m["format"]["duration"])
assert (w, h) == (1080, 1920), f"visuals {w}x{h} != 1080x1920"
assert d > 0.5, "render produced nothing"
print(f"[gate-stamp] hyperframes: {n} graphics takeovers rendered, visuals {d:.1f}s")
PY
```

Fallback (ONLY if the HyperFrames render genuinely fails after a `npx hyperframes@0.7.5 doctor`
check): compose the takeover cards with ffmpeg `overlay` from PNG renders of the filled templates,
and say so in your final message with the real error — a silent skip is a defect.

### Part D — Composite b-roll takeovers onto the visuals (only if beat_list present)

```bash
if [ -f work/beat_list.json ]; then
python3 - <<'PY' > work/broll_overlay.sh
import json
bl = json.load(open("work/beat_list.json"))
bb = [b for b in bl["beats"] if b["kind"] == "broll" and "_rendered_path" in b]
if not bb: print('cp work/visuals.mp4 work/scenes.mp4'); raise SystemExit
inputs = ['work/visuals.mp4'] + [b["_rendered_path"] for b in bb]
parts, cur = [], "[0:v]"
for i, b in enumerate(bb):
    s, e = float(b["start"]), float(b["end"]); nxt = f"[ov{i}]" if i < len(bb)-1 else "[vfinal]"
    parts.append(f"[{i+1}:v]setpts=PTS-STARTPTS+{s}/TB[brl{i}];{cur}[brl{i}]overlay=enable='between(t,{s},{e})':eof_action=pass{nxt}")
    cur = nxt
print(f'ffmpeg -y {" ".join("-i "+p for p in inputs)} -filter_complex "{";".join(parts)}" -map "[vfinal]" -an '
      f'-c:v libx264 -pix_fmt yuv420p -preset medium -crf 19 -r 30 -movflags +faststart work/scenes.mp4')
PY
bash work/broll_overlay.sh
else
  cp work/visuals.mp4 work/scenes.mp4
fi
cp work/scenes.mp4 saves/rendered_scenes.mp4
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing template, missing vendored
GSAP, or a render that fails even after the fallback is a failure: exit non-zero with one plain
line.

## Checks the harness runs

- `scenes_not_blank` — `saves/rendered_scenes.mp4` is 1080×1920, its duration matches the bed
  within 0.5 s, and frames sampled inside every planned takeover window (graphics and b-roll) and
  at 10/50/90 % are not black (mean luma above 16/255) — i.e. every takeover rendered an opaque card
  or clip, not a blank.
