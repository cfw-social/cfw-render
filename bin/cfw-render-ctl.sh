#!/usr/bin/env bash
# cfw-render-ctl.sh — operator control surface. Mirrors ab-hustler-ctl.sh verb
# style. All read paths are LOCAL (state dir + journal) — the narrow worker
# key has no read tool by design (plan §7).
#
# Usage:
#   cfw-render-ctl.sh status
#   cfw-render-ctl.sh run-now
#   cfw-render-ctl.sh pause | resume
#   cfw-render-ctl.sh logs [n]
#   cfw-render-ctl.sh send-logs [--yes] [--dry]
#   cfw-render-ctl.sh unblock <orderId>
#   cfw-render-ctl.sh clear-limit <engine>
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

VERB="${1:-}"; shift || true

case "$VERB" in
  status)
    cr_load_config || exit 1
    echo "cfw-render status"
    echo "------------------"
    lock="$CFW_RENDER_STATE_DIR/tick.lock"
    if [[ -d "$lock" ]]; then
      pid="$(grep '^pid=' "$lock/info" 2>/dev/null | cut -d= -f2)"
      ts="$(grep '^ts=' "$lock/info" 2>/dev/null | cut -d= -f2)"
      age=$(( $(date +%s) - ${ts:-0} ))
      echo "tick lock: HELD (pid=$pid, age=${age}s)"
    else
      echo "tick lock: free"
    fi

    # [M3-01a] status.json (written by the worker after every claim round)
    if [[ -f "$CFW_RENDER_STATE_DIR/status.json" ]]; then
      python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); c = d.get("computer", {})
p = "yes (%s)" % c.get("pauseReason") if c.get("paused") else "no"
print("paused: " + p)
print("on battery: " + ("yes" if c.get("onBattery") else "no"))
print("version: " + str(d.get("workerVersion")))
print("last check: " + str(d.get("lastCheckAt")))
print("running: %s/%s" % (c.get("running", 0), c.get("max", "?")))
' "$CFW_RENDER_STATE_DIR/status.json" 2>/dev/null || echo "status.json: unreadable"
    fi

    journal="$CFW_RENDER_STATE_DIR/journal.tsv"
    echo ""
    echo "live director pids: journal rows are post-mortem only (no live-pid column) —"
    echo "  check 'ps aux | grep claude' on the host for a currently-running Director."

    echo ""
    echo "last 10 journal rows:"
    if [[ -f "$journal" ]]; then
      tail -10 "$journal" | column -t -s $'\t' 2>/dev/null || tail -10 "$journal"
    else
      echo "  (none)"
    fi

    echo ""
    echo "timer status:"
    if command -v launchctl >/dev/null 2>&1; then
      launchctl print "gui/$(id -u)/com.cfw.render" 2>&1 | head -5 || echo "  com.cfw.render not loaded"
    else
      echo "  no launchctl on this computer"
    fi

    echo ""
    "$SELF_DIR/cfw-render.sh" --dry
    ;;

  run-now)
    cr_load_config || exit 1
    if [[ -d "$CFW_RENDER_STATE_DIR/tick.lock" ]]; then
      # the loop is running: it picks the flag up on its next 2 s tick
      touch "$CFW_RENDER_STATE_DIR/run-now"
      echo "run-now: asked the running worker to check for requests now"
    else
      "$SELF_DIR/cfw-render.sh" --once
    fi
    ;;

  pause)
    cr_load_config || exit 1
    mkdir -p "$CFW_RENDER_STATE_DIR" && touch "$CFW_RENDER_STATE_DIR/paused"
    echo "paused: this computer will not take new requests (running ones finish). 'resume' to undo."
    ;;

  resume)
    cr_load_config || exit 1
    rm -f "$CFW_RENDER_STATE_DIR/paused"
    echo "resumed: this computer takes requests again"
    ;;

  logs)
    n="${1:-50}"
    cr_load_config || exit 1
    echo "== $CFW_RENDER_LOG_DIR/cfw-render.log (last $n) =="
    tail -n "$n" "$CFW_RENDER_LOG_DIR/cfw-render.log" 2>/dev/null || echo "(no log yet)"
    echo ""
    newest="$(ls -t "$CFW_RENDER_LOG_DIR"/runs/*.out 2>/dev/null | head -1)"
    if [[ -n "$newest" ]]; then
      echo "== newest run: $newest (last $n) =="
      tail -n "$n" "$newest"
    fi
    ;;

  unblock)
    order_id="${1:-}"
    if [[ -z "$order_id" ]]; then
      echo "cfw-render-ctl: usage: unblock <orderId>" >&2
      exit 2
    fi
    cr_load_config || exit 1
    args="$(python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1]}))' "$order_id")"
    resp="$(cr_mcp_call requeue_render_order "$args" 2>&1)"
    rc=$?
    if (( rc == 0 )); then
      echo "$resp"
      exit 0
    fi
    cat >&2 <<EOF
cfw-render-ctl: unblock $order_id — requeue_render_order is not available yet.

This is a known server-side gap (implementation-plan.md §0.4, follow-up task
AB-RNDR-REQUEUE in cfw-social): neither claim tool can reclaim a
'blocked'/expired-lease order, and there is no requeue_render_order worker
tool today. This command does NOT silently no-op — land AB-RNDR-REQUEUE, or
have an admin run:

  UPDATE render_orders SET status='queued', claimed_by=NULL, claimed_at=NULL,
    lease_expires_at=NULL WHERE id='$order_id' AND status='blocked';

