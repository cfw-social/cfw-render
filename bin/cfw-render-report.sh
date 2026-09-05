#!/usr/bin/env bash
# cfw-render-report.sh — Director-facing: stage | complete | block.
# Reads CFW_ORDER_ID / CFW_WORKER_ID from env (the Director never handles
# ids directly). On PATH during a Director run (bin/cfw-render.sh exports
# PATH=<repo bin>:$PATH), so the Director calls it by bare name.
#
# Usage:
#   cfw-render-report.sh stage <stage> <pct> <message>
#   cfw-render-report.sh complete <file> [file2 ...]
#       CFW-135: EVERY deliverable goes in this ONE call, in delivery order —
#       cover/slide 1 first, then slides 2..N, then the carousel PDF. The call
#       sends outputUrl (= first file, legacy), outputUrls[] (all URLs) and
#       outputs[] ({url, kind, mimeType, order, role}); cfw-social attaches every
#       slide to the dish and the PDF as a "PDF" chip. Nothing can be reported
#       after complete (the order is terminal), so never split deliverables.
#       CFW-136: a reel = the video first, then its cover.png — the PNG after a
#       video is tagged role "poster" (the still the Reviews bezel shows before
#       tap-to-play; never a slide). CAPTIONS: if final/captions.json exists
#       (or $CFW_CAPTIONS_FILE points at a JSON file) — `{ "<platform>": "<caption>" }`
#       per target platform, brand voice — it is sent as `captions` so the dish
#       lands in Reviews with per-platform copy instead of "No caption". A
#       missing platform falls back server-side (order copy → intent); an
#       absent file logs a WARNING (the Director should always write one).
#   cfw-render-report.sh block <reason>
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

: "${CFW_ORDER_ID:?cfw-render-report: CFW_ORDER_ID not set in env}"
: "${CFW_WORKER_ID:?cfw-render-report: CFW_WORKER_ID not set in env}"
: "${CFW_API_BASE:?cfw-render-report: CFW_API_BASE not set in env}"
: "${CFW_RENDER_WORKER_KEY:?cfw-render-report: CFW_RENDER_WORKER_KEY not set in env}"

VERB="${1:-}"; shift || true

