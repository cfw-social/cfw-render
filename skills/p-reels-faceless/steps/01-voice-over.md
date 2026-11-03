# Generate the voice-over

Turn the script into the **voice bed**: the one continuous narration every later step is timed
against. Its duration is the master reel length. This is provider work plus one loudnorm — no
graphics, no captions here.

## You receive

- `inputs/script/script.json` — `{"text": "<the narration script>"}` (a `.txt`/`.md` in the same
  dir is also acceptable) — OR `prior/approved_script.md` when the owner chose the
  research-and-write path (the server wrote it; use it verbatim).
- `inputs/voice_id/voice_id.json` — `{"text": "<ElevenLabs voice id>"}` when supplied; dir absent
  → `brief.json.brand.elevenlabs.voiceId`.
- `brief.json` — `brand`, `options.target_seconds` (default 45).

The ElevenLabs key comes ONLY from the environment (`ELEVENLABS_API_KEY`). Never read a secrets
file, never print the key.

## You must produce

- `saves/voice_bed.mp4` — 1080×1920, 30 fps, H.264 yuv420p over a solid brand-background colour
  (the picture is a stand-in; `render_graphics` replaces it), carrying the narration as AAC 48 kHz
  stereo, loudnormed **once** to `I=-14:TP=-1.5:LRA=11`, 30–90 s long, leading/trailing silence
  trimmed to ≤ 0.3 s.

## How

```bash
mkdir -p work saves
eval "$(python3 - <<'PY'
import glob, json, os, shlex
def text_input(i):
    j = f"inputs/{i}/{i}.json"
    if os.path.exists(j): return (json.load(open(j)).get("text") or "").strip()
    for f in sorted(glob.glob(f"inputs/{i}/*")):
        if f.endswith((".txt", ".md")): return open(f).read().strip()
    return ""
b = json.load(open("brief.json"))
script = text_input("script") or (open("prior/approved_script.md").read().strip() if os.path.exists("prior/approved_script.md") else "")
el = (b.get("brand") or {}).get("elevenlabs") or {}
print("SCRIPT=" + shlex.quote(script))
print("VOICE_ID=" + shlex.quote(text_input("voice_id") or el.get("voiceId") or ""))
print("BG=" + shlex.quote(((b.get("brand") or {}).get("palette") or {}).get("bg") or "#0F172A"))
print("TARGET=" + str((b.get("options") or {}).get("target_seconds") or 45))
PY
)"
[ -n "$SCRIPT" ]   || { echo '{ "inputId": "script", "reason": "Please provide the narration script for the reel.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "$VOICE_ID" ] || { echo '{ "inputId": "voice_id", "reason": "No narration voice is set for this brand — please provide the ElevenLabs voice id to use.", "count": 1 }' > needs_input.json; exit 0; }
[ -n "${ELEVENLABS_API_KEY:-}" ] || { echo "ElevenLabs is not connected for this brand (no provider key in the environment)"; exit 1; }
WORDS=$(printf '%s' "$SCRIPT" | wc -w | tr -d ' ')
[ "$WORDS" -ge 60 ] && [ "$WORDS" -le 260 ] || { echo "{ \"inputId\": \"script\", \"reason\": \"The script is $WORDS words — a 30–90 second reel needs roughly 80–230 words.\", \"count\": 1 }" > needs_input.json; exit 0; }
```

### 1. Make the script TTS-clean

Write `work/vo-script.txt`: one continuous narration, no headings, no stage directions, no
markdown. Spell tricky tokens for speech (`/terminal` → "slash terminal", `2x` → "twice as
fast", URLs read as words). Keep the hook first and the CTA last; do not add claims.

### 2. Synthesise with ElevenLabs (REST path of `c-audio`)

```bash
python3 - <<'PY' > work/payload.json
import json
print(json.dumps({"text": open("work/vo-script.txt").read().strip(), "model_id": "eleven_turbo_v2_5",
  "voice_settings": {"stability": 0.5, "similarity_boost": 0.75, "style": 0.0}}))
PY
curl -sS -f -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" \
  --data @work/payload.json --output work/vo.mp3
file work/vo.mp3 | grep -qi "audio\|mpeg" || { echo "ElevenLabs did not return audio"; exit 1; }
```

Idempotency: if `work/vo.mp3` already exists and decodes, do not synthesise again.

### 3. Trim, loudnorm once, wrap in the bed container

```bash
ffmpeg -y -i work/vo.mp3 -af "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.3,areverse,silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.3,areverse,loudnorm=I=-14:TP=-1.5:LRA=11" \
  -ar 48000 -ac 2 work/vo-normed.wav
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 work/vo-normed.wav)
ffmpeg -y -f lavfi -i "color=c=${BG}:s=1080x1920:r=30" -i work/vo-normed.wav -t "$BED_DUR" \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -preset fast -crf 20 -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -shortest -movflags +faststart saves/voice_bed.mp4
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 saves/voice_bed.mp4
python3 -c "d=float('$BED_DUR'); assert 30 <= d <= 90, f'bed {d:.1f}s outside 30–90 s'; print(f'bed OK: {d:.1f}s')"
```

If the bed is outside 30–90 s, the script is the problem: write `needs_input.json` for `script`
saying how many seconds it came to and what range is needed (do not speed-change the audio).

## Checks the harness runs

- `bed_has_audio` — `saves/voice_bed.mp4` has an AAC audio stream with non-silent content
  (`volumedetect` mean above −40 dB).
- `bed_duration_window` — duration between 30 and 90 s.
