#!/usr/bin/env bash
# test/sync-skills-out-dir.test.sh — standalone check that scripts/sync-skills.sh
# refuses to write into this repo's frozen skills/ (WI28, owner decision 2026-11-10),
# and that it refuses a run with no --recipes.
# Safe to run alone: no server, no engine, no network, no process stops. It writes
# only to its own temp folder and never to the source library. Every refusal case
# sets CFW_SKILLS_SRC=/nonexistent, so even a refusal that was skipped would stop at the
# source check before anything is written.
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

skills_state() { git -C "$REPO_DIR" status --porcelain --untracked-files=all -- skills config; }
before="$(skills_state)"

# A refusal case: run sync from $1 with the remaining args, expect rc == 2 EXACTLY, the message
# fragment $2, skills/ and config/ unchanged, and (when $3 is set) that path absent.
# usage: expect_refusal <label> <run_dir> <message-fragment> <must-not-exist-or-""> -- <sync args...>
expect_refusal() {
  local label="$1" run_dir="$2" frag="$3" absent="$4"; shift 5
  local out rc
  out="$(cd "$run_dir" && CFW_SKILLS_SRC=/nonexistent "$SYNC" "$@" 2>&1)"; rc=$?
  if [[ "$rc" == "2" && "$out" == *"$frag"* ]]; then pass "$label: refused (rc=2)"; else fail "$label" "rc=$rc out=${out:0:240}"; fi
  if [[ "$(skills_state)" == "$before" ]]; then pass "$label: skills/ and config/ unchanged"; else fail "$label" "skills/ or config/ changed"; fi
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

# 3. a scratch dir succeeds. 3a builds from this repo's fixtures (no private source needed).
out="$(CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$SYNC" --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$WORK/bundle-fixture" 2>&1)"; rc=$?
if [[ "$rc" == "0" && -f "$WORK/bundle-fixture/index.json" ]]; then pass "--out-dir temp dir (fixtures): bundle built (rc=0, index.json present)"; else fail "--out-dir temp dir (fixtures)" "rc=$rc out=${out: -300}"; fi
if [[ "$(skills_state)" == "$before" ]]; then pass "temp-dir build (fixtures): skills/ and config/ unchanged"; else fail "temp-dir build (fixtures)" "skills/ or config/ changed"; fi
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
