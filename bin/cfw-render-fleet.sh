#!/usr/bin/env bash
# cfw-render-fleet.sh — OPERATOR fleet-enable admin surface (CFW-16 / CFW-V2-073).
#
# Per-brand, reversible set/read of Brand.renderFleetEnabled via the cfw-social
# MASTER-key admin route. This is the proper, auditable replacement for the raw
# `UPDATE brands SET render_fleet_enabled=...` flip documented in
# docs/deploy.md §6 — the "genuine gap" the Dev-Director named on CFW-16:
# there was no master-key helper to opt a brand in/out of the render fleet and
# read current fleet state.
#
# SECURITY — READ THIS:
#   * Uses the MASTER API key (header `cfw-api-key`), NOT the narrow
#     `cfw_render_` worker key. Flipping renderFleetEnabled is a privileged
#     operator action; the worker credential must never be able to do it.
#   * Run from an OPERATOR machine. NEVER install the master key on a render
#     box — the box is stateless and minimally-scoped by design (the point of
#     CFW-16). The key is read from $CFW_RENDER_ADMIN_ENV (default
#     ~/.gsai/secrets/cfw-render-admin.env) or the process env — deliberately
#     NOT from /etc/cfw-render.env (the box file). See cr_load_admin_config.
#   * The flip is an operator decision — this NEVER bulk-flips. You name each
#     brand id explicitly, and the live rollout stays brand-by-brand + gated.
#
# Usage:
#   cfw-render-fleet.sh status  <brandId> [<brandId>...]   # read current state
#   cfw-render-fleet.sh enable  <brandId> [<brandId>...]   # opt brand(s) IN
#   cfw-render-fleet.sh disable <brandId> [<brandId>...]   # opt brand(s) OUT
#
# Exit: 0 iff every named brand's operation (and read-back) succeeded.
#
# Server-side contract (cfw-social):
#   PATCH /api/v1/admin/brands/:id  {"renderFleetEnabled": <bool>}
#     -> {"ok":true,"id":...,"renderFleetEnabled":<bool>}
#   GET   /api/v1/admin/brands/:id
#     -> {"id":...,"renderFleetEnabled":<bool>}
#   Both are master-key guarded (assertMasterOrAdmin). See the "SERVER-SIDE
#   FOLLOW-UP" note in docs/deploy.md §6 — if this helper reports the route is
#   not deployed, that cfw-social change must land before the live flip.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

usage() {
  echo "cfw-render-fleet: usage: {status|enable|disable} <brandId> [<brandId>...]" >&2
  exit 2
}

# _fleet_read_bool <json> — extract renderFleetEnabled from a response body.
# Prints "true"/"false", or empty string if the key is absent.
_fleet_read_bool() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
v = d.get("renderFleetEnabled")
if isinstance(v, bool):
    print("true" if v else "false")
' <<< "$1"
}

# _fleet_diagnose <response-body> — print a truthful, actionable note to stderr
# for a failed admin call, disambiguating the failure mode from the body so we
# never cry "server gap" on a plain auth error or a genuinely-missing brand.
_fleet_diagnose() {
  local body="$1"
  case "$body" in
    *"master API key"*|*"Invalid master"*)
      echo "cfw-render-fleet: the master key was rejected — check CFW_MASTER_API_KEY (this is the cfw-social master key, not the cfw_render_ worker key)." >&2
      return ;;
    *not_found*)
      echo "cfw-render-fleet: no such brand — that brand id does not exist on the server." >&2
      return ;;
  esac
  # Anything else (422 "Expected { isShowcase }", 404 HTML route-missing, 405):
  # the master-key fleet route contract is not deployed. This is the CFW-16
  # SERVER-SIDE FOLLOW-UP; no silent success.
  cat >&2 <<EOF

cfw-render-fleet: the cfw-social master-key fleet route did not accept this call.
This is the SERVER-SIDE FOLLOW-UP for CFW-16: extend the admin brands route to
carry renderFleetEnabled (it currently curates only isShowcase):

  cfw-social  src/app/api/v1/admin/brands/[id]/route.ts
    - add \`renderFleetEnabled: z.boolean().optional()\` to PatchSchema and
      write it through prisma.brand.update
    - add a GET handler returning { id, renderFleetEnabled } behind the same
      assertMasterOrAdmin() gate

Until that lands, an operator can still flip a single brand by hand (break-glass):
  UPDATE brands SET render_fleet_enabled = true  WHERE id = '<brandId>';   -- enable
  UPDATE brands SET render_fleet_enabled = false WHERE id = '<brandId>';   -- disable
EOF
}

# _fleet_set <brandId> <true|false>
_fleet_set() {
  local brand="$1" want="$2" body resp rc
  body="$(python3 -c 'import json,sys; print(json.dumps({"renderFleetEnabled": sys.argv[1]=="true"}))' "$want")"
  resp="$(cr_admin_call PATCH "/api/v1/admin/brands/$brand" "$body")"; rc=$?
  if (( rc != 0 )); then
    printf '%s\tERROR (set failed)\n' "$brand"
    _fleet_diagnose "$resp"
    return 1
  fi
  # Read back to confirm the flip actually took.
  local got_resp got
  got_resp="$(cr_admin_call GET "/api/v1/admin/brands/$brand")"; rc=$?
  if (( rc != 0 )); then
    printf '%s\tERROR (read-back failed)\n' "$brand"
    _fleet_diagnose "$got_resp"
    return 1
  fi
  got="$(_fleet_read_bool "$got_resp")"
  if [[ "$got" != "$want" ]]; then
    printf '%s\tERROR (read-back mismatch: wanted %s, got %s)\n' "$brand" "$want" "${got:-<absent>}"
    return 1
  fi
  printf '%s\trenderFleetEnabled=%s\n' "$brand" "$got"
  return 0
}

# _fleet_status <brandId>
_fleet_status() {
  local brand="$1" resp rc got
  resp="$(cr_admin_call GET "/api/v1/admin/brands/$brand")"; rc=$?
  if (( rc != 0 )); then
    printf '%s\tERROR (read failed)\n' "$brand"
    _fleet_diagnose "$resp"
    return 1
  fi
  got="$(_fleet_read_bool "$resp")"
  if [[ -z "$got" ]]; then
    printf '%s\tERROR (renderFleetEnabled absent from response)\n' "$brand"
    return 1
  fi
  printf '%s\trenderFleetEnabled=%s\n' "$brand" "$got"
  return 0
}

VERB="${1:-}"; shift || true
[[ -z "$VERB" ]] && usage
(( $# >= 1 )) || usage

cr_load_admin_config || exit 1

rc=0
case "$VERB" in
  status)
    for b in "$@"; do _fleet_status "$b" || rc=1; done
    ;;
  enable)
    for b in "$@"; do _fleet_set "$b" true  || rc=1; done
    ;;
  disable)
    for b in "$@"; do _fleet_set "$b" false || rc=1; done
    ;;
  *)
    usage
    ;;
esac
exit "$rc"
