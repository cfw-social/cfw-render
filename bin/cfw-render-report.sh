#!/usr/bin/env bash
# cfw-render-report.sh — Director-facing: stage | complete | block.
# Reads CFW_ORDER_ID / CFW_WORKER_ID from env (the Director never handles
# ids directly). On PATH during a Director run (bin/cfw-render.sh exports
# PATH=<repo bin>:$PATH), so the Director calls it by bare name.
#
# Usage:
#   cfw-render-report.sh stage <stage> <pct> <message>
#   cfw-render-report.sh complete <file> [file2 ...]
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

    complete_args="$(python3 -c '
import json, sys
order_id, worker_id, output_url, director_model, fanout_json = sys.argv[1:6]
d = {
    "orderId": order_id,
    "workerId": worker_id,
    "outputUrl": output_url,
    "models": {"director": director_model, "fanout": json.loads(fanout_json), "escalated": director_model != "sonnet"},
}
print(json.dumps(d))
' "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$output_url" "$director_model" "$fanout_json")"

    resp="$(cr_mcp_call complete_render_order "$complete_args")" || { echo "cfw-render-report: complete_render_order failed" >&2; exit 1; }
    ok="$(python3 -c 'import json,sys; print("1" if json.loads(sys.stdin.read()).get("ok") else "0")' <<< "$resp" 2>/dev/null)"
    if [[ "$ok" != "1" ]]; then
      echo "cfw-render-report: complete_render_order returned ok:false — treating as fatal: $resp" >&2
      exit 1
    fi

    if (( ${#urls[@]} > 1 )); then
      extra="${urls[*]:1}"
      cr_event "$CFW_ORDER_ID" stage assemble "Additional deliverables: $extra" 100 2>/dev/null || true
    fi

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
