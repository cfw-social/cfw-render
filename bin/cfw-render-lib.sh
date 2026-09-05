#!/usr/bin/env bash
# cfw-render-lib.sh — shared core for the cfw-render drainer + Director-facing
# helpers. Sourced, never executed directly. bash (not zsh) — must run
# unmodified on hst (Linux) and a macOS dev box. No jq (not guaranteed on the
# box); all JSON via python3 -c, same choice as ab-hustler.
#
# Design source: backlog/attachments/AB-RNDR-WORKER/implementation-plan.md §3.
# Skills bundling (CFW-HST-BUNDLE, VPS-simplification epic Phase 2):
# backlog/queue/CFW-HST-BUNDLE.md.
set -u

# ---------------------------------------------------------------------------
# Repo root, computed once at source time from this file's own location
# (bin/cfw-render-lib.sh -> repo root is one level up). This is also where
# install.sh copies things, so it resolves correctly both in a dev checkout
# and an installed $PREFIX tree (see install/install.sh).
# ---------------------------------------------------------------------------
_CR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CR_REPO_ROOT="$(cd "$_CR_LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# cr_default_skills_dir — the in-repo bundled skills/ (pinned via
# config/skills-version.json, source-synced by scripts/sync-skills.sh). This is
# cfw-render's ONLY skills source: the old /data/shared/cfw-skills/cfw shared-box
# path (a Hermes-assistant bundle, never cfw-render's) was dropped 2026-09-01 —
# cfw-render no longer shares skills with Hermes. This is ONLY the default;
# CFW_RENDER_SKILLS_DIR set via env/config file always wins (local-dev override).
# ---------------------------------------------------------------------------
cr_default_skills_dir() {
  printf '%s' "$_CR_REPO_ROOT/skills"
}

# ---------------------------------------------------------------------------
# cr_log_skills_version — best-effort, non-fatal. Logs the pinned skills bundle
# version (config/skills-version.json) so a run's journal/log makes it obvious
# which recipe closure served it. Missing manifest (e.g. CFW_RENDER_SKILLS_DIR
# overridden to the legacy path, or a pre-bundle checkout) is a WARN, not a
# failure — the worker still runs against whatever CFW_RENDER_SKILLS_DIR points
# at.
# ---------------------------------------------------------------------------
cr_log_skills_version() {
  local manifest="$_CR_REPO_ROOT/config/skills-version.json"
  if [[ ! -r "$manifest" ]]; then
    cr_log "skills version manifest not found at $manifest (ok if CFW_RENDER_SKILLS_DIR points at a non-bundled dir) — dir in use: $CFW_RENDER_SKILLS_DIR"
    return 0
  fi
  local summary
  summary="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("unreadable (%s)" % e)
    sys.exit(0)
print("sourceCommit=%s recipeCount=%s bundledAt=%s" % (
    d.get("sourceCommit", "?"), d.get("recipeCount", "?"), d.get("bundledAt", "?")))
' "$manifest" 2>/dev/null)"
  cr_log "skills bundle: ${summary:-unreadable} — dir in use: $CFW_RENDER_SKILLS_DIR"
}

# ---------------------------------------------------------------------------
# cr_skills_pin_summary — one-line "<sourceSha-short> · N recipes" for the
# --dry `skills:pinned` row (doc §5 last para). Reads config/skills-version.json.
# Prints "unpinned" if the manifest is absent/unreadable. Never fails.
# ---------------------------------------------------------------------------
cr_skills_pin_summary() {
  local manifest="$_CR_REPO_ROOT/config/skills-version.json"
  [[ -r "$manifest" ]] || { printf 'unpinned (no manifest)'; return 0; }
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unpinned (unreadable manifest)"); sys.exit(0)
sha = (d.get("sourceSha") or "")[:12] or "?"
n = d.get("recipeCount", len(d.get("recipes", {})))
print("sourceSha=%s recipes=%s" % (sha, n))
' "$manifest" 2>/dev/null || printf 'unpinned (manifest read error)'
}

