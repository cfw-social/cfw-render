#!/usr/bin/env bash
# scripts/lint.sh — bash -n every script + shellcheck when available (skip
# with a notice otherwise). No new JS toolchain (AC "pnpm/bash lint clean").
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

shopt -s nullglob
SCRIPTS=("$REPO_DIR"/bin/*.sh "$REPO_DIR"/install/*.sh "$REPO_DIR"/test/*.sh "$REPO_DIR"/scripts/*.sh)

echo "== bash -n =="
for f in "${SCRIPTS[@]}"; do
  if bash -n "$f"; then
    echo "  ok    $f"
  else
    echo "  FAIL  $f"
    FAILED=1
  fi
done

echo ""
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck -S warning =="
  for f in "${SCRIPTS[@]}"; do
    if shellcheck -S warning "$f"; then
      echo "  ok    $f"
    else
      echo "  FAIL  $f"
      FAILED=1
    fi
  done
else
  echo "== shellcheck not installed — skipping (dev-only nicety, not a hard requirement) =="
fi

exit $FAILED