(raw server error, if any, was: $resp)
EOF
    exit 1
    ;;

  send-logs)
    # [M3-06a] redacted support bundle → POST /api/v1/computers/logs.
    sl_yes=0; sl_dry=0
    for a in "$@"; do
      case "$a" in
        --yes) sl_yes=1 ;;
        --dry) sl_dry=1 ;;
        *) echo "cfw-render-ctl: usage: send-logs [--yes] [--dry]" >&2; exit 2 ;;
      esac
    done
    cr_load_config || exit 1
    sl_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cfw-render-logs.XXXXXX")"
    sl_hdr=""
    # shellcheck disable=SC2064
    trap 'rm -rf "$sl_tmp"; [[ -n "$sl_hdr" ]] && rm -f "$sl_hdr"' EXIT
    mkdir -p "$sl_tmp/bundle"
    sl_redact() { python3 "$SELF_DIR/cfw-render-redact.py"; }
    while IFS= read -r -d '' f; do
      rel="${f#"$CFW_RENDER_LOG_DIR"/}"
      mkdir -p "$sl_tmp/bundle/logs/$(dirname "$rel")"
      sl_redact < "$f" > "$sl_tmp/bundle/logs/$rel"
    done < <(find "$CFW_RENDER_LOG_DIR" -maxdepth 2 \( -path "$CFW_RENDER_LOG_DIR/*.log" -o -path "$CFW_RENDER_LOG_DIR/runs/*" \) -type f -mmin -1440 -print0 2>/dev/null)
    [[ -f "$CFW_RENDER_STATE_DIR/status.json" ]] && sl_redact < "$CFW_RENDER_STATE_DIR/status.json" > "$sl_tmp/bundle/status.json"
    [[ -f "$CFW_RENDER_STATE_DIR/journal.tsv" ]] && tail -n 200 "$CFW_RENDER_STATE_DIR/journal.tsv" | sl_redact > "$sl_tmp/bundle/journal.tsv"
    sl_gz="$sl_tmp/cfw-render-logs.tar.gz"
    tar -czf "$sl_gz" -C "$sl_tmp" bundle || { echo "cfw-render-ctl: could not pack the logs" >&2; exit 1; }
    sl_size="$(wc -c < "$sl_gz" | tr -d ' ')"
    if (( sl_dry )); then
      sl_out="${TMPDIR:-/tmp}/cfw-render-logs-$(date +%Y%m%d%H%M%S)-$$.tar.gz"
      cp "$sl_gz" "$sl_out"
      echo "size: $sl_size"
      echo "path: $sl_out"
      exit 0
    fi
    echo "Log bundle: $sl_size bytes (secrets, emails and your user name removed)."
    if (( sl_size > 5242880 )); then
      echo "cfw-render-ctl: the log bundle is larger than 5 MB — CFW support can't take it." >&2
      exit 1
    fi
    if (( ! sl_yes )); then
      read -r -p "Send it to CFW support? [y/N] " sl_ans || sl_ans=""
      case "$sl_ans" in y|Y|yes|YES) ;; *) echo "Not sent."; exit 0 ;; esac
    fi
    sl_base="${CFW_RENDER_API_BASE:-${CFW_API_BASE:-https://app.cfw.social}}"
    sl_hdr="$(mktemp "${TMPDIR:-/tmp}/cfw-render-hdr.XXXXXX")"
    chmod 600 "$sl_hdr"
    printf 'cfw-render-key: %s\n' "$CFW_RENDER_WORKER_KEY" > "$sl_hdr"
    sl_resp="$(curl -sS --max-time 120 -w '\n%{http_code}' -X POST "${sl_base%/}/api/v1/computers/logs" \
      -H @"$sl_hdr" -H "content-type: application/gzip" --data-binary @"$sl_gz" 2>/dev/null)" || sl_resp=$'\n000'
    rm -f "$sl_hdr"; sl_hdr=""
    sl_code="${sl_resp##*$'\n'}"; sl_resp="${sl_resp%$'\n'*}"
    sl_ref="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read()).get("reference", ""))
except Exception:
    pass' <<< "$sl_resp")"
    if [[ "$sl_code" =~ ^2 && -n "$sl_ref" ]]; then
      echo "Reference: $sl_ref — quote it to CFW support."
      exit 0
    fi
    case "$sl_code" in
      000) echo "cfw-render-ctl: could not reach CFW — check your internet connection and try again." >&2 ;;
      401|403) echo "cfw-render-ctl: CFW did not accept this computer's key — set CFW Render up again." >&2 ;;
      413) echo "cfw-render-ctl: the log bundle is too large for CFW support." >&2 ;;
      *) echo "cfw-render-ctl: CFW could not take the logs (HTTP $sl_code) — try again in a minute." >&2 ;;
    esac
    exit 1
    ;;

  clear-limit)
    # [M3-08b] Drop an engine's usage/credit limit from engine-limits.json.
    [[ -n "${1:-}" ]] || { echo "cfw-render-ctl: usage: clear-limit <engine>" >&2; exit 2; }
    # No cr_load_config: works without a worker key (state dir defaults).
    # shellcheck disable=SC1091
    source "$SELF_DIR/cfw-render-engine.sh"
    cr_engine_limit_clear "$1"
    echo "cleared limit for $1"
    ;;

  *)
    echo "cfw-render-ctl: usage: {status|run-now|pause|resume|logs [n]|send-logs [--yes] [--dry]|unblock <orderId>|clear-limit <engine>}" >&2
    exit 2
    ;;
esac
