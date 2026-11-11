#!/usr/bin/env bash
# scripts/check-no-duplicate-steps.sh — bundle gate (WI31.10): fails loudly if a
# recipe carries the same step twice. R-8HZS shipped two copies of spotlight's
# step 4b: the source had gained the section and the sync added its older copy
# beside it, undoing the no-CTA guard. Every other gate passed.
#
# Checks each recipe, and each p-* recipe vendored under its .hub/:
#   - manifest.json steps[].id values are unique
#   - no two numbered files in steps/ share a number
#   - no markdown heading repeats inside one steps/ file (code fences are
#     skipped, so a bash comment is not a heading)
#
# Same "one script per static guard" pattern as check-no-host-paths.sh.
# Runtime-free repo: bash + python3 only. NO node, NO npm.
#
# Usage:
#   check-no-duplicate-steps.sh [--skills-dir DIR] [recipe ...]
#     --skills-dir DIR   skills root to scan (default: <repo>/skills, or
#                        $CFW_RENDER_SKILLS_DIR if exported)
#     recipe ...         recipe names to scan; if omitted, scan EVERY recipe
#                        dir under --skills-dir that has a steps/ folder
#
# Exit codes:
#   0 = clean
#   1 = FOUND — every duplicate printed above the summary
#   2 = usage error, or a named recipe is missing
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

SKILLS_DIR="${CFW_RENDER_SKILLS_DIR:-$REPO_DIR/skills}"
RECIPES=()
while (( $# )); do
  case "$1" in
    --skills-dir)
      [[ $# -ge 2 ]] || { echo "check-no-duplicate-steps.sh: --skills-dir needs a value" >&2; exit 2; }
      SKILLS_DIR="$2"; shift 2 ;;
    -*) echo "check-no-duplicate-steps.sh: unknown option $1" >&2; exit 2 ;;
    *) RECIPES+=("$1"); shift ;;
  esac
done

[[ -d "$SKILLS_DIR" ]] || { echo "check-no-duplicate-steps.sh: no skills dir at $SKILLS_DIR" >&2; exit 2; }

exec python3 -I - "$SKILLS_DIR" ${RECIPES[@]+"${RECIPES[@]}"} <<'PY'
import collections, json, pathlib, re, sys

skills = pathlib.Path(sys.argv[1])
named = sys.argv[2:]
for name in named:
    if not (skills / name / "steps").is_dir():
        print(f"check-no-duplicate-steps.sh: no recipe with steps/ at {skills / name}", file=sys.stderr)
        sys.exit(2)
recipes = [skills / n for n in named] or sorted(p for p in skills.iterdir() if (p / "steps").is_dir())
roots = []
for recipe in recipes:
    roots.append(recipe)
    roots += sorted(p for p in (recipe / ".hub").glob("p-*") if (p / "steps").is_dir())

HEADING = re.compile(r"^#{1,6}\s+\S")
FENCE = re.compile(r"^\s*(```|~~~)")
NUMBERED = re.compile(r"^(\d+)-")
found = []


def repeats(items):
    return [k for k, n in collections.Counter(items).items() if n > 1]


def headings(path):
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced and HEADING.match(line):
            yield line.strip()


for root in roots:
    label = root.relative_to(skills)
    manifest = root / "manifest.json"
    if manifest.is_file():
        ids = [s.get("id") for s in json.loads(manifest.read_text(encoding="utf-8")).get("steps", [])]
        found += [f"{label}/manifest.json: step id {i!r} appears more than once" for i in repeats(ids)]
    files = sorted((root / "steps").glob("*.md"))
    numbers = [m.group(1) for m in (NUMBERED.match(p.name) for p in files) if m]
    found += [f"{label}/steps: two files are numbered {n}" for n in repeats(numbers)]
    for path in files:
        found += [f"{label}/steps/{path.name}: heading repeats: {h}" for h in repeats(list(headings(path)))]

for line in found:
    print(f"DUPLICATE: {line}")
if found:
    print(f"check-no-duplicate-steps.sh: FOUND {len(found)} duplicate(s) in {len(roots)} recipe copies")
    sys.exit(1)
print(f"check-no-duplicate-steps.sh: clean ({len(roots)} recipe copies)")
PY
