#!/usr/bin/env bash
# scripts/check-skills-portability.sh — bundle gate (CFW-312): fails loudly if
# any bundled skill resolves a sub-skill (or itself) via a host-path `find`
# instead of the bundle's own .hub/<dep>/ — the exact bug this ticket fixes.
# Wired into scripts/sync-skills.sh (abort the sync) and test/run-tests.sh
# (fail the Dozer test gate) so it cannot silently recur.
#
# Runtime-free repo: bash + python3 only (python3 is already a hard dep of
# this worker — see verify-skills-bundle.sh). NO node, NO npm. python3 is used
# only to join backslash line-continuations before matching, so a resolver
# split across lines (`find \` + next-line roots, as the real bug's source
# shape sometimes is) can't dodge the gate by splitting "find" and the host
# root onto different physical lines.
#
# Scope: this is a bundle-RESOLUTION gate, not a "never mention a host path"
# gate. It flags the specific idiom that caused CFW-312 — a `find` invocation
# searching a host skill-install root ($HOME/.claude/skills, $HOME/.hermes/*,
# or the source library's own absolute path) — not every line that happens to
# mention one of those strings. A handful of recipes legitimately hardcode the
# SOURCE LIBRARY's absolute path for asset/data lookups that only ever run on
# the author's own machine (c-audio's SFX library doc, c-kie-ai/sync-models.sh's
# output path, c-production's example) — those are out of scope for CFW-312
# (see DOZER-DESIGN-CFW-312.md "Out of scope") and deliberately NOT flagged.
#
# Usage:
#   check-skills-portability.sh [--skills-dir DIR] [recipe ...]
#     --skills-dir DIR   skills root to scan (default: <repo>/skills, or
#                        $CFW_RENDER_SKILLS_DIR if exported)
#     recipe ...         one or more recipe names to scan; if omitted, scan
#                        EVERY recipe dir under --skills-dir
#
# Exit codes:
#   0 = clean — no offending host-path resolver line found
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
    -*) echo "check-skills-portability.sh: unknown flag $1" >&2; exit 2 ;;
    *) RECIPES+=("$1"); shift ;;
  esac
done

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "check-skills-portability.sh: ERROR — skills dir '$SKILLS_DIR' does not exist." >&2
  exit 2
fi

SCAN_ROOTS=()
if (( ${#RECIPES[@]} > 0 )); then
  for r in "${RECIPES[@]}"; do
    if [[ ! -d "$SKILLS_DIR/$r" ]]; then
      echo "check-skills-portability.sh: ERROR — recipe '$r' not found under $SKILLS_DIR" >&2
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
  echo "check-skills-portability.sh: PASS — no recipe dirs under $SKILLS_DIR to scan"
  exit 0
fi

OFFENSES="$(python3 - "$SKILLS_DIR" "${SCAN_ROOTS[@]}" <<'PY'
import re
import sys
from pathlib import Path

skills_dir = Path(sys.argv[1])
scan_roots = [Path(p) for p in sys.argv[2:]]

HOST_ROOT_RE = re.compile(
    r'\$HOME/\.claude|\$HOME/\.hermes|/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills'
)

# The one known, intentionally-kept exception — same shape as the bug but
# CORRECT precedence (.hub/ checked first; host find only as a last-resort
# fallback when the bundle itself is missing c-shorts-qa-gate). Vendored
# byte-for-byte into every recipe's .hub/c-eval-runner/, so match on path
# suffix + exact fallback text rather than a line number (which would drift
# per-copy as unrelated lines above it change). If this allowlist ever needs
# a third entry, that's a signal the rewrite in scripts/sync-skills.py missed
# a case — fix the rewrite, don't grow this list.
ALLOWLIST_PATH_SUFFIX = "c-eval-runner/scripts/eval_run.py"
ALLOWLIST_TEXT = 'find "$HOME/.hermes/skills" "$HOME/.claude/skills" "$HOME/Code/skills"'


def is_allowlisted(rel: str, logical: str) -> bool:
    return rel.endswith(ALLOWLIST_PATH_SUFFIX) and ALLOWLIST_TEXT in logical


def logical_lines(text: str):
    """Yield (starting_line_no, logical_line) pairs, joining any line ending
    in a backslash continuation into its successor so a resolver that splits
    `find` and the host root across lines can't dodge a single-line scan."""
    lines = text.split("\n")
    start = None
    buf = []
    for i, raw in enumerate(lines, start=1):
        if start is None:
            start = i
        if raw.endswith("\\"):
            buf.append(raw[:-1])
            continue
        buf.append(raw)
        yield start, " ".join(buf)
        start = None
        buf = []
    if buf:
        yield start, " ".join(buf)


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
        for lineno, logical in logical_lines(text):
            if "find" in logical and HOST_ROOT_RE.search(logical):
                if is_allowlisted(rel, logical):
                    continue
                offenses.append(f"{rel}:{lineno}")

for o in offenses:
    print(o)
PY
)"
rc=$?
if (( rc != 0 )); then
  echo "check-skills-portability.sh: ERROR — scan failed (python3 exit $rc)" >&2
  exit 2
fi

if [[ -n "$OFFENSES" ]]; then
  echo "check-skills-portability.sh: FAIL — host-path sub-skill resolver found (CFW-312):" >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "  $line" >&2
  done <<< "$OFFENSES"
  exit 1
fi

echo "check-skills-portability.sh: PASS — no host-path sub-skill resolver in ${#SCAN_ROOTS[@]} recipe dir(s)"
exit 0
