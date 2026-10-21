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

### 2. Composite — scale-to-FILL (top-biased crop, no bars), bottom-centre, audio = the bed

`filter_complex` is ONE line. `alphamerge` needs `yuva444p` and identical dims, hence the `crop`. WI2.71: fill + crop, never fit + pad — padding showed bars in the card.
The crop is top-biased (`y=0`): the head is always kept; only the body below the card is lost.
`shortest=1` on the head overlay only — the static frame overlay keeps `eof_action=repeat`.
That shortest cut can end the picture before the bed audio; the hold below clones the last
real frame across the gap so the tail is not black. A CTA mov that runs past the bed does
the same if it is not trimmed — the overlay cap below stops at the bed.

```bash
PFROM=$(( MARGIN - PIP_PAD ))
if [ -n "$MASK" ] && [ -n "$FRAME" ]; then
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=increase,crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0,setsar=1,format=yuva444p[thfit];[thfit][2:v]alphamerge[avpip];[0:v]format=yuv420p[bg];[bg][3:v]overlay=(W-w)/2:(H-h-${PFROM}):format=auto[bgf];[bgf][avpip]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -i "$MASK" -i "$FRAME" -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
elif [ -n "$MASK" ]; then
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=increase,crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0,setsar=1,format=yuva444p[thfit];[thfit][2:v]alphamerge[avpip];[0:v]format=yuv420p[bg];[bg][avpip]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -i "$MASK" -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
else
  FC="[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=increase,crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0,setsar=1[thfit];[0:v]format=yuv420p[bg];[bg][thfit]overlay=(W-w)/2:(H-h-${MARGIN}):format=auto:shortest=1[v];[1:a]anull[a]"
  ffmpeg -y -i prior/background.mp4 -i prior/voice_track.mp4 -filter_complex "$FC" -map "[v]" -map "[a]" \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart work/composed.mp4
fi
# WI2.64: hold the last real frame out to the bed, and stop captions at the CTA window.
cat > work/hold_tail.py <<'PY'
import json, os, re, subprocess, sys

FLOOR = 16.0
OUT_FPS = 30.0

def run(args):
    return subprocess.run(args, capture_output=True, text=True)

def probe(path):
    p = run(["ffprobe", "-v", "error", "-show_entries",
             "format=duration:stream=codec_type,duration,nb_frames,r_frame_rate",
             "-of", "json", path])
    if p.returncode != 0:
        sys.stderr.write("hold_tail: ffprobe failed\n")
        return None
    data = json.loads(p.stdout or "{}")
    fmt = float((data.get("format") or {}).get("duration") or 0)
    vid = None
    fps = OUT_FPS
    for st in data.get("streams") or []:
        if st.get("codec_type") != "video":
            continue
        rate = str(st.get("r_frame_rate") or "30/1")
        if "/" in rate:
            n, d = rate.split("/", 1)
            df = float(d) if d else 0.0
            fps = (float(n) / df) if df else OUT_FPS
        else:
            fps = float(rate or OUT_FPS)
        if fps <= 0:
            fps = OUT_FPS
        dur = st.get("duration")
        nb = st.get("nb_frames")
        if dur not in (None, "N/A", ""):
            vid = float(dur)
        elif nb not in (None, "N/A", ""):
            vid = float(nb) / fps
        break
    if vid is None:
        c = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
                 "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path])
        n = (c.stdout or "").strip()
        vid = (int(n) / fps) if n.isdigit() else fmt
    return fmt, vid, fps

def yavgs(path, start):
    cmd = ["ffmpeg", "-hide_banner", "-nostats"]
    if start is not None and start > 0:
        cmd += ["-ss", "%.3f" % start]
    cmd += ["-i", path, "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
            "-an", "-f", "null", "-"]
    p = run(cmd)
    blob = (p.stderr or "") + "\n" + (p.stdout or "")
    return [float(v) for v in re.findall(r"lavfi\.signalstats\.YAVG=([0-9.]+)", blob)]

def trailing(samples):
    n = 0
    for v in reversed(samples):
        if v <= FLOOR:
            n += 1
        else:
            break
    return n

def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: hold_tail.py VIDEO [TARGET_SECONDS]\n")
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        sys.stderr.write("hold_tail: missing %s\n" % path)
        return 1
    target = None
    if len(sys.argv) > 2 and sys.argv[2] not in ("", "none"):
        target = float(sys.argv[2])
    probed = probe(path)
    if not probed:
        return 1
    fmt, vid, fps = probed
    if target is None:
        target = fmt
    if target <= 0 or vid <= 0:
        sys.stderr.write("hold_tail: bad duration\n")
        return 1
    samples = yavgs(path, max(0.0, vid - 3.0))
    if not samples:
        samples = yavgs(path, None)
    if not samples:
        sys.stderr.write("hold_tail: no YAVG samples\n")
        return 1
    trail = trailing(samples)
    if trail == len(samples):
        full = yavgs(path, None)
        if not full or trailing(full) == len(full):
            sys.stderr.write("hold_tail: entire video is black\n")
            return 1
        samples = full
        trail = trailing(samples)
    picture_end = vid - (trail / fps)
    if trail > 0:
        picture_end -= 0.5 / fps
    frame = 1.0 / fps
    # A short video stream must not no-op just because the container matches the bed.
    if trail == 0 and abs(vid - target) <= frame + 1e-3 and abs(fmt - target) <= frame + 1e-3:
        print("hold_tail: no-op %s picture=%.3f target=%.3f" % (path, picture_end, target))
        return 0
    out_frames = max(1, int(round(target * OUT_FPS)))
    keep = int(picture_end * OUT_FPS)
    if keep < 1:
        keep = 1
    if keep > out_frames:
        keep = out_frames
    good_end = keep / OUT_FPS
    gap = (out_frames - keep) / OUT_FPS
    out = path + ".hold.mp4"
    fc = (
        "[0:v]trim=start=0:end=%.6f,setpts=PTS-STARTPTS,fps=30,"
        "tpad=stop_mode=clone:stop_duration=%.6f,format=yuv420p[v]"
        % (good_end, gap)
    )
    # Copy the bed audio. Re-encoding it would move the sealed -14 LUFS level.
    p = run([
        "ffmpeg", "-y", "-i", path, "-filter_complex", fc,
        "-map", "[v]", "-map", "0:a",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p",
        "-c:a", "copy", "-t", "%.6f" % (out_frames / OUT_FPS), "-movflags", "+faststart", out,
    ])
    if p.returncode != 0 or not os.path.isfile(out):
        err = ((p.stderr or "")[-400:]).replace("\n", " | ")
        sys.stderr.write("hold_tail: encode failed: %s\n" % err)
        if os.path.isfile(out):
            os.remove(out)
        return 1
    last = yavgs(out, max(0.0, (out_frames / OUT_FPS) - 0.5))
    if not last or last[-1] <= FLOOR:
        got = last[-1] if last else None
        sys.stderr.write("hold_tail: last frame still black (%s)\n" % got)
        os.remove(out)
        return 1
    os.replace(out, path)
    print("hold_tail: held %s to %.3fs (keep %.3f gap %.3f)" % (path, out_frames / OUT_FPS, good_end, gap))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PY
cat > work/clamp_captions.py <<'PY'
import json, os, sys

EPS = 1e-3

def limit_of():
    path = os.environ.get("CTA_WINDOW") or "work/cta-window.json"
    if not os.path.exists(path):
        return None
    data = json.load(open(path))
    if not isinstance(data, dict):
        return None
    start = data.get("cta_start")
    if start is None:
        return None
    return float(start)

def start_of(row):
    if isinstance(row, dict) and "start" in row:
        return float(row["start"])
    if isinstance(row, dict) and "s" in row:
        return float(row["s"])
    return None

def end_of(row):
    if isinstance(row, dict) and "end" in row:
        return float(row["end"])
    if isinstance(row, dict) and "e" in row:
        return float(row["e"])
    return None

def clamp_row(row, limit):
    s = start_of(row)
    if s is not None and s >= limit - EPS:
        return None
    e = end_of(row)
    if e is not None and e > limit:
        if "end" in row:
            row["end"] = limit
        if "e" in row:
            row["e"] = limit
    return row

def overlaps(row, limit):
    s = start_of(row)
    e = end_of(row)
    if s is not None and s >= limit - EPS:
        return True
    if e is not None and e > limit + 1e-6:
        return True
    return False

def dump(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh)
        fh.write("\n")

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: clamp_captions.py words SRC DEST | plan PLAN\n")
        return 2
    mode = sys.argv[1]
    limit = limit_of()
    if mode == "words":
        if len(sys.argv) != 4:
            sys.stderr.write("usage: clamp_captions.py words SRC DEST\n")
            return 2
        src, dest = sys.argv[2], sys.argv[3]
        data = json.load(open(src))
        words = data["words"] if isinstance(data, dict) and "words" in data else data
        if not isinstance(words, list):
            sys.stderr.write("clamp_captions: words payload is not a list\n")
            return 1
        out = []
        for w in words:
            if limit is None or not isinstance(w, dict):
                out.append(w)
                continue
            c = clamp_row(dict(w), limit)
            if c is not None:
                out.append(c)
        if limit is not None:
            for w in out:
                if isinstance(w, dict) and overlaps(w, limit):
                    sys.stderr.write("clamp_captions: word still overlaps the CTA window\n")
                    return 1
        dump(dest, out)
        return 0
    if mode == "plan":
        plan_path = sys.argv[2]
        if not os.path.exists(plan_path):
            return 0
        plan = json.load(open(plan_path))
        if limit is not None and isinstance(plan, dict) and isinstance(plan.get("caption_groups"), list):
            kept = []
            for g in plan["caption_groups"]:
                if not isinstance(g, dict):
                    kept.append(g)
                    continue
                gs = start_of(g)
                if gs is not None and gs >= limit - EPS:
                    continue
                g = dict(g)
                words = g.get("words")
                if isinstance(words, list):
                    nw = []
                    for w in words:
                        if not isinstance(w, dict):
                            nw.append(w)
                            continue
                        c = clamp_row(dict(w), limit)
                        if c is not None:
                            nw.append(c)
                    g["words"] = nw
                    if not nw:
                        continue
                ge = end_of(g)
                if ge is not None and ge > limit:
                    if "end" in g:
                        g["end"] = limit
                    if "e" in g:
                        g["e"] = limit
                kept.append(g)
            plan["caption_groups"] = kept
            for g in kept:
                if not isinstance(g, dict):
                    continue
                if overlaps(g, limit):
                    sys.stderr.write("clamp_captions: caption group still overlaps the CTA window\n")
                    return 1
                for w in g.get("words") or []:
                    if isinstance(w, dict) and overlaps(w, limit):
                        sys.stderr.write("clamp_captions: plan word still overlaps the CTA window\n")
                        return 1
        if isinstance(plan, (dict, list)):
            dump(plan_path, plan)
        return 0
    sys.stderr.write("clamp_captions: unknown mode %s\n" % mode)
    return 2

if __name__ == "__main__":
    sys.exit(main())
PY
python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
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
  BED_DUR=${BED_DUR:-$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)}
  python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
  CTA_START=$(python3 -c "print(max(0.0, round(${BED_DUR} - ${CTA_DURATION}, 3)))")
  python3 -c 'import json,sys; json.dump({"cta_start": float(sys.argv[1]), "bed_dur": float(sys.argv[2])}, open("work/cta-window.json","w"))' "$CTA_START" "$BED_DUR"
  # WI2.64 CTA overlay: trim the card to the window, delay it, stop at the bed.
  ffmpeg -y -i work/composed.mp4 -i work/cta-card.mov \
    -filter_complex "[1:v]trim=duration=${CTA_DURATION},setpts=PTS-STARTPTS+${CTA_START}/TB[cta];[0:v][cta]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
    -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -c:a copy -t "$BED_DUR" -movflags +faststart work/with-cta.mp4
  python3 work/hold_tail.py work/with-cta.mp4 "$BED_DUR" || exit 1
  # Scrim proof: the bottom 55 % of the last frame must be more than one flat colour.
  ffmpeg -y -v error -ss "$(python3 -c "print(max(0.0, ${BED_DUR} - 0.5))")" -i work/with-cta.mp4 -frames:v 1 work/cta-proof.png
  N=$(ffmpeg -v error -i work/cta-proof.png -vf "crop=iw:ih*0.55:0:ih*0.45" -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys; b=sys.stdin.buffer.read(); print(len({b[i:i+3] for i in range(0,len(b),3)}))")
  [ "${N:-0}" -gt 1 ] || { echo "CTA scrim shipped opaque"; exit 1; }
else
  BED_DUR=${BED_DUR:-$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)}
  python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
  python3 -c 'import json,sys; json.dump({"cta_start": None, "bed_dur": float(sys.argv[1])}, open("work/cta-window.json","w"))' "$BED_DUR"
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
python3 work/hold_tail.py work/pre-premium.mp4 || exit 1
```

