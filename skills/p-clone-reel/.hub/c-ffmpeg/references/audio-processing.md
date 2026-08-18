# FFmpeg — Audio Processing Reference

## Loudness Normalization (Two-Pass — MANDATORY)

Target: **-14 LUFS** (landscape/YouTube), **-16 LUFS** (portrait/shorts).

```bash
# Pass 1: analyze
LUFS_DATA=$(ffmpeg -i "$INPUT" -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | tail -20)
INPUT_I=$(echo "$LUFS_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['input_i'])")
INPUT_TP=$(echo "$LUFS_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['input_tp'])")
INPUT_LRA=$(echo "$LUFS_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['input_lra'])")
INPUT_THRESH=$(echo "$LUFS_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['input_thresh'])")
OFFSET=$(echo "$LUFS_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['target_offset'])")

# Pass 2: apply (measured values)
ffmpeg -i "$INPUT" \
  -af "loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=${INPUT_I}:measured_TP=${INPUT_TP}:measured_LRA=${INPUT_LRA}:measured_thresh=${INPUT_THRESH}:offset=${OFFSET}:linear=true:print_format=summary" \
  -c:a aac -b:a 192k -y "$OUTPUT"
```

For shorts (portrait): change `-14` to `-16` in both passes.

---

## SFX Mixing with Voiceover

Mix SFX at lower volume with voiceover using `adelay` + `amix`:

```bash
# SFX starts 500ms after voiceover (to clear hook opener)
ffmpeg -i "$VOICEOVER" -i "$SFX" \
  -filter_complex "
    [1:a]adelay=500|500,volume=0.3[sfx_delayed];
    [0:a][sfx_delayed]amix=inputs=2:duration=first:dropout_transition=2[audio_mix]
  " \
  -map "[audio_mix]" -c:a aac -b:a 192k -y "$OUTPUT"
```

### Common SFX Volume Levels

| SFX type | Volume |
|----------|--------|
| Background ambient | 0.08–0.12 |
| Transition whoosh | 0.3–0.4 |
| Ding / notification | 0.5–0.6 |
| Tension/suspense | 0.2–0.3 |
| Swell / CTA sting | 0.4–0.5 |

---

## Audio Speed Adjustment (atempo)

```bash
# Single atempo (0.5–2.0 range only)
ffmpeg -i "$INPUT" -filter:a "atempo=1.1" -y "$OUTPUT"

# Chained for values outside 0.5–2.0
# 2.5x = atempo=2.0,atempo=1.25
ffmpeg -i "$INPUT" -filter:a "atempo=2.0,atempo=1.25" -y "$OUTPUT"

# 0.4x = atempo=0.5,atempo=0.8
ffmpeg -i "$INPUT" -filter:a "atempo=0.5,atempo=0.8" -y "$OUTPUT"
```

---

## Audio Extraction

```bash
# Extract audio track from video
ffmpeg -i "$VIDEO" -vn -c:a aac -b:a 192k -y "$AUDIO.aac"

# Extract as MP3
ffmpeg -i "$VIDEO" -vn -c:a libmp3lame -b:a 192k -y "$AUDIO.mp3"

# Check audio loudness
ffmpeg -i "$INPUT" -af loudnorm=print_format=json -f null - 2>&1 | tail -15
```

---

## Voiceover + Background Music Ducking

```bash
# Duck music under voice, -20dB reduction when voice is present
ffmpeg -i "$VOICEOVER" -i "$MUSIC" \
  -filter_complex "
    [1:a]volume=0.4[music];
    [0:a][music]sidechaincompress=threshold=0.02:ratio=8:attack=10:release=200[ducked];
    [0:a][ducked]amix=inputs=2:duration=first[out]
  " \
  -map "[out]" -c:a aac -b:a 192k -y "$OUTPUT"
```

---

## Caption Audio Sync Check

After compositing, verify audio/video sync at multiple points:

```bash
# Check at 1min, 3min, 5min intervals
for T in 60 180 300; do
  ffmpeg -ss $T -i "$FINAL" -vframes 1 -y "/tmp/frame-${T}s.jpg" 2>/dev/null
  echo "Frame at ${T}s extracted: /tmp/frame-${T}s.jpg"
done
# Visually inspect against SRT transcript to confirm lip sync
```
