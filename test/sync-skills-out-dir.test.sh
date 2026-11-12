#!/usr/bin/env bash
# test/sync-skills-out-dir.test.sh — standalone check that scripts/sync-skills.sh
# refuses to write into this repo's frozen skills/ (WI28, owner decision 2026-11-10),
# and that it refuses a run with no --recipes.
# Safe to run alone: no server, no engine, no network, no process stops. It writes
# only to its own temp folder and never to the source library. Most refusal cases
# set CFW_SKILLS_SRC=/nonexistent, so even a refusal that was skipped would stop at the
# source check before anything is written; the cases that need a source (names, dependsOn, the source
# library as out-dir) run on a temp COPY of test/fixtures/skills-src. "Unchanged" is a hash of the whole
# file list (ignored files included), not git status.
#
#   bash test/sync-skills-out-dir.test.sh
#   CFW_SKILLS_SRC=<path to the harness skills source> bash test/sync-skills-out-dir.test.sh   # also builds from it
#
# The build case (3) runs from this repo's own fixtures, so it needs no private source. With
# CFW_SKILLS_SRC set it also builds from that source (3b); without it, 3b is reported as skipped.
# Cases that need a case-insensitive disk (SKILLS, ./Skills) or a macOS firmlink are reported as
# skipped when this machine has neither; they are not counted as passed.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_DIR/scripts/sync-skills.sh"
REPO_REAL="$(cd "$REPO_DIR" && pwd -P)"
REAL_SRC="${CFW_SKILLS_SRC:-}"

PASS_COUNT=0
FAILURES=0
SKIPPED=0
pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }
skip() { printf '  SKIP  %s — %s\n' "$1" "$2"; SKIPPED=$((SKIPPED+1)); }

