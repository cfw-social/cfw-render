#!/usr/bin/env bash
# scripts/check-no-host-paths.sh — bundle gate (CFW-318): fails loudly if any
# `/Users/<anyone>/...` string ships ANYWHERE in the bundle, `.hub/**` and
# `brand-overrides/**` at any nesting depth included. The inverse check of
# what scripts/sync-skills.py's strip_brand_override_host_paths() and
# redact_literal_host_paths() are supposed to guarantee.
#
# Wired into scripts/sync-skills.sh (abort the sync, right after the
# existing check-skills-portability.sh call) and test/run-tests.sh (fail the
# Dozer test gate) so it cannot silently recur.
#
# Scope: a DIFFERENT, narrower concern than check-skills-portability.sh —
# that gate is a bundle-RESOLUTION gate ("will this recipe break on the
# render box"); this one is a "does this bundle leak the author's
# identity/filesystem layout" gate. Kept as a separate script/separate test
# case rather than folded together, same "one script per static guard"
# pattern as check-no-worker-heygen-credential.sh (CFW-313).
#
# Runtime-free repo: bash + python3 only. NO node, NO npm.
#
# Usage:
#   check-no-host-paths.sh [--skills-dir DIR] [recipe ...]
#     --skills-dir DIR   skills root to scan (default: <repo>/skills, or
#                        $CFW_RENDER_SKILLS_DIR if exported)
#     recipe ...         one or more recipe names to scan; if omitted, scan
#                        EVERY recipe dir under --skills-dir
#
# Exit codes:
#   0 = clean — no offending `/Users/<anyone>/...` string found
#   1 = FOUND — at least one offending file:line printed above the summary
#   2 = usage error
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

SKILLS_DIR="${CFW_RENDER_SKILLS_DIR:-$REPO_DIR/skills}"
RECIPES=()
while (( $# )); do
  case "$1" in
    --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
    -*) echo "check-no-host-paths.sh: unknown flag $1" >&2; exit 2 ;;
    *) RECIPES+=("$1"); shift ;;
  esac
done

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "check-no-host-paths.sh: ERROR — skills dir '$SKILLS_DIR' does not exist." >&2
  exit 2
fi

SCAN_ROOTS=()
if (( ${#RECIPES[@]} > 0 )); then
  for r in "${RECIPES[@]}"; do
    if [[ ! -d "$SKILLS_DIR/$r" ]]; then
      echo "check-no-host-paths.sh: ERROR — recipe '$r' not found under $SKILLS_DIR" >&2
      exit 2
    fi
    SCAN_ROOTS+=("$SKILLS_DIR/$r")
  done
else
  shopt -s nullglob
  for d in "$SKILLS_DIR"/*/; do
    SCAN_ROOTS+=("${d%/}")
  done
  shopt -u nullglob
fi

if (( ${#SCAN_ROOTS[@]} == 0 )); then
  echo "check-no-host-paths.sh: PASS — no recipe dirs under $SKILLS_DIR to scan"
  exit 0
fi

OFFENSES="$(python3 - "$SKILLS_DIR" "${SCAN_ROOTS[@]}" <<'PY'
import re
import sys
from pathlib import Path

skills_dir = Path(sys.argv[1])
scan_roots = [Path(p) for p in sys.argv[2:]]

HOST_PATH_RE = re.compile(r'/Users/[A-Za-z0-9_.\-]+(?=/)')

# Tiny explicit allowlist, same shape as check-skills-portability.sh's. Expect
# ZERO entries after CFW-318's rewrite ships — if this gate ever needs an
# allowlist entry, that's a signal the rewrite missed a case, not a reason to
# grow the list (same philosophy CFW-312 already established).
ALLOWLIST_PATH_SUFFIX = ()
ALLOWLIST_TEXT = ()


def is_allowlisted(rel: str, line: str) -> bool:
    return any(rel.endswith(suf) for suf in ALLOWLIST_PATH_SUFFIX) and \
        any(txt in line for txt in ALLOWLIST_TEXT)


offenses = []
seen_files = set()
for root in scan_roots:
    if not root.is_dir():
        continue
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path in seen_files:
            continue
        seen_files.add(path)
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue  # binary file
        try:
            rel = str(path.relative_to(skills_dir))
        except ValueError:
            rel = str(path)
        for lineno, line in enumerate(text.split("\n"), start=1):
            if HOST_PATH_RE.search(line):
                if is_allowlisted(rel, line):
                    continue
                offenses.append(f"{rel}:{lineno}")

for o in offenses:
    print(o)
PY
)"
rc=$?
if (( rc != 0 )); then
  echo "check-no-host-paths.sh: ERROR — scan failed (python3 exit $rc)" >&2
  exit 2
fi

if [[ -n "$OFFENSES" ]]; then
  echo "check-no-host-paths.sh: FAIL — bare host path found (CFW-318):" >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "  $line" >&2
  done <<< "$OFFENSES"
  exit 1
fi

echo "check-no-host-paths.sh: PASS — no bare host path in ${#SCAN_ROOTS[@]} recipe dir(s)"
exit 0
