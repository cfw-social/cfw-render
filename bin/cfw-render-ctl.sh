#!/usr/bin/env bash
# cfw-render-ctl.sh — operator control surface. Mirrors ab-hustler-ctl.sh verb
# style. All read paths are LOCAL (state dir + journal) — the narrow worker
# key has no read tool by design (plan §7).
#
# Usage:
#   cfw-render-ctl.sh status
#   cfw-render-ctl.sh run-now
#   cfw-render-ctl.sh logs [n]
#   cfw-render-ctl.sh unblock <orderId>
#   cfw-render-ctl.sh fleet {status|enable|disable} <brandId>...
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
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl status cfw-render.timer 2>&1 | head -5 || echo "  cfw-render.timer not found"
    else
      echo "  no launchctl/systemctl on this host"
    fi

    echo ""
    "$SELF_DIR/cfw-render.sh" --dry
    ;;

  run-now)
    "$SELF_DIR/cfw-render.sh" --once
    ;;

  logs)
    n="${1:-50}"
    cr_load_config || exit 1
    echo "== $CFW_RENDER_STATE_DIR/cfw-render.log (last $n) =="
    tail -n "$n" "$CFW_RENDER_STATE_DIR/cfw-render.log" 2>/dev/null || echo "(no log yet)"
    echo ""
    newest="$(ls -t "$CFW_RENDER_STATE_DIR"/runs/*.out 2>/dev/null | head -1)"
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

  fleet)
    # Operator fleet-enable surface (CFW-16). Delegates to cfw-render-fleet.sh,
    # which uses the MASTER key (operator-only) — NOT the worker key this ctl's
    # other verbs use. Runs from an operator machine, never the box.
    exec "$SELF_DIR/cfw-render-fleet.sh" "$@"
    ;;

  *)
    echo "cfw-render-ctl: usage: {status|run-now|logs [n]|unblock <orderId>|fleet {status|enable|disable} <brandId>...}" >&2
    exit 2
    ;;
esac
