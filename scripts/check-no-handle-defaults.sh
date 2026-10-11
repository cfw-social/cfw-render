#!/usr/bin/env bash
# scripts/check-no-handle-defaults.sh — bundle gate (CFW-354): fails loudly if
# any bundled skill ships a LITERAL social handle as a default. The bug this
# ticket fixes: p-reels-spotlight's end card defaulted
# `CTA_HANDLE="${CTA_HANDLE:-@mr.growthguide}"`, so one brand's handle (and
# kicker) was printed on EVERY brand's reels. The end card must be per-brand —
# the handle comes from the order/brand data or is omitted, never baked in.
#
# Wired into scripts/sync-skills.sh (abort the sync, right after the existing
# check-no-host-paths.sh call) and test/run-tests.sh (fail the Dozer test
# gate) so it cannot silently recur.
#
# Scope: a "does this bundle hardcode a brand identity" gate, same
# "one script per static guard" pattern as check-no-host-paths.sh (CFW-318)
# and check-skills-portability.sh (CFW-312). Three rules, scanning every text
# file under the scan roots (`.hub/**` vendored copies included; binaries
# skipped):
#   a. Any shell parameter default whose value starts with `@` —
#      `${VAR:-@…}` / `${VAR-@…}` (e.g. `CTA_HANDLE="${CTA_HANDLE:-@handle}"`).
#      Backslash line-continuations are joined first so a default split across
#      physical lines can't dodge the gate.
#   b. Any JSON-ish literal `"handle": "@…"` — EXCEPT inside
#      `brand-overrides/<slug>/brand.json` (any depth, `.hub/` included), which
#      is legitimate per-brand data.
#   c. The literal `@mr.growthguide` (case-insensitive) or the rendered kicker
#      `MR GROWTH GUIDE` (upper-case only; prose "Mr Growth Guide" is fine)
#      anywhere outside `brand-overrides/**`.
# Prose mentions such as "`@handle` if known" (no `${…:-@…}` shape) are NOT
# flagged — p-reels-faceless/SKILL.md has one and must stay clean.
#
# Runtime-free repo: bash + python3 only. NO node, NO npm.
#
# Usage:
#   check-no-handle-defaults.sh [--skills-dir DIR] [recipe ...]
#     --skills-dir DIR   skills root to scan (default: <repo>/skills, or
#                        $CFW_RENDER_SKILLS_DIR if exported)
#     recipe ...         one or more recipe names to scan; if omitted, scan
#                        EVERY recipe dir under --skills-dir
#
# Exit codes:
#   0 = clean — no literal handle default found
#   1 = FOUND — at least one offending `path:line: <text>` printed above the summary
#   2 = usage error
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

SKILLS_DIR="${CFW_RENDER_SKILLS_DIR:-$REPO_DIR/skills}"
RECIPES=()
while (( $# )); do
  case "$1" in
    --skills-dir)
      if (( $# < 2 )); then
        echo "check-no-handle-defaults.sh: --skills-dir requires a DIR argument" >&2
        exit 2
      fi
      SKILLS_DIR="$2"; shift 2 ;;
    -*) echo "check-no-handle-defaults.sh: unknown flag $1" >&2; exit 2 ;;
    *) RECIPES+=("$1"); shift ;;
  esac
done

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "check-no-handle-defaults.sh: ERROR — skills dir '$SKILLS_DIR' does not exist." >&2
  exit 2
fi

SCAN_ROOTS=()
if (( ${#RECIPES[@]} > 0 )); then
  for r in "${RECIPES[@]}"; do
    if [[ ! -d "$SKILLS_DIR/$r" ]]; then
      echo "check-no-handle-defaults.sh: ERROR — recipe '$r' not found under $SKILLS_DIR" >&2
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
  echo "check-no-handle-defaults.sh: PASS — no recipe dirs under $SKILLS_DIR to scan"
  exit 0
fi

OFFENSES="$(python3 - "$SKILLS_DIR" "${SCAN_ROOTS[@]}" <<'PY'
import re
import sys
from pathlib import Path

skills_dir = Path(sys.argv[1])
scan_roots = [Path(p) for p in sys.argv[2:]]

# Rule a: shell parameter default whose value starts with `@`.
SHELL_DEFAULT_RE = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*:?-@[^}]*\}')
# Rule b: JSON-ish literal handle default.
JSON_HANDLE_RE = re.compile(r'"handle"\s*:\s*"@')
# Rule c: the specific handle AND kicker text that leaked in CFW-354 (the
# end card printed both `@mr.growthguide` and `MR GROWTH GUIDE`).
LEAKED_HANDLE_RE = re.compile(r'@mr\.growthguide', re.IGNORECASE)
# The rendered kicker is upper-case; prose mentions ("Mr Growth Guide") are fine.
LEAKED_KICKER_RE = re.compile(r'MR GROWTH GUIDE')

# brand-overrides/<slug>/brand.json at any depth — legitimate per-brand data.
BRAND_JSON_RE = re.compile(r'(^|/)brand-overrides/[^/]+/brand\.json$')
# anything under brand-overrides/** at any depth.
BRAND_OVERRIDES_RE = re.compile(r'(^|/)brand-overrides/')


def logical_lines(text: str):
    """Yield (starting_line_no, logical_line) pairs, joining any line ending
    in a backslash continuation into its successor so a default split across
    physical lines can't dodge a single-line scan."""
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
        yield start, "".join(buf)
        start = None
        buf = []
    if buf:
        yield start, "".join(buf)


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
        in_brand_overrides = bool(BRAND_OVERRIDES_RE.search(rel))
        is_brand_json = bool(BRAND_JSON_RE.search(rel))
        for lineno, logical in logical_lines(text):
            hit = bool(SHELL_DEFAULT_RE.search(logical))
            if not hit and not is_brand_json:
                hit = bool(JSON_HANDLE_RE.search(logical))
            if not hit and not in_brand_overrides:
                hit = bool(LEAKED_HANDLE_RE.search(logical)) or bool(LEAKED_KICKER_RE.search(logical))
            if hit:
                offenses.append(f"{rel}:{lineno}: {logical.strip()}")

for o in offenses:
    print(o)
PY
)"
rc=$?
if (( rc != 0 )); then
  echo "check-no-handle-defaults.sh: ERROR — scan failed (python3 exit $rc)" >&2
  exit 2
fi

if [[ -n "$OFFENSES" ]]; then
  echo "check-no-handle-defaults.sh: FAIL — literal handle default found (CFW-354):" >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "  $line" >&2
  done <<< "$OFFENSES"
  exit 1
fi

echo "check-no-handle-defaults.sh: PASS — no literal handle default in ${#SCAN_ROOTS[@]} recipe dir(s)"
exit 0