# ---------------------------------------------------------------------------
# cr_verify_skills_bundle <recipe>
# Per-tick integrity gate (doc §5). Verifies ONLY the recipe(s) the claimed
# order references (not the whole tree) against the per-file sha256 hashes in
# $CFW_RENDER_SKILLS_DIR/index.json, via scripts/verify-skills-bundle.sh
# (single source of truth for the checksum logic; installed to $PREFIX/scripts).
#
# Return contract (kept simple for the caller):
#   0  → verified, OR unverifiable-and-safe-to-proceed (no index.json, or the
#        recipe isn't pinned in this bundle). Both are LOGGED; neither is a
#        block, because doing no verification is exactly today's behavior and
#        over-blocking on missing-manifest would be strictly worse. This also
#        keeps a non-bundle CFW_RENDER_SKILLS_DIR (legacy path / local dev
#        override / bare test fixture) working.
#   1  → genuine checksum MISMATCH (a pinned file differs on disk) — the
#        "pull landed mid-tick / corrupted bundle" case. Caller MUST NOT spawn
#        the Director; it blocks the order with an owner-safe reason.
# cfw-render has exactly one skills source: the in-repo bundle (skills/).
# ---------------------------------------------------------------------------
cr_verify_skills_bundle() {
  local recipe="${1:-}"
  if [[ -z "$recipe" ]]; then
    cr_log "skills verify: no recipe on the order — skipping per-recipe checksum verification (Director resolves recipe from order.json)"
    return 0
  fi
  local script="$_CR_REPO_ROOT/scripts/verify-skills-bundle.sh"
  if [[ ! -x "$script" && ! -r "$script" ]]; then
    cr_log "skills verify: verify-skills-bundle.sh not found at $script — skipping (proceeding, integrity unchecked for $recipe)"
    return 0
  fi
  local out rc
  out="$(CFW_RENDER_SKILLS_DIR="$CFW_RENDER_SKILLS_DIR" bash "$script" "$recipe" 2>&1)"
  rc=$?
  case "$rc" in
    0)
      cr_log "skills verify: $recipe OK — bundle matches index.json"
      return 0
      ;;
    3)
      cr_log "skills verify: no index.json in $CFW_RENDER_SKILLS_DIR — cannot verify $recipe (not a published bundle); proceeding (integrity unchecked)"
      return 0
      ;;
    4)
      cr_log "skills verify: recipe $recipe not pinned in $CFW_RENDER_SKILLS_DIR/index.json — cannot verify (worker may need a redeploy); proceeding (integrity unchecked)"
      return 0
      ;;
    *)
      # rc==1 (mismatch) or any unexpected non-zero — treat as corruption.
      cr_log "skills verify: MISMATCH for $recipe — bundle does not match index.json. Detail: $(printf '%s' "$out" | tr '\n' '|')"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cr_load_config — env cascade: /etc/cfw-render.env (Linux box) → $CFW_RENDER_ENV