### 5. Kinetic captions + grade + SFX — `c-reel-premium`, EXACTLY ONCE, pip-safe

`CAP_TOP=760` so the caption band never enters the PIP zone (bottom 680 px). Follow P1 → P4 of
`$PREMIUM_DIR/SKILL.md`: P1 plans `caption_groups` / `sfx` / `grade` from `prior/transcripts.json`
`.words` (2–4 words per group, phrases kept whole, Latin script only, ≤ 1 emphasis word, no
SFX in the first second;
tell the planner `CAP_TOP=760` and that the bottom 680 px is the PIP zone); P2 renders the
caption overlay comp (`CAPTIONS=off` → `cp "$REEL_IN" "$PW/visuals.mp4"`); P3 grades and mixes SFX
under the original audio with `amix=normalize=0` (`SFX=off` → empty cue list; **never loudnorm**);
P4 is its QA gate (duration of `REEL_OUT` equals `REEL_IN`). Hand-burning captions with raw
`drawtext` is a defect.

Keep caption phrases whole (WI2.76). P1's plan may split a phrase (`She approved them with` /
`FLOUR STILL` / `on her hands,`). Write the helper below first. The block after it runs P1, then
the repair `python3 work/caption_phrases.py "$PW/plan.json" || exit 1` as a command, then P2 → P4
(WI2.78). The repair moves a group-ending preposition, article, possessive, conjunction or
auxiliary into the next group, merges a 1–2 word mid-clause fragment into a neighbour, keeps every
word timing and fixes styles, overlaps and emphasis. The `--check` after P4 fails the step when a
split phrase was rendered. `CAPTIONS=off` renders no captions, so both are skipped.

