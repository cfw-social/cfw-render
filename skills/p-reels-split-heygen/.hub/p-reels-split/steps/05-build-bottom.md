# Build the bottom-zone face track

Render the sealed talking head into the **1080×960** bottom zone with the bed audio attached.
`bottom_fit=cover` (default) scales-to-cover; `fit` keeps the whole face with a blurred side fill.
`bottom_cutzoom=true` splits the face at the beat boundaries and alternates 1.0× (b-roll beats) /
1.4× (card beats) framing — a zoom-cut on every beat; the audio is still the single unbroken bed.

## You receive

- `prior/voice_track.mp4` — the sealed bed (picture = cleaned talking head at source size, audio
  = the ONLY voice source). Never cut, re-time or loudnorm the audio.
- `prior/beat_list.json` — beats (for `bottom_cutzoom` segment boundaries).
- `brief.json` — `options.bottom_fit` (`cover`), `options.bottom_cutzoom` (`false`).

## You must produce

- `saves/bottom_track.mp4` — 1080×960, 30 fps, H.264 yuv420p + AAC 48 kHz stereo (the bed
  audio, byte-equivalent in timing), duration = bed duration (±0.1 s). The face is whole and
  fills the zone — never a small inset.

## How

```bash
mkdir -p work saves
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
BOTTOM_FIT=$(opt bottom_fit cover); BOTTOM_CUTZOOM=$(opt bottom_cutzoom false)
TH=prior/voice_track.mp4
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TH")
```

### 1a. Static framing (`bottom_cutzoom=false`)

`split` the source before forking into bg/fg chains (a double-read of `[0:v]` is fatal).

```bash
if [ "$BOTTOM_CUTZOOM" != "true" ]; then
  if [ "$BOTTOM_FIT" = "fit" ]; then
    FC="[0:v]split[_a][_b];[_a]scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,boxblur=40:2,setsar=1[bg];[_b]scale=1080:960:force_original_aspect_ratio=decrease,setsar=1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,fps=30[bv]"
  else
    FC="[0:v]scale=1080:960:force_original_aspect_ratio=increase,crop=1080:960,setsar=1,format=yuv420p,fps=30[bv]"
  fi
  ffmpeg -y -i "$TH" -filter_complex "$FC" -map "[bv]" -map 0:a \
    -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a copy -movflags +faststart saves/bottom_track.mp4
fi
```

### 1b. Cut-zoom framing (`bottom_cutzoom=true`)

Crop from the FULL-RES source, TOP-anchored (never crop the forehead), one silent segment per
beat, concat, then mux the untouched bed audio back in.

```bash
if [ "$BOTTOM_CUTZOOM" = "true" ]; then
  mkdir -p work/av
  python3 - "$TH" <<'PY'
import json, subprocess, sys
TH = sys.argv[1]; bl = json.load(open("prior/beat_list.json"))["beats"]
SW, SH = [int(x) for x in subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0:s=x",TH],capture_output=True,text=True).stdout.strip().split("x")]
BASE_W = min(SW, SH*1080/960); lines = []
for k, b in enumerate(bl):
    z = 1.0 if b["kind"] == "broll" else 1.4
    cw = int(round(BASE_W/z/2))*2; ch = int(round(cw*960/1080/2))*2; x = int((SW-cw)/2)
    subprocess.run(["ffmpeg","-y","-ss",str(b["start"]),"-to",str(b["end"]),"-i",TH,"-an",
        "-vf",f"crop={cw}:{ch}:{x}:0,scale=1080:960:flags=lanczos,setsar=1,fps=30,format=yuv420p",
        "-c:v","libx264","-preset","slow","-crf","17",f"work/av/s{k}.mp4"], check=True)
    lines.append(f"file 's{k}.mp4'")
open("work/av/concat.txt","w").write("\n".join(lines)+"\n"); print(f"cut-zoom: {len(bl)} segments")
PY
  ffmpeg -y -f concat -safe 0 -i work/av/concat.txt -an -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p work/av/bottom-video.mp4
  ffmpeg -y -i work/av/bottom-video.mp4 -i "$TH" -map 0:v -map 1:a -c:v copy -c:a copy -shortest -movflags +faststart saves/bottom_track.mp4
fi
```

### 2. Verify

```bash
read BW BH < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 saves/bottom_track.mp4 | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
[ "$BW" = 1080 ] && [ "$BH" = 960 ] || { echo "bottom track is ${BW}x${BH}, not 1080x960"; exit 1; }
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 saves/bottom_track.mp4 | grep -q audio || { echo "bottom track lost the bed audio"; exit 1; }
BOT_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/bottom_track.mp4)
python3 -c "assert abs(float('$BOT_DUR')-float('$BED_DUR'))<0.15, 'bottom $BOT_DUR != bed $BED_DUR'"
echo "[split] bottom track OK: ${BOT_DUR}s (fit=$BOTTOM_FIT cutzoom=$BOTTOM_CUTZOOM)"
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A probe failure or a dimension /
duration mismatch is a failure: exit non-zero with one plain line.

## Checks the harness runs

- `bottom_track_dims` — `saves/bottom_track.mp4` is exactly 1080×960.
- `bottom_has_audio` — one AAC 48 kHz stereo audio stream is present.
- `bottom_track_matches_bed` — duration equals the voice bed within 0.15 s.
