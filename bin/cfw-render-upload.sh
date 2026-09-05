#!/usr/bin/env bash
# cfw-render-upload.sh — Director-facing upload of render OUTPUTS to CFW Media.
#
# CFW-144: Vercel Functions reject any request body over 4.5 MB
# (413 FUNCTION_PAYLOAD_TOO_LARGE — a platform limit, not app config), so the
# multipart route can never carry a finished reel. The DEFAULT path is now a
# presigned direct-to-R2 PUT, worker-key authed, brand+order-namespaced by the
# server:
#
#   (1) POST /api/v1/render/upload-url      {orderId, workerId, filename, mimeType, bytes}
#         → {uploadUrl, storageKey, cdnUrl, expiresAt, …}
#   (2) PUT  <uploadUrl>                     the raw bytes, Content-Type = mimeType
#         → R2 answers with ETag = MD5 of the body (single-part PUT); we compare
#           it to the local MD5 and retry the PUT on mismatch / transport error
#   (3) POST /api/v1/render/upload-complete {orderId, workerId, storageKey, bytes, mimeType}
#         → cfw-social HEAD-verifies the object (namespace + size + mime) and
#           returns {assets:[{cdnUrl, mimeType, storageKey, bytes}]} — the same
#           shape the multipart route returns, so nothing downstream changes.
#
# Modes (CFW_RENDER_UPLOAD_MODE):
#   presign   (default) every file goes through (1)–(3).
#   auto      files ≤ CFW_RENDER_UPLOAD_MULTIPART_MAX bytes (default 4 MiB) use
#             the legacy multipart POST /api/v1/render/upload; larger → presign.
#   multipart legacy multipart only (≤ 4 MiB on Vercel — a larger file FAILS
#             with the platform 413; there is NO silent fallback either way).
#
# Modeled on cfw-provisioner's cfw-upload.sh (mime map, concurrent curls,
# ordered output, ERROR marker, non-zero if any fail, NEVER a fallback host);
# credential = the cfw-render-key header + orderId/workerId (the brand
# cfw-upload key is structurally unavailable to this worker — plan §0.2).
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

UPLOAD_MODE="${CFW_RENDER_UPLOAD_MODE:-presign}"
case "$UPLOAD_MODE" in presign|auto|multipart) ;; *) echo "cfw-render-upload: CFW_RENDER_UPLOAD_MODE must be presign|auto|multipart (got '$UPLOAD_MODE')" >&2; exit 2;; esac
# 4 MiB — safely under the 4.5 MB Vercel Functions body cap (multipart framing adds a little).
MULTIPART_MAX="${CFW_RENDER_UPLOAD_MULTIPART_MAX:-4194304}"
PUT_ATTEMPTS="${CFW_RENDER_UPLOAD_ATTEMPTS:-3}"
API="${CFW_API_BASE%/}"

mime_for() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4) echo video/mp4 ;;  mov) echo video/quicktime ;;  webm) echo video/webm ;;  m4v) echo video/x-m4v ;;
    png) echo image/png ;;  jpg|jpeg) echo image/jpeg ;;  gif) echo image/gif ;;  webp) echo image/webp ;;
    pdf) echo application/pdf ;;   # CFW-135: the LinkedIn-native carousel document, stored as a `doc` output
    *) echo "" ;;
  esac
}

