#!/usr/bin/env bash
# cfw-render-upload.sh — Director-facing upload to CFW Media via the render
# route. Modeled on cfw-provisioner/src/lib/tmpl/cfw-upload.sh (mime map,
# concurrent curls, ordered output, ERROR marker, non-zero if any fail, NEVER
# a fallback host) but targets POST /api/v1/render/upload with the
# cfw-render-key header + orderId/workerId form fields (the brand cfw-upload
# credential is structurally unavailable to this worker — plan §0.2).
#
# Usage:  cfw-render-upload.sh <file1> [file2] [file3] ...
# Output: one CDN URL per input file, SAME ORDER as args (one per line).
# Exit:   non-zero if ANY upload fails.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

[ "$#" -ge 1 ] || { echo "cfw-render-upload: usage: cfw-render-upload <file1> [file2] ..." >&2; exit 2; }
: "${CFW_API_BASE:?cfw-render-upload: CFW_API_BASE not set in env}" \
  "${CFW_RENDER_WORKER_KEY:?cfw-render-upload: CFW_RENDER_WORKER_KEY not set in env}" \
  "${CFW_ORDER_ID:?cfw-render-upload: CFW_ORDER_ID not set in env}" \
  "${CFW_WORKER_ID:?cfw-render-upload: CFW_WORKER_ID not set in env}"

mime_for() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4) echo video/mp4 ;;  mov) echo video/quicktime ;;  webm) echo video/webm ;;  m4v) echo video/x-m4v ;;
    png) echo image/png ;;  jpg|jpeg) echo image/jpeg ;;  gif) echo image/gif ;;  webp) echo image/webp ;;
    pdf) echo application/pdf ;;   # CFW-135: the LinkedIn-native carousel document (≤50 MB), stored as a `doc` output
    *) echo "" ;;
  esac
}

upload_one() {
  local file="$1" out="$2" mime
  if [ ! -s "$file" ]; then echo "cfw-render-upload: file not found or empty: $file" >&2; echo ERROR > "$out"; return 1; fi
  mime="$(mime_for "$file")"
  if [ -z "$mime" ]; then echo "cfw-render-upload: unsupported extension for $file (image/*, video/* or .pdf only)" >&2; echo ERROR > "$out"; return 1; fi
  local resp
  resp="$(curl -fsS -X POST "${CFW_API_BASE%/}/api/v1/render/upload" \
            -H "cfw-render-key: $CFW_RENDER_WORKER_KEY" \
            -F "files=@$file;type=$mime" \
            -F "orderId=$CFW_ORDER_ID" \
            -F "workerId=$CFW_WORKER_ID" 2>/dev/null)" \
    || { echo "cfw-render-upload: POST failed for $file (auth? >100MB? mime?)" >&2; echo ERROR > "$out"; return 1; }
  local url
  url="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["assets"][0]["cdnUrl"])' 2>/dev/null)" \
    || { echo "cfw-render-upload: no cdnUrl in response for $file: $resp" >&2; echo ERROR > "$out"; return 1; }
  echo "$url" > "$out"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

i=0
for f in "$@"; do
  upload_one "$f" "$tmpdir/$i.url" &
  i=$((i+1))
done
wait

rc=0
for j in $(seq 0 $((i-1))); do
  line="$(cat "$tmpdir/$j.url" 2>/dev/null || echo ERROR)"
  echo "$line"
  [ "$line" = "ERROR" ] && rc=1
done
exit "$rc"
