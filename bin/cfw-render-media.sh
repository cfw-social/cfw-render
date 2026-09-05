#!/usr/bin/env bash
# cfw-render-media.sh — upload a REUSED ingredient (raw avatar render, outro
# card, b-roll clip) to CFW Media so it can be referenced from a render order's
# `ingredients[]`. Wraps cfw-social's `upload_media` two-door capability
# (CFW-131): the REST twin is POST /api/v1/media/upload-media, the MCP twin is
# the `upload_media` tool the brand's Hermes Director calls.
#
#   local file → (1) POST {filePath,kind,filename}        → presigned R2 PUT
#                (2) PUT the bytes (any size; bypasses the Vercel body cap)
#                (3) POST {filePath,kind,filename,storageKey} → registered
#   http(s) URL → one POST {url,kind,filename} — the server fetches + stores it.
#
# Both paths return the CDN URL + a mediaId (a BrandAsset row, so the file is
# findable later with list_brand_assets). Output: one line per input,
# "<cdnUrl>\t<mediaId>", in arg order. Non-zero exit if ANY upload fails. NEVER
# a fallback host.
#
# AUTH: this is a BRAND capability. It needs a brand API key (`cfw_…`) in
# CFW_BRAND_API_KEY — the render worker key (CFW_RENDER_WORKER_KEY, header
# cfw-render-key) is write-only for render OUTPUTS and is rejected here by
# design. Run this from the Hermes gateway env / an operator shell BEFORE
# submitting the order, not from inside a Director run.
#
# Usage:  cfw-render-media.sh [--kind image|video|doc] [--filename NAME] [--note TEXT] <file-or-url> [...]
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"
cr_load_config

KIND=""; FILENAME=""; NOTE=""; INPUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)     KIND="$2"; shift 2;;
    --filename) FILENAME="$2"; shift 2;;
    --note)     NOTE="$2"; shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)          INPUTS+=("$1"); shift;;
  esac
done
[ "${#INPUTS[@]}" -ge 1 ] || { echo "cfw-render-media: usage: [--kind image|video|doc] [--filename NAME] [--note TEXT] <file-or-url> [...]" >&2; exit 2; }
: "${CFW_API_BASE:?cfw-render-media: CFW_API_BASE not set in env}"
if [ -z "${CFW_BRAND_API_KEY:-}" ]; then
  echo "cfw-render-media: CFW_BRAND_API_KEY (a brand cfw_… API key) is required — upload_media is a BRAND capability; the render worker key cannot upload ingredients (outputs-only via cfw-render-upload.sh)." >&2
  exit 2
fi
case "$CFW_BRAND_API_KEY" in cfw_render_*) echo "cfw-render-media: CFW_BRAND_API_KEY is a render-worker key — need a brand key" >&2; exit 2;; esac

mime_for() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4) echo video/mp4 ;;  mov) echo video/quicktime ;;  webm) echo video/webm ;;
    png) echo image/png ;;  jpg|jpeg) echo image/jpeg ;;  gif) echo image/gif ;;  webp) echo image/webp ;;
    pdf) echo application/pdf ;;   # CFW-135: kind doc (≤50 MB)
    *) echo "" ;;
  esac
}
kind_for_mime() { case "$1" in video/*) echo video;; image/*) echo image;; application/pdf) echo doc;; *) echo "";; esac; }

api_post() { # <json-body> → response body on stdout; non-zero on HTTP failure
  curl -fsS -X POST "${CFW_API_BASE%/}/api/v1/media/upload-media" \
    -H "x-api-key: $CFW_BRAND_API_KEY" -H "content-type: application/json" \
    --data-binary "$1"
}
jbody() { # build a JSON body from key=value pairs (values are strings)
  python3 -c 'import json,sys; print(json.dumps({k:v for k,v in (a.split("=",1) for a in sys.argv[1:]) if v!=""}))' "$@"
}
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$1"; }

upload_one() {
  local src="$1" out="$2" name mime kind resp
  name="${FILENAME:-$(basename "${src%%\?*}")}"
  mime="$(mime_for "$name")"
  kind="${KIND:-$(kind_for_mime "$mime")}"
  if [ -z "$kind" ]; then echo "cfw-render-media: cannot infer --kind for $src (image/*, video/* or .pdf extensions only)" >&2; echo ERROR > "$out"; return 1; fi
  case "$src" in
    http://*|https://*)
      resp="$(api_post "$(jbody "url=$src" "kind=$kind" "filename=$name" "mimeType=$mime" "note=$NOTE")" 2>&1)" \
        || { echo "cfw-render-media: server-fetch upload failed for $src: $resp" >&2; echo ERROR > "$out"; return 1; }
      ;;
    *)
      if [ ! -s "$src" ]; then echo "cfw-render-media: file not found or empty: $src" >&2; echo ERROR > "$out"; return 1; fi
      if [ -z "$mime" ]; then echo "cfw-render-media: unsupported extension for $src" >&2; echo ERROR > "$out"; return 1; fi
      # (1) presign
      local pre uploadUrl storageKey
      pre="$(api_post "$(jbody "filePath=$src" "kind=$kind" "filename=$name" "mimeType=$mime" "note=$NOTE")" 2>&1)" \
        || { echo "cfw-render-media: presign failed for $src: $pre" >&2; echo ERROR > "$out"; return 1; }
      uploadUrl="$(printf '%s' "$pre" | jget uploadUrl)"; storageKey="$(printf '%s' "$pre" | jget storageKey)"
      [ -n "$uploadUrl" ] && [ -n "$storageKey" ] || { echo "cfw-render-media: presign response missing uploadUrl/storageKey: $pre" >&2; echo ERROR > "$out"; return 1; }
      # (2) PUT bytes straight to R2 (Content-Type must match the signature)
      curl -fsS -X PUT "$uploadUrl" -H "content-type: $mime" --data-binary "@$src" -o /dev/null \
        || { echo "cfw-render-media: R2 PUT failed for $src" >&2; echo ERROR > "$out"; return 1; }
      # (3) register
      resp="$(api_post "$(jbody "filePath=$src" "storageKey=$storageKey" "kind=$kind" "filename=$name" "mimeType=$mime" "note=$NOTE")" 2>&1)" \
        || { echo "cfw-render-media: register failed for $src: $resp" >&2; echo ERROR > "$out"; return 1; }
      ;;
  esac
  local cdn id
  cdn="$(printf '%s' "$resp" | jget cdnUrl)"; id="$(printf '%s' "$resp" | jget mediaId)"
  [ -n "$cdn" ] || { echo "cfw-render-media: no cdnUrl in response for $src: $resp" >&2; echo ERROR > "$out"; return 1; }
  printf '%s\t%s\n' "$cdn" "$id" > "$out"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
i=0
for f in "${INPUTS[@]}"; do upload_one "$f" "$tmpdir/$i.out" & i=$((i+1)); done
wait
rc=0
for j in $(seq 0 $((i-1))); do
  line="$(cat "$tmpdir/$j.out" 2>/dev/null || echo ERROR)"
  echo "$line"; [ "$line" = "ERROR" ] && rc=1
done
exit "$rc"