# (default ~/.gsai/secrets/cfw-render.env) → process env wins over both files
# (a file only fills vars that are still unset). Fails fast on missing
# required vars; never prints values.
# ---------------------------------------------------------------------------
cr_load_config() {
  # Capture every knob already set by the real process env BEFORE sourcing
  # any file, so process env always wins per the cascade — a sourced file's
  # plain `VAR=value` line would otherwise unconditionally clobber a value
  # the caller/test harness exported, regardless of "required" status.
  local _cr_vars=(
    CFW_API_BASE CFW_RENDER_WORKER_KEY CFW_RENDER_CONCURRENCY CFW_RENDER_SCRATCH
    CFW_RENDER_STATE_DIR CFW_RENDER_SKILLS_DIR CFW_RENDER_DIRECTOR_MODEL
    CFW_RENDER_FANOUT_MODELS CFW_RENDER_TIMEOUT_VIDEO CFW_RENDER_TIMEOUT_IMAGE
    CFW_RENDER_GATE_FAIL_CAP CFW_RENDER_OLLAMA_KEYS_FILE CFW_RENDER_DIRECTOR_CMD
    CFW_RENDER_MODE CFW_RENDER_WORKER_ID_FILE
  )
  local _cr_preset=() _v
  for _v in "${_cr_vars[@]}"; do
    _cr_preset+=("${!_v:-}")
  done

  if [[ -r /etc/cfw-render.env ]]; then
    # shellcheck disable=SC1091
    source /etc/cfw-render.env
  fi

  local env_file="${CFW_RENDER_ENV:-$HOME/.gsai/secrets/cfw-render.env}"
  if [[ -r "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi

  # Process env wins over both files: restore any var that was already set
  # before sourcing.
  local _i=0
  for _v in "${_cr_vars[@]}"; do
    [[ -n "${_cr_preset[$_i]}" ]] && printf -v "$_v" '%s' "${_cr_preset[$_i]}"
    _i=$(( _i + 1 ))
  done

  : "${CFW_RENDER_CONCURRENCY:=1}"
  : "${CFW_RENDER_SCRATCH:=$HOME/cfw-render-scratch}"
  : "${CFW_RENDER_STATE_DIR:=$HOME/.cfw-render}"
  : "${CFW_RENDER_SKILLS_DIR:=$(cr_default_skills_dir)}"
  : "${CFW_RENDER_DIRECTOR_MODEL:=sonnet}"
  : "${CFW_RENDER_FANOUT_MODELS:=glm-5.2,kimi-k2}"
  : "${CFW_RENDER_TIMEOUT_VIDEO:=3600}"
  : "${CFW_RENDER_TIMEOUT_IMAGE:=900}"
  : "${CFW_RENDER_GATE_FAIL_CAP:=2}"
  : "${CFW_RENDER_OLLAMA_KEYS_FILE:=$HOME/.gsai/secrets/ollama-keys.env}"
  : "${CFW_RENDER_DIRECTOR_CMD:=}"
  # Deploy mode (doc §4) — operational only, NEVER the security boundary (the
  # server enforces that via which credential family resolves). Set once at
  # install time; default matches our fleet. Skills always come from the in-repo
  # bundle (there is no longer a bundle-vs-fetch switch — cfw-render carries its
  # own skills/, git-pull to update; BYOA and server use the same source).
  : "${CFW_RENDER_MODE:=server}"
  : "${CFW_RENDER_WORKER_ID_FILE:=$CFW_RENDER_STATE_DIR/worker-id}"
  export CFW_RENDER_CONCURRENCY CFW_RENDER_SCRATCH CFW_RENDER_STATE_DIR \
    CFW_RENDER_SKILLS_DIR CFW_RENDER_DIRECTOR_MODEL CFW_RENDER_FANOUT_MODELS \
    CFW_RENDER_TIMEOUT_VIDEO CFW_RENDER_TIMEOUT_IMAGE CFW_RENDER_GATE_FAIL_CAP \
    CFW_RENDER_OLLAMA_KEYS_FILE CFW_RENDER_DIRECTOR_CMD \
    CFW_RENDER_MODE CFW_RENDER_WORKER_ID_FILE

  local missing=()
  [[ -z "${CFW_API_BASE:-}" ]] && missing+=("CFW_API_BASE")
  [[ -z "${CFW_RENDER_WORKER_KEY:-}" ]] && missing+=("CFW_RENDER_WORKER_KEY")
  if (( ${#missing[@]} > 0 )); then
    printf 'cfw-render: missing required config var(s): %s (checked /etc/cfw-render.env, %s, process env)\n' \
      "${missing[*]}" "$env_file" >&2
    return 1
  fi
  if [[ "$CFW_RENDER_WORKER_KEY" != cfw_render_* ]]; then
    printf 'cfw-render: CFW_RENDER_WORKER_KEY does not match expected shape ^cfw_render_ — refusing to run\n' >&2
    return 1
  fi
  mkdir -p "$CFW_RENDER_STATE_DIR" "$CFW_RENDER_SCRATCH" 2>/dev/null

  cr_log_skills_version

  # workerId — STABLE per install, NOT per process (doc §6.3). The systemd
  # oneshot fires a fresh PID every 15-min tick, so the old `hostname:$$`
  # changed every tick and would defeat CFW-V2-068's per-workerId circuit
  # breaker (consecutiveFailures never accumulates against a moving id).
  # Order of precedence:
  #   1. an explicitly exported CFW_WORKER_ID (tests / special ops) wins;
  #   2. else the persisted install-identity file (seeded once by install.sh,
  #      lazily seeded here too so a hand-run/dev worker is also stable);
  #   3. hostname:$$ survives only as free-text forensic context in log/event
  #      MESSAGES — never as the claim identity.
  if [[ -z "${CFW_WORKER_ID:-}" ]]; then
    local _wid_file="${CFW_RENDER_WORKER_ID_FILE:-$CFW_RENDER_STATE_DIR/worker-id}"
    if [[ ! -s "$_wid_file" ]]; then
      cr_seed_worker_id "$_wid_file"
    fi
    CFW_WORKER_ID="$(tr -d '[:space:]' < "$_wid_file" 2>/dev/null)"
    # Last-ditch fallback if the file is unreadable/empty (never block a tick
    # on this) — a per-process id is worse for the breaker but better than no
    # claim identity at all; log it loudly.
    if [[ -z "$CFW_WORKER_ID" ]]; then
      CFW_WORKER_ID="$(hostname -s 2>/dev/null || hostname):$$"
      cr_log "WARN: worker-id file $_wid_file empty/unreadable — falling back to unstable $CFW_WORKER_ID (circuit breaker will not accumulate; check install)"
    fi
  fi
  export CFW_WORKER_ID
  return 0
}

# ---------------------------------------------------------------------------
# cr_seed_worker_id <file> — write a stable install identity once. uuidgen if
# present, else the kernel uuid source, else python3 uuid4, else a
# hostname+random fallback. Idempotent by the caller's `-s` guard; safe to call
# from install.sh and lazily from cr_load_config.
# ---------------------------------------------------------------------------
cr_seed_worker_id() {
  local file="$1" id=""
  mkdir -p "$(dirname "$file")" 2>/dev/null
  if command -v uuidgen >/dev/null 2>&1; then
    id="$(uuidgen 2>/dev/null)"
  fi
  if [[ -z "$id" && -r /proc/sys/kernel/random/uuid ]]; then
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  fi
  if [[ -z "$id" ]] && command -v python3 >/dev/null 2>&1; then
    id="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)"
  fi
  if [[ -z "$id" ]]; then
    id="$(hostname -s 2>/dev/null || hostname)-$$-${RANDOM}${RANDOM}"
  fi
  printf '%s\n' "$id" > "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# cr_log <msg> — timestamped append to $CFW_RENDER_STATE_DIR/cfw-render.log
# (mirrors ab-lib.sh:63).
# ---------------------------------------------------------------------------
cr_log() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  mkdir -p "$dir" 2>/dev/null
  printf '%s [cfw-render] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$dir/cfw-render.log"
}

# ---------------------------------------------------------------------------
# cr_mcp_call <tool> <json-args>
# Single curl JSON-RPC wrapper against $CFW_API_BASE/api/v1/mcp (pattern:
# cfw-social/docs/mcp-brand-context-smoke.md "Manual curl reference"), headers
# cfw-render-key + accept json/SSE, --max-time 30, 2 retries with backoff on
# curl-level failure. Prints the unwrapped inner JSON (result.content[0].text)
# on stdout; non-zero exit on curl failure / JSON-RPC error / isError.
# ---------------------------------------------------------------------------
cr_mcp_call() {
  local tool="$1" args_json="$2"
  local url="${CFW_API_BASE%/}/api/v1/mcp"
  local body
  body="$(python3 -c '
import json, sys
tool = sys.argv[1]
args = json.loads(sys.argv[2]) if sys.argv[2] else {}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}))
' "$tool" "$args_json" 2>/dev/null)" || { printf 'cfw-render: cr_mcp_call could not build request JSON for %s\n' "$tool" >&2; return 1; }

  local attempt resp rc
  for attempt in 1 2 3; do
    resp="$(curl -sS --max-time 30 -X POST "$url" \
      -H "cfw-render-key: $CFW_RENDER_WORKER_KEY" \
      -H "content-type: application/json" \
      -H "accept: application/json, text/event-stream" \
      -d "$body" 2>/dev/null)"
    rc=$?
    if (( rc == 0 )) && [[ -n "$resp" ]]; then
      break
    fi
    (( attempt < 3 )) && sleep $(( attempt * 2 ))
  done
  if (( rc != 0 )) || [[ -z "${resp:-}" ]]; then
    printf 'cfw-render: cr_mcp_call %s — curl failed after retries (rc=%s)\n' "$tool" "$rc" >&2
    return 1
  fi

  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    env = json.loads(raw)
except Exception as e:
    print(f"cfw-render: cr_mcp_call — non-JSON response: {e}", file=sys.stderr)
    sys.exit(1)
if "error" in env:
    err = env["error"]
    print(f"cfw-render: cr_mcp_call — JSON-RPC error: {err}", file=sys.stderr)
    sys.exit(1)
result = env.get("result", {})
if result.get("isError"):
    print(f"cfw-render: cr_mcp_call — tool error: {result}", file=sys.stderr)
    sys.exit(1)
content = result.get("content", [])
if not content or "text" not in content[0]:
    print(f"cfw-render: cr_mcp_call — unexpected result shape: {result}", file=sys.stderr)
    sys.exit(1)
# The inner text is itself JSON — validate then print verbatim.
inner = content[0]["text"]
json.loads(inner)
sys.stdout.write(inner)
' <<< "$resp"
}

# ---------------------------------------------------------------------------
# cr_load_admin_config — config loader for the OPERATOR fleet-enable surface
# (cfw-render-fleet.sh, CFW-16). Distinct from cr_load_config on purpose:
#   * requires CFW_API_BASE + CFW_MASTER_API_KEY (the master key), NOT the
#     narrow cfw_render_ worker key — flipping renderFleetEnabled is a
#     privileged operator action the worker credential must NOT be able to do.
#   * reads ONLY $CFW_RENDER_ADMIN_ENV (default ~/.gsai/secrets/cfw-render-admin
#     .env) and the process env — DELIBERATELY never /etc/cfw-render.env. The
#     master key must never live on a render box: the box is stateless and
#     minimally-scoped by design (the whole point of CFW-16). This helper is an
#     operator tool, run from an operator machine.
# Process env wins over the file (same precedence rule as cr_load_config).
# ---------------------------------------------------------------------------
cr_load_admin_config() {
  local _cr_vars=(CFW_API_BASE CFW_MASTER_API_KEY CFW_RENDER_ADMIN_ENV)
  local _cr_preset=() _v
  for _v in "${_cr_vars[@]}"; do _cr_preset+=("${!_v:-}"); done

  local admin_env="${CFW_RENDER_ADMIN_ENV:-$HOME/.gsai/secrets/cfw-render-admin.env}"
  if [[ -r "$admin_env" ]]; then
    # shellcheck disable=SC1090
    source "$admin_env"
  fi

  local _i=0
  for _v in "${_cr_vars[@]}"; do
    [[ -n "${_cr_preset[$_i]}" ]] && printf -v "$_v" '%s' "${_cr_preset[$_i]}"
    _i=$(( _i + 1 ))
  done
  export CFW_API_BASE CFW_MASTER_API_KEY

  local missing=()
  [[ -z "${CFW_API_BASE:-}" ]] && missing+=("CFW_API_BASE")
  [[ -z "${CFW_MASTER_API_KEY:-}" ]] && missing+=("CFW_MASTER_API_KEY")
  if (( ${#missing[@]} > 0 )); then
    printf 'cfw-render-fleet: missing required config var(s): %s (checked %s, process env). The master key is operator-only — never put it on a render box.\n' \
      "${missing[*]}" "$admin_env" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# cr_admin_call <method> <path> [json-body]
# Single curl wrapper against the cfw-social MASTER-key admin surface
# ($CFW_API_BASE$path, header cfw-api-key: $CFW_MASTER_API_KEY — the same auth
# assertMasterOrAdmin() checks in cfw-social). Prints the raw response body on
# stdout (even on an HTTP error, so the caller can inspect it); the HTTP status
# goes to stderr. Returns 0 only on a 2xx, non-zero on curl failure or any
# non-2xx. Assumes cr_load_admin_config already ran.
# ---------------------------------------------------------------------------
cr_admin_call() {
  local method="$1" path="$2" body="${3:-}"
  local url="${CFW_API_BASE%/}$path"
  local curl_args=(-sS --max-time 30 -X "$method" "$url"
    -H "cfw-api-key: $CFW_MASTER_API_KEY"
    -H "content-type: application/json"
    -w $'\n%{http_code}')
  [[ -n "$body" ]] && curl_args+=(-d "$body")

  local raw rc
  raw="$(curl "${curl_args[@]}" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    printf 'cfw-render-fleet: admin call %s %s — curl failed (rc=%s)\n' "$method" "$path" "$rc" >&2
    return 1
  fi
  # Last line = HTTP status (from -w); everything before = body.
  local status="${raw##*$'\n'}"
  local out="${raw%$'\n'*}"
  printf '%s' "$out"
  if [[ "$status" == 2* ]]; then
    return 0
  fi
  printf 'cfw-render-fleet: admin call %s %s -> HTTP %s\n' "$method" "$path" "$status" >&2
  return 1
}

# ---------------------------------------------------------------------------
# cr_event <orderId> <kind> <stage> <message> <pct> [model]
# Thin append_render_event wrapper. Best-effort — NEVER fails the caller;
# logs on error. stage/model may be empty strings (omitted from the call).
# ---------------------------------------------------------------------------
cr_event() {
  local order_id="$1" kind="$2" stage="$3" message="$4" pct="$5" model="${6:-}"
  local args
  args="$(python3 -c '
import json, sys
order_id, worker_id, kind, stage, message, pct, model = sys.argv[1:8]
d = {"orderId": order_id, "workerId": worker_id, "kind": kind, "message": message}
if stage:
    d["stage"] = stage
if pct != "":
    d["pct"] = int(pct)
if model:
    d["model"] = model
print(json.dumps(d))
' "$order_id" "$CFW_WORKER_ID" "$kind" "$stage" "$message" "$pct" "$model" 2>/dev/null)" || return 0
  cr_mcp_call append_render_event "$args" >/dev/null 2>>"$CFW_RENDER_STATE_DIR/cfw-render.log" || \
    cr_log "cr_event: append_render_event failed (best-effort, ignored) — order=$order_id kind=$kind stage=$stage"
  return 0
}

# ---------------------------------------------------------------------------
# claude_ollama_failover <label> <model> <outfile> -- <claude args...>
# BASH PORT of ~/ecosystem/ab-hustler/ab-lib.sh:76-105 (claude_ollama_failover).
# Same account order goofy_hugle -> recursing_pike, same rate-limit regex,
# same "non-quota failure does not burn the 2nd account" rule. Ported from
# zsh (`emulate -L zsh` / `typeset -ga`) to portable bash per plan §0.5 —
# hst has no guaranteed zsh.
# ---------------------------------------------------------------------------
claude_ollama_failover() {
  local label="$1" model="$2" out="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local keysfile="${CFW_RENDER_OLLAMA_KEYS_FILE:-$HOME/.gsai/secrets/ollama-keys.env}"
  # shellcheck source=/dev/null
  [[ -f "$keysfile" ]] && source "$keysfile"
  local accts=(
    "goofy_hugle:${OLLAMA_KEY_GOOFY_HUGLE_463_B:-}"
    "recursing_pike:${OLLAMA_KEY_RECURSING_PIKE_357:-}"
  )
  local rc=1 e nm key
  for e in "${accts[@]}"; do
    nm="${e%%:*}"; key="${e#*:}"
    [[ -z "$key" ]] && continue
    ANTHROPIC_BASE_URL="https://ollama.com" ANTHROPIC_AUTH_TOKEN="$key" \
      ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
      claude "$@" < /dev/null >> "$out" 2>&1
    rc=$?
    if (( rc == 0 )); then
      cr_log "  served by ollama:$nm ($model) — $label"
      return 0
    fi
    if grep -qiE 'rate.?limit|429|too many requests|quota|over capacity|exceeded|insufficient' "$out"; then
      cr_log "  ollama:$nm rate-limited on $label — failing over to next account"
      continue
    fi
    cr_log "  ollama:$nm failed on $label (exit $rc, not rate-limit) — caller's error path takes over"
    return $rc
  done
  cr_log "  all ollama accounts exhausted for $label (last exit $rc)"
  return $rc
}

# ---------------------------------------------------------------------------
# claude_native_or_ollama_quota_fallback <label> <native_model> <outfile> \
#   <state_file> -- <claude args...>
# BASH PORT of ab-lib.sh:109-140. Runs native Claude first (Sonnet, Claude
# subscription OAuth); on a quota/rate-limit-shaped failure, retries via
# claude_ollama_failover with glm-5.2. Additionally (plan §3): writes which
# model actually served ("sonnet" or "glm-5.2") to <state_file> so the
# Director-model rollup in cfw-render-report.sh is truthful.
# ---------------------------------------------------------------------------
claude_native_or_ollama_quota_fallback() {
  local label="$1" native_model="$2" out="$3" state_file="$4"; shift 4
  [[ "${1:-}" == "--" ]] && shift
  local native_model_flag=()
  [[ -n "$native_model" ]] && native_model_flag=(--model "$native_model")

  claude "${native_model_flag[@]}" "$@" < /dev/null >> "$out" 2>&1
  local rc=$?
  if (( rc == 0 )); then
    printf '%s\n' "${native_model:-sonnet}" > "$state_file" 2>/dev/null
    return 0
  fi

  if grep -qiE 'rate.?limit|429|too many requests|quota|over capacity|exceeded|insufficient|weekly limit' "$out" 2>/dev/null; then
    cr_log "  native Claude quota/rate-limited on $label — retrying with GLM-5.2 via Ollama"
    local fallback_args=() skip_next=0 arg
    for arg in "$@"; do
      if (( skip_next )); then skip_next=0; continue; fi
      if [[ "$arg" == "--effort" ]]; then skip_next=1; continue; fi
      fallback_args+=("$arg")
    done
    claude_ollama_failover "$label" "glm-5.2" "$out" -- "${fallback_args[@]}"
    rc=$?
    (( rc == 0 )) && printf 'glm-5.2\n' > "$state_file" 2>/dev/null
    return $rc
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# cr_tick_lock_acquire / cr_tick_lock_release
# mkdir-based tick lock with stale-age self-heal (ab-hustler batch-lock
# semantics, no sqlite — plan §0.3: order-level mutex is already the server's
# claim CAS; this only prevents two overlapping drainer ticks on one host).
# Stale threshold: CFW_RENDER_TIMEOUT_VIDEO (default 3600) + 600s, OR the recorded pid is dead.
# ---------------------------------------------------------------------------
cr_tick_lock_acquire() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  local lock="$dir/tick.lock"
  mkdir -p "$dir" 2>/dev/null
  if mkdir "$lock" 2>/dev/null; then
    printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock/info" 2>/dev/null
    return 0
  fi
  # Lock exists — check staleness.
  local info="$lock/info" pid ts now stale_after
  pid="$(grep '^pid=' "$info" 2>/dev/null | cut -d= -f2)"
  ts="$(grep '^ts=' "$info" 2>/dev/null | cut -d= -f2)"
  now="$(date +%s)"
  stale_after=$(( ${CFW_RENDER_TIMEOUT_VIDEO:-3600} + 600 ))
  local is_stale=0
  if [[ -z "$pid" || -z "$ts" ]]; then
    is_stale=1
  elif ! kill -0 "$pid" 2>/dev/null; then
    is_stale=1
  elif (( now - ts > stale_after )); then
    is_stale=1
  fi
  if (( is_stale )); then
    cr_log "tick lock stale (pid=$pid ts=$ts) — self-healing, retaking"
    rm -rf "$lock" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then
      printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock/info" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

cr_tick_lock_release() {
  local dir="${CFW_RENDER_STATE_DIR:-$HOME/.cfw-render}"
  rm -rf "$dir/tick.lock" 2>/dev/null
  return 0
}
