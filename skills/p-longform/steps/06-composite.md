# Composite

Assemble the video from the b-roll plan: key (or not) the avatar, build every row as a segment
with its synced audio slice, concat, and append the outro when one was given. The avatar audio is
the spine — each segment carries the exact audio of its window so the narration is continuous.

## You receive

- `prior/avatar_video.mp4` — the sealed avatar track (green or opaque background).
- `prior/broll_plan.json` — the rows.
- `prior/visuals_manifest.json` — GFX / stills / concept sources (re-render to `work/visuals/`).
- `prior/transcripts.json` — `sections` (for `tutorial` chapter stitching), `avatar_mode`
  (`supplied`, `avatar` or `voice`).
- `inputs/broll/` — the footage the plan references.
- `inputs/outro/` — one landscape clip (1–15 s) when supplied.
- `brief.json` — `brand` palette, `options.pip_mode`.

## You must produce

- `saves/composite_video.mp4` — 1920×1080, 25 fps, H.264 yuv420p, AAC 48 kHz stereo; the full
  narration, uncut, then the outro if any. Not yet loudness-normalised.

## How

```bash
mkdir -p work/seg work/visuals saves
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-longform"
AV=prior/avatar_video.mp4
BG_TYPE=$(ffmpeg -v error -ss 2 -i "$AV" -vf "crop=60:60:0:0,scale=1:1" -frames:v 1 -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys;r,g,b=sys.stdin.buffer.read()[:3];print('green_screen' if g>180 and r<90 and b<90 else 'opaque')")
KEY=""; [ "$BG_TYPE" = green_screen ] && KEY="colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01,"
eval "$(python3 - <<'PY'
import json, re
t = json.load(open("prior/transcripts.json")); plan = json.load(open("prior/broll_plan.json"))
bg = (((json.load(open("brief.json")).get("brand") or {}).get("palette") or {}).get("bg")) or ""
mode = t.get("avatar_mode") or "avatar"
print("MODE=" + mode)
print("NOPIP=" + ("1" if mode == "voice" or plan.get("pip_mode") == "none" else "0"))
print("BGHEX=" + (bg.lstrip("#").upper() if re.match(r"^#?[0-9A-Fa-f]{6}$", bg) else "0F172A"))
PY
)"
echo "bg_type=$BG_TYPE avatar_mode=$MODE no_pip=$NOPIP"
```

`NOPIP=1` (a voice-only run, or the plan says `pip_mode: none`): no presenter is drawn beside
footage; every row that would show one is built as `FULLSCREEN_BROLL`.

### 0. Re-render the visuals

For each `visuals_manifest.assets[]` entry write its `html` back to `work/visuals/<id>/` and
render to `work/visuals/<id>.mp4` exactly as `build_visuals` did (HyperFrames 0.7.5, 25 fps,
`seconds` long). A still is not rendered: write its `png_b64` to `work/visuals/<id>.png`
(`build_segments` turns it into a clip and applies the row's slow zoom).

### 1. Pre-render the avatar on a contextual background (`c-ffmpeg/references/landscape-pip.md`)

```bash
ffmpeg -y -f lavfi -i "color=c=0x${BGHEX}:s=1920x1080:r=25" -i "$AV" -filter_complex \
  "[1:v]${KEY}format=rgba[fg];[0:v][fg]overlay=0:0:shortest=1,format=yuv420p[v]" \
  -map "[v]" -map 1:a -c:v libx264 -preset fast -crf 18 -g 25 -c:a copy work/avatar-on-bg.mp4
```

Use the brand `bg` hex. Inspect one frame at 50 % for a green fringe before building 60 segments.

### 2. Build one segment per row

```bash
NOPIP_ARG=""; if [ "$NOPIP" = 1 ]; then NOPIP_ARG="--no-pip"; fi
python3 "$SKILL_DIR/.hub/c-ffmpeg/scripts/build-segments.py" --plan prior/broll_plan.json \
  --avatar work/avatar-on-bg.mp4 --avatar-raw "$AV" --key "${KEY%,}" --visuals work/visuals \
  --broll inputs/broll --out work/seg --pip-card rounded --pip-size 304x380 --pip-margin 72 --pip-border "#D4A84C" \
  --card-bg "#$BGHEX" $NOPIP_ARG
```

Per layout: `AVATAR_FULL` → `work/avatar-on-bg.mp4` trimmed `[start,end)`; `PIP_CORNER` → asset
scaled / blurred-fill to 1920×1080 (no bars) with the keyed avatar inside the rounded gold-rim
card at the row's `pip_side`; `FULLSCREEN_BROLL` → the asset alone; `SIDE_BY_SIDE` → `hstack` of
the recording and the avatar, each 960 wide; `PIP_SIDE` → avatar in a 640-wide column on the
`pip_side`. Every segment takes its audio from `"$AV"` for the row's exact window (a row starts on
the 25 fps frame nearest its `start`, so rows join with no gap), `-g 25`, 25 fps, yuv420p. The
segment files hold PCM audio on purpose: AAC per segment would add up to 21 ms of silence at
every cut and drift a 10-minute video by seconds. The one AAC encode is the concat below.
`tutorial` section title cards arrive as ordinary plan rows (`gfx:` assets); the script draws
nothing of its own. It exits 2 (nothing encoded) when an input is missing or the plan is
unusable, naming the row, and 1 when ffmpeg fails. A finished segment is not rebuilt on a rerun.
Run it with `--dry-run` first to see the checks and commands without encoding.

### 3. Concat, outro, verify

```bash
ls work/seg/*.mp4 | sort -V | while read -r f; do printf "file '%s'\n" "$PWD/$f"; done > work/concat.txt
OUTRO=$(ls inputs/outro/*.m* 2>/dev/null | head -1 || true)
if [ -n "$OUTRO" ]; then
  ffmpeg -y -i "$OUTRO" -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x0F172A,fps=25,format=yuv420p" \
    -af "aresample=48000" -c:v libx264 -crf 18 -g 25 -c:a pcm_s16le -ar 48000 -ac 2 -f mov work/outro.mp4 && printf "file '%s'\n" "$PWD/work/outro.mp4" >> work/concat.txt
fi
ffmpeg -y -f concat -safe 0 -i work/concat.txt -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.1 -preset medium -crf 18 -g 25 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/composite_video.mp4
ffmpeg -v error -i saves/composite_video.mp4 -f null -
AVD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AV"); CD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/composite_video.mp4)
python3 -c "a=float('$AVD'); c=float('$CD'); assert c >= a-0.5, f'composite {c:.1f}s shorter than narration {a:.1f}s — a segment is missing'"
```

If a row fails to build, fix that row and rebuild — never carry a broken composite into post.
The outro is never keyed, never padded with black beyond letterbox fill to the brand colour. It
is encoded with PCM audio like the segments, so every file in `work/concat.txt` has the same
audio format (the concat demuxer needs that).

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. A missing outro means no outro; a
referenced b-roll file that is missing is a failure of `plan_broll` — exit non-zero naming the row.

## Checks the harness runs

- `composite_dims` — video stream exactly 1920×1080.
- `composite_not_black` — frames at 10/30/50/70/90 % have mean luma above 16/255.
- `vo_continuous` — the narration audio runs uncut: duration ≥ avatar duration − 0.5 s and no
  silence gap > 2 s before the outro.
