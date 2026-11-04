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
#   cfw-render-report.sh block <reason> [needs]
#       CFW-146: optional `needs` — ingredient | decision | capacity — tells the
#       owner's order card WHICH action to offer ("Add a photo or clip" /
#       "Answer" / just Retry). Omit it for a plain struggle; the card then reads
#       "Struggled at <step>" with Retry.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

: "${CFW_ORDER_ID:?cfw-render-report: CFW_ORDER_ID not set in env}"
: "${CFW_WORKER_ID:?cfw-render-report: CFW_WORKER_ID not set in env}"
: "${CFW_API_BASE:?cfw-render-report: CFW_API_BASE not set in env}"

# ---------------------------------------------------------------------------
# cr_redact_signed_links — stdin → stdout. WI2.152 / B39. A signed link is a
# bearer credential: whoever holds the approval URL can open the review. The
# worker's stdout/stderr land in cfw-render.out.log in plain text, so every
# reply this script echoes goes through this first. It keeps the path up to the
# token and prints <token> for the rest. Defined here, not in the lib, so a
# caller that swaps in its own lib cannot lose it:
#   https://host/a/AbC123  → https://host/a/<token>
#   …?token=AbC123&x=1     → …?token=<token>&x=1   (token|sig|signature|key|auth|code|password)
# ---------------------------------------------------------------------------
cr_redact_signed_links() {
  python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"(https?://[^\s\"\x27/]+/(?:a|approve|approval|approvals)/)[^\s\"\x27?#/\\]+", r"\1<token>", text)
text = re.sub(r"([?&](?:token|sig|signature|key|auth|code|password)=)[^&\s\"\x27#\\]*", r"\1<token>", text)
sys.stdout.write(text)
'
}

VERB="${1:-}"; shift || true

# WI2.152: the coder runs without the worker key, and provider-wait-start/-end
# (called from a step) never talk to CFW. Only the verbs that do need the key.
case "$VERB" in
  stage|complete|block)
    : "${CFW_RENDER_WORKER_KEY:?cfw-render-report: CFW_RENDER_WORKER_KEY not set in env}" ;;