WORK="$(mktemp -d)" || { echo "sync-skills-out-dir.test.sh: cannot make a temp folder" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Hash of every file under the given dirs (relative to $REPO_DIR or absolute), ignored files included,
# plus the folder list, so a created or removed file or folder shows.
hash_tree() {
  local d
  for d in "$@"; do
    ( cd "$d" 2>/dev/null || exit 0
      find . -print | LC_ALL=C sort
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null )
  done | shasum -a 256
}
skills_state() { ( cd "$REPO_DIR" && hash_tree skills config ); }
before="$(skills_state)"

# A refusal case: run sync from $2 with the remaining args, expect rc == 2 EXACTLY, the message
# fragment $3, skills/ and config/ unchanged (hashed file list), CASE_HASH_DIR (when set) unchanged, and
# (when $4 is set) that path absent. CASE_SRC is the source for the run (default /nonexistent).
# usage: expect_refusal <label> <run_dir> <message-fragment> <must-not-exist-or-""> -- <sync args...>
expect_refusal() {
  local label="$1" run_dir="$2" frag="$3" absent="$4"; shift 5
  local out rc h0="" h1=""
  [[ -n "${CASE_HASH_DIR:-}" ]] && h0="$(hash_tree "$CASE_HASH_DIR")"
  out="$(cd "$run_dir" && CFW_SKILLS_SRC="${CASE_SRC:-/nonexistent}" "$SYNC" "$@" 2>&1)"; rc=$?
  if [[ "$rc" == "2" && "$out" == *"$frag"* ]]; then pass "$label: refused (rc=2)"; else fail "$label" "rc=$rc out=${out:0:240}"; fi
  if [[ "$(skills_state)" == "$before" ]]; then pass "$label: skills/ and config/ unchanged"; else fail "$label" "skills/ or config/ changed"; fi
  if [[ -n "${CASE_HASH_DIR:-}" ]]; then
    h1="$(hash_tree "$CASE_HASH_DIR")"
    if [[ "$h0" == "$h1" ]]; then pass "$label: $(basename "$CASE_HASH_DIR") unchanged"; else fail "$label" "$CASE_HASH_DIR changed"; fi
  fi
  if [[ -n "$absent" ]]; then
    if [[ ! -e "$absent" ]]; then pass "$label: $absent was not created"; else fail "$label" "$absent exists"; fi
  fi
}

INSIDE="inside this repo's skills/"

# 1. no --out-dir (rc == 2, not just non-zero)
expect_refusal "no --out-dir" "$WORK" "--out-dir is required" "" --

# 2. --out-dir at skills/ — direct, relative, symlink, inside it (2a-2d)
ln -s "$REPO_DIR/skills" "$WORK/skills-link"
expect_refusal "--out-dir direct (2a)"   "$WORK"     "$INSIDE" "" -- --out-dir "$REPO_DIR/skills"
expect_refusal "--out-dir relative (2b)" "$REPO_DIR" "$INSIDE" "" -- --out-dir "skills"
expect_refusal "--out-dir symlink (2c)"  "$WORK"     "$INSIDE" "" -- --out-dir "$WORK/skills-link"
expect_refusal "--out-dir inside (2d)"   "$WORK"     "$INSIDE" "" -- --out-dir "$REPO_DIR/skills/p-carousel"

# 2e. case variants: on a case-insensitive disk (default APFS) SKILLS is skills/. The refusal is by
# file identity, so these must be refused even though the path text differs.
if [[ -d "$REPO_DIR/SKILLS" ]] && [[ "$(stat -f %i "$REPO_DIR/SKILLS" 2>/dev/null || stat -c %i "$REPO_DIR/SKILLS" 2>/dev/null)" == "$(stat -f %i "$REPO_DIR/skills" 2>/dev/null || stat -c %i "$REPO_DIR/skills" 2>/dev/null)" ]]; then
  expect_refusal "--out-dir SKILLS"   "$REPO_DIR" "$INSIDE" ""                      -- --out-dir SKILLS
  expect_refusal "--out-dir SKILLS/x" "$REPO_DIR" "$INSIDE" "$REPO_DIR/skills/x"    -- --out-dir SKILLS/x
  expect_refusal "--out-dir ./Skills" "$REPO_DIR" "$INSIDE" ""                      -- --out-dir ./Skills
  # a symlinked parent that reaches skills/ under a case variant
  ln -s "$REPO_REAL" "$WORK/repo-link"
  expect_refusal "--out-dir symlinked parent + case" "$WORK" "$INSIDE" "$REPO_DIR/skills/x" -- --out-dir "$WORK/repo-link/SKILLS/x"
  # the symlink + `..` + case path: $WORK/l -> skills/p-carousel, so l/../.. is the repo root. A lexical
  # walk (and the realpath string check) both miss it; the kernel writes to skills/x.
  ln -s "$REPO_REAL/skills/p-carousel" "$WORK/l"
  expect_refusal "--out-dir symlink + .. + case" "$WORK" "$INSIDE" "$REPO_DIR/skills/x" -- --out-dir "$WORK/l/../../SKILLS/x"
else
  skip "case-variant --out-dir (SKILLS, SKILLS/x, ./Skills, symlinked parent, symlink + .. + case)" "this disk is case-sensitive"
fi

# 2f. a symlinked parent and the symlink + `..` path, with the real case (any disk)
ln -sfn "$REPO_REAL" "$WORK/repo-link"
expect_refusal "--out-dir symlinked parent" "$WORK" "$INSIDE" "$REPO_DIR/skills/x" -- --out-dir "$WORK/repo-link/skills/x"
ln -sfn "$REPO_REAL/skills/p-carousel" "$WORK/l"
expect_refusal "--out-dir symlink + .." "$WORK" "$INSIDE" "$REPO_DIR/skills/x" -- --out-dir "$WORK/l/../../skills/x"

# 2g. the macOS firmlink path to the same folder (/System/Volumes/Data/<path>)
if [[ -d "/System/Volumes/Data$REPO_REAL/skills" ]]; then
  expect_refusal "--out-dir firmlink" "$WORK" "$INSIDE" "" -- --out-dir "/System/Volumes/Data$REPO_REAL/skills"
  expect_refusal "--out-dir firmlink/x" "$WORK" "$INSIDE" "$REPO_DIR/skills/x" -- --out-dir "/System/Volumes/Data$REPO_REAL/skills/x"
else
  skip "firmlink --out-dir" "no /System/Volumes/Data firmlink on this machine"
fi

# 2h. no --recipes: refused with rc == 2 and the plain message, and nothing is written
expect_refusal "no --recipes" "$WORK" "name only the recipes you publish; config/recipes.json describes the frozen skills/ copy" "$WORK/norecipes" -- --out-dir "$WORK/norecipes"

# 2i. the rest of the repo, and its parent (WI28 round 2): config/, the repo root, test/, a parent of the repo
REPO_MSG="inside this repo"
expect_refusal "--out-dir config"    "$REPO_DIR" "$REPO_MSG" ""                       -- --out-dir config
expect_refusal "--out-dir config/x"  "$REPO_DIR" "$REPO_MSG" "$REPO_DIR/config/x"     -- --out-dir config/x
expect_refusal "--out-dir . (repo root)" "$REPO_DIR" "$REPO_MSG" ""                   -- --out-dir .
expect_refusal "--out-dir test/tmp-x" "$REPO_DIR" "$REPO_MSG" "$REPO_DIR/test/tmp-x"  -- --out-dir test/tmp-x
expect_refusal "--out-dir repo's parent" "$WORK" "parent of this repo" ""             -- --out-dir "$(dirname "$REPO_REAL")"

# a temp COPY of the fixture source (the real fixtures are never the thing under test)
SRC="$WORK/src"; mkdir -p "$SRC" && cp -R "$TEST_DIR/fixtures/skills-src/." "$SRC/"
list_recipes() { python3 -c 'import json,sys; print(json.dumps({"recipes":[{"name":n,"version":"1.0.0","providers":[]} for n in sys.argv[1:]]}))' "$@"; }

# 2j. a recipe named "skills" with the repo root as --out-dir used to reach copy_tree's rmtree
list_recipes skills > "$WORK/r-skills.json"
CASE_SRC="$SRC" CASE_HASH_DIR="$SRC" expect_refusal "recipe 'skills' + --out-dir repo root" "$REPO_DIR" "$REPO_MSG" "" -- --recipes "$WORK/r-skills.json" --out-dir "$REPO_DIR"

# 2k. recipe names that are not plain names (rc 2, the repr of the name, nothing written)
n=0
for bad in '..' 'a/b' '.hidden' "$(printf 'a%.0s' $(seq 1 65))"; do
  n=$((n+1)); list_recipes "$bad" > "$WORK/r-bad$n.json"
  CASE_SRC="$SRC" CASE_HASH_DIR="$SRC" expect_refusal "recipe name '${bad:0:12}'" "$WORK" "invalid recipe name '$bad'" "$WORK/out-bad$n" -- --recipes "$WORK/r-bad$n.json" --out-dir "$WORK/out-bad$n"
done

# 2l. a dependsOn that names ../x (on the temp copy of the source), and one on a LATER recipe
SRC2="$WORK/src2"; mkdir -p "$SRC2" && cp -R "$SRC/." "$SRC2/"
sed -i.bak 's|^dependsOn: \[c-fixture-dep\]|dependsOn: [c-fixture-dep, ../x]|' "$SRC2/p-fixture-recipe/SKILL.md" && rm -f "$SRC2/p-fixture-recipe/SKILL.md.bak"
list_recipes p-fixture-recipe > "$WORK/r-dep.json"
CASE_SRC="$SRC2" CASE_HASH_DIR="$SRC2" expect_refusal "dependsOn '../x'" "$WORK" "invalid dependsOn name '../x'" "$WORK/out-dep" -- --recipes "$WORK/r-dep.json" --out-dir "$WORK/out-dep"
SRC3="$WORK/src3"; mkdir -p "$SRC3" && cp -R "$SRC/." "$SRC3/"
printf -- '---\nname: c-fixture-clean\nkind: component\nvisibility: catalog\ndependsOn: [../x]\n---\n\n# c-fixture-clean\n' > "$SRC3/c-fixture-clean/SKILL.md"
list_recipes p-fixture-recipe c-fixture-clean > "$WORK/r-later.json"
mkdir "$WORK/out-later"
CASE_SRC="$SRC3" CASE_HASH_DIR="$SRC3" expect_refusal "bad dependsOn on a later recipe" "$WORK" "invalid dependsOn name '../x'" "" -- --recipes "$WORK/r-later.json" --out-dir "$WORK/out-later"
if [[ -z "$(ls -A "$WORK/out-later")" ]]; then pass "bad dependsOn on a later recipe: the out-dir is still empty"; else fail "bad dependsOn on a later recipe" "out-dir holds: $(ls -A "$WORK/out-later" | tr '\n' ' ')"; fi

# 2m. the source library as --out-dir (or inside it), a non-empty folder, an existing file
list_recipes p-fixture-recipe > "$WORK/r-one.json"
CASE_SRC="$SRC" CASE_HASH_DIR="$SRC" expect_refusal "--out-dir = the source library" "$WORK" "inside the source library" "" -- --recipes "$WORK/r-one.json" --out-dir "$SRC"
CASE_SRC="$SRC" CASE_HASH_DIR="$SRC" expect_refusal "--out-dir inside the source library" "$WORK" "inside the source library" "$SRC/sub" -- --recipes "$WORK/r-one.json" --out-dir "$SRC/sub"
mkdir "$WORK/full"; echo keep > "$WORK/full/keep.txt"; mkdir "$WORK/full/p-fixture-recipe"; echo keep2 > "$WORK/full/p-fixture-recipe/mine.txt"
CASE_SRC="$SRC" CASE_HASH_DIR="$WORK/full" expect_refusal "non-empty --out-dir" "$WORK" "is not empty" "" -- --recipes "$WORK/r-one.json" --out-dir "$WORK/full"
echo x > "$WORK/afile"
CASE_SRC="$SRC" CASE_HASH_DIR="$WORK/afile" expect_refusal "--out-dir is a file" "$WORK" "is not a directory" "" -- --recipes "$WORK/r-one.json" --out-dir "$WORK/afile"

# 3. a scratch dir succeeds. 3a builds from this repo's fixtures (no private source needed).
out="$(CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$SYNC" --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$WORK/bundle-fixture" 2>&1)"; rc=$?
if [[ "$rc" == "0" && -f "$WORK/bundle-fixture/index.json" ]]; then pass "--out-dir temp dir (fixtures): bundle built (rc=0, index.json present)"; else fail "--out-dir temp dir (fixtures)" "rc=$rc out=${out: -300}"; fi
if [[ "$(skills_state)" == "$before" ]]; then pass "temp-dir build (fixtures): skills/ and config/ unchanged"; else fail "temp-dir build (fixtures)" "skills/ or config/ changed"; fi
# an existing EMPTY folder is fine
mkdir "$WORK/bundle-empty"
out="$(CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$SYNC" --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$WORK/bundle-empty" 2>&1)"; rc=$?
if [[ "$rc" == "0" && -f "$WORK/bundle-empty/index.json" ]]; then pass "--out-dir existing empty folder: bundle built"; else fail "--out-dir existing empty folder" "rc=$rc out=${out: -300}"; fi
# --skip-manifest is still accepted (and ignored): the callers in run-tests.sh pass it.
out="$(CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$SYNC" --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$WORK/bundle-skip" --skip-manifest 2>&1)"; rc=$?
if [[ "$rc" == "0" && -f "$WORK/bundle-skip/index.json" ]]; then pass "--skip-manifest still accepted (no-op)"; else fail "--skip-manifest" "rc=$rc out=${out: -300}"; fi

# 3b. the same against a real source library, when one is named
if [[ -z "$REAL_SRC" ]]; then
  skip "--out-dir temp dir (real source)" "CFW_SKILLS_SRC is not set"
else
  # The source library may have dropped recipes that config/recipes.json still lists (the sync
  # fails loudly on those), so build from the allowlist entries the source actually has.
  python3 - "$REPO_DIR/config/recipes.json" "$REAL_SRC" "$WORK/recipes.json" <<'PY'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
cfg["recipes"] = [r for r in cfg["recipes"] if os.path.isdir(os.path.join(sys.argv[2], r["name"]))]
json.dump(cfg, open(sys.argv[3], "w"))
PY
  out="$(CFW_SKILLS_SRC="$REAL_SRC" "$SYNC" --recipes "$WORK/recipes.json" --out-dir "$WORK/bundle" 2>&1)"; rc=$?
  if [[ "$rc" == "0" && -f "$WORK/bundle/index.json" ]]; then pass "--out-dir temp dir (real source): bundle built (rc=0, index.json present)"; else fail "--out-dir temp dir (real source)" "rc=$rc out=${out: -300}"; fi
  if [[ "$(skills_state)" == "$before" ]]; then pass "temp-dir build (real source): skills/ and config/ unchanged"; else fail "temp-dir build (real source)" "skills/ or config/ changed"; fi
fi

echo "sync-skills-out-dir.test.sh: $PASS_COUNT passed, $FAILURES failed, $SKIPPED skipped"
(( FAILURES == 0 ))
