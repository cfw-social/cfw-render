# Render the avatar

Produce the **avatar track**: the one continuous narration every later step is timed against.
Reuse the owner's `source_video` when given (never burn HeyGen credits for a layout change);
otherwise render with HeyGen on a `#00FF00` green screen, or — with no avatar — synthesise an
ElevenLabs voice-over into a solid-colour 1920×1080 bed.

## You receive

- `prior/tts_script.md` — front matter + TTS-clean body (use the body verbatim).
- `inputs/source_video/` — one landscape avatar render (green-screen or opaque) when supplied.
- `inputs/avatar_id/avatar_id.json` — `{"text": "<HeyGen avatar id>"}` when supplied; dir absent
  → `brief.json.brand.heygen.avatarId`; neither → voice-only path.
- `inputs/voice_id/voice_id.json` — `{"text": "<voice id>"}`; dir absent → `brief.json.brand.heygen.voiceId`
  (avatar path) or `brief.json.brand.elevenlabs.voiceId`.
- `brief.json` — `brand`, `options.speed` (default 1.0), `options.pip_mode`.

Keys come ONLY from the environment: `HEYGEN_API_KEY` for the avatar path, `ELEVENLABS_API_KEY`
for the voice path. Never read a secrets file, never print a key.

## You must produce

- `saves/avatar_video.mp4` — 1920×1080, 25 fps, H.264 yuv420p, AAC 48 kHz stereo, 4–21 min,
  speed already applied; green (`#00FF00`) or opaque uniform background. NOT loudness-normalised
  (that happens once in `post_process`).

## How

```bash
mkdir -p work saves
eval "$(python3 - <<'PY'
import glob, json, os, re, shlex
def t(i):
    p = f"inputs/{i}/{i}.json"
    return (json.load(open(p)).get("text") or "").strip() if os.path.exists(p) else ""
b = json.load(open("brief.json")); br = b.get("brand") or {}; hg = br.get("heygen") or {}; el = br.get("elevenlabs") or {}
body = re.sub(r"^---.*?---\s*", "", open("prior/tts_script.md").read(), flags=re.S).strip()
src = next(iter(sorted(glob.glob("inputs/source_video/*.m*"))), "")
avatar = t("avatar_id") or hg.get("avatarId") or ""
voice = t("voice_id") or (hg.get("voiceId") if avatar else el.get("voiceId")) or ""
print("SRC=" + shlex.quote(src)); print("AVATAR=" + shlex.quote(avatar)); print("VOICE=" + shlex.quote(voice))
print("BG=" + shlex.quote((br.get("palette") or {}).get("bg") or "#0F172A"))
print("SPEED=" + str((b.get("options") or {}).get("speed") or 1.0))
open("work/narration.txt", "w").write(body + "\n")
PY
)"
```

### A. Reuse path — `source_video` supplied

```bash
if [ -n "$SRC" ]; then
  ffmpeg -v error -i "$SRC" -f null - || { echo '{ "inputId": "source_video", "reason": "The avatar video you shared does not play back — please upload it again or leave it out to render a new one.", "count": 1 }' > needs_input.json; exit 0; }
  cp "$SRC" work/avatar-raw.mp4
fi
```

### B. HeyGen path (`c-heygen` API, background `#00FF00`)

```bash
if [ -z "$SRC" ] && [ -n "$AVATAR" ]; then
  [ -n "${HEYGEN_API_KEY:-}" ] || { echo "HeyGen is not connected for this brand (no provider key in the environment)"; exit 1; }
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No HeyGen voice is set for this brand — please provide the voice id the avatar should speak with.", "count": 1 }' > needs_input.json; exit 0; }
  python3 "$CFW_RENDER_SKILLS_DIR/p-longform/.hub/c-heygen/scripts/render.py" \
    --avatar-id "$AVATAR" --voice-id "$VOICE" --script work/narration.txt --speed "$SPEED" \
    --background "#00FF00" --width 1920 --height 1080 --poll 60 --out work/avatar-raw.mp4
fi
```

Idempotency: if `work/avatar-raw.mp4` exists and decodes, do not submit again. Poll every 60 s in
the background; a job that errors is a failure with HeyGen's plain status text — never retry
blindly (credits).

### C. Voice-only path (`c-audio` → ElevenLabs REST)

```bash
if [ -z "$SRC" ] && [ -z "$AVATAR" ]; then
  [ -n "${ELEVENLABS_API_KEY:-}" ] || { echo '{ "inputId": "avatar_id", "reason": "This brand has no avatar and no ElevenLabs voice connected — provide a HeyGen avatar id, or connect ElevenLabs for a voice-only video.", "count": 1 }' > needs_input.json; exit 0; }
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No narration voice is set for this brand — please provide the ElevenLabs voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
  python3 -c "import json;print(json.dumps({'text':open('work/narration.txt').read().strip(),'model_id':'eleven_turbo_v2_5','voice_settings':{'stability':0.5,'similarity_boost':0.75,'speed':$SPEED}}))" > work/payload.json
  curl -sS -f -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" -H "xi-api-key: $ELEVENLABS_API_KEY" \
    -H "Content-Type: application/json" --data @work/payload.json --output work/vo.mp3
  ffmpeg -y -f lavfi -i "color=c=${BG}:s=1920x1080:r=25" -i work/vo.mp3 -shortest -map 0:v -map 1:a \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/avatar-raw.mp4
fi
```

Scripts over ~5000 characters are synthesised per section paragraph and concatenated with
`-f concat` (re-encode) before wrapping.

### D. Conform and seal

```bash
ffmpeg -y -i work/avatar-raw.mp4 -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,fps=25" \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 18 -g 25 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/avatar_video.mp4
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
