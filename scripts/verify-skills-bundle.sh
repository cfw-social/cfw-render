#!/usr/bin/env bash
# scripts/verify-skills-bundle.sh — checksum-verify the on-disk skills bundle
# against the per-file sha256 hashes that ship inside the bundle's own
# index.json (skills/index.json.recipes[<recipe>].fileHashes — raw-bytes sha256
# of each file, written by scripts/sync-skills.py when the bundle is synced).
#
# Runtime-free repo: pure bash + shasum/sha256sum + python3 (all already hard
# deps of the worker). NO node, NO npm.
#
# Usage:
#   verify-skills-bundle.sh [--skills-dir DIR] [recipe ...]
#     --skills-dir DIR   skills root to verify (default: <repo>/skills, or
#                        $CFW_RENDER_SKILLS_DIR if exported)
#     recipe ...         one or more recipe names to verify; if omitted, verify
#                        EVERY recipe present in index.json (full-tree sweep —
#                        used pre-tag / by --dry's optional deep check, NOT the
#                        per-tick fast path, which passes just the claimed
#                        order's recipe)
#
# Exit codes (distinct so callers can tell corruption from unverifiable):
#   0 = all requested recipes verify
#   1 = checksum MISMATCH — a pinned file differs from / is missing on disk
#       (the "pull landed mid-tick / corrupted bundle" case → callers BLOCK)
#   3 = no index.json in the skills dir — nothing to verify against
#       (not a published bundle → callers SKIP, non-fatal)
#   4 = a requested recipe is absent from index.json — unverifiable for that
#       recipe (worker may need a redeploy → callers SKIP, non-fatal, but log)
# Precedence when a sweep hits several classes: mismatch(1) > recipe-absent(4).
# Prints expected/actual for every mismatch.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

SKILLS_DIR="${CFW_RENDER_SKILLS_DIR:-$REPO_DIR/skills}"
RECIPES=()
while (( $# )); do
  case "$1" in
    --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
    -*) echo "verify-skills-bundle.sh: unknown flag $1" >&2; exit 2 ;;
    *) RECIPES+=("$1"); shift ;;
  esac
done

# sha256 of raw file bytes -> "sha256:<hex>" (matches publish-github.mjs).
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
  else
    printf 'sha256:%s' "$(shasum -a 256 "$1" | awk '{print $1}')"
  fi
}

INDEX="$SKILLS_DIR/index.json"
if [[ ! -r "$INDEX" ]]; then
  echo "verify-skills-bundle.sh: no index.json at $INDEX — cannot verify (skills dir not a published bundle?)" >&2
  exit 3
fi

# Resolve the recipe list: explicit args, else every recipe in index.json.
if (( ${#RECIPES[@]} == 0 )); then
  mapfile -t RECIPES < <(python3 -c '
import json, sys
idx = json.load(open(sys.argv[1]))
for name in sorted(idx.get("recipes", {})):
    print(name)
' "$INDEX")
fi

mismatch_seen=0
absent_seen=0
verified_recipes=0
verified_files=0

for recipe in "${RECIPES[@]}"; do
  # Pull "<relpath>\t<expected-hash>" lines for this recipe from index.json.
  # A recipe absent from index.json is a hard error (can't verify what isn't
  # pinned) — exit non-zero so the caller treats it as "unverifiable", never
  # as "verified".
  entries="$(python3 -c '
import json, sys
idx = json.load(open(sys.argv[1]))
r = idx.get("recipes", {}).get(sys.argv[2])
if r is None:
    sys.exit(9)
fh = r.get("fileHashes") or {}
for path in sorted(fh):
    print(f"{path}\t{fh[path]}")
' "$INDEX" "$recipe")"
  rc=$?
  if (( rc == 9 )); then
    echo "verify-skills-bundle.sh: recipe '$recipe' not present in $INDEX — unverifiable" >&2
    absent_seen=1
    continue
  elif (( rc != 0 )); then
    echo "verify-skills-bundle.sh: could not read fileHashes for '$recipe' from $INDEX" >&2
    mismatch_seen=1
    continue
  fi

  local_mismatch=0
  local_files=0
  while IFS=$'\t' read -r relpath expected; do
    [[ -z "$relpath" ]] && continue
    local_files=$(( local_files + 1 ))
    ondisk="$SKILLS_DIR/$recipe/$relpath"
    if [[ ! -f "$ondisk" ]]; then
      echo "MISMATCH $recipe/$relpath — expected $expected, actual <file missing on disk>"
      local_mismatch=1
      continue
    fi
    actual="$(_sha256_file "$ondisk")"
    if [[ "$actual" != "$expected" ]]; then
      echo "MISMATCH $recipe/$relpath — expected $expected, actual $actual"
      local_mismatch=1
    fi
  done <<< "$entries"

  if (( local_mismatch )); then
    echo "FAIL $recipe ($local_files files checked, at least one mismatch)"
    mismatch_seen=1
  else
    echo "OK   $recipe ($local_files files verified)"
    verified_recipes=$(( verified_recipes + 1 ))
    verified_files=$(( verified_files + local_files ))
  fi
done

if (( mismatch_seen )); then
  echo "verify-skills-bundle.sh: FAIL — bundle does not match index.json (checksum mismatch)" >&2
  exit 1
fi
if (( absent_seen )); then
  echo "verify-skills-bundle.sh: UNVERIFIABLE — one or more requested recipes are not pinned in index.json" >&2
  exit 4
fi
echo "verify-skills-bundle.sh: PASS — $verified_recipes recipe(s), $verified_files file(s) match index.json"
exit 0
