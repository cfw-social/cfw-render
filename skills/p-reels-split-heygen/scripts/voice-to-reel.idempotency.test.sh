#!/usr/bin/env bash
# Idempotency test for voice-to-reel.sh (AB-FLEETFIX-HEYGEN-DUP-RENDER).
#
# Proves the money-burning fix: running the render with the SAME inputs twice
# (as happens when a turn times out mid-poll/mid-download and the agent retries)
# results in EXACTLY ONE HeyGen /v3/videos render call — not two.
#
# No network, no real keys: `curl` is replaced with a stub on PATH that counts
# render submissions and returns canned HeyGen JSON. ElevenLabs TTS is skipped by
# pre-seeding the keyed VO file (the same skip path a real resume takes).
#
# Run:  bash voice-to-reel.idempotency.test.sh
# Exit: 0 = pass, non-zero = fail.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/voice-to-reel.sh"
[ -f "$SUT" ] || { echo "FAIL: cannot find voice-to-reel.sh at $SUT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RENDER_COUNT_FILE="$TMP/render_count"
echo 0 > "$RENDER_COUNT_FILE"

# ── Stub curl ────────────────────────────────────────────────────────────────
# Dispatches on the URL / flags present in the args, mirroring the four real
# HeyGen calls the script makes. Increments the render counter ONLY on a
# /v3/videos POST (the billed submission).
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
args="\$*"
# download step: -o <path> -> write a dummy mp4
for ((i=1; i<=\$#; i++)); do
  if [ "\${!i}" = "-o" ]; then
    j=\$((i+1)); out="\${!j}"
    printf 'FAKE_MP4' > "\$out"
    exit 0
  fi
done
case "\$args" in
  *upload.heygen.com/v1/asset*)
    echo '{"data":{"id":"asset-stub-1"}}' ;;
  *api.heygen.com/v3/videos*)
    n=\$(cat "$RENDER_COUNT_FILE"); echo \$((n+1)) > "$RENDER_COUNT_FILE"
    echo '{"data":{"video_id":"video-stub-1"}}' ;;
  *video_status.get*)
    echo '{"data":{"status":"completed","video_url":"https://example.test/v.mp4"}}' ;;
  *)
    echo '{}' ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/curl"

# ── Inputs (identical across both runs) ──────────────────────────────────────
export PATH="$STUB_BIN:$PATH"
export ELEVENLABS_API_KEY="test-el-key"
export HEYGEN_API_KEY="test-hg-key"
export SECRETS_FILE="$TMP/no-secrets.env"   # force env-only key loading
export EL_VOICE="voice-test"
export EL_MODEL="eleven_v3"
export HG_AVATAR="avatar-test"
SCRIPT_TEXT="Hello fleet, this is a deterministic idempotency probe."
OUT="$TMP/th.mp4"
export WORK="$TMP/_v2r"; mkdir -p "$WORK"

# Pre-seed the keyed VO so the ElevenLabs network call is skipped on run 1 too
# (the test asserts render idempotency, not the TTS provider). The key derivation
# must match the script exactly.
RENDER_KEY=$(SCRIPT="$SCRIPT_TEXT" EL_VOICE="$EL_VOICE" EL_MODEL="$EL_MODEL" HG_AVATAR="$HG_AVATAR" python3 - <<'PY'
import os, hashlib
s = "|".join([os.environ["SCRIPT"], os.environ["EL_VOICE"], os.environ["EL_MODEL"], os.environ["HG_AVATAR"]])
print(hashlib.sha256(s.encode("utf-8")).hexdigest()[:16])
PY
)
printf 'FAKE_VO' > "$WORK/vo-$RENDER_KEY.mp3"

run() {
  SCRIPT="$SCRIPT_TEXT" OUT="$OUT" bash "$SUT" >/dev/null 2>"$TMP/run.log" || {
    echo "FAIL: script exited non-zero"; cat "$TMP/run.log"; exit 1;
  }
}

echo "── run 1 (initial cook) ──"
run
echo "── run 2 (simulated timeout retry — same inputs) ──"
run

RENDERS=$(cat "$RENDER_COUNT_FILE")
echo "HeyGen /v3/videos render submissions across 2 runs: $RENDERS"

fail=0
if [ "$RENDERS" -ne 1 ]; then
  echo "FAIL: expected exactly 1 render submission, got $RENDERS (duplicate billing not prevented)"
  fail=1
fi
if [ ! -s "$OUT" ]; then
  echo "FAIL: output MP4 was not produced at $OUT"
  fail=1
fi
# A completed render must be reusable across runs via the keyed cache file.
if [ ! -s "$WORK/heygen-$RENDER_KEY.mp4" ]; then
  echo "FAIL: keyed render cache file missing (resume/reuse broken)"
  fail=1
fi

# ── Bonus: FORCE_RENDER=1 must bypass the cache and submit a fresh render ──────
echo "── run 3 (FORCE_RENDER=1) ──"
FORCE_RENDER=1 SCRIPT="$SCRIPT_TEXT" OUT="$OUT" bash "$SUT" >/dev/null 2>"$TMP/run3.log" || {
  echo "FAIL: FORCE_RENDER run exited non-zero"; cat "$TMP/run3.log"; exit 1;
}
RENDERS_AFTER_FORCE=$(cat "$RENDER_COUNT_FILE")
if [ "$RENDERS_AFTER_FORCE" -ne 2 ]; then
  echo "FAIL: FORCE_RENDER=1 should submit a fresh render (expected total 2, got $RENDERS_AFTER_FORCE)"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "❌ TEST FAILED"
  exit 1
fi
echo "✅ PASS: identical inputs => 1 render; output + keyed cache present; FORCE_RENDER bypasses cache."
