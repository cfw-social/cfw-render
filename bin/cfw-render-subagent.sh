#!/usr/bin/env bash
# cfw-render-subagent.sh — Director-facing: GLM/Kimi fan-out wrapper.
# Validates the model against CFW_RENDER_FANOUT_MODELS, runs the bash-ported
# claude_ollama_failover (goofy→pike), appends the served model to
# work/.models-fanout (deduped later by cfw-render-report.sh complete), and
# emits append_render_event(kind:subagent, model:...) — the AC "record
# per-stage model" satisfied mechanically, not by trusting the Director's
# self-report.
#
# Usage: cfw-render-subagent.sh <model> [-s <stage>] -p <prompt> [claude args...]
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

: "${CFW_ORDER_ID:?cfw-render-subagent: CFW_ORDER_ID not set in env}"
: "${CFW_WORKER_ID:?cfw-render-subagent: CFW_WORKER_ID not set in env}"
: "${CFW_RENDER_FANOUT_MODELS:?cfw-render-subagent: CFW_RENDER_FANOUT_MODELS not set in env}"

model="${1:-}"; shift || true
if [[ -z "$model" ]]; then
  echo "cfw-render-subagent: usage: <model> [-s <stage>] -p <prompt> [claude args...]" >&2
  exit 2
fi

IFS=',' read -r -a allowed <<< "$CFW_RENDER_FANOUT_MODELS"
valid=0
for m in "${allowed[@]}"; do [[ "$m" == "$model" ]] && valid=1; done
if (( ! valid )); then
  echo "cfw-render-subagent: model '$model' not in CFW_RENDER_FANOUT_MODELS ($CFW_RENDER_FANOUT_MODELS)" >&2
  exit 2
fi

stage="fanout"
if [[ "${1:-}" == "-s" ]]; then
  stage="$2"; shift 2
fi

mkdir -p work
out="work/.subagent-$(date +%s)-$$.out"
claude_ollama_failover "$CFW_ORDER_ID:$stage" "$model" "$out" -- "$@"
rc=$?

if (( rc == 0 )); then
  echo "$model" >> work/.models-fanout
  cr_event "$CFW_ORDER_ID" subagent "$stage" "Prep station working" "" "$model" 2>/dev/null || true
else
  echo "cfw-render-subagent: model=$model stage=$stage failed (exit $rc) — see $out" >&2
fi

exit $rc