```bash
mkdir -p work saves
cat > work/caption_phrases.py <<'PY'
# WI2.76: keep caption phrases whole - never split a group mid-clause.
# usage: python3 work/caption_phrases.py PLAN.json           (repair caption_groups in place)
#        python3 work/caption_phrases.py --check PLAN.json   (exit 1 when a group splits a phrase)
# A break never follows a preposition, article, conjunction or auxiliary (the trailing word
# moves to the next group). A 1-2 word group from mid-clause (no punctuation before it or after
# it) merges into a neighbour. Groups stay 2-4 words where they were; up to 6 to keep a phrase
# whole (a longer one is split at punctuation or a clause start). Word timings never change.
# WI2.78: repair mode also fixes adjacent equal styles, a group overlap and a second emphasis
# word on a plan that is already whole; a possessive ("her", "his") joins the next word.
# WI2.79: both modes refuse a group whose end is not after its start, or whose start is not
# after the previous group's start - an overlap is clamped only when the groups are in order.
import json, os, re, sys

MAX_WORDS = 6
JOINERS = set((
    "a an the my your our their its his her every each "
    "and but or nor so yet if than because while "
    "with of to in on at for from by into onto about as like through over under after before "
    "between among during without within until upon via toward towards near against across "
    "is am are was were be been being will would can could shall should may might must").split())
CLOSERS = ".,!?;:—–…"
CONTRACTION = re.compile(r"[a-z]('s|'re|'ve|'ll|'d|'m)$")

def text(w):
    return str(w.get("w", w.get("text", "")))

def bare(w):
    t = text(w).strip().lower().replace("’", "'")
    return re.sub(r"^[^a-z0-9']+|[^a-z0-9']+$", "", t)

def closes(w):
    # the word ends a clause: trailing punctuation (quotes/brackets ignored)
    t = re.sub(r"[\"'”’)\]]+$", "", text(w).strip())
    return bool(t) and t[-1] in CLOSERS

def joiner(w):
    if closes(w):
        return False
    b = bare(w)
    return b in JOINERS or bool(CONTRACTION.search(b))

def empty_groups(groups):
    # WI2.78: a group without words cannot be checked or repaired - say so plainly
    return ["group %d has no words - every caption group needs at least one word" % i
            for i, g in enumerate(groups) if not g.get("words")]

def num(v):
    try:
        return None if isinstance(v, bool) else float(v)
    except (TypeError, ValueError):
        return None

def timing_problems(groups):
    # WI2.79: clamping an overlap is only safe when every group runs forward in time and
    # the groups are in order; otherwise say so plainly (no clamp to end <= start)
    out, prev = [], None
    for i, g in enumerate(groups):
        s, e = num(g.get("start")), num(g.get("end"))
        if s is None or e is None:
            out.append("group %d has no start/end time (start=%r, end=%r) - every caption group "
                       "needs numeric start and end" % (i, g.get("start"), g.get("end")))
            prev = None
            continue
        if e <= s:
            out.append("group %d ends at %s, not after its start %s - a group must end after it starts"
                       % (i, g.get("end"), g.get("start")))
        if prev is not None and s <= prev:
            out.append("group %d starts at %s, not after group %d (starts at %s) - caption groups "
                       "must be in time order" % (i, g.get("start"), i - 1, groups[i - 1].get("start")))
        prev = s
    return out

def structure_problems(groups):
    # a plan these cannot be checked or repaired safely: no words, no/bad timings
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        return ["caption_groups is not a list of groups"]
    return empty_groups(groups) or timing_problems(groups)

def fragment(groups, i):
    # a 1-2 word group with no clause break before it and none after it
    g = groups[i]["words"]
    if not (0 < i < len(groups) - 1) or len(g) > 2:
        return False
    return not closes(groups[i - 1]["words"][-1]) and not closes(g[-1])

def bad_break(groups, i):
    # the break after group i falls inside a phrase
    return i < len(groups) - 1 and joiner(groups[i]["words"][-1])

def problems(groups):
    out = structure_problems(groups)
    if out:
        return out
    for i, g in enumerate(groups):
        ws = g.get("words") or []
        say = " ".join(text(w) for w in ws)
        if len(ws) > MAX_WORDS + 1:
            out.append("group %d has %d words: %r" % (i, len(ws), say))
        if fragment(groups, i):
            out.append("group %d is a mid-clause fragment: %r" % (i, say))
        if bad_break(groups, i):
            out.append("group %d ends inside a phrase: %r | %r" % (
                i, say, " ".join(text(w) for w in groups[i + 1]["words"])))
        if sum(1 for w in ws if w.get("em")) > 1:
            out.append("group %d has more than one emphasis word" % i)
        if i and g.get("style") == groups[i - 1].get("style"):
            out.append("groups %d and %d share style %s" % (i - 1, i, g.get("style")))
        if i and float(g["start"]) < float(groups[i - 1]["end"]) - 1e-6:
            out.append("group %d overlaps group %d" % (i, i - 1))
    return out

def split_long(ws):
    # best cut of an over-long group: after punctuation, else before a clause start,
    # never leaving a phrase-ending word on the left, both sides >= 3 words
    best = None
    for k in range(3, len(ws) - 2):
        left = ws[k - 1]
        if joiner(left):
            continue
        score = (0 if closes(left) else 1 if bare(ws[k]) in JOINERS else 2, abs(len(ws) - 2 * k))
        if best is None or score < best[0]:
            best = (score, k)
    return None if best is None else best[1]

def repair(groups):
    groups = [dict(g, words=[dict(w) for w in (g.get("words") or [])]) for g in groups]
    changed = False
    for _ in range(200):
        moved = False
        # fragments first, then phrase-ending breaks, then over-long groups
        frag = [i for i in range(len(groups)) if fragment(groups, i)]
        brk = [i for i in range(len(groups)) if bad_break(groups, i)]
        order = frag[:1] or brk[:1] or range(len(groups))
        for i in order:
            if fragment(groups, i):
                prev_n, next_n = len(groups[i - 1]["words"]), len(groups[i + 1]["words"])
                j = i - 1 if prev_n < next_n else i + 1
                lo, hi = min(i, j), max(i, j)
                groups[lo]["words"] += groups[hi]["words"]
                groups[lo]["_new"] = changed = True; del groups[hi]
                moved = True; break
            if bad_break(groups, i):
                a, b = groups[i], groups[i + 1]
                while a["words"] and joiner(a["words"][-1]):
                    b["words"].insert(0, a["words"].pop())
                a["_new"] = b["_new"] = changed = True
                if not a["words"]:
                    del groups[i]
                moved = True; break
            if len(groups[i]["words"]) > MAX_WORDS:
                k = split_long(groups[i]["words"])
                if k is None:
                    continue
                g = groups[i]
                tail = dict(g, words=g["words"][k:]); g["words"] = g["words"][:k]
                groups.insert(i + 1, tail); g["_new"] = tail["_new"] = changed = True
                moved = True; break
        if not moved:
            break
    for g in groups:
        if g.pop("_new", False):
            g["start"], g["end"] = g["words"][0]["s"], g["words"][-1]["e"]
    return groups, changed

def restyle(groups):
    for i, g in enumerate(groups):
        prev = groups[i - 1].get("style") if i else None
        if g.get("style") == prev:
            nxt = groups[i + 1].get("style") if i + 1 < len(groups) else None
            g["style"] = next(s for s in (0, 1, 2) if s not in (prev, nxt))

def tidy(groups):
    # WI2.78: run on every plan, regrouped or not - at most one emphasis word per group,
    # no group overlaps the next (its end moves back, word timings never move), no two
    # neighbours share a style
    for g in groups:
        seen = False
        for w in g["words"]:
            if w.get("em"):
                if seen:
                    w["em"] = False
                seen = True
    for a, b in zip(groups, groups[1:]):
        if float(a["end"]) > float(b["start"]):
            a["end"] = b["start"]
    restyle(groups)

def run(plan):
    orig = plan.get("caption_groups") or []
    if not orig:
        return plan, False
    bad = structure_problems(orig)
    if bad:
        raise ValueError("; ".join(bad))
    first_start, last_end = orig[0]["start"], orig[-1]["end"]
    groups, regrouped = repair(orig)
    if regrouped:
        groups[0]["start"] = min(float(groups[0]["start"]), float(first_start))
        groups[-1]["end"] = max(float(groups[-1]["end"]), float(last_end))
    tidy(groups)
    if not regrouped and groups == orig:
        return plan, False
    plan = dict(plan, caption_groups=groups)
    return plan, True

def stop(msg):
    print("caption phrase check: " + msg, file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    args = sys.argv[1:]
    check = args[:1] == ["--check"]
    if len(args) != (2 if check else 1):
        stop("usage: caption_phrases.py [--check] PLAN.json (WI2.79)")
    path = args[-1]
    if not os.path.isfile(path):
        stop("plan not found: %s - write the plan before this step (WI2.79)" % path)
    try:
        plan = json.load(open(path))
    except ValueError as exc:
        stop("plan is not valid JSON: %s (%s) (WI2.79)" % (path, exc))
    if not isinstance(plan, dict):
        stop("plan is not a JSON object: %s (WI2.79)" % path)
    structural = structure_problems(plan.get("caption_groups") or [])
    if structural:
        for b in structural:
            print("caption phrase check: " + b, file=sys.stderr)
        sys.exit(1)
    if not check:
        before = [" ".join(text(w) for w in g.get("words") or []) for g in plan.get("caption_groups") or []]
        plan, changed = run(plan)
        if changed:
            json.dump(plan, open(path, "w"), indent=1)
            after = [" ".join(text(w) for w in g["words"]) for g in plan["caption_groups"]]
            if after == before:
                print("[plan] caption phrases: groups kept, styles/overlaps/emphasis fixed")
            else:
                print("[plan] caption phrases: regrouped %d -> %d groups" % (len(before), len(after)))
            for line in sorted(set(after) - set(before), key=after.index):
                print("  [%s]" % line)
        else:
            print("[plan] caption phrases: already whole, plan unchanged")
    bad = problems(plan.get("caption_groups") or [])
    for b in bad:
        print("caption phrase check: " + b, file=sys.stderr)
    sys.exit(1 if bad else 0)
PY
```

