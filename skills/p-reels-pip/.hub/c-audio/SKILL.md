---
name: c-audio
description: Audio production for the creative studio. Use for text-to-speech voiceover generation (ElevenLabs via Floe API), SFX generation, audio chunk splitting, speech-to-text transcription (MLX Whisper on Apple Silicon), and audio loudness normalization.
when_to_use: Trigger on TTS, voiceover, ElevenLabs, script-to-audio, SFX, sound effect, transcribe, whisper, MLX, loudnorm, audio chunk, audio split, LUFS, voiceover generation.
allowed-tools: Bash
kind: component
visibility: internal
providers: elevenlabs
requires: ffmpeg, python3
---


# Studio Audio — TTS, SFX, Transcription


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `$SCRIPT_TEXT` | Yes | Caller | TTS-clean script text |
| `$VOICE_ID` | Yes | Caller / brand config | ElevenLabs voice ID |
| `$OUTPUT_PATH` | Yes | Caller | Target `.mp3` path |
| `{production}` | Yes | Caller | Absolute path to production folder |
| `$FLOE_API_KEY` | Yes | `~/.gsai/secrets.env` | Floe API key for TTS |
| `$ELEVENLABS_API_KEY` | Fallback | `~/.gsai/secrets.env` | Direct ElevenLabs (backup only) |

## Priority Order
1. **Check SFX library first** — `sfx/sfx-library.md` at `/Users/vasanth/Code/skills/sfx/`. Preview: `afplay /Users/vasanth/Code/skills/sfx/{category}/{file}.mp3`.
2. **TTS via Floe API** (primary). Direct ElevenLabs API as fallback only.
3. **MLX Whisper** for transcription — local, Apple Silicon, no API cost.

## TTS — Floe API (Primary)

```bash
RESULT=$(curl -s -X POST "https://floe-production.up.railway.app/api/v1/script-to-audio" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $FLOE_API_KEY" \
  -d "{
    \"execution_id\": \"tts-$(date +%s)\",
    \"task_name\": \"voiceover\",
    \"input_fields\": {
      \"script\": \"$SCRIPT_TEXT\",
      \"voice_id\": \"$VOICE_ID\",
      \"language\": \"english\"
    }
  }")
AUDIO_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_fields']['audio_url'])")
curl -s -o "$OUTPUT_PATH" "$AUDIO_URL"
```

## Voice Presets

| Voice | ID | Style |
|-------|----|-------|
| Crystal | `pq3wL6Xv3fuEM14W6ZCg` | Clear, professional female |
| Layla | `ujoCPuNXFKVxZSRRrMHv` | Warm, conversational female |
| Vasanth | `$ELEVENLABS_DEFAULT_VOICE_ID` | Owner's voice clone |

## TTS — Direct ElevenLabs (Fallback)

Model: `eleven_turbo_v2_5`

```bash
curl -s -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"text\": \"$SCRIPT_TEXT\",
    \"model_id\": \"eleven_turbo_v2_5\",
    \"voice_settings\": {\"stability\": 0.5, \"similarity_boost\": 0.75, \"style\": 0.0}
  }" --output "$OUTPUT_PATH"
```

<!-- 05-STT removed: see cfw-transcribe -->
## Transcription — `cfw-transcribe` (Gemini cloud, MLX fast-path on macOS)

Runs Gemini 2.5-flash in the Linux container; auto-prefers `mlx_whisper` on
macOS when it's on PATH. Output is identical across providers — callers don't
branch on host.

```bash
# Transcribe — Gemini in container, MLX fast-path on macOS
cfw-transcribe --input "$INPUT_AUDIO" --out "$OUTPUT_DIR/vo.srt" --format srt
cfw-transcribe --input "$INPUT_AUDIO" --format text > "$OUTPUT_DIR/vo.txt"
```

SRT is ground truth for beat windows. Gemini segment timings are ±1s; for
word-level accuracy use ElevenLabs Scribe (`$ELEVENLABS_API_KEY`).

## Audio Chunk Split (Speed Adjustment)

```bash
ffmpeg -i "$AUDIO" -filter:a "atempo=$SPEED" -y "$OUTPUT"
```
atempo: 0.5–2.0 only. Chain for values outside: 2.5x = `atempo=2.0,atempo=1.25`

## SFX Library

```
/Users/vasanth/Code/skills/sfx/: whoosh/ ding/ transition/ tension/ swell/ ambient/
```
Check `sfx-library.md` before generating. New SFX → `/Users/vasanth/Code/skills/sfx/{category}/` (NEVER in production `audio/`).

## Output Paths

- Voiceover: `{production}/interim/audio/{name}.mp3`
- SFX: `/Users/vasanth/Code/skills/sfx/{category}/{name}.mp3`
- Transcription: `{production}/interim/audio/{name}.srt`

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

