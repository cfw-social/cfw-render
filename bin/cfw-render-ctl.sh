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
      launchctl print "gui/$(id -u)/$(cr_launchd_label)" 2>&1 | head -5 || echo "  $(cr_launchd_label) not loaded"
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
    # Background bash ignores SIGINT, and bash will not trap a signal that was
    # ignored when it started. WI2.105 starts this command that way and then
    # sends INT while the key file exists, so the INT trap never runs and the
    # file stays. Re-exec once with SIGINT restored to the default. Nothing
    # has been created yet, so the exec leaves no file behind.
    if [[ -z "${CFW_RENDER_CTL_SIGINT_RESET:-}" ]]; then
      export CFW_RENDER_CTL_SIGINT_RESET=1
      exec python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$0" "$VERB" "$@"
    fi
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
    sl_curl_pid=""
    sl_guard=""
    sl_body=""
    sl_done=""
    # Idempotent: a signal trap and the EXIT trap both call this. The key
    # file goes first so a kill cannot leave cfw-render-hdr.* in TMPDIR.
    _sl_drop_hdr() {
      if [[ -n "${sl_hdr:-}" ]]; then
        rm -f "$sl_hdr"
        sl_hdr=""
      fi
      if [[ -n "${sl_curl_pid:-}" ]]; then
        kill "$sl_curl_pid" 2>/dev/null || true
        sl_curl_pid=""
      fi
      if [[ -n "${sl_body:-}" ]]; then
        rm -f "$sl_body"
        sl_body=""
      fi
      if [[ -n "${sl_done:-}" ]]; then
        rm -f "$sl_done"
        sl_done=""
      fi
      if [[ -n "${sl_tmp:-}" ]]; then
        rm -rf "$sl_tmp"
        sl_tmp=""
      fi
    }
    trap '_sl_drop_hdr' EXIT
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
    # [WI27] A dev worker's logs and key go only to the CFW on this computer.
    if [[ "$(cr_profile 2>/dev/null)" == dev ]] && ! cr_dev_api_base_ok "$sl_base"; then
      echo "cfw-render-ctl: the dev profile only sends logs to CFW on this computer; refusing $sl_base" >&2
      exit 1
    fi
    # EXIT alone does not run when this shell is killed while a foreground
    # curl is still going (WI2.104). Same pattern as cr_curl_with_key: trap
    # TERM, INT and HUP, start curl in the background, and wait. The key file
    # is this shell's, so the trap removes it. --data-binary reads the bundle
    # file, not stdin (background curl has stdin /dev/null).
    trap '_sl_drop_hdr; exit 129' HUP
    trap '_sl_drop_hdr; exit 130' INT
    trap '_sl_drop_hdr; exit 143' TERM
    sl_hdr="$(mktemp "${TMPDIR:-/tmp}/cfw-render-hdr.XXXXXX")"
    chmod 600 "$sl_hdr"
    printf 'cfw-render-key: %s\n' "$CFW_RENDER_WORKER_KEY" > "$sl_hdr"
    # Bash re-raises SIGINT out of `wait` and skips this shell's INT trap, so
    # the key file can outlive the process (WI2.105). This helper is not that
    # wait: it ignores INT/TERM/HUP and deletes the file once this shell is gone.
    # $$ is this shell even inside the subshell; PPID there is not.
    sl_owner=$$
    (
      owner="$sl_owner"
      target="$sl_hdr"
      trap '' INT HUP TERM
      while kill -0 "$owner" 2>/dev/null; do
        sleep 0.1
      done
      rm -f "$target"
    ) &
    sl_guard=$!
    # The helper ignores INT/HUP/TERM and deletes the key file once this
    # shell is gone. Keep its pid so the assignment is used, and do not
    # signal it (a signal would not stop it).
    : "${sl_guard:-}"
    sl_body="$(mktemp "${TMPDIR:-/tmp}/cfw-render-body.XXXXXX")"
    set +m
    sl_done="$(mktemp "${TMPDIR:-/tmp}/cfw-render-curlrc.XXXXXX")"
    # The subshell waits on curl and records its status. This shell sleeps
    # instead of blocking in `wait`: SIGINT during `wait` skips the INT trap
    # and re-raises. A short sleep is an ordinary foreground command, so
    # INT/TERM/HUP run the trap when it returns. The helper above still
    # removes the key file if this shell dies without the trap. TERM on the
    # subshell (it is inside `wait`) kills curl.
    (
      cpid=""
      trap '[[ -n "${cpid:-}" ]] && kill "$cpid" 2>/dev/null; exit 143' TERM
      trap '[[ -n "${cpid:-}" ]] && kill "$cpid" 2>/dev/null; exit 130' INT
      curl -sS --max-time 120 -w '\n%{http_code}' -X POST "${sl_base%/}/api/v1/computers/logs" \
        -H "@$sl_hdr" -H "content-type: application/gzip" --data-binary @"$sl_gz" >"$sl_body" 2>/dev/null &
      cpid=$!
      wait "$cpid"
      echo $? > "$sl_done"
    ) &
    sl_curl_pid=$!
    if [[ -z "$sl_curl_pid" ]]; then
      sl_resp=$'\n000'
    else
      while [[ ! -s "$sl_done" ]]; do
        if ! kill -0 "$sl_curl_pid" 2>/dev/null; then
          break
        fi
        sleep 0.2
      done
      # Reap only a child that has already exited. A blocking `wait` is where
      # bash 5 re-raises SIGINT and skips the trap (WI2.105).
      sl_rc=1
      if ! kill -0 "$sl_curl_pid" 2>/dev/null; then
        wait "$sl_curl_pid" 2>/dev/null || sl_rc=$?
      fi
      if [[ -s "$sl_done" ]]; then
        sl_rc="$(tr -d '[:space:]' < "$sl_done")"
      fi
      sl_curl_pid=""
      if (( sl_rc == 0 )); then
        sl_resp="$(cat "$sl_body" 2>/dev/null)" || sl_resp=$'\n000'
      else
        sl_resp=$'\n000'
      fi
    fi
    rm -f "$sl_body"; sl_body=""
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
    # [WI27] Under the dev profile the default is the dev state folder, never
    # the installed worker's ~/.cfw-render.
    if [[ "$(cr_profile 2>/dev/null)" == dev ]]; then
      : "${CFW_RENDER_STATE_DIR:=$(cr_dev_state_dir_default)}"
      cr_dev_path_ok "$CFW_RENDER_STATE_DIR" || { echo "cfw-render-ctl: the dev profile never uses the production install folders" >&2; exit 1; }
      export CFW_RENDER_STATE_DIR
    fi
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
