#!/usr/bin/env bash
# voice-to-reel: SCRIPT → ElevenLabs v3 VO → HeyGen v3 audio-driven avatar (Avatar III, 16:9 1080p)
#   → downloads the finished talking-head MP4 to $OUT.
#
# This is the provider step ONLY (Step 0 of p-reels-split-heygen). It contains ZERO compositing —
# the split-screen / cut-zoom / captions / CTA all live in p-reels-split, which this skill delegates
# to afterwards. Source-promoted from
#   cfw-marketing/creatives/productions/fnb-split-screen-short/voice-to-reel.sh
# and generalized: no hardcoded production folder; output path + work dir are parameterized.
#
# IDEMPOTENCY (AB-FLEETFIX-HEYGEN-DUP-RENDER, 2026-06-25)
# ------------------------------------------------------
# Each HeyGen /v3/videos POST is a SEPARATELY BILLED render. A turn timeout that killed this
# script mid-poll/mid-download used to cause the agent to re-run it from the top → a brand-new
# video_id → a duplicate paid render (member saw 6 reels instead of 3).
#
# This script is now idempotent on (script + voice + model + avatar):
#   * A deterministic RENDER_KEY (sha256 of those four inputs) names a stable state file
#     ($STATE_DIR/.heygen-render-<key>.json) holding {asset_id, video_id, status}.
#   * Re-running with the same inputs RESUMES the existing render by video_id (poll + download)
#     instead of submitting a new one — so a mid-flight timeout can never orphan a paid render.
#   * The VO + uploaded audio asset are cached by key too, so a resume never re-pays for TTS
#     or re-uploads.
#   * The completed MP4 is cached at a keyed path ($STATE_DIR/heygen-<key>.mp4); a fully
#     completed render short-circuits to a copy with zero API calls.
# Override the state location with RENDER_STATE_DIR=... (defaults to $WORK). Set
# FORCE_RENDER=1 to bypass the cache and force a fresh render.
#
# Keys: ELEVENLABS_API_KEY, HEYGEN_API_KEY — taken from the environment, else auto-loaded
#       from ~/.gsai/secrets.env (override path with SECRETS_FILE=...).
# Usage:
#   bash voice-to-reel.sh "Script text here" /path/to/out/th.mp4
#   SCRIPT="..." OUT=/path/th.mp4 bash voice-to-reel.sh
# Optional env overrides: EL_VOICE, EL_MODEL, HG_AVATAR, WORK, RENDER_STATE_DIR, FORCE_RENDER
#
# Prints the absolute path of the finished MP4 as its LAST line.
set -euo pipefail

# Load keys from the canonical secrets file if not already in the environment.
# Single source of truth: ~/.gsai/secrets.env (also feeds heygen-credit-check.sh).
SECRETS_FILE="${SECRETS_FILE:-${HOME}/.gsai/secrets.env}"
if { [ -z "${ELEVENLABS_API_KEY:-}" ] || [ -z "${HEYGEN_API_KEY:-}" ]; } && [ -f "$SECRETS_FILE" ]; then
  # shellcheck source=/dev/null
  set +u; source "$SECRETS_FILE"; set -u
fi

: "${ELEVENLABS_API_KEY:?set ELEVENLABS_API_KEY (env or $SECRETS_FILE)}"
: "${HEYGEN_API_KEY:?set HEYGEN_API_KEY (env or $SECRETS_FILE)}"

EL_VOICE="${EL_VOICE:-qfNHzU5pVyzMLm53FhzY}"          # ElevenLabs cloned "Vasanth-042026"
EL_MODEL="${EL_MODEL:-eleven_v3}"
# DEFAULT = Avatar III "GG-4k" (id confirmed Avatar III via preview path /avatar/v3/).
# Do NOT swap to an Avatar IV/V avatar — generation is set by the avatar_id itself
# (no version param exists in the API). Keep an Avatar-III avatar_id here.
HG_AVATAR="${HG_AVATAR:-9273e994f1ed484d9031afa3725676c5}"  # HeyGen Growth Guide (GG-4k, Avatar III)