file_size() { # portable stat → bytes
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
md5_of() { # lower-case hex MD5 of a file (macOS `md5`, GNU `md5sum`, or openssl)
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else openssl dgst -md5 -r "$1" | cut -d' ' -f1
  fi | tr '[:upper:]' '[:lower:]'
}
jget() { # jget <key> ← JSON on stdin; prints "" when absent
  python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit(0)
v=d
for k in sys.argv[1].split("."):
    if isinstance(v,list):
        try: v=v[int(k)]
        except Exception: v=None
    elif isinstance(v,dict): v=v.get(k)
    else: v=None
print("" if v is None else v)' "$1"
}
jbody() { # jbody k=v ... — strings, except *_int keys which become integers
  python3 -c 'import json,sys
o={}
for a in sys.argv[1:]:
    k,v=a.split("=",1)
    if k.endswith("_int"): o[k[:-4]]=int(v)
    else: o[k]=v
print(json.dumps(o))' "$@"
}
api_post_json() { # api_post_json <path> <json> → body on stdout; prints "HTTP <code>" line to stderr on failure; rc≠0 on failure
  local path="$1" body="$2" out code
  out="$(mktemp)"
  code="$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' -X POST "$API$path" \
            -H "cfw-render-key: $CFW_RENDER_WORKER_KEY" -H "content-type: application/json" \
            --data-binary "$body" 2>/dev/null)" || code="000"
  if [ "$code" != "200" ]; then
    echo "HTTP $code $(head -c 300 "$out" 2>/dev/null | tr '\n' ' ')" >&2; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# ── legacy multipart (≤ 4 MiB on Vercel) ────────────────────────────────────
upload_multipart() { # <file> <mime> → cdnUrl on stdout
  local file="$1" mime="$2" resp
  resp="$(curl -fsS --max-time 300 -X POST "$API/api/v1/render/upload" \
            -H "cfw-render-key: $CFW_RENDER_WORKER_KEY" \
            -F "files=@$file;type=$mime" \
            -F "orderId=$CFW_ORDER_ID" \
            -F "workerId=$CFW_WORKER_ID" 2>/dev/null)" \
    || { echo "cfw-render-upload: multipart POST failed for $file (auth? >4 MiB → use presign; mime?)" >&2; return 1; }
  local url
  url="$(printf '%s' "$resp" | jget assets.0.cdnUrl)"
  [ -n "$url" ] || { echo "cfw-render-upload: no cdnUrl in multipart response for $file: $resp" >&2; return 1; }
  echo "$url"
}

# ── presigned direct-to-R2 (any size) ───────────────────────────────────────
upload_presign() { # <file> <mime> → cdnUrl on stdout
  local file="$1" mime="$2" name bytes sum pre uploadUrl storageKey
  name="$(basename "$file")"; bytes="$(file_size "$file")"; sum="$(md5_of "$file")"

  # (1) presign — the server derives the R2 key from the CLAIMED order (brand + order namespace).
  pre="$(api_post_json /api/v1/render/upload-url \
          "$(jbody "orderId=$CFW_ORDER_ID" "workerId=$CFW_WORKER_ID" "filename=$name" "mimeType=$mime" "bytes_int=$bytes")" 2>&1)" \
    || { echo "cfw-render-upload: upload-url failed for $file: $pre" >&2; return 1; }
  uploadUrl="$(printf '%s' "$pre" | jget uploadUrl)"; storageKey="$(printf '%s' "$pre" | jget storageKey)"
  [ -n "$uploadUrl" ] && [ -n "$storageKey" ] || { echo "cfw-render-upload: upload-url response missing uploadUrl/storageKey for $file: $pre" >&2; return 1; }

  # (2) PUT straight to R2 — retried; ETag (single-part PUT = MD5 of the body) must equal the local MD5.
  local attempt hdr code etag ok=0
  hdr="$(mktemp)"
  for attempt in $(seq 1 "$PUT_ATTEMPTS"); do
    code="$(curl -sS --max-time 3600 -o /dev/null -D "$hdr" -w '%{http_code}' -X PUT "$uploadUrl" \
              -H "content-type: $mime" -H "expect:" --data-binary "@$file" 2>/dev/null)" || code="000"
    if [ "$code" = "200" ]; then
      etag="$(grep -i '^etag:' "$hdr" | tail -1 | cut -d: -f2- | tr -d ' "\r' | tr '[:upper:]' '[:lower:]')"
      if [ -z "$etag" ]; then
        echo "cfw-render-upload: WARN no ETag on PUT response for $file — relying on the server-side size check" >&2; ok=1; break
      elif case "$etag" in *-*) true;; *) false;; esac; then
        # multipart-style ETag (not an MD5) — cannot compare; the server size check still applies.
        ok=1; break
      elif [ "$etag" = "$sum" ]; then
        ok=1; break
      else
        echo "cfw-render-upload: PUT attempt $attempt/$PUT_ATTEMPTS for $file — checksum mismatch (etag $etag ≠ md5 $sum), retrying" >&2
      fi
    else
      echo "cfw-render-upload: PUT attempt $attempt/$PUT_ATTEMPTS for $file failed (HTTP $code), retrying" >&2
    fi
    [ "$attempt" -lt "$PUT_ATTEMPTS" ] && sleep $((attempt * 2))
  done
  rm -f "$hdr"
  [ "$ok" = 1 ] || { echo "cfw-render-upload: R2 PUT failed for $file after $PUT_ATTEMPTS attempts" >&2; return 1; }

  # (3) complete — cfw-social HEAD-verifies namespace + size + mime; 404 = not visible yet → brief retry.
  local resp url got
  for attempt in 1 2 3; do
    resp="$(api_post_json /api/v1/render/upload-complete \
             "$(jbody "orderId=$CFW_ORDER_ID" "workerId=$CFW_WORKER_ID" "storageKey=$storageKey" "bytes_int=$bytes" "mimeType=$mime")" 2>&1)" && break
    case "$resp" in "HTTP 404"*) sleep $((attempt * 2));; *) break;; esac
  done
  url="$(printf '%s' "$resp" | jget assets.0.cdnUrl)"; got="$(printf '%s' "$resp" | jget assets.0.bytes)"
  [ -n "$url" ] || { echo "cfw-render-upload: upload-complete failed for $file: $resp" >&2; return 1; }
  [ "$got" = "$bytes" ] || { echo "cfw-render-upload: upload-complete size mismatch for $file (server $got ≠ local $bytes)" >&2; return 1; }
  echo "$url"
}

upload_one() {
  local file="$1" out="$2" mime bytes url path
  if [ ! -s "$file" ]; then echo "cfw-render-upload: file not found or empty: $file" >&2; echo ERROR > "$out"; return 1; fi
  mime="$(mime_for "$file")"
  if [ -z "$mime" ]; then echo "cfw-render-upload: unsupported extension for $file (image/*, video/* or .pdf only)" >&2; echo ERROR > "$out"; return 1; fi
  bytes="$(file_size "$file")"
  case "$UPLOAD_MODE" in
    presign)   path=presign ;;
    multipart) path=multipart ;;
    auto)      if [ "$bytes" -le "$MULTIPART_MAX" ]; then path=multipart; else path=presign; fi ;;
  esac
  if [ "$path" = multipart ] && [ "$bytes" -gt "$MULTIPART_MAX" ]; then
    echo "cfw-render-upload: $file is $bytes bytes > $MULTIPART_MAX — the multipart route 413s on Vercel; use CFW_RENDER_UPLOAD_MODE=presign (default) or auto" >&2
    echo ERROR > "$out"; return 1
  fi
  if url="$(upload_$path "$file" "$mime")"; then echo "$url" > "$out"; else echo ERROR > "$out"; return 1; fi
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
