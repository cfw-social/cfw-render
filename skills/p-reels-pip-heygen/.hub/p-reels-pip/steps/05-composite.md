# Composite the PIP reel

Put the speaker on the background as a rounded, brand-ringed bottom-centre PIP card, mux the sealed
voice bed back in, add the CTA end card as a **tail takeover**, optionally append the `outro`, then
burn pip-safe kinetic captions with `c-reel-premium` (grade + SFX under the voice, ONE pass).

## You receive

- `prior/voice_track.mp4` — the sealed bed (picture = the cleaned talking head, audio = the ONLY
  voice source). Never cut, re-time or loudnorm it.
- `prior/background.mp4` — silent 1080×1920 background track at bed length.
- `prior/transcripts.json` — `.words` for the caption pass.
- `prior/beat_list.json` — `cover_at` and the beats (the caption planner avoids b-roll windows' text).
- `inputs/cta/cta.json` — `{"text","brandName","handle"}` when supplied; dir absent → use
  `brief.json.brand` (`name`, `handle`, `cta` if present).
- `inputs/outro/` — one optional clip; dir absent → no outro.
- `brief.json` — `brand` (palette), `options.captions` (on), `options.sfx` (on), `options.grade`,
  `options.cta_card` (on), `options.cta_duration` (3), `options.overlay_beats` ([]),
  `options.pip_ring` (8), `options.pip_shadow` (22).

## You must produce

- `saves/assembled_video.mp4` — 1080×1920 30 fps, H.264 yuv420p + AAC 48 kHz stereo: background
  + ringed PIP card + end card over the last `cta_duration` seconds + captions, duration = bed
  duration (+ outro length when an outro was supplied). No cover frame yet — that is the final step.

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
PREMIUM_DIR="$SKILL_DIR/.hub/c-reel-premium"; OVERLAY_FX_DIR="$SKILL_DIR/.hub/c-overlay-fx"
GSAP="$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js"
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
CAPTIONS=$(opt captions on); SFX=$(opt sfx on); CTA_CARD=$(opt cta_card on); CTA_DURATION=$(opt cta_duration 3.0)
PIP_RING=$(opt pip_ring 8); PIP_SHADOW=$(opt pip_shadow 22)
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
python3 -c "import json; json.dump(json.load(open('brief.json')).get('brand') or {}, open('work/brand.json','w'))"
ACCENT_HEX=$(python3 -c "import json;print((json.load(open('work/brand.json')).get('accent') or '#F97316').lstrip('#'))")
```

### 1. PIP mask + ring frame (PIL; sharp-corner fallback if PIL is missing)

Card 364×504, 110 px bottom margin, radius 40. The ring colour is the brand accent — never a
hard-coded hex.

```bash
CARD_W=364; CARD_H=504; MARGIN=110; PIP_PAD=$(( PIP_RING + PIP_SHADOW ))
MASK=""; FRAME=""
if python3 - "$CARD_W" "$CARD_H" "$PIP_RING" "$PIP_SHADOW" "$ACCENT_HEX" 2>/dev/null <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter
CW, CH, RING, SH, HEX = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
R = 40
m = Image.new('RGBA', (CW, CH), (0, 0, 0, 0))
ImageDraw.Draw(m).rounded_rectangle([0, 0, CW-1, CH-1], radius=R, fill=(255, 255, 255, 255)); m.save("work/pip-mask.png")
if RING > 0:
    acc = tuple(int(HEX[i:i+2], 16) for i in (0, 2, 4)); P = RING + SH; FW, FH = CW + 2*P, CH + 2*P
    fr = Image.new('RGBA', (FW, FH), (0, 0, 0, 0)); rr = [P-RING, P-RING, FW-(P-RING)-1, FH-(P-RING)-1]
    if SH > 0:
        sh = Image.new('RGBA', (FW, FH), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([rr[0], rr[1]+6, rr[2], rr[3]+6], radius=R+RING, fill=(0, 0, 0, 150))
        fr = Image.alpha_composite(fr, sh.filter(ImageFilter.GaussianBlur(max(1, int(SH*0.6)))))
    ImageDraw.Draw(fr).rounded_rectangle(rr, radius=R+RING, fill=acc + (255,)); fr.save("work/pip-frame.png")
PY
then MASK=work/pip-mask.png; [ "$PIP_RING" -gt 0 ] && [ -f work/pip-frame.png ] && FRAME=work/pip-frame.png; fi
```

### 2. Composite — scale-to-FIT (face never cropped), bottom-centre, audio = the bed

`filter_complex` is ONE line. `alphamerge` needs `yuva444p` and identical dims, hence the `pad`.
`shortest=1` on the head overlay only — the static frame overlay keeps `eof_action=repeat`.

```bash
PFROM=$(( MARGIN - PIP_PAD ))
if [ -n "$MASK" ] && [ -n "$FRAME" ]; then
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=decrease,pad=${CARD_W}:${CARD_H}:(ow-iw)/2:0,setsar=1,format=yuva444p[thfit];[thfit][2:v]alphamerge[avpip];[0:v]format=yuv420p[bg];[bg][3:v]overlay=(W-w)/2:(H-h-${PFROM}):format=auto[bgf];[bgf][avpip]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -i "$MASK" -i "$FRAME" -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
elif [ -n "$MASK" ]; then
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=decrease,pad=${CARD_W}:${CARD_H}:(ow-iw)/2:0,setsar=1,format=yuva444p[thfit];[thfit][2:v]alphamerge[avpip];[0:v]format=yuv420p[bg];[bg][avpip]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -i "$MASK" -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
else
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=decrease,setsar=1[thfit];[0:v]format=yuv420p[bg];[bg][thfit]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
fi
```

### 3. CTA end card — tail takeover with ALPHA, per-brand copy

Resolve the copy: `inputs/cta/cta.json` wins; otherwise `brief.json.brand`. **No handle → no
handle line.** The card is rendered with `--format mov` (ProRes 4444) so the scrim stays
translucent — an mp4 card ships opaque. Scrim + copy live on INNER absolute layers (the alpha
capture forces the root transparent).

```bash
eval "$(python3 - <<'PY'
import json, os, shlex
cta = json.load(open('inputs/cta/cta.json')) if os.path.exists('inputs/cta/cta.json') else {}
brand = json.load(open('brief.json')).get('brand', {})
text = cta.get('text') or brand.get('cta') or f"Follow {brand.get('name','')} for more".strip()
print(f"CTA_TEXT={shlex.quote(text)}; CTA_HANDLE={shlex.quote(cta.get('handle') or brand.get('handle') or '')}")
PY
)"
if [ "$CTA_CARD" = "on" ]; then
  mkdir -p work/cta && cp "$GSAP" work/cta/gsap.min.js
  HANDLE_HTML=""; [ -n "$CTA_HANDLE" ] && HANDLE_HTML="<p id=\"cta-handle\">${CTA_HANDLE}</p>"
  cat > work/cta/index.html <<HTML
<!DOCTYPE html><html><head><meta charset="utf-8"><script src="gsap.min.js"></script>
<style>html,body{margin:0;padding:0;width:1080px;height:1920px;overflow:hidden;background:transparent;}
.scrim{position:absolute;left:0;top:0;width:1080px;height:1920px;background:rgba(15,23,42,0.85);}
.cta{position:absolute;left:0;top:0;width:1080px;height:1920px;box-sizing:border-box;padding:0 80px 288px;display:flex;flex-direction:column;align-items:center;justify-content:center;}
h1{color:#F1F5F9;font-family:Oswald,sans-serif;font-size:120px;font-weight:900;text-align:center;margin:0;}
p{color:#${ACCENT_HEX};font-family:Inter,sans-serif;font-size:56px;opacity:0.9;margin:40px 0 0;text-align:center;}</style></head>
<body><div data-composition-id="root" data-start="0" data-duration="${CTA_DURATION}" data-width="1080" data-height="1920">
<div class="scrim"></div><div class="cta"><h1 id="cta-text">${CTA_TEXT}</h1>${HANDLE_HTML}</div></div>
<script>(function(){var g=window.__gsap||window.gsap;if(!g)return;var tl=g.timeline({paused:true});
tl.from("#cta-text",{opacity:0,y:40,duration:0.4,ease:"power2.out"},0.1);
if(document.getElementById("cta-handle"))tl.from("#cta-handle",{opacity:0,y:20,duration:0.35,ease:"power2.out"},0.3);
if(!window.__timelines)window.__timelines={};window.__timelines["root"]=tl;})();</script></body></html>
HTML
  sed -i.bak 's/##/#/g' work/cta/index.html
  ( cd work/cta && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --format mov --output ../cta-card.mov --fps 30 --quality high )
  CTA_PIX=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 work/cta-card.mov)
  case "$CTA_PIX" in yuva*|rgba|argb|bgra|abgr|gbrap*) ;; *) echo "CTA card has no alpha ($CTA_PIX)"; exit 1 ;; esac
  CTA_START=$(python3 -c "print(round(${BED_DUR} - ${CTA_DURATION}, 3))")
  ffmpeg -y -i work/composed.mp4 -itsoffset "$CTA_START" -i work/cta-card.mov \
    -filter_complex "[0:v][1:v]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
    -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -c:a copy -movflags +faststart work/with-cta.mp4
  # Scrim proof: the bottom 55 % of the last frame must be more than one flat colour.
  ffmpeg -y -v error -ss "$(python3 -c "print(max(0.0, ${BED_DUR} - 0.5))")" -i work/with-cta.mp4 -frames:v 1 work/cta-proof.png
  N=$(ffmpeg -v error -i work/cta-proof.png -vf "crop=iw:ih*0.55:0:ih*0.45" -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys; b=sys.stdin.buffer.read(); print(len({b[i:i+3] for i in range(0,len(b),3)}))")
  [ "${N:-0}" -gt 1 ] || { echo "CTA scrim shipped opaque"; exit 1; }
else
  cp work/composed.mp4 work/with-cta.mp4
fi
```

### 4. Optional outro (the only thing ever appended)

```bash
OUTRO=$(ls inputs/outro/* 2>/dev/null | head -1)
if [ -n "$OUTRO" ]; then
  ffmpeg -y -i "$OUTRO" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30,format=yuv420p" \
    -af "aresample=48000" -c:v libx264 -preset medium -crf 20 -c:a aac -b:a 192k -ar 48000 -ac 2 work/outro-norm.mp4
  printf "file '%s'\nfile '%s'\n" "$PWD/work/with-cta.mp4" "$PWD/work/outro-norm.mp4" > work/outro_concat.txt
  ffmpeg -y -f concat -safe 0 -i work/outro_concat.txt -c:v libx264 -pix_fmt yuv420p -crf 19 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/pre-premium.mp4
else
  cp work/with-cta.mp4 work/pre-premium.mp4
fi
```

### 5. Kinetic captions + grade + SFX — `c-reel-premium`, EXACTLY ONCE, pip-safe

`CAP_TOP=760` so the caption band never enters the PIP zone (bottom 680 px). Follow P1 → P4 of
`$PREMIUM_DIR/SKILL.md`: P1 plans `caption_groups` / `sfx` / `grade` from `prior/transcripts.json`
`.words` (2–4 words per group, Latin script only, ≤ 1 emphasis word, no SFX in the first second;
tell the planner `CAP_TOP=760` and that the bottom 680 px is the PIP zone); P2 renders the
caption overlay comp (`CAPTIONS=off` → `cp "$REEL_IN" "$PW/visuals.mp4"`); P3 grades and mixes SFX
under the original audio with `amix=normalize=0` (`SFX=off` → empty cue list; **never loudnorm**);
P4 is its QA gate (duration of `REEL_OUT` equals `REEL_IN`). Hand-burning captions with raw
`drawtext` is a defect.

```bash
python3 -c "import json; json.dump(json.load(open('prior/transcripts.json'))['words'], open('work/words.json','w'))"
export PREMIUM_DIR REEL_IN=work/pre-premium.mp4 REEL_OUT=work/polished.mp4 WORDS_JSON=work/words.json \
       PW=work/premium CAP_TOP=760 CAPTIONS="$CAPTIONS" SFX="$SFX" GRADE="$(opt grade clean-bright)"
mkdir -p "$PW"
# run P1 → P4 here; GSAP for the premium comp: cp "$GSAP" "$PW/comp/gsap.min.js" "$PW/comp/compositions/"
python3 - <<'PY'
import os
assert os.path.getsize("work/polished.mp4") > 100_000, "premium output missing/empty — the pass did not run"
PY
```

### 6. Overlay-FX beats (optional — off by default), then save

Only when `options.overlay_beats` is non-empty: each spec renders via
`node "$OVERLAY_FX_DIR/render-overlay.cjs" spec.json out.mov` and is composited with
`overlay=X:Y:format=auto:enable='between(t,ST,EN)'`, `-c:a copy`, chaining into
`work/polished.mp4`. Safe zones: side gutters (`x < 240` or `x > 840`) and the band y ≈ 1060–1220.
Never the PIP (x 270–810, y 1240–1810), never the upper graphics zone.

```bash
cp work/polished.mp4 saves/assembled_video.mp4
python3 - <<'PY'
import os, subprocess
d = lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',f],capture_output=True,text=True).stdout)
a, b = d('saves/assembled_video.mp4'), d('prior/voice_track.mp4')
if os.path.exists('work/outro-norm.mp4'): b += d('work/outro-norm.mp4')
assert abs(a-b) < 0.15, f'duration drifted {a:.2f} vs expected {b:.2f}'; print(f'assembled OK {a:.2f}s')
PY
```

## If you cannot proceed

This step has no `canAsk` (`cta` defaults to the brand, `outro` is optional). Never write `needs_input.json`. A failed card render, an opaque scrim or a premium pass that did not run is a
failure: exit non-zero with one plain line.

## Checks the harness runs

- `vo_continuous_bed` — `volumedetect` over the whole bed window of `saves/assembled_video.mp4`
  (and the end-card window) reports a real (non −inf) `mean_volume`; duration equals the bed's
  (+ outro).
- `pip_zone_clear` — sampled frames show the ringed card bottom-centre with the face whole and no
  caption text inside y > 1240.