SCRIPT="${SCRIPT:-${1:-}}"
[ -z "$SCRIPT" ] && { echo "[voice-to-reel] No script. Pass as arg 1 or set SCRIPT=." >&2; exit 1; }
OUT="${OUT:-${2:-./th.mp4}}"
mkdir -p "$(dirname "$OUT")"
WORK="${WORK:-$(dirname "$OUT")/_v2r}" ; mkdir -p "$WORK"

# ── Idempotency state ───────────────────────────────────────────────────────
# Deterministic key over the render-defining inputs. Same inputs => same key =>
# same render reused. python3 is already a hard dependency (used below), so we
# hash with it for portability (no shasum/sha256sum availability assumptions).
RENDER_KEY=$(SCRIPT="$SCRIPT" EL_VOICE="$EL_VOICE" EL_MODEL="$EL_MODEL" HG_AVATAR="$HG_AVATAR" python3 - <<'PY'
import os, hashlib
s = "|".join([os.environ["SCRIPT"], os.environ["EL_VOICE"], os.environ["EL_MODEL"], os.environ["HG_AVATAR"]])
print(hashlib.sha256(s.encode("utf-8")).hexdigest()[:16])
PY
)
STATE_DIR="${RENDER_STATE_DIR:-$WORK}" ; mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/.heygen-render-$RENDER_KEY.json"
VO_MP3="$STATE_DIR/vo-$RENDER_KEY.mp3"
KEYED_MP4="$STATE_DIR/heygen-$RENDER_KEY.mp4"
echo "[voice-to-reel] render key=$RENDER_KEY state=$STATE" >&2

# Read a string field from the JSON state file (empty if file/field absent).
state_get() {
  [ -f "$STATE" ] || { echo ""; return; }
  FIELD="$1" python3 - "$STATE" <<'PY'
import os, sys, json
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    d = {}
print(d.get(os.environ["FIELD"], "") or "")
PY
}

# Merge key=value pairs into the JSON state file (creates it if missing).
state_set() {
  STATE_FILE="$STATE" python3 - "$@" <<'PY'
import os, sys, json
path = os.environ["STATE_FILE"]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    d[k] = v
with open(path, "w") as f:
    json.dump(d, f)
PY
}

# ── Fast path: a fully completed render is reused with ZERO API calls ─────────
if [ "${FORCE_RENDER:-}" != "1" ] && [ "$(state_get status)" = "completed" ] && [ -s "$KEYED_MP4" ]; then
  cp "$KEYED_MP4" "$OUT"
  echo "[voice-to-reel] reusing completed render (key=$RENDER_KEY); no HeyGen call made" >&2
  echo "$OUT"
  exit 0
fi
[ "${FORCE_RENDER:-}" = "1" ] && { echo "[voice-to-reel] FORCE_RENDER=1 — ignoring any cached render" >&2; rm -f "$STATE"; }

ASSET="$(state_get asset_id)"
VID="$(state_get video_id)"

# If we already hold a video_id for this key we are RESUMING a submitted render: skip TTS and the
# asset upload entirely and jump straight to polling (no re-charge for ElevenLabs / re-upload, and
# crucially no new /v3/videos submission).
if [ -n "$VID" ]; then
  echo "[1/4][2/4] resume — VO + asset steps skipped (video_id=$VID already submitted)" >&2
else
# [1/4] ElevenLabs TTS — skipped if the keyed VO already exists (resume never re-pays for TTS).
if [ -s "$VO_MP3" ]; then
  echo "[1/4] reusing cached VO ($VO_MP3)" >&2
else
  echo "[1/4] ElevenLabs $EL_MODEL TTS ($EL_VOICE) ..." >&2
  EL_VOICE="$EL_VOICE" EL_MODEL="$EL_MODEL" SCRIPT="$SCRIPT" VO_MP3="$VO_MP3" python3 - <<'PY'
import os,json,urllib.request
voice,model,script,out=os.environ["EL_VOICE"],os.environ["EL_MODEL"],os.environ["SCRIPT"],os.environ["VO_MP3"]
body=json.dumps({"text":script,"model_id":model,"voice_settings":{"stability":0.5,"similarity_boost":0.75}}).encode()
req=urllib.request.Request(f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128",
    data=body, headers={"xi-api-key":os.environ["ELEVENLABS_API_KEY"],"Content-Type":"application/json","Accept":"audio/mpeg"}, method="POST")
