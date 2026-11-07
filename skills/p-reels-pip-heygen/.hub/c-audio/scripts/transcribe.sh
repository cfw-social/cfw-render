#!/usr/bin/env bash
# c-audio/scripts/transcribe.sh - offline, word-level speech-to-text.
#
# Usage:  transcribe.sh INPUT [OUTPUT_JSON] [LANGUAGE]
#
#   INPUT         Audio or video file (wav, mp3, m4a, mp4, mov, webm ...). Anything that
#                 is not already a 16 kHz mono PCM WAV is converted with ffmpeg first.
#   OUTPUT_JSON   Where to write the result. Omit it, or pass "-", to print to stdout.
#                 The parent folder is created.
#   LANGUAGE      Whisper language code. Default "en" (or $TRANSCRIBE_LANG). The cached
#                 model is English-only, so any other code fails unless WHISPER_GGML
#                 names a multilingual model.
#
# Output (JSON, UTF-8):
#   { "duration": <seconds>, "text": "...", "wpm": <n>,
#     "words": [ { "w": "Hello", "start": 0.58, "end": 0.74 }, ... ],
#     "engine": "whisper.cpp", "model": "<model file name>", "language": "en" }
#   Times are seconds, rounded to milliseconds, never decreasing, and never past duration.
#   Word times are whisper.cpp token times: good to about 0.1-0.2 s, not frame accurate.
#   Non-speech markers such as [MUSIC] are dropped. No speech gives "words": [] and a
#   warning on stderr (the caller decides whether that is an error).
#
# Environment:
#   WHISPER_GGML     Path to a ggml model file.
#                    Default: ~/.cache/whisper-models/ggml-base.en.bin
#   TRANSCRIBE_LANG  Default language code when LANGUAGE is not given.
#
# Offline by design: whisper.cpp (whisper-cli) and a local model only. There is no hosted
# fallback. A missing tool or model stops with exit 2 and a message saying what is missing.
#
# Exit codes: 0 ok | 1 bad input or runtime failure | 2 local speech-to-text not available.
set -euo pipefail

