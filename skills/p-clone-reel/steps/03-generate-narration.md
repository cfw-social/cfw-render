# Generate the narration

Turn the adapted script into the **narration track** every later step is timed against: a HeyGen
green-screen avatar video when the brand (or the owner) names an avatar, otherwise an ElevenLabs
voice-over wrapped in a solid-colour 1080×1920 bed. Loudness is normalised once here.

## You receive

- `prior/adapted_script.md` — front matter + TTS-clean body (use the body verbatim).
- `inputs/avatar_id/avatar_id.json` — `{"text": "<HeyGen avatar id>"}` when supplied; dir absent
  → `brief.json.brand.heygen.avatarId`; neither → voice-only path.
- `inputs/voice_id/voice_id.json` — `{"text": "<voice id>"}` when supplied; dir absent →
  `brief.json.brand.heygen.voiceId` (avatar path) or `brief.json.brand.elevenlabs.voiceId`.
- `brief.json` — `brand`, `options.speed` (default 1.0).

Keys come ONLY from the environment: `HEYGEN_API_KEY` for the avatar path, `ELEVENLABS_API_KEY`
for the voice path. Never read a secrets file, never print a key.

## You must produce

- `saves/narration.mp4` — 1080×1920, 30 fps, H.264 yuv420p, AAC 48 kHz stereo, 25–65 s, loudnormed
  once to `I=-14:TP=-1.5:LRA=11`. Avatar path: the presenter on a solid `#00FF00` background
  (keyed later). Voice path: a solid brand-background frame carrying the voice-over.
  A sidecar is NOT a save — record `{"mode": "avatar|voice"}` as the first line comment of your
  log only; `composite` detects the mode from the green edge pixels.

## How

```bash
mkdir -p work saves
eval "$(python3 - <<'PY'
import json, os, shlex, re
def t(i):
    p = f"inputs/{i}/{i}.json"
    return (json.load(open(p)).get("text") or "").strip() if os.path.exists(p) else ""
b = json.load(open("brief.json")); br = b.get("brand") or {}
hg = br.get("heygen") or {}; el = br.get("elevenlabs") or {}
body = re.sub(r"^---.*?---\s*", "", open("prior/adapted_script.md").read(), flags=re.S).strip()
avatar = t("avatar_id") or hg.get("avatarId") or ""
voice = t("voice_id") or (hg.get("voiceId") if avatar else el.get("voiceId")) or ""
print("SCRIPT=" + shlex.quote(body)); print("AVATAR=" + shlex.quote(avatar)); print("VOICE=" + shlex.quote(voice))
print("BG=" + shlex.quote((br.get("palette") or {}).get("bg") or "#0F172A"))
print("SPEED=" + str((b.get("options") or {}).get("speed") or 1.0))
PY
)"
[ -n "$SCRIPT" ] || { echo "adapted script is empty — rerun adapt_script"; exit 1; }
if [ -n "$AVATAR" ]; then
  [ -n "${HEYGEN_API_KEY:-}" ] || { echo "HeyGen is not connected for this brand (no provider key in the environment)"; exit 1; }
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No HeyGen voice is set for this brand — please provide the voice id the avatar should speak with.", "count": 1 }' > needs_input.json; exit 0; }
else
  [ -n "${ELEVENLABS_API_KEY:-}" ] || { echo '{ "inputId": "avatar_id", "reason": "This brand has no avatar and no ElevenLabs voice connected — provide a HeyGen avatar id, or connect ElevenLabs for a voice-only remake.", "count": 1 }' > needs_input.json; exit 0; }
  [ -n "$VOICE" ] || { echo '{ "inputId": "voice_id", "reason": "No narration voice is set for this brand — please provide the ElevenLabs voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
fi
printf '%s\n' "$SCRIPT" > work/narration.txt
```

### A. Avatar path (`c-heygen` API)

```bash
python3 "$CFW_RENDER_SKILLS_DIR/p-clone-reel/.hub/c-heygen/scripts/render.py" \
  --avatar-id "$AVATAR" --voice-id "$VOICE" --script work/narration.txt --speed "$SPEED" \
  --background "#00FF00" --width 1080 --height 1920 --poll 30 --out work/avatar-raw.mp4
```

Idempotency: if `work/avatar-raw.mp4` exists and decodes, do not submit again. Verify the
background is green at the edges (`crop=40:40:0:0` mean ≈ 0,255,0) — an off-green edge means the
wrong background was applied; fail with a plain message rather than keying a bad render.

### B. Voice path (`c-audio` → ElevenLabs REST)

```bash
python3 -c "import json;print(json.dumps({'text':open('work/narration.txt').read().strip(),'model_id':'eleven_turbo_v2_5','voice_settings':{'stability':0.5,'similarity_boost':0.75,'speed':$SPEED}}))" > work/payload.json
curl -sS -f -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE" -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -H "Content-Type: application/json" --data @work/payload.json --output work/vo.mp3
ffmpeg -y -f lavfi -i "color=c=${BG}:s=1080x1920:r=30" -i work/vo.mp3 -shortest -map 0:v -map 1:a \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 work/avatar-raw.mp4
```

### C. Trim, loudnorm once, seal

```bash
ffmpeg -y -i work/avatar-raw.mp4 -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30" \
  -af "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.3,areverse,silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.3,areverse,loudnorm=I=-14:TP=-1.5:LRA=11" \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 18 -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart saves/narration.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 saves/narration.mp4)
python3 -c "d=float('$DUR'); assert 25 <= d <= 65, f'narration {d:.1f}s outside 25–65 s'; print(f'narration OK {d:.1f}s')"
```

A narration outside 25–65 s means the adapted script is mistimed: fail with the measured seconds so
`adapt_script` is rerun — do not speed-change the audio to fit.

## Checks the harness runs

- `narration_has_audio` — `saves/narration.mp4` has an AAC stream with non-silent content
  (`volumedetect` mean above −40 dB).
- `narration_duration_window` — duration between 25 and 65 s.
