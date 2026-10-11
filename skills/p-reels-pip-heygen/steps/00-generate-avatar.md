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
- `inputs/voice_id/voice_id.json` — `{"text": "<HeyGen voice id>"}` when supplied; dir absent
  → `brief.json.brand.heygen.voiceId`.
- `brief.json` — `brand` (`heygen.avatarId`, `heygen.voiceId` when the brand has them).

Provider keys come ONLY from the environment (`HEYGEN_API_KEY`), exported by the harness from the brand's
connected provider accounts. Never read a secrets file, never print a key.

## You must produce

- `saves/talking_head.mp4` — the finished avatar render, portrait or landscape (the PIP card is scale-to-fit), H.264 + AAC, 20–60 s, audio
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
[ -n "$VOICE_ID" ]  || { echo '{ "inputId": "voice_id", "reason": "No voice is set for this brand — please provide the HeyGen voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "${HEYGEN_API_KEY:-}" ] || { echo "HeyGen is not connected for this brand (no provider key in the environment)"; exit 1; }
WORDS=$(printf '%s' "$SCRIPT" | wc -w | tr -d ' ')
[ "$WORDS" -ge 40 ] && [ "$WORDS" -le 180 ] || { echo "{ \"inputId\": \"script\", \"reason\": \"The script is $WORDS words — a 20–60 second reel needs roughly 50–150 words.\", \"count\": 1 }" > needs_input.json; exit 0; }
```

### 1. Render with HeyGen (REST path of `c-heygen`) — never pay twice

Follow `$SKILL_DIR/.hub/c-heygen/SKILL.md` **Path 4 (REST API)** with the HeyGen key from the
environment: `POST https://api.heygen.com/v2/video/generate` with `character.type=avatar`,
`avatar_id=$AVATAR_ID`, `voice.type=text`, `input_text=$SCRIPT`, `voice_id=$VOICE_ID`, a solid
background and `dimension` `{"width":1280,"height":720}` (the PIP card scales to fit). Auth is the `X-Api-Key` header, not Bearer. The MCP / browser
/ human paths of `c-heygen` are not available in this harness — on a REST failure, fail the step.

Idempotency: key the render on `sha256(script|avatar|voice)` and keep `work/render-<key>.json`
(`{"video_id","status"}`); if it exists, RESUME polling that `video_id` instead of submitting a
new one (each submit is a separately billed render).

```bash
KEY=$(printf '%s|%s|%s' "$SCRIPT" "$AVATAR_ID" "$VOICE_ID" | shasum -a 256 | cut -c1-16)
STATE="work/render-$KEY.json"
if [ -f "$STATE" ]; then VIDEO_ID=$(python3 -c "import json;print(json.load(open('$STATE'))['video_id'])"); else
  VIDEO_ID=$(python3 - "$AVATAR_ID" "$VOICE_ID" "$SCRIPT" <<'PY'
import json, os, sys, urllib.request
avatar, voice, script = sys.argv[1:4]
body = {"video_inputs": [{"character": {"type": "avatar", "avatar_id": avatar, "avatar_style": "normal"},
        "voice": {"type": "text", "input_text": script, "voice_id": voice},
        "background": {"type": "color", "value": "#0F172A"}}], "dimension": {"width": 1280, "height": 720}}
req = urllib.request.Request("https://api.heygen.com/v2/video/generate", data=json.dumps(body).encode(),
      headers={"X-Api-Key": os.environ["HEYGEN_API_KEY"], "Content-Type": "application/json"}, method="POST")
r = json.load(urllib.request.urlopen(req, timeout=60))
vid = (r.get("data") or {}).get("video_id") or ""
assert vid, f"HeyGen did not return a video_id: {r.get('error') or r}"
print(vid)
PY
)
  printf '{"video_id":"%s","status":"submitted"}' "$VIDEO_ID" > "$STATE"
fi
# Poll (every 30 s, up to 30 min). Run this in the background if your engine offers it.
for i in $(seq 1 60); do
  R=$(curl -s -H "X-Api-Key: $HEYGEN_API_KEY" "https://api.heygen.com/v1/video_status.get?video_id=$VIDEO_ID")
  ST=$(printf '%s' "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status',''))")
  case "$ST" in
    completed) URL=$(printf '%s' "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['video_url'])"); break ;;
    failed) echo "HeyGen render failed: $(printf '%s' "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('error',''))")"; exit 1 ;;
  esac
  sleep 30
done
[ -n "${URL:-}" ] || { echo "HeyGen render did not complete in 30 min (video_id $VIDEO_ID)"; exit 1; }
curl -sL "$URL" -o work/avatar.mp4
printf '{"video_id":"%s","status":"completed"}' "$VIDEO_ID" > "$STATE"
```

### 2. Verify and save

```bash
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 work/avatar.mp4)
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 work/avatar.mp4 | grep -q audio \
  || { echo "avatar video has no audio stream"; exit 1; }
python3 -c "d=float('$DUR'); assert 20 <= d <= 60, f'avatar video is {d:.1f}s — outside 20–60 s; shorten or lengthen the script'"
read AW AH < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 work/avatar.mp4 | awk -F= 'NR==1{w=$2} NR==2{h=$2} END{print w,h}')
echo "[pip-heygen] avatar ${AW}x${AH} ${DUR}s"
true
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