die() {
  printf 'transcribe.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Locate a tool on PATH, then in the usual Homebrew folders (a launchd job has a short PATH).
find_tool() {
  local name="$1" dir
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
[ "$#" -ge 1 ] && [ "$#" -le 3 ] || die "usage: transcribe.sh INPUT [OUTPUT_JSON] [LANGUAGE]" 1

IN="$1"
OUT="${2:--}"
LANG_CODE="$(printf '%s' "${3:-${TRANSCRIBE_LANG:-en}}" | tr '[:upper:]' '[:lower:]')"

[ -f "$IN" ] || die "input file not found: $IN"
[ -s "$IN" ] || die "input file is empty: $IN"

WHISPER="$(find_tool whisper-cli)" \
  || die "no local speech-to-text available: whisper-cli (whisper.cpp) is not installed. Install it with 'brew install whisper-cpp'. This script never calls a hosted service." 2
FFMPEG="$(find_tool ffmpeg)" || die "ffmpeg is not installed" 2
FFPROBE="$(find_tool ffprobe)" || die "ffprobe is not installed" 2
PYTHON="$(find_tool python3)" || die "python3 is not installed" 2

MODEL="${WHISPER_GGML:-$HOME/.cache/whisper-models/ggml-base.en.bin}"
[ -f "$MODEL" ] \
  || die "no local speech-to-text available: whisper model not found at $MODEL. Put ggml-base.en.bin in ~/.cache/whisper-models/ or set WHISPER_GGML to a ggml model file." 2
[ -s "$MODEL" ] || die "whisper model file is empty: $MODEL" 2
MODEL_NAME="$(basename "$MODEL")"

case "$MODEL_NAME" in
  *.en.bin)
    [ "$LANG_CODE" = "en" ] \
      || die "model $MODEL_NAME is English-only but language '$LANG_CODE' was requested. Set WHISPER_GGML to a multilingual ggml model." 2
    ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/transcribe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# What is the input? Need an audio stream; skip the conversion only for a 16 kHz mono PCM WAV.
INFO="$("$FFPROBE" -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,channels:format=format_name \
  -of default=noprint_wrappers=1 -i "$IN" 2>"$TMP/probe.err")" \
  || die "cannot read the input as media: $IN ($(tail -n 1 "$TMP/probe.err"))"
probe_field() { printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -n 1; }
[ -n "$(probe_field codec_name)" ] || die "the input has no audio stream: $IN"

WAV="$TMP/audio.wav"
if [ "$(probe_field format_name)" = "wav" ] && [ "$(probe_field codec_name)" = "pcm_s16le" ] \
  && [ "$(probe_field sample_rate)" = "16000" ] && [ "$(probe_field channels)" = "1" ]; then
  WAV="$IN"
else
  "$FFMPEG" -nostdin -v error -y -i "$IN" -vn -map 0:a:0 -ar 16000 -ac 1 -c:a pcm_s16le "$WAV" \
    || die "ffmpeg could not extract audio from: $IN"
fi

DURATION="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 -i "$WAV")"
[ -n "$DURATION" ] || die "could not measure the audio duration of: $IN"

# Full JSON with per-token timestamps (-ojf); whisper writes $TMP/asr.json.
if ! "$WHISPER" -m "$MODEL" -f "$WAV" -l "$LANG_CODE" -ojf -np -of "$TMP/asr" \
  >"$TMP/whisper.out" 2>"$TMP/whisper.err"; then
  tail -n 8 "$TMP/whisper.err" >&2
  die "whisper-cli failed on: $IN" 1
fi
[ -s "$TMP/asr.json" ] || die "whisper-cli finished but wrote no JSON for: $IN" 1

"$PYTHON" -I - "$TMP/asr.json" "$DURATION" "$LANG_CODE" "$MODEL_NAME" "$WAV" >"$TMP/out.json" <<'PY'
import array
import json
import math
import re
import sys
import wave

asr_path, duration_s, language, model, wav_path = sys.argv[1:6]
duration = float(duration_s)
with open(asr_path, encoding="utf-8") as fh:
    segments = json.load(fh).get("transcription") or []

# Build words from whisper's token stream: a token that starts with a space begins a new word,
# and the tokens after it (word pieces, trailing punctuation) belong to the same word. A word
# runs from its first token's start to the end of its last token that carries a letter or digit,
# so the pause whisper hangs on a trailing "." or "," is not counted as speech.
raw = []
for segment in segments:
    for token in segment.get("tokens") or []:
        text = token.get("text") or ""
        if text.startswith("[_") or not text.strip():
            continue
        offsets = token.get("offsets") or {}
        begin = max(0.0, offsets.get("from", 0) / 1000.0)
        finish = max(begin, offsets.get("to", 0) / 1000.0)
        if text[0].isspace() or not raw:
            raw.append({"w": text.strip(), "start": begin, "end": begin, "spoken": False})
        else:
            raw[-1]["w"] += text
        if re.search(r"\w", text):
            if not raw[-1]["spoken"]:
                raw[-1]["start"] = begin
            raw[-1]["end"] = finish
            raw[-1]["spoken"] = True

NOISE = re.compile(r"^(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)$")
words = []
for item in raw:
    text = item["w"]
    if NOISE.match(text) or "♪" in text:
        continue
    if not item["spoken"]:
        # Punctuation on its own: glue it to the previous word, which keeps its timing.
        if words:
            words[-1]["w"] += text
        continue
    start = min(duration, item["start"])
    end = min(duration, max(start, item["end"]))
    if words:
        start = max(start, words[-1]["start"])
        end = max(end, start)
    words.append({"w": text, "start": start, "end": end})

# The model sometimes invents a word ("You", "Thank you") over silence. Drop a word only when
# the audio around it is digital silence (RMS below -60 dBFS over its span plus 0.3 s each side,
# because word times can be that far off); the WAV is 16 kHz mono 16-bit by now.
with wave.open(wav_path, "rb") as wav:
    rate = wav.getframerate()
    samples = array.array("h")
    samples.frombytes(wav.readframes(wav.getnframes()))
if sys.byteorder == "big":
    samples.byteswap()


def is_silent(word):
    first = max(0, int((word["start"] - 0.3) * rate))
    window = samples[first:int((word["end"] + 0.3) * rate)]
    if not window:
        return True
    rms = math.sqrt(sum(v * v for v in window) / len(window))
    return rms < 32768 * 10 ** (-60 / 20)


words = [w for w in words if not is_silent(w)]

# Whisper's token times are rough: a word can come out a few milliseconds long, or stop just
# short of the next word. Real pauses stay as gaps, and the rest is tidied in three ways:
#   - a word under 50 ms whose next word starts within 100 ms shares their joint span with it,
#     split by letter count (so no word is left with a zero-length caption);
#   - any other word under 50 ms gets the time up to the next word, at most 300 ms;
#   - a gap under 120 ms to the next word is closed.
for i, word in enumerate(words):
    following = words[i + 1] if i + 1 < len(words) else None
    next_start = following["start"] if following else duration
    if word["end"] - word["start"] < 0.05:
        span = (following["end"] if following else next_start) - word["start"]
        if following and following["start"] - word["start"] < 0.1 and span > 0:
            share = span * (len(word["w"]) + 1) / (len(word["w"]) + len(following["w"]) + 2)
            floor = min(0.05, span / 2)
            word["end"] = word["start"] + min(max(share, floor), span - floor)
            following["start"] = word["end"]
        elif next_start > word["start"]:
            word["end"] = min(next_start, word["start"] + 0.3)
    elif 0 < next_start - word["end"] < 0.12:
        word["end"] = next_start
    word["start"] = round(word["start"], 3)
    word["end"] = round(word["end"], 3)

for a, b in zip(words, words[1:]):
    assert a["start"] <= b["start"], "non-monotonic word timing"
for word in words:
    assert 0 <= word["start"] <= word["end"] <= duration + 0.001, "word timing outside the audio"
if not words:
    print("transcribe.sh: warning: no speech recognised", file=sys.stderr)

result = {
    "duration": round(duration, 3),
    "text": " ".join(w["w"] for w in words),
    "wpm": round(len(words) / (duration / 60.0)) if duration > 0 else 0,
    "words": words,
    "engine": "whisper.cpp",
    "model": model,
    "language": language,
}
json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
sys.stdout.write("\n")
PY

if [ "$OUT" = "-" ]; then
  cat "$TMP/out.json"
else
  mkdir -p "$(dirname "$OUT")"
  cp "$TMP/out.json" "$OUT.tmp.$$"
  mv "$OUT.tmp.$$" "$OUT"
  printf 'transcribe.sh: wrote %s (%s s audio, model %s)\n' "$OUT" "$DURATION" "$MODEL_NAME" >&2
fi