esac

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
    printf '%s\n' "$resp" | cr_redact_signed_links
    ;;

  complete)
    if [[ $# -eq 0 ]]; then
      echo "cfw-render-report: usage: complete <file> [file2 ...]" >&2
      exit 2
    fi
    # Preserve legacy explicit side-file caption discovery before validation.
    if [[ -z "${CFW_CAPTIONS_FILE:-}" ]]; then
      for f in "$@"; do
        if [[ "$f" != http://* && "$f" != https://* && "$(basename "$f")" == captions.json ]]; then
          CFW_CAPTIONS_FILE="$f"; break
        fi
      done
    fi
    # Validate declared local delivery and captions before uploading. The helper
    # enforces ordered references and current checksums; arguments cannot sweep
    # intermediates into the final list. Ordinary claims retain legacy fallback.
    captions_json="$(python3 - "$SELF_DIR" "${CFW_WORKER_ID}" "${CFW_CAPTIONS_FILE:-final/captions.json}" "$@" <<'PY'
import importlib.util, json, pathlib, sys

def invalid(*args):
    raise ValueError()

def unique(pairs):
    out = {}
    for k, v in pairs:
        if k in out: invalid()
        out[k] = v
    return out

def load(path):
    return json.loads(path.read_text(), object_pairs_hook=unique, parse_constant=invalid)

def text(v):
    if not isinstance(v, str): invalid()
    return v.strip()

def caption(v):
    if isinstance(v, str): return v.strip()
    if not isinstance(v, dict) or set(v) - {'title', 'caption', 'description', 'hashtags'}: invalid()
    parts = [text(v[k]) for k in ('title', 'caption', 'description') if k in v]
    if 'hashtags' in v:
        tags = v['hashtags']
        parts.append(' '.join(text(t) for t in tags) if isinstance(tags, list) else text(tags))
    return '\n\n'.join(p for p in parts if p)

try:
    order = load(pathlib.Path('order.json')) if pathlib.Path('order.json').exists() else {}
    local = (order.get('checkpoint') or {}).get('mode') == 'local-v1'
    required = False
    if local:
        spec = importlib.util.spec_from_file_location('checkpoint', pathlib.Path(sys.argv[1]) / 'cfw-render-checkpoint.py')
        cp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cp)
        root = pathlib.Path.cwd()
        with cp.locked(root):
            state = cp.read_json(cp.contained(root, 'checkpoint.json'))
            cp.require(state['identity'] == cp.identity(order, sys.argv[2]))
            outbox = state['attempts'][order['attempt']['id']]
            cp.require(not outbox['pending'] and any(r['event'] == 'attempt_completed' for r in outbox['acked']))
            outputs = cp.final_outputs(root, order, cp.steps_of(order), state)
            cp.require([x['path'] for x in outputs if x['role'] != 'captions'] == sys.argv[4:])
            captions = [x['path'] for x in outputs if x['role'] == 'captions']
            required = bool(captions)
            if required: cp.require(str(pathlib.Path(sys.argv[3]).absolute()) == captions[0])
except Exception:
    print('cfw-render-report: Cannot verify local delivery. Local files are retained; reconcile the claim before retrying.', file=sys.stderr)
    sys.exit(1)
out = {}
try:
    data = load(pathlib.Path(sys.argv[3]))
    if not isinstance(data, dict): invalid()
    for key, value in data.items():
        try:
            key, value = text(key).lower(), caption(value)
            if (not key or not value or len(key.encode('utf-16-le')) > 80
                    or len(value.encode('utf-16-le')) > 12000 or (required and key in out)): invalid()
            out[key] = value
        except (ValueError, TypeError):
            if required: raise
    if not out or len(out) > 12: invalid()
except (OSError, ValueError, TypeError):
    if required:
        print('cfw-render-report: Required captions are invalid. Local files are retained; nothing was uploaded.', file=sys.stderr)
        sys.exit(1)
    out = {}
    print('cfw-render-report: WARNING — no usable captions; using server copy/intent fallback.', file=sys.stderr)
print(json.dumps(out))
PY
)" || exit 1
    # One explicit ordered delivery only. Keep this marker on ALL failures.
    # Only a synchronous upload failure proves completion was never submitted;
    # otherwise the server may have committed before its response reached us.
    # A later invocation must not re-upload or re-complete automatically.
    if [[ -e .outcome ]] || ! mkdir .delivery-started 2>/dev/null; then
      echo 'cfw-render-report: delivery already started; retain artifacts and reconcile with CFW before retrying' >&2
      exit 1
    fi
    python3 -c 'import json,sys; json.dump(sys.argv[1:], open(".delivery-started/files.json", "x"))' "$@" || exit 1
    # Upload in caller order. Side files must never become carousel slides.
    urls=()
    local_files=()
    for f in "$@"; do
      if [[ "$f" == http://* || "$f" == https://* ]]; then
        urls+=("$f")
      else
        [[ -f "$f" ]] || { echo "cfw-render-report: complete — file not found: $f" >&2; exit 1; }
        f_base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        case "$f_base" in
          *.mp4|*.mov|*.webm|*.m4v|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.pdf|*.mp3|*.wav|*.m4a) ;;
          *)
            if [[ "$f_base" == captions.json && -z "${CFW_CAPTIONS_FILE:-}" ]]; then
              CFW_CAPTIONS_FILE="$f"
            fi
            echo 'cfw-render-report: side file omitted from deliverables' >&2
            continue ;;
        esac
        u="$("$SELF_DIR/cfw-render-upload.sh" "$f")" || {
          # This invocation owns the delivery lock and has not called complete.
          # Permit a block, never another upload/delivery, after this known failure.
          (set -o noclobber; : > .delivery-started/upload-failed) || exit 1
          echo "cfw-render-report: upload failed for $f" >&2
          exit 1
        }
        urls+=("$u")
        local_files+=("$f")
      fi
    done
    if [[ ${#urls[@]} -eq 0 ]]; then
      echo 'cfw-render-report: no media deliverables in explicit output list' >&2
      exit 2
    fi
    output_url="${urls[0]}"
    # CFW-135: every URL, arg order, as one JSON array (consumed below).
    urls_json="$(printf '%s\n' "${urls[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

    # models rollup: director model from the failover state file (written by
    # claude_native_or_ollama_quota_fallback into work/.director-model),
    # fanout list from work/.models-fanout (deduped, written by
    # cfw-render-subagent.sh).
    director_model="$(cat work/.director-model 2>/dev/null || true)"
    # set -u: completion may run without work/.director-model and without the
    # worker having exported CFW_RENDER_DIRECTOR_MODEL into this process.
    [[ -z "$director_model" ]] && director_model="${CFW_RENDER_DIRECTOR_MODEL:-}"
    fanout_json="[]"
    if [[ -f work/.models-fanout ]]; then
      fanout_json="$(sort -u work/.models-fanout | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
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
# Bind delivery to the claimed attempt when present. Legacy servers already
# support this optional guard; no new recovery protocol is implied.
if os.environ.get("CFW_ATTEMPT_ID"):
    d["attemptId"] = os.environ["CFW_ATTEMPT_ID"]
# CFW-136: per-platform captions (brand voice) — only when the recipe wrote some.
if captions:
    d["captions"] = captions
print(json.dumps(d))
' "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$output_url" "$director_model" "$fanout_json" "$urls_json" "$captions_json")"

    cr_heartbeat_stop_if_pending
    resp="$(cr_mcp_call complete_render_order "$complete_args")" || { echo "cfw-render-report: complete_render_order failed" >&2; exit 1; }
    ok="$(python3 -c 'import json,sys; print("1" if json.loads(sys.stdin.read()).get("ok") else "0")' <<< "$resp" 2>/dev/null)"
    if [[ "$ok" != "1" ]]; then
      echo "cfw-render-report: complete_render_order returned ok:false — treating as fatal: $(printf '%s' "$resp" | cr_redact_signed_links)" >&2
      exit 1
    fi

    # Acknowledge immediately, before optional local copying. The remaining
    # crash window is covered by .delivery-started, never by a rescue retry.
    printf 'complete\n' > .outcome.tmp && mv .outcome.tmp .outcome || exit 1

    # Keep a local copy of every finished file on the owner's computer
    # ("$HOME/CFW Render/outputs/<brand>/<date>_<order>/") — only now, after
    # each upload succeeded and CFW accepted the order, so a kept file is
    # always one CFW has too. Never fatal: the order is already complete.
    if [[ -n "${CFW_RENDER_KEEP_DIR:-}" && ${#local_files[@]} -gt 0 ]]; then
      if mkdir -p "$CFW_RENDER_KEEP_DIR" 2>/dev/null && cp -p "${local_files[@]}" "$CFW_RENDER_KEEP_DIR/" 2>/dev/null; then
        cr_log "order $CFW_ORDER_ID — kept ${#local_files[@]} finished file(s) in $CFW_RENDER_KEEP_DIR"
      else
        cr_log "WARN: order $CFW_ORDER_ID — could not keep a local copy in $CFW_RENDER_KEEP_DIR (the render is complete in CFW)"
      fi
    fi

    # CFW-135: NO post-complete event — the order is terminal after
    # complete_render_order and the server rejects further events ("Order not
    # claimed by this worker"). Every deliverable already went in the call above.

    # B39: the reply carries approvalUrl (a signed /a/<token> link). Print the
    # reply without the token; the worker's stdout is a plain-text log.
    printf '%s\n' "$resp" | cr_redact_signed_links
    ;;

  block)
    if [[ -e .delivery-started && ( ! -f .delivery-started/upload-failed || -L .delivery-started/upload-failed ) ]]; then
      echo 'cfw-render-report: delivery may already have completed; refusing conflicting block' >&2
      exit 1
    fi
    reason="${1:-}"; needs="${2:-}"
    if [[ -z "$reason" ]]; then
      echo "cfw-render-report: usage: block <reason> [ingredient|decision|capacity]" >&2
      exit 2
    fi
    if [[ -n "$needs" && "$needs" != "ingredient" && "$needs" != "decision" && "$needs" != "capacity" ]]; then
      echo "cfw-render-report: block — needs must be ingredient|decision|capacity (got '$needs')" >&2
      exit 2
    fi
    args="$(python3 -c '
import json, sys
d = {"orderId": sys.argv[1], "workerId": sys.argv[2], "reason": sys.argv[3]}
if sys.argv[4]:
    d["needs"] = sys.argv[4]
print(json.dumps(d))
' "$CFW_ORDER_ID" "$CFW_WORKER_ID" "$reason" "$needs")"
    cr_heartbeat_stop_if_pending
    resp="$(cr_mcp_call block_render_order "$args")" || { echo "cfw-render-report: block_render_order failed" >&2; exit 1; }
    echo "block" > .outcome
    printf '%s\n' "$resp" | cr_redact_signed_links
    ;;

  provider-wait-start|provider-wait-end)
    # Only a worker-issued per-invocation file is writable. No arbitrary path,
    # provider strings, cross-attempt logs or legacy shared scratch fallback.
    python3 - "$VERB" "${1:-}" "${CFW_RENDER_WAIT_FILE:-}" "${CFW_RENDER_SCRATCH_DIR:-}" <<'PY'
import os, pathlib, sys, time
verb, provider, name, root = sys.argv[1:]
try:
    if provider != "heygen" or not name or not root:
        raise ValueError("missing wait scope")
    path = pathlib.Path(name)
    path.resolve().relative_to(pathlib.Path(root).resolve())
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    with os.fdopen(fd, "a") as f:
        f.write(f'{"start" if verb.endswith("start") else "end"}\theygen\t{int(time.time())}\n')
except (OSError, ValueError):
    print("cfw-render-report: invalid provider wait scope", file=sys.stderr)
    sys.exit(2)
PY
    exit $?
    ;;

  *)
    echo "cfw-render-report: usage: {stage|complete|block|provider-wait-start|provider-wait-end} ..." >&2
    exit 2
    ;;
esac