```bash
# WI2.64: drop caption cues that would sit on the CTA card. Card off leaves the words unchanged.
python3 work/clamp_captions.py words prior/transcripts.json work/words.json || exit 1
export PREMIUM_DIR REEL_IN=work/pre-premium.mp4 REEL_OUT=work/polished.mp4 WORDS_JSON=work/words.json \
       PW=work/premium CAP_TOP=760 CAPTIONS="$CAPTIONS" SFX="$SFX" GRADE="$(opt grade clean-bright)"
mkdir -p "$PW"
# 1) run P1 (plan) here: it writes "$PW/plan.json"
# 2) WI2.76/WI2.78: keep caption phrases whole before P2 renders them (captions off: nothing to render)
if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py "$PW/plan.json" || exit 1; fi
# 3) now run P2 → P4 only (P1 is done above; planning again would undo the repair); GSAP for the
#    premium comp: cp "$GSAP" "$PW/comp/gsap.min.js" "$PW/comp/compositions/"
python3 work/clamp_captions.py plan work/premium/plan.json || exit 1
python3 - <<'PY'
import os
assert os.path.getsize("work/polished.mp4") > 100_000, "premium output missing/empty — the pass did not run"
PY
# WI2.76: the rendered premium plan kept phrases whole (captions off: no caption groups rendered)
if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py --check "$PW/plan.json" || exit 1; fi
```

