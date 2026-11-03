# Render the avatar

Produce the **avatar track**: the one continuous narration every later step is timed against.
There are three ways to get it, and the owner always chooses. First match wins:

1. **Supplied clip** — the owner's `source_video`, a playable video in `inputs/source_video/`
   (never burn HeyGen credits for a layout change). This is the route to use when no HeyGen API
   key is connected: the owner makes the avatar render in the HeyGen web app and uploads it. It
   costs nothing.
2. **Voice-only** — only when the owner typed `none`, `no`, `voice-only` or `off` as the avatar:
   an ElevenLabs voice-over on a solid-colour 1920×1080 bed. Voice-only is never a default, so
   ElevenLabs is never charged unless the owner chose it.
3. **HeyGen render** — an avatar id (typed, else the brand's), `HEYGEN_API_KEY` and the c-heygen
   render script, on a `#00FF00` green screen.

If none of these applies (no clip, no avatar id, no `none`), or a `source_video` folder arrived
but holds no playable video, the step asks for `source_video` and stops. It never falls through
to a paid path.

## You receive

- `prior/tts_script.md` — front matter + TTS-clean body (use the body verbatim).
- `inputs/source_video/` — one 16:9 avatar clip (green-screen or opaque) when supplied. The clip
  is chosen by what is in it (a video stream), not by its file name.
- `inputs/avatar_id/avatar_id.md` — the typed avatar id as raw text (the worker stages every typed
  answer as `<id>.md`; `avatar_id.json` `{"text": "<HeyGen avatar id>"}` and `.txt` are read too).
  `none`, `no`, `voice-only` or `off` (any case) is the owner choosing voice-only, even when the
  brand has an avatar. Dir absent → `brief.json.brand.heygen.avatarId`; neither → ask.
- `inputs/voice_id/voice_id.md` — raw text, same readers; dir absent → `brief.json.brand.heygen.voiceId`
  (avatar path) or `brief.json.brand.elevenlabs.voiceId`.
- `brief.json` — `brand`, `options.speed` (default 1.0), `options.pip_mode`.

Keys come ONLY from the environment: `HEYGEN_API_KEY` for the HeyGen path, `ELEVENLABS_API_KEY`
for the voice path. The supplied-clip path reads no key and spends nothing. A key being set is
not a reason to spend: only the path chosen below calls a paid service. Never read a secrets
file, never print a key.

## You must produce

- `saves/avatar_video.mp4` — 1920×1080, 25 fps, H.264 yuv420p, AAC 48 kHz stereo, 4–21 min,
  speed already applied; green (`#00FF00`) or opaque uniform background. NOT loudness-normalised
  (that happens once in `post_process`). The container carries `comment=cfw-avatar-mode=<mode>`
  (`supplied`, `avatar` or `voice`); `transcribe` copies it into `transcripts.json` so every
  later step knows whether a presenter is on screen. It is not a save of its own.

## How

```bash
mkdir -p work saves
eval "$(python3 - <<'PY'
import glob, json, os, re, shlex, subprocess
def t(i):
    # typed answers are staged as inputs/<id>/<id>.md (raw text); also read <id>.json and <id>.txt
    p = f"inputs/{i}/{i}.json"
    if os.path.exists(p): return (json.load(open(p, encoding="utf-8")).get("text") or "").strip()
    for f in sorted(glob.glob(f"inputs/{i}/*")):
        if f.endswith((".md", ".txt")): return open(f, encoding="utf-8").read().strip()
    return ""
def has_video(path):
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_type", "-of", "csv=p=0", path],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0 and "video" in r.stdout
b = json.load(open("brief.json")); br = b.get("brand") or {}; hg = br.get("heygen") or {}; el = br.get("elevenlabs") or {}
body = re.sub(r"^---.*?---\s*", "", open("prior/tts_script.md", encoding="utf-8").read(), flags=re.S).strip()
clip_dir = os.path.isdir("inputs/source_video")      # the owner sent something, even if it is not usable
src = next((f for f in sorted(glob.glob("inputs/source_video/*")) if os.path.isfile(f) and has_video(f)), "")
avatar_in = t("avatar_id")
# "none", "no", "voice-only" or "off" (any case) is the owner choosing voice-only, even when the brand has an avatar
no_avatar = avatar_in.lower() in ("none", "no", "voice-only", "off")
avatar = "" if no_avatar else (avatar_in or hg.get("avatarId") or "")
voice = t("voice_id") or (hg.get("voiceId") if avatar else el.get("voiceId")) or ""
if src: mode = "supplied"                             # 1. a playable clip
elif clip_dir: mode = "ask_clip"                      # a clip folder with no video in it: ask again, never pay
elif no_avatar: mode = "voice"                        # 2. voice-only, only when chosen
elif avatar: mode = "avatar"                          # 3. an avatar id
else: mode = "ask"                                    # 4. nothing chosen: ask
bg = (br.get("palette") or {}).get("bg") or ""
if not re.match(r"^#?[0-9A-Fa-f]{6}$", bg): bg = "#0F172A"
speed = (b.get("options") or {}).get("speed") or 1.0
print("SRC=" + shlex.quote(src)); print("AVATAR=" + shlex.quote(avatar)); print("VOICE=" + shlex.quote(voice))
print("MODE=" + mode); print("BG=" + shlex.quote(bg)); print("SPEED=" + str(float(speed)))
open("work/narration.txt", "w", encoding="utf-8").write(body + "\n")
PY
)"
echo "avatar_mode=$MODE"
```

### 0. Nothing usable to start from → ask, never spend

```bash
if [ "$MODE" = ask_clip ]; then
  echo '{ "inputId": "source_video", "reason": "The avatar video you shared did not arrive or is not a video file. Please upload it again.", "count": 1 }' > needs_input.json; exit 0
fi
if [ "$MODE" = ask ]; then
  echo '{ "inputId": "source_video", "reason": "Please upload the avatar video you made in HeyGen (16:9, 5 to 20 minutes). If you want a voice-only video instead, answer none for the avatar.", "count": 1 }' > needs_input.json; exit 0
fi
REUSE=0; if [ -s work/avatar-raw.mp4 ] && ffmpeg -v error -i work/avatar-raw.mp4 -f null - 2>/dev/null; then REUSE=1; fi
```

`REUSE=1` means `work/avatar-raw.mp4` already exists and decodes: skip A, B and C and go to D
(never submit or synthesise twice — that is a second charge).

### A. Supplied clip — `source_video`

```bash
if [ "$MODE" = supplied ] && [ "$REUSE" = 0 ]; then
  ffmpeg -v error -i "$SRC" -f null - || { echo '{ "inputId": "source_video", "reason": "The avatar video you shared does not play back — please upload it again or leave it out to render a new one.", "count": 1 }' > needs_input.json; exit 0; }
  [ "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$SRC" | head -1)" = audio ] || { echo '{ "inputId": "source_video", "reason": "The avatar video you shared has no sound. It must carry the narration — please upload the version with audio.", "count": 1 }' > needs_input.json; exit 0; }
  DIMS=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$SRC" | head -1)
  python3 -c "w,h=map(int,'$DIMS'.split('x')); raise SystemExit(0 if h>0 and w/h>=1.5 else 1)" || { printf '{ "inputId": "source_video", "reason": "The avatar video you shared is %s, which is not 16:9 widescreen. This video is 16:9, so a squarer or taller clip would be cropped and could cut off the head. Please upload a 16:9 version.", "count": 1 }\n' "$DIMS" > needs_input.json; exit 0; }
  SD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
  python3 -c "d=float('$SD'); raise SystemExit(0 if 300<=d<=1200 else 1)" || { printf '{ "inputId": "source_video", "reason": "The avatar video you shared is %s minutes long; it must be between 5 and 20 minutes.", "count": 1 }\n' "$(python3 -c "print(round(float('$SD')/60,1))")" > needs_input.json; exit 0; }
  cp "$SRC" work/avatar-raw.mp4
fi
```

The clip's own audio is the narration. It should be a render of this script: the transcript is
aligned to the script text in `transcribe`, and the section map is built from the script.

### B. HeyGen path (`c-heygen` API, background `#00FF00`)

```bash
if [ "$MODE" = avatar ] && [ "$REUSE" = 0 ]; then
  [ ! -d inputs/source_video ] || { echo "An owner clip arrived: it is never replaced by a paid render"; exit 1; }
  RENDER="$CFW_RENDER_SKILLS_DIR/p-longform/.hub/c-heygen/scripts/render.py"
  [ -f "$RENDER" ] || { echo '{ "inputId": "source_video", "reason": "This computer cannot render a HeyGen avatar by itself. Please upload the avatar video you made in HeyGen, or set the avatar to none for a voice-only video.", "count": 1 }' > needs_input.json; exit 0; }
  [ -n "${HEYGEN_API_KEY:-}" ] || { echo "HeyGen is not connected for this brand (no provider key in the environment)"; exit 1; }
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No HeyGen voice is set for this brand — please provide the voice id the avatar should speak with.", "count": 1 }' > needs_input.json; exit 0; }
  python3 "$RENDER" \
    --avatar-id "$AVATAR" --voice-id "$VOICE" --script work/narration.txt --speed "$SPEED" \
    --background "#00FF00" --width 1920 --height 1080 --poll 60 --out work/avatar-raw.mp4
fi
```

Poll every 60 s in the background; a job that errors is a failure with HeyGen's plain status
text — never retry blindly (credits).

### C. Voice-only path (`c-audio` → ElevenLabs REST) — only when the owner chose it

The script is sent in parts of at most 4,500 characters (split on paragraph, then sentence
ends, then words); a part already on disk is not requested again. The API key goes to curl on
stdin, not on its command line; curl may only use https, does not follow redirects and gives up
after 300 s.

```bash
if [ "$MODE" = voice ] && [ "$REUSE" = 0 ]; then
  [ ! -d inputs/source_video ] || { echo "An owner clip arrived: it is never replaced by a paid voice-over"; exit 1; }
  if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
    echo '{ "inputId": "source_video", "reason": "You chose a voice-only video, but no ElevenLabs voice is connected for this brand. Please upload the avatar video you made in HeyGen instead, or connect ElevenLabs and answer none for the avatar again.", "count": 1 }' > needs_input.json; exit 0
  fi
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No narration voice is set for this brand — please provide the ElevenLabs voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
  mkdir -p work/vo
  python3 - "$SPEED" <<'PY'
import json, re, sys
speed = min(float(sys.argv[1]), 1.2)          # ElevenLabs accepts 0.7-1.2
LIMIT = 4500
text = open("work/narration.txt", encoding="utf-8").read()
def pieces(s):                                 # paragraph, else sentences, else words: each piece <= LIMIT
    if len(s) <= LIMIT: return [s]
    out = []
    for sent in [x for x in re.split(r"(?<=[.!?])\s+", s) if x]:
        if len(sent) <= LIMIT: out.append(sent); continue
        cur = ""
        for w in sent.split():
            if cur and len(cur) + len(w) + 1 > LIMIT: out.append(cur); cur = w
            else: cur = (cur + " " + w) if cur else w
        if cur: out.append(cur)
    return out
units = [u for para in [p.strip() for p in re.split(r"\n+", text) if p.strip()] for u in pieces(para)]
parts, cur = [], ""
for u in units:
    if cur and len(cur) + len(u) + 2 > LIMIT: parts.append(cur); cur = u
    else: cur = (cur + "\n\n" + u) if cur else u
if cur: parts.append(cur)
for i, p in enumerate(parts, 1):
    json.dump({"text": p, "model_id": "eleven_turbo_v2_5", "voice_settings": {"stability": 0.5, "similarity_boost": 0.75, "speed": speed}},
              open("work/vo/payload-%03d.json" % i, "w", encoding="utf-8"))
print("%d part(s), %d characters" % (len(parts), sum(len(p) for p in parts)))
PY
  for p in work/vo/payload-*.json; do
    o="${p%.json}.mp3"
    if [ ! -s "$o" ]; then
      printf 'xi-api-key: %s\n' "$ELEVENLABS_API_KEY" | curl -sS -f --proto '=https' --max-time 300 -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" \
        --header @- -H "Content-Type: application/json" --data @"$p" --output "$o.part" || { echo "ElevenLabs did not return audio for $(basename "$p") — not retried (credits)"; rm -f "$o.part"; exit 1; }
      mv "$o.part" "$o"
    fi
  done
  for o in work/vo/payload-*.mp3; do printf "file '%s'\n" "$PWD/$o"; done > work/vo/list.txt
  ffmpeg -y -f concat -safe 0 -i work/vo/list.txt -ar 48000 -ac 2 work/vo.wav
  ffmpeg -y -f lavfi -i "color=c=${BG}:s=1920x1080:r=25" -i work/vo.wav -shortest -map 0:v -map 1:a \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/avatar-raw.mp4
fi
```

### D. Conform and seal

```bash
ffmpeg -y -i work/avatar-raw.mp4 -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,fps=25" \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 18 -g 25 -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -metadata comment="cfw-avatar-mode=$MODE" -movflags +faststart saves/avatar_video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/avatar_video.mp4)
python3 -c "d=float('$DUR'); assert 240 <= d <= 1260, f'avatar {d/60:.1f} min outside 4–21 min'; print(f'avatar OK {d/60:.1f} min')"
ffmpeg -v error -ss 2 -i saves/avatar_video.mp4 -vf "crop=60:60:0:0,scale=1:1" -frames:v 1 -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys;r,g,b=sys.stdin.buffer.read()[:3];print('bg=green' if g>180 and r<90 and b<90 else f'bg=opaque rgb({r},{g},{b})')"
```

Check the edge in four corners: a green render whose corners disagree by > 40 in any channel has
lighting spill — fail with a plain message rather than keying a bad render.

## Checks the harness runs

- `avatar_has_audio` — `saves/avatar_video.mp4` has an AAC stream with non-silent content
  (`volumedetect` mean above −40 dB).
- `avatar_duration_window` — duration between 240 and 1260 s.
- `avatar_bg_uniform` — the four 60×60 corner patches at 2 s agree within 40/255 per channel
  (clean green screen or opaque background).
