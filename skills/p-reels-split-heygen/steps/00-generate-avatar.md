# Generate the avatar video

Turn the narration `script` into the talking-head video with the brand's HeyGen avatar. This is
provider work only — no compositing, no captions, no grade happens here. The output becomes the
`talking_head` every later step builds on, so it must be a clean, decodable 20–60 s clip with the
avatar's voice as its audio.

## You receive

- `inputs/script/script.json` — `{"text": "<the narration script>"}` (a plain `.txt`/`.md` file
  in the same dir is also acceptable). TTS-clean prose: no stage directions, no markdown.
- `inputs/avatar_id/avatar_id.json` — `{"text": "<HeyGen avatar id>"}` when the owner supplied
  one; dir absent → `brief.json.brand.heygen.avatarId`.
- `inputs/voice_id/voice_id.json` — `{"text": "<ElevenLabs voice id>"}` when supplied; dir absent
  → `brief.json.brand.heygen.voiceId`.
- `brief.json` — `brand` (`heygen.avatarId`, `heygen.voiceId` when the brand has them).

Provider keys come ONLY from the environment (`ELEVENLABS_API_KEY` + `HEYGEN_API_KEY`), exported by the harness from the brand's
connected provider accounts. Never read a secrets file, never print a key.

## You must produce

- `saves/talking_head.mp4` — the finished avatar render, **16:9 1080p landscape** (mandatory — the bottom-zone crop + cut-zoom must stay sharp), H.264 + AAC, 20–60 s, audio
  present. Not re-encoded, not trimmed, not loudnormed (that is `prepare_footage`'s job).

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
eval "$(python3 - <<'PY'
import glob, json, os, shlex
def text_input(i):
    j = f"inputs/{i}/{i}.json"
    if os.path.exists(j): return (json.load(open(j)).get("text") or "").strip()
    for f in sorted(glob.glob(f"inputs/{i}/*")):
        if f.endswith((".txt", ".md")): return open(f).read().strip()
    return ""
hg = (json.load(open("brief.json")).get("brand") or {}).get("heygen") or {}
print("SCRIPT=" + shlex.quote(text_input("script")))
print("AVATAR_ID=" + shlex.quote(text_input("avatar_id") or hg.get("avatarId") or ""))
print("VOICE_ID=" + shlex.quote(text_input("voice_id") or hg.get("voiceId") or ""))
PY
)"
[ -n "$SCRIPT" ]    || { echo '{ "inputId": "script", "reason": "Please provide the narration script for the avatar to read.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "$AVATAR_ID" ] || { echo '{ "inputId": "avatar_id", "reason": "No HeyGen avatar is set for this brand — please provide the avatar id to use.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "$VOICE_ID" ]  || { echo '{ "inputId": "voice_id", "reason": "No voice is set for this brand — please provide the ElevenLabs voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "${HEYGEN_API_KEY:-}" ] && [ -n "${ELEVENLABS_API_KEY:-}" ] || { echo "HeyGen / ElevenLabs is not connected for this brand (no provider key in the environment)"; exit 1; }
WORDS=$(printf '%s' "$SCRIPT" | wc -w | tr -d ' ')
[ "$WORDS" -ge 40 ] && [ "$WORDS" -le 180 ] || { echo "{ \"inputId\": \"script\", \"reason\": \"The script is $WORDS words — a 20–60 second reel needs roughly 50–150 words.\", \"count\": 1 }" > needs_input.json; exit 0; }
```

### 1. Render with ElevenLabs v3 → HeyGen v3 Avatar III (`scripts/voice-to-reel.sh`)

The provider step is this recipe's own `voice-to-reel.sh`: ElevenLabs `eleven_v3` TTS on the
script → audio uploaded to HeyGen → audio-driven `type:avatar` video at **16:9 1080p** → polled
and downloaded. It is idempotent on `(script, voice, model, avatar)` via a state file in `WORK`,
so a rerun resumes an in-flight render instead of paying for a new one. `EL_VOICE` is the
ElevenLabs voice id and `HG_AVATAR` must be an **Avatar III** id (generation is set by the id).

```bash
EL_VOICE="$VOICE_ID" HG_AVATAR="$AVATAR_ID" WORK="$PWD/work" RENDER_STATE_DIR="$PWD/work" \
  SECRETS_FILE=/dev/null \
  bash "$SKILL_DIR/scripts/voice-to-reel.sh" "$SCRIPT" "$PWD/work/avatar.mp4" | tail -1
[ -s work/avatar.mp4 ] || { echo "voice-to-reel did not produce a video"; exit 1; }
```

### 2. Verify and save

```bash
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 work/avatar.mp4)
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 work/avatar.mp4 | grep -q audio \
  || { echo "avatar video has no audio stream"; exit 1; }
python3 -c "d=float('$DUR'); assert 20 <= d <= 60, f'avatar video is {d:.1f}s — outside 20–60 s; shorten or lengthen the script'"
read AW AH < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 work/avatar.mp4 | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
echo "[split-heygen] avatar ${AW}x${AH} ${DUR}s"
[ "$AW" -ge 1920 ] && [ "$AW" -gt "$AH" ] || { echo "avatar video is ${AW}x${AH} — split needs a 16:9 1080p landscape render"; exit 1; }
cp work/avatar.mp4 saves/talking_head.mp4
```

## If you cannot proceed

This step may ask for **`script`, `avatar_id` or `voice_id`** (see above): write `needs_input.json`
and stop without a save when the script is missing / the wrong length or when neither the owner
nor the brand supplies an avatar or voice id. A missing provider key, a provider error or a
render that will not complete is a failure, not an ask: exit non-zero with one plain line that
names the provider (never the key). Never submit a second render for the same script to "retry".

## Checks the harness runs

- `avatar_has_audio` — `saves/talking_head.mp4` has one audio stream.
- `avatar_duration_window` — duration is within 20–60 s.
