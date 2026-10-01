#!/usr/bin/env bash
# scripts/check-no-worker-heygen-credential.sh — static guard (CFW-313):
# fails loudly if bin/, lib/, or config/ ever combine a HeyGen credential
# reference with a worker-owned vault path ON THE SAME LINE — the exact bug
# this ticket fixes (HEYGEN_API_KEY sourced from
# ~/ecosystem/vault/secrets.env, one key shared across every brand the
# render fleet serves). The render worker must take HeyGen credentials ONLY
# from taskOrder.credentials.heygen — a brand-scoped OAuth credential
# cfw-social embeds into the order at claim time — never a worker-local key,
# whatever vault file it happens to live in.
#
# Scope: bin/, lib/, config/ only — NOT skills/. skills/ is a bundle
# source-synced from a different repo (scripts/sync-skills.sh), never
# hand-edited here; that content bug is tracked as a companion issue, same
# scope boundary CFW-312's portability gate drew (DOZER-DESIGN-CFW-313.md
# "Scope boundary").
#
# Runtime-free: bash + grep only.
#
# Usage: check-no-worker-heygen-credential.sh [--dir DIR]
#   --dir DIR   scan this single directory instead of the default three
#               (bin/, lib/, config/ under the repo root)
#
# Exit codes:
#   0 = clean — no offending line found
#   1 = FOUND — at least one offending file:line printed above the summary
#   2 = usage error
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

SCAN_DIRS=("$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/config")
while (( $# )); do
  case "$1" in
    --dir) SCAN_DIRS=("$2"); shift 2 ;;
    -*) echo "check-no-worker-heygen-credential.sh: unknown flag $1" >&2; exit 2 ;;
    *) echo "check-no-worker-heygen-credential.sh: unexpected arg $1" >&2; exit 2 ;;
  esac
done

EXISTING_DIRS=()
for d in "${SCAN_DIRS[@]}"; do
  [[ -d "$d" ]] && EXISTING_DIRS+=("$d")
done
if (( ${#EXISTING_DIRS[@]} == 0 )); then
  echo "check-no-worker-heygen-credential.sh: PASS — no scan dirs exist (${SCAN_DIRS[*]})"
  exit 0
fi

# Any line mentioning "heygen" (case-insensitive) AND a worker-owned vault
# path marker, on the SAME line — this is the exact shape of the bug: a line
# that reads/sets a HeyGen credential FROM a worker-local vault file.
OFFENSES="$(grep -rniE 'heygen' "${EXISTING_DIRS[@]}" 2>/dev/null \
  | grep -iE 'ecosystem/vault|\.gsai/secrets' || true)"

if [[ -n "$OFFENSES" ]]; then
  {
    echo "check-no-worker-heygen-credential.sh: FAIL — a worker-vault HeyGen credential reference found (CFW-313):"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "  $line"
    done <<< "$OFFENSES"
    echo ""
    echo "HeyGen credentials are brand-owned and arrive per-order in taskOrder.credentials.heygen"
    echo "(embedded by cfw-social at claim time) — never from a worker-local vault file. See"
    echo "config/cfw-render.env.example and README.md."
  } >&2
  exit 1
fi

echo "check-no-worker-heygen-credential.sh: PASS — no worker-vault HeyGen credential reference in ${EXISTING_DIRS[*]}"
exit 0
