# Assemble

Marry the rendered picture back to the sealed voice bed in ONE pass (grade + SFX under the voice),
burn kinetic captions with `c-reel-premium`, optionally add overlay-FX beats, and finish with the
branded CTA end card as a **tail takeover** of the bed — nothing is appended. Total duration = bed
duration.

## You receive

- `prior/voice_track.mp4` — the sealed bed; its audio is the ONLY voice source. Never cut, re-time
  or loudnorm it.
- `prior/rendered_scenes.mp4` — silent picture: bed + graphics takeovers (+ b-roll takeovers).
- `prior/edit_plan.json` — `grade`, `brand`, `sfx[]`, `caption_groups[]`, `takeovers[]`.
- `prior/transcripts.json` — `.words` for the caption pass.
- `inputs/cta/cta.json` — `{"text","brandName","handle"}` when the owner supplied a CTA; dir absent
  → use the brand block of `brief.json` (`brand.name`, `brand.handle`, `brand.cta` if present).
- `brief.json` — `options.captions` (on), `options.sfx` (on), `options.cta_card` (on),
  `options.cta_duration` (3), `options.overlay_beats` ([]), `options.music` (none).

## You must produce

- `saves/assembled_video.mp4` — 1080×1920 30 fps, H.264 + AAC 48 kHz stereo, exactly the bed's
  duration: graded picture, captions burned, SFX under the voice, end card over the last
  `cta_duration` seconds. No cover frame yet — that is the final step.

## How

```bash
mkdir -p work saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-spotlight"
PREMIUM_DIR="$SKILL_DIR/.hub/c-reel-premium"; OVERLAY_FX_DIR="$SKILL_DIR/.hub/c-overlay-fx"
cp prior/edit_plan.json work/plan.json
python3 -c "import json; json.dump(json.load(open('prior/transcripts.json'))['words'], open('work/words.json','w'))"
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
CAPTIONS=$(opt captions on); SFX=$(opt sfx on); CTA_CARD=$(opt cta_card on); CTA_DURATION=$(opt cta_duration 3.0)
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
```

### 1. Grade + audio mux — bed untouched, SFX under, ONE pass

```bash
python3 - "$SKILL_DIR" <<'PY' > work/mux.sh
import json, sys
SKILL = sys.argv[1]; plan = json.load(open("work/plan.json")); cues = plan.get("sfx", [])
GRADES = {
  "warm-amber":   "curves=r='0/0 0.5/0.55 1/1':b='0/0 0.5/0.46 1/0.95',eq=contrast=1.05:saturation=1.08,unsharp=5:5:0.5",
  "clean-bright": "eq=brightness=0.02:contrast=1.06:saturation=1.1,unsharp=5:5:0.5",
}
grade = GRADES.get(plan.get("grade", "clean-bright"), GRADES["clean-bright"])
inputs = " ".join(f'-i "{SKILL}/assets/sfx/{c["name"]}.wav"' for c in cues)
parts, mix = [], "[1:a]"
for j, c in enumerate(cues):
    ms = int(float(c["t"]) * 1000)
    parts.append(f"[{j+2}:a]adelay={ms}|{ms},volume={min(float(c.get('gain', 0.5)), 0.8)}[s{j}]"); mix += f"[s{j}]"
fc = (";".join(parts) + f";{mix}amix=inputs={len(cues)+1}:normalize=0:duration=first[aout]") if cues else "[1:a]anull[aout]"
print(f'''ffmpeg -y -i prior/rendered_scenes.mp4 -i prior/voice_track.mp4 {inputs} \\
  -filter_complex "[0:v]{grade},format=yuv420p[vout];{fc}" -map "[vout]" -map "[aout]" \\
  -c:v libx264 -preset medium -crf 19 -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/bed.mp4''')
PY
[ "$SFX" = "on" ] || sed -i.bak 's/ -i "[^"]*\/assets\/sfx\/[^"]*"//g' work/mux.sh
bash work/mux.sh
```

`amix=normalize=0` keeps the voice at exactly the level sealed in *Prepare footage*. **Never
loudnorm here.** (With `sfx: off`, regenerate `work/mux.sh` with `cues = []` instead of the sed.)

### 2. Kinetic captions — `c-reel-premium`, applied EXACTLY ONCE

`work/bed.mp4` is the only valid input; never feed `work/polished.mp4` back in (double-burn).
Captions land on the fully composited picture, so they sit on top of takeovers and b-roll.
Hand-burning captions with raw ffmpeg `drawtext` is a defect.

The caption plan already exists: `work/plan.json` carries `caption_groups`, `brand` and `sfx` from
the planner, so **skip c-reel-premium's P1 planning step entirely** (no model call) and run its
P2 → P3 → P4 bodies from `$PREMIUM_DIR/SKILL.md` with:

```bash
GRADE=$(python3 -c "import json; print(json.load(open('work/plan.json')).get('grade','clean-bright'))")
export PREMIUM_DIR REEL_IN=work/bed.mp4 REEL_OUT=work/polished.mp4 WORDS_JSON=work/words.json \
       PW=work/premium CAP_TOP=1180 CAPTIONS="$CAPTIONS" GRADE="$GRADE"
mkdir -p "$PW" && cp work/plan.json "$PW/plan.json"
# P2: render the caption overlay composition (uses $PW/plan.json caption_groups; CAPTIONS=off → cp "$REEL_IN" "$PW/visuals.mp4")
# P3: mux — the grade and SFX were ALREADY applied in section 1, so run P3 with an empty sfx list and
#     no grade filter (plan copy for P3: python3 -c "import json;p=json.load(open('$PW/plan.json'));p['sfx']=[];p['grade']='none';json.dump(p,open('$PW/plan.json','w'))")
#     — the original audio of work/bed.mp4 passes through untouched.
# P4: its QA gate (duration of REEL_OUT must equal REEL_IN).
python3 - <<'PY2'
import os
assert os.path.getsize("work/polished.mp4") > 100_000, "premium output missing/empty — the pass did not run"
assert os.path.getsize("work/polished.mp4") != os.path.getsize("work/bed.mp4"), "polished == input — captions were not burned"
print("[gate-stamp] premium: kinetic captions applied once")
PY2
```