with urllib.request.urlopen(req) as r: open(out,"wb").write(r.read())
print("  wrote", out)
PY
fi

# [2/4] Upload audio asset to HeyGen — skipped if we already have an asset_id for this key.
if [ -n "$ASSET" ]; then
  echo "[2/4] reusing uploaded audio asset_id=$ASSET" >&2
else
  echo "[2/4] upload audio asset to HeyGen ..." >&2
  ASSET=$(curl -s -X POST "https://upload.heygen.com/v1/asset" -H "X-Api-Key: $HEYGEN_API_KEY" \
    -H "Content-Type: audio/mpeg" --data-binary "@$VO_MP3" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
  [ -n "$ASSET" ] || { echo "[voice-to-reel] FATAL: no asset_id from HeyGen upload" >&2; exit 1; }
  state_set "asset_id=$ASSET"
  echo "  asset_id=$ASSET" >&2
fi
fi  # end resume-vs-fresh (VO + asset) block

# [3/4] Generate the avatar video — THE BILLED STEP. Only submit if we don't already
# hold a video_id for this key. A resume after a timeout has a video_id here and skips
# straight to polling, so the render is never re-triggered (no duplicate billing).
if [ -n "$VID" ]; then
  echo "[3/4] resuming existing render video_id=$VID (no new HeyGen render submitted)" >&2
else
  echo "[3/4] generate v3 avatar video (audio-driven, 16:9 1080p) ..." >&2
  # IMPORTANT: request 16:9 (NOT 9:16). 9:16 letterboxes the landscape avatar with white bars →
  # only ~1080x608 of real avatar pixels → pixelated after the split-screen crop+cut-zoom upscale.
  # 16:9 gives a full 1920x1080 sharp avatar; p-reels-split only needs the landscape strip anyway.
  VID=$(curl -s -X POST "https://api.heygen.com/v3/videos" -H "X-Api-Key: $HEYGEN_API_KEY" -H "Content-Type: application/json" \
    -d "{\"type\":\"avatar\",\"avatar_id\":\"$HG_AVATAR\",\"audio_asset_id\":\"$ASSET\",\"aspect_ratio\":\"16:9\",\"resolution\":\"1080p\",\"title\":\"voice-to-reel\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['video_id'])")
  [ -n "$VID" ] || { echo "[voice-to-reel] FATAL: no video_id from HeyGen create" >&2; exit 1; }
  # Persist the video_id IMMEDIATELY (before polling) so a timeout mid-poll preserves it
  # for the next run to resume rather than re-submit.
  state_set "video_id=$VID" "status=submitted"
  echo "  video_id=$VID" >&2
fi

echo "[4/4] poll + download -> $OUT ..." >&2
while true; do
  S=$(curl -s -H "X-Api-Key: $HEYGEN_API_KEY" "https://api.heygen.com/v1/video_status.get?video_id=$VID")
  ST=$(echo "$S" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['status'])")
  if [ "$ST" = "completed" ]; then
    URL=$(echo "$S" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['video_url'])")
    # Download to the keyed path first, then copy to OUT, so a timeout mid-copy still leaves a
    # reusable keyed artifact (status flips to completed only once the keyed file is on disk).
    curl -sL "$URL" -o "$KEYED_MP4"
    state_set "status=completed"
    cp "$KEYED_MP4" "$OUT"
    echo "  downloaded $OUT" >&2
    break
  fi
  if [ "$ST" = "failed" ]; then
    # A failed render is not a reusable result — clear video_id so a future run can re-submit
    # (keep the cached VO + asset so the retry doesn't re-pay for those).
    state_set "video_id=" "status=failed"
    echo "  RENDER FAILED: $S" >&2
    exit 1
  fi
  sleep 15
done

# Final line = the path the caller (p-reels-split-heygen Step 1) reads as TALKING_HEAD_VIDEO.
echo "$OUT"