case "$VERB" in
  stage)
    stage="${1:-}"; pct="${2:-}"; message="${3:-}"
    if [[ -z "$stage" || -z "$message" ]]; then
      echo "cfw-render-report: usage: stage <stage> <pct> <message>" >&2
      exit 2
    fi
    args="$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"kind":"stage","stage":sys.argv[3],"message":sys.argv[4],"pct":int(sys.argv[5])} if sys.argv[5] else {"orderId":sys.argv[1],"workerId":sys.argv[2],"kind":"stage","stage":sys.argv[3],"message":sys.argv[4]}))' \
      "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$stage" "$message" "$pct")"
    resp="$(cr_mcp_call append_render_event "$args")" || { echo "cfw-render-report: stage event failed" >&2; exit 1; }
    echo "$resp"
    ;;

  complete)
    if [[ $# -eq 0 ]]; then
      echo "cfw-render-report: usage: complete <file> [file2 ...]" >&2
      exit 2
    fi
    # Upload every file (local paths); a URL arg is passed through as-is.
    urls=()
    for f in "$@"; do
      if [[ "$f" == http://* || "$f" == https://* ]]; then
        urls+=("$f")
      else
        [[ -f "$f" ]] || { echo "cfw-render-report: complete — file not found: $f" >&2; exit 1; }
        u="$("$SELF_DIR/cfw-render-upload.sh" "$f")" || { echo "cfw-render-report: upload failed for $f" >&2; exit 1; }
        urls+=("$u")
      fi
    done
    output_url="${urls[0]}"
    # CFW-135: every URL, arg order, as one JSON array (consumed below).
    urls_json="$(printf '%s\n' "${urls[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

    # models rollup: director model from the failover state file (written by
    # claude_native_or_ollama_quota_fallback into work/.director-model),
    # fanout list from work/.models-fanout (deduped, written by
    # cfw-render-subagent.sh).
    director_model="$(cat work/.director-model 2>/dev/null || true)"
    [[ -z "$director_model" ]] && director_model="$CFW_RENDER_DIRECTOR_MODEL"
    fanout_json="[]"
    if [[ -f work/.models-fanout ]]; then
      fanout_json="$(sort -u work/.models-fanout | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    fi

    # CFW-136: per-platform captions written by the recipe (brand voice).
    # final/captions.json = { "<platform>": "<caption>", ... }. Optional override
    # via $CFW_CAPTIONS_FILE. Absent → WARN (the dish still mints; cfw-social
    # falls back to the order's copy block, then its intent — never blank).
    captions_file="${CFW_CAPTIONS_FILE:-final/captions.json}"
    captions_json="{}"
    if [[ -f "$captions_file" ]]; then
      captions_json="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("{}"); sys.exit(0)
if not isinstance(d, dict):
    print("{}"); sys.exit(0)
out = {}
for k, v in d.items():
    if isinstance(k, str) and isinstance(v, str) and k.strip() and v.strip():
        out[k.strip().lower()] = v.strip()
print(json.dumps(out))
' "$captions_file")"
      if [[ "$captions_json" == "{}" ]]; then
        echo "cfw-render-report: WARNING — $captions_file has no usable {platform: caption} entries; server will fall back to order copy/intent" >&2
      fi
    else
      echo "cfw-render-report: WARNING — no $captions_file; the dish will use the order's copy/intent as its caption. Recipes should write final/captions.json (one entry per target platform)." >&2
    fi

    complete_args="$(python3 -c '
import json, sys, os
order_id, worker_id, output_url, director_model, fanout_json, urls_json, captions_json = sys.argv[1:8]
urls = json.loads(urls_json)
captions = json.loads(captions_json)
KIND = {"pdf": "doc", "mp4": "video", "mov": "video", "webm": "video", "m4v": "video",
        "mp3": "audio", "wav": "audio", "m4a": "audio"}
MIME = {"pdf": "application/pdf", "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "m4v": "video/x-m4v", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4"}
def ext(u):
    return os.path.splitext(u.split("?")[0].split("#")[0])[1].lstrip(".").lower()
outputs = []
seen_video = False
for i, u in enumerate(urls):
    kind = KIND.get(ext(u), "image")
    item = {"url": u, "kind": kind, "mimeType": MIME.get(ext(u), "image/jpeg"), "order": i}
    # CFW-136 role: the first IMAGE after a video is the reel poster (cover.png);
    # otherwise slide 1 = cover, the rest = slide. Docs carry no role.
    if kind == "video":
        seen_video = True
        item["role"] = "cover" if i == 0 else "slide"
    elif kind == "image":
        if seen_video and not any(o.get("role") == "poster" for o in outputs):
            item["role"] = "poster"
        else:
            item["role"] = "cover" if i == 0 else "slide"
    outputs.append(item)
d = {
    "orderId": order_id,
    "workerId": worker_id,
    # legacy single-URL field (cover) — kept for older servers
    "outputUrl": output_url,
    # CFW-135: the FULL ordered deliverable list (slides + PDF) — one call
    "outputUrls": urls,
    "outputs": outputs,
    "models": {"director": director_model, "fanout": json.loads(fanout_json), "escalated": director_model != "sonnet"},
}
# CFW-136: per-platform captions (brand voice) — only when the recipe wrote some.
if captions:
    d["captions"] = captions
print(json.dumps(d))
' "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$output_url" "$director_model" "$fanout_json" "$urls_json" "$captions_json")"

    resp="$(cr_mcp_call complete_render_order "$complete_args")" || { echo "cfw-render-report: complete_render_order failed" >&2; exit 1; }
    ok="$(python3 -c 'import json,sys; print("1" if json.loads(sys.stdin.read()).get("ok") else "0")' <<< "$resp" 2>/dev/null)"
    if [[ "$ok" != "1" ]]; then
      echo "cfw-render-report: complete_render_order returned ok:false — treating as fatal: $resp" >&2
      exit 1
    fi

    # CFW-135: NO post-complete event — the order is terminal after
    # complete_render_order and the server rejects further events ("Order not
    # claimed by this worker"). Every deliverable already went in the call above.

    echo "complete" > .outcome
    echo "$resp"
    ;;

  block)
    reason="${1:-}"
    if [[ -z "$reason" ]]; then
      echo "cfw-render-report: usage: block <reason>" >&2
      exit 2
    fi
    args="$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"reason":sys.argv[3]}))' \
      "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$reason")"
    resp="$(cr_mcp_call block_render_order "$args")" || { echo "cfw-render-report: block_render_order failed" >&2; exit 1; }
    echo "block" > .outcome
    echo "$resp"
    ;;

  *)
    echo "cfw-render-report: usage: {stage|complete|block} ..." >&2
    exit 2
    ;;
esac