### 6. Overlay-FX beats (optional — off by default), then save

Only when `options.overlay_beats` is non-empty: each spec renders via
`node "$OVERLAY_FX_DIR/render-overlay.cjs" spec.json out.mov` and is composited with
`overlay=X:Y:format=auto:enable='between(t,ST,EN)'`, `-c:a copy`, chaining into
`work/polished.mp4`. Safe zones: side gutters (`x < 240` or `x > 840`) and the band y ≈ 1060–1220.
Never the PIP (x 270–810, y 1240–1810), never the upper graphics zone.

```bash
python3 work/clamp_captions.py plan work/premium/plan.json || exit 1
python3 work/hold_tail.py work/polished.mp4 || exit 1
cp work/polished.mp4 saves/assembled_video.mp4
python3 - <<'PY'
import json, os, subprocess
d = lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',f],capture_output=True,text=True).stdout)
a, b = d('saves/assembled_video.mp4'), d('prior/voice_track.mp4')
if os.path.exists('work/outro-norm.mp4'): b += d('work/outro-norm.mp4')
assert abs(a-b) < 0.15, f'duration drifted {a:.2f} vs expected {b:.2f}'
win = json.load(open('work/cta-window.json')) if os.path.exists('work/cta-window.json') else {}
limit = win.get('cta_start')
if limit is not None:
    limit = float(limit)
    bad = []
    def cue_bad(row):
        if not isinstance(row, dict):
            return
        s = row.get('start', row.get('s'))
        e = row.get('end', row.get('e'))
        if s is not None and float(s) >= limit - 1e-3:
            bad.append('start %s' % s)
        if e is not None and float(e) > limit + 1e-6:
            bad.append('end %s' % e)
    words = []
    if os.path.exists('work/words.json'):
        words = json.load(open('work/words.json'))
        if isinstance(words, dict):
            words = words.get('words') or []
    for w in words or []:
        cue_bad(w)
    plan_path = 'work/premium/plan.json'
    if os.path.exists(plan_path):
        plan = json.load(open(plan_path))
        groups = plan.get('caption_groups') if isinstance(plan, dict) else []
        for g in groups or []:
            cue_bad(g)
            if isinstance(g, dict):
                for w in g.get('words') or []:
                    cue_bad(w)
    assert not bad, 'caption cue overlaps CTA window: ' + ', '.join(bad)
print(f'assembled OK {a:.2f}s')
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