The brand accent (`plan.brand.accent`) goes on the emphasis word; the caption band top is y=1180
(takeover cards keep their content in the top ~55 %, so captions never collide).

### 3. Overlay-FX beats (optional — off by default)

Only when `options.overlay_beats` is a non-empty array. Each spec
(`{"type","text","position":{"x","y"},"start","duration"}`) renders to a transparent clip via
`node "$OVERLAY_FX_DIR/render-overlay.cjs" spec.json out.mov` and is composited with
`overlay=X:Y:format=auto:enable='between(t,ST,EN)'`, `-c:a copy`, chaining into `work/polished.mp4`.
Safe zones on this format are ONLY the top (`y < 160`) and bottom (`y > 1700`) corners — never the
face, never the caption band (y ≈ 1180–1440). Skip with a log line if the component is absent.

### 4. CTA end card — tail takeover, per-brand copy

Resolve the copy: `inputs/cta/cta.json` wins; otherwise `brief.json.brand`. **No handle → no
handle line.** Never invent a handle or reuse another brand's.

```bash
eval "$(python3 - <<'PY'
import json, os, shlex
cta = json.load(open('inputs/cta/cta.json')) if os.path.exists('inputs/cta/cta.json') else {}
brand = json.load(open('brief.json')).get('brand', {})
text = cta.get('text') or brand.get('cta') or f"Follow {brand.get('name','')} for more".strip()
print(f"CTA_TEXT={shlex.quote(text)}; BRAND_NAME={shlex.quote(cta.get('brandName') or brand.get('name') or '')}; "
      f"CTA_HANDLE={shlex.quote(cta.get('handle') or brand.get('handle') or '')}")
PY
)"
if [ "$CTA_CARD" = "on" ]; then
  CTA_DURATION="$CTA_DURATION" CTA_TEXT="$CTA_TEXT" CTA_HANDLE="$CTA_HANDLE" BRAND_NAME="$BRAND_NAME" \
    python3 "$SKILL_DIR/scripts/cta-card.py" work/plan.json work/cta-card.json   # omits the handle layer when empty
  npx hyperframes@0.7.5 render work/cta-card.json --output work/cta-card.mp4 || {
    BG_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['bg'].lstrip('#'))")
    ACCENT_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['accent'].lstrip('#'))")
    FG_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['fg'].lstrip('#'))")
    CTA_VF="drawtext=text='${CTA_TEXT}':fontcolor=#${FG_HEX}:fontsize=64:x=(w-text_w)/2:y=760:font=Oswald"
    [ -n "$CTA_HANDLE" ] && CTA_VF="${CTA_VF},drawtext=text='${CTA_HANDLE}':fontcolor=#${ACCENT_HEX}:fontsize=48:x=(w-text_w)/2:y=900:font=Inter"
    ffmpeg -y -f lavfi -i "color=c=#${BG_HEX}:s=1080x1920:r=30:d=${CTA_DURATION}" -vf "$CTA_VF" \
      -c:v libx264 -pix_fmt yuv420p -r 30 work/cta-card.mp4
  }
  CTA_START=$(python3 -c "print(${BED_DUR} - ${CTA_DURATION})")
  ffmpeg -y -i work/polished.mp4 -itsoffset "$CTA_START" -i work/cta-card.mp4 \
    -filter_complex "[0:v][1:v]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
    -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -c:a copy -movflags +faststart work/assembled.mp4
else
  cp work/polished.mp4 work/assembled.mp4
fi
```

### 5. Optional music, then save

```bash
MUSIC=$(opt music ""); if [ -n "$MUSIC" ] && [ -f "$MUSIC" ]; then
  FADE_START=$(python3 -c "print(${BED_DUR} - 0.5)")
  ffmpeg -y -i work/assembled.mp4 -i "$MUSIC" \
    -filter_complex "[1:a]aloop=loop=-1:size=2e9,atrim=duration=${BED_DUR},asetpts=PTS-STARTPTS,volume=-22dB,afade=in:st=0:d=0.8,afade=out:st=${FADE_START}:d=0.5[bg];[0:a][bg]amix=inputs=2:duration=first:normalize=0[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/with-music.mp4 \
    && mv work/with-music.mp4 work/assembled.mp4
fi
cp work/assembled.mp4 saves/assembled_video.mp4
python3 -c "
import subprocess; d=lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',f],capture_output=True,text=True).stdout)
a,b=d('saves/assembled_video.mp4'),d('prior/voice_track.mp4'); assert abs(a-b)<0.15, f'duration drifted {a:.2f} vs bed {b:.2f}'; print(f'assembled OK {a:.2f}s')"
```

## If you cannot proceed

This step has no `canAsk` (`cta` defaults to the brand). Never write `needs_input.json`. A missing
SFX file, a failed premium pass or a card render that fails even on the drawtext fallback is a
failure: exit non-zero with one plain line.

## Checks the harness runs

- `vo_continuous_bed` — for every takeover window in the edit plan (and every b-roll beat when
  present) plus the end-card window, `volumedetect` on `saves/assembled_video.mp4` reports a real
  (non −inf) `mean_volume`: the voice is audible under every cutaway and the duration equals the
  bed's.
